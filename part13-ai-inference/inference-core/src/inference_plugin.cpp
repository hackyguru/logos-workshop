#include "inference_plugin.h"
#include "logos_api.h"
#include "logos_api_client.h"
#include "logos_object.h"

#include <QDateTime>
#include <QDebug>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonParseError>
#include <QUuid>

// Content-topic format: /<app>/<version>/<subtopic>/<format>
// The inference provider (logoscore CLI) subscribes to the exact same topic.
static const QString TOPIC_PREFIX = "/inference/1/";
static const QString TOPIC_SUFFIX = "/json";

InferencePlugin::InferencePlugin(QObject* parent)
    : QObject(parent)
    , m_myId(QUuid::createUuid().toString(QUuid::WithoutBraces).left(8))
{
    qDebug() << "InferencePlugin: created, myId =" << m_myId;
}

InferencePlugin::~InferencePlugin() = default;

void InferencePlugin::initLogos(LogosAPI* api)
{
    logosAPI = api;
    qDebug() << "InferencePlugin: LogosAPI wired up";
}

qint64 InferencePlugin::nowMs()
{
    return QDateTime::currentMSecsSinceEpoch();
}

// ── Delivery lifecycle ───────────────────────────────────────────────

bool InferencePlugin::startDelivery()
{
    if (m_started) return true;

    // connectionStateChanged can fire synchronously inside start(); mark
    // "connecting" first so we don't clobber a later "Connected".
    setDeliveryStatus(1);

    m_deliveryClient = logosAPI->getClient("delivery_module");
    if (!m_deliveryClient) {
        qWarning() << "InferencePlugin: delivery_module client unavailable";
        setDeliveryStatus(3);
        return false;
    }

    // createNode is "call once per process" — skip it on re-Start.
    if (!m_createNodeDone) {
        QJsonObject cfgObj;
        cfgObj["logLevel"] = "INFO";
        cfgObj["mode"]     = "Core";
        cfgObj["preset"]   = "logos.dev";
        // Running a second delivery node on one machine? Override the port.
        const int customPort = qEnvironmentVariableIntValue("INFERENCE_TCPPORT");
        if (customPort > 0) {
            cfgObj["tcpPort"]       = customPort;
            cfgObj["discv5UdpPort"] = 9000 + (customPort - 60000);
        }
        const QString cfg = QString::fromUtf8(
            QJsonDocument(cfgObj).toJson(QJsonDocument::Compact));
        if (!invokeBool("createNode", "createNode", cfg)) {
            setDeliveryStatus(3);
            return false;
        }
        m_createNodeDone = true;
    }

    // Register the inbound handler BEFORE start so we don't miss the first event.
    m_deliveryObject = m_deliveryClient->requestObject("delivery_module");
    if (m_deliveryObject) {
        m_deliveryClient->onEvent(m_deliveryObject, "messageReceived",
            [this](const QString&, const QVariantList& data) {
                handleMessageReceived(data);
            });

        m_deliveryClient->onEvent(m_deliveryObject, "connectionStateChanged",
            [this](const QString&, const QVariantList& data) {
                if (data.isEmpty()) return;
                const QString status = data[0].toString();
                if (status.contains("Connected", Qt::CaseInsensitive)) {
                    setDeliveryStatus(2);
                } else if (!status.isEmpty()) {
                    setDeliveryStatus(1);
                }
            });

        m_deliveryClient->onEvent(m_deliveryObject, "messageError",
            [](const QString&, const QVariantList& data) {
                if (data.size() >= 3) qWarning() << "inference: delivery send error:" << data[2];
            });
    } else {
        qWarning() << "InferencePlugin: no delivery_module object — events will be missed";
    }

    if (!invokeBool("start", "start")) {
        setDeliveryStatus(3);
        return false;
    }
    m_started = true;

    if (invokeBool("subscribe", "subscribe", topicForRoom(m_room))) {
        m_subscribed = true;
        qDebug() << "InferencePlugin: subscribed to" << topicForRoom(m_room);
    }

    // Optimistically flip to "connected (locally up)" — the real
    // connectionStateChanged can take a while (and is flaky on logos.dev's
    // bootstrap). Same rationale as part3-polling / part11.
    if (m_deliveryStatus < 2) setDeliveryStatus(2);
    return true;
}

bool InferencePlugin::stopDelivery()
{
    if (!m_started) return true;

    if (m_deliveryClient) {
        if (m_subscribed) {
            m_deliveryClient->invokeRemoteMethod(
                "delivery_module", "unsubscribe", topicForRoom(m_room));
        }
        invokeBool("stop", "stop");
    }

    m_deliveryObject = nullptr;
    m_started        = false;
    m_subscribed     = false;
    setDeliveryStatus(0);
    return true;
}

int InferencePlugin::deliveryStatus() { return m_deliveryStatus; }

// ── Rooms ────────────────────────────────────────────────────────────

bool InferencePlugin::joinRoom(const QString& room)
{
    const QString clean = room.trimmed();
    if (clean.isEmpty() || clean == m_room) return true;

    if (m_started && m_deliveryClient) {
        if (m_subscribed) {
            m_deliveryClient->invokeRemoteMethod(
                "delivery_module", "unsubscribe", topicForRoom(m_room));
            m_subscribed = false;
        }
        if (invokeBool("subscribe", "subscribe", topicForRoom(clean))) {
            m_subscribed = true;
        }
    }
    m_room = clean;
    qDebug() << "InferencePlugin: joined room" << m_room << "topic" << topicForRoom(m_room);
    emit eventResponse("roomChanged", QVariantList{ m_room });
    return true;
}

