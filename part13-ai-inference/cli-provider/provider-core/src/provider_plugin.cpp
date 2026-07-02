#include "provider_plugin.h"
#include "logos_api.h"
#include "logos_api_client.h"
#include "logos_object.h"

#include <QDebug>
#include <QElapsedTimer>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonParseError>
#include <QProcess>
#include <QTimer>
#include <QUuid>

// Must match the inference user (part13 inference-core / inference-ui).
static const QString TOPIC_PREFIX = "/inference/1/";
static const QString TOPIC_SUFFIX = "/json";

ProviderPlugin::ProviderPlugin(QObject* parent)
    : QObject(parent)
    , m_id("cli-llm-" + QUuid::createUuid().toString(QUuid::WithoutBraces).left(4))
    , m_model(qEnvironmentVariable("INFERENCE_MODEL", "tinyllama"))
    , m_ollamaUrl(qEnvironmentVariable("OLLAMA_URL", "http://localhost:11434"))
{
    qDebug() << "ProviderPlugin: created, id =" << m_id
             << "model =" << m_model << "ollama =" << m_ollamaUrl;
}

ProviderPlugin::~ProviderPlugin() = default;

void ProviderPlugin::initLogos(LogosAPI* api)
{
    logosAPI = api;
    qDebug() << "ProviderPlugin: LogosAPI wired up";
}

bool ProviderPlugin::start(const QString& room)
{
    const QString clean = room.trimmed().isEmpty() ? QStringLiteral("lobby") : room.trimmed();

    if (m_started) {
        if (clean != m_room && m_deliveryClient) {
            invokeBool("unsubscribe", "unsubscribe", topicForRoom(m_room));
            m_room = clean;
            invokeBool("subscribe", "subscribe", topicForRoom(m_room));
        }
        return true;
    }
    m_room = clean;

    m_deliveryClient = logosAPI->getClient("delivery_module");
    if (!m_deliveryClient) {
        qWarning() << "ProviderPlugin: delivery_module client unavailable";
        return false;
    }

    if (!m_createNodeDone) {
        // Default to tcpPort 60010 so a standalone CLI node doesn't collide with a
        // co-running Basecamp delivery node on 60000. Override with INFERENCE_TCPPORT.
        QJsonObject cfgObj;
        cfgObj["logLevel"] = "INFO";
        cfgObj["mode"]     = "Core";
        cfgObj["preset"]   = "logos.dev";
        int customPort = qEnvironmentVariableIntValue("INFERENCE_TCPPORT");
        if (customPort <= 0) customPort = 60010;
        cfgObj["tcpPort"]       = customPort;
        cfgObj["discv5UdpPort"] = 9000 + (customPort - 60000);
        const QString cfg = QString::fromUtf8(
            QJsonDocument(cfgObj).toJson(QJsonDocument::Compact));
        if (!invokeBool("createNode", "createNode", cfg)) return false;
        m_createNodeDone = true;
    }

    // Register the inbound handler BEFORE start so we don't miss anything.
    m_deliveryObject = m_deliveryClient->requestObject("delivery_module");
    if (m_deliveryObject) {
        m_deliveryClient->onEvent(m_deliveryObject, "messageReceived",
            [this](const QString&, const QVariantList& data) {
                handleMessageReceived(data);
            });
    } else {
        qWarning() << "ProviderPlugin: no delivery_module object — cannot hear prompts";
        return false;
    }

    if (!invokeBool("start", "start")) return false;
    m_started = true;

    if (!invokeBool("subscribe", "subscribe", topicForRoom(m_room))) return false;

    qDebug() << "ProviderPlugin:" << m_id << "listening on" << topicForRoom(m_room)
             << "model" << m_model;
    emit eventResponse("listening", QVariantList{ m_room, m_id, m_model });
    return true;
}

bool ProviderPlugin::stop()
{
    if (!m_started) return true;
    if (m_deliveryClient) {
        invokeBool("unsubscribe", "unsubscribe", topicForRoom(m_room));
        invokeBool("stop", "stop");
    }
    m_deliveryObject = nullptr;
    m_started = false;
    return true;
}

QString ProviderPlugin::stats()
{
    QJsonObject o;
    o["id"]            = m_id;
    o["room"]          = m_room;
    o["listening"]     = m_started;
    o["model"]         = m_model;
    o["promptsSeen"]   = m_promptsSeen;
    o["responsesSent"] = m_responsesSent;
    o["lastPromptId"]  = m_lastPromptId;
    o["lastFrom"]      = m_lastFrom;
    return QString::fromUtf8(QJsonDocument(o).toJson(QJsonDocument::Compact));
}

QString ProviderPlugin::providerId() { return m_id; }

QString ProviderPlugin::topicForRoom(const QString& room) const
{
    return TOPIC_PREFIX + room + TOPIC_SUFFIX;
}

void ProviderPlugin::handleMessageReceived(const QVariantList& data)
{
    // delivery_module.messageReceived: [hash, contentTopic, payload_base64, ts_ns]
    if (data.size() < 3) return;

    const QString topic = data[1].toString();
    if (topic != topicForRoom(m_room)) return;

    const QByteArray payload =
        QByteArray::fromBase64(data[2].toString().toUtf8());

    QJsonParseError err{};
    const QJsonDocument doc = QJsonDocument::fromJson(payload, &err);
    if (err.error != QJsonParseError::NoError || !doc.isObject()) return;

    const QJsonObject obj = doc.object();
    if (obj.value("type").toString() != "prompt") return;   // only answer prompts

    const QString id     = obj.value("id").toString();
    const QString from   = obj.value("from").toString();
    const QString prompt = obj.value("prompt").toString();
    if (id.isEmpty() || prompt.isEmpty()) return;

    ++m_promptsSeen;
    m_lastPromptId = id;
    m_lastFrom     = from;
    qDebug() << "ProviderPlugin: prompt" << id << "from" << from
             << "→ running" << m_model;

    // Defer the inference so we don't block (and don't re-enter delivery_module
    // from inside its own event dispatch — delivery-guide gotcha #9). The actual
    // ollama call is async (QProcess), so it never blocks the event loop either.
    const QString topicCopy = topic;
    QTimer::singleShot(0, this, [this, id, from, prompt, topicCopy]() {
        runInference(id, from, prompt, topicCopy);
    });
}

void ProviderPlugin::runInference(const QString& id, const QString& from,
                                  const QString& prompt, const QString& topic)
{
    // Ask ollama via its HTTP API (the server is already running on $OLLAMA_URL).
    // We shell out to curl rather than link Qt Network, and pass the request body
    // on stdin (curl -d @-) so the prompt needs no shell escaping.
    QJsonObject req;
    req["model"]  = m_model;
    req["prompt"] = prompt;
    req["stream"] = false;
    const QByteArray body = QJsonDocument(req).toJson(QJsonDocument::Compact);
    const QString url = m_ollamaUrl + "/api/generate";

    auto* proc  = new QProcess(this);
    auto* timer = new QElapsedTimer;
    timer->start();

    connect(proc, &QProcess::finished, this,
        [this, proc, timer, id, from, topic](int exitCode, QProcess::ExitStatus) {
            const qint64 ms = timer->elapsed();
            delete timer;
            const QByteArray out = proc->readAllStandardOutput();
            const QByteArray errOut = proc->readAllStandardError();
            proc->deleteLater();

            QString text;
            QJsonParseError e{};
            const QJsonDocument d = QJsonDocument::fromJson(out, &e);
            if (e.error == QJsonParseError::NoError && d.isObject()) {
                const QJsonObject o = d.object();
                text = o.value("response").toString();
                if (text.isEmpty() && o.contains("error"))
                    text = "[model error] " + o.value("error").toString();
            }
            if (text.isEmpty()) {
                qWarning() << "ProviderPlugin: empty/invalid ollama reply (exit" << exitCode
                           << "):" << out.left(200) << errOut.left(200);
                text = "[inference failed — is ollama running and the model pulled?]";
            }
            qDebug() << "ProviderPlugin: inference for" << id << "done in" << ms
                     << "ms," << text.size() << "chars";
            sendResponse(id, from, text.trimmed(), topic);
        });

    // curl is at /usr/bin/curl on macOS / standard on Linux — on the base PATH.
    proc->start("curl", { "-sS", "--max-time", "180", url, "-d", "@-" });
    proc->write(body);
    proc->closeWriteChannel();
}

void ProviderPlugin::sendResponse(const QString& id, const QString& from,
                                  const QString& text, const QString& topic)
{
    if (!m_deliveryClient) return;
    QJsonObject resp;
    resp["type"]  = "response";
    resp["id"]    = id;
    resp["from"]  = m_id;
    resp["to"]    = from;
    resp["text"]  = text;
    resp["model"] = m_model;
    const QString payload = QString::fromUtf8(
        QJsonDocument(resp).toJson(QJsonDocument::Compact));

    const QVariant r = m_deliveryClient->invokeRemoteMethod(
        "delivery_module", "send", topic, payload);
    if (r.isValid()) {
        ++m_responsesSent;
        emit eventResponse("responseSent", QVariantList{ id, from });
    } else {
        qWarning() << "ProviderPlugin: response send RPC failed for" << id;
    }
}

bool ProviderPlugin::invokeBool(const char* what,
                                const QString& method,
                                const QVariant& arg)
{
    const QVariant r = arg.isValid()
        ? m_deliveryClient->invokeRemoteMethod("delivery_module", method, arg)
        : m_deliveryClient->invokeRemoteMethod("delivery_module", method);
    if (!r.isValid()) {
        qWarning() << "ProviderPlugin:" << what << "RPC failed (invalid QVariant)";
        return false;
    }
    if (r.canConvert<LogosResult>()) {
        const LogosResult lr = r.value<LogosResult>();
        if (!lr.success) {
            qWarning() << "ProviderPlugin:" << what << "failed:" << lr.error.toString();
            return false;
        }
        return true;
    }
    if (!r.toBool()) {
        qWarning() << "ProviderPlugin:" << what << "returned false:" << r;
        return false;
    }
    return true;
}