QString InferencePlugin::room() { return m_room; }

// ── Prompt ───────────────────────────────────────────────────────────

QString InferencePlugin::sendPrompt(const QString& prompt)
{
    const QString text = prompt.trimmed();
    if (text.isEmpty()) return QString();
    if (!m_started && !startDelivery()) return QString();

    PromptRec rec;
    rec.id     = QUuid::createUuid().toString(QUuid::WithoutBraces).left(8);
    rec.prompt = text;
    rec.sentMs = nowMs();
    m_prompts.prepend(rec);

    QJsonObject obj;
    obj["type"]   = "prompt";
    obj["id"]     = rec.id;
    obj["from"]   = m_myId;
    obj["ts"]     = rec.sentMs;
    obj["prompt"] = text;
    const QString payload = QString::fromUtf8(
        QJsonDocument(obj).toJson(QJsonDocument::Compact));

    const QVariant r = m_deliveryClient->invokeRemoteMethod(
        "delivery_module", "send", topicForRoom(m_room), payload);
    if (!r.isValid()) {
        qWarning() << "InferencePlugin: delivery_module.send RPC failed";
    }

    qDebug() << "InferencePlugin: sent prompt" << rec.id << "to" << topicForRoom(m_room);
    emit eventResponse("promptSent", QVariantList{ rec.id, m_room });
    return rec.id;
}

// ── Query helpers ────────────────────────────────────────────────────

QString InferencePlugin::listExchanges()
{
    QJsonArray arr;
    const qint64 now = nowMs();
    for (const PromptRec& p : m_prompts) {
        QJsonObject o;
        o["id"]       = p.id;
        o["prompt"]   = p.prompt;
        o["sentMs"]   = p.sentMs;
        o["ageMs"]    = now - p.sentMs;
        o["answered"] = p.answered;
        o["rttMs"]    = static_cast<double>(p.rttMs);
        o["text"]     = p.text;
        o["provider"] = p.provider;
        o["model"]    = p.model;
        arr.append(o);
    }
    return QString::fromUtf8(QJsonDocument(arr).toJson(QJsonDocument::Compact));
}

bool InferencePlugin::clearExchanges()
{
    m_prompts.clear();
    emit eventResponse("cleared", QVariantList{});
    return true;
}

QString InferencePlugin::myId() { return m_myId; }

// ── Private helpers ──────────────────────────────────────────────────

QString InferencePlugin::topicForRoom(const QString& room) const
{
    return TOPIC_PREFIX + room + TOPIC_SUFFIX;
}

void InferencePlugin::handleMessageReceived(const QVariantList& data)
{
    // delivery_module.messageReceived: [hash, contentTopic, payload_base64, ts_ns]
    if (data.size() < 3) return;

    const QString topic = data[1].toString();
    if (topic != topicForRoom(m_room)) return;   // not our room

    const QByteArray payload =
        QByteArray::fromBase64(data[2].toString().toUtf8());

    QJsonParseError err{};
    const QJsonDocument doc = QJsonDocument::fromJson(payload, &err);
    if (err.error != QJsonParseError::NoError || !doc.isObject()) return;

    const QJsonObject obj  = doc.object();
    const QString     type = obj.value("type").toString();

    // We only care about responses to one of our prompts. (We never echo our own
    // prompts back over gossipsub, and answering prompts is the provider's job.)
    if (type != "response") return;

    const QString id   = obj.value("id").toString();
    const QString from = obj.value("from").toString();
    if (id.isEmpty()) return;

    for (PromptRec& p : m_prompts) {
        if (p.id == id && !p.answered) {
            p.answered = true;
            p.rttMs    = nowMs() - p.sentMs;
            p.text     = obj.value("text").toString();
            p.provider = from;
            p.model    = obj.value("model").toString();
            qDebug() << "InferencePlugin: response for" << id << "from" << from
                     << "rtt" << p.rttMs << "ms" << "(" << p.text.size() << "chars )";
            emit eventResponse("responseReceived",
                QVariantList{ id, from, static_cast<double>(p.rttMs) });
            return;
        }
    }
}

void InferencePlugin::setDeliveryStatus(int status)
{
    if (m_deliveryStatus == status) return;
    m_deliveryStatus = status;
    emit eventResponse("deliveryStatusChanged", QVariantList{ status });
}

bool InferencePlugin::invokeBool(const char* what,
                                 const QString& method,
                                 const QVariant& arg)
{
    const QVariant r = arg.isValid()
        ? m_deliveryClient->invokeRemoteMethod("delivery_module", method, arg)
        : m_deliveryClient->invokeRemoteMethod("delivery_module", method);
    if (!r.isValid()) {
        qWarning() << "InferencePlugin:" << what << "RPC failed (invalid QVariant)";
        return false;
    }
    if (r.canConvert<LogosResult>()) {
        const LogosResult lr = r.value<LogosResult>();
        if (!lr.success) {
            qWarning() << "InferencePlugin:" << what << "failed:" << lr.error.toString();
            return false;
        }
        return true;
    }
    if (!r.toBool()) {
        qWarning() << "InferencePlugin:" << what << "returned false:" << r;
        return false;
    }
    return true;
}
