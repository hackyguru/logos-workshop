#include "inference_plugin.h"

#include <QByteArray>
#include <QDebug>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonParseError>

// Content-topic format: /<app>/<version>/<subtopic>/<format>
// See https://lip.logos.co/messaging/informational/23/topics.html#content-topics
static const QString PROMPT_TOPIC = "/inference/1/prompt/json";
static const QString REPLY_PREFIX = "/inference/1/reply-";
static const QString REPLY_SUFFIX = "/json";

InferencePlugin::InferencePlugin(QObject* parent)
    : QObject(parent)
{
    qDebug() << "InferencePlugin: created";
}

InferencePlugin::~InferencePlugin() = default;

void InferencePlugin::initLogos(LogosAPI* api)
{
    logosAPI = api;
    qDebug() << "InferencePlugin: LogosAPI wired up";
}

// ── Delivery lifecycle ───────────────────────────────────────────────

bool InferencePlugin::start()
{
    if (m_started) return true;

    // Mark "connecting" before start() — connectionStateChanged can fire
    // synchronously inside start(), and we don't want to clobber it.
    setStatus(1);

    m_deliveryClient = logosAPI->getClient("delivery_module");
    if (!m_deliveryClient) {
        qWarning() << "InferencePlugin: delivery_module client unavailable";
        setStatus(3);
        return false;
    }

    if (!m_createNodeDone) {
        // logos.dev preset = cluster 2, built-in bootstrap nodes, auto-sharded.
        // Set INFERENCE_TCPPORT=60001 (etc.) on a second node on the same machine
        // to avoid the default 60000 TCP / 9000 UDP clash.
        QJsonObject cfgObj;
        cfgObj["logLevel"] = "INFO";
        cfgObj["mode"]     = "Core";
        cfgObj["preset"]   = "logos.dev";
        const int customPort = qEnvironmentVariableIntValue("INFERENCE_TCPPORT");
        if (customPort > 0) {
            cfgObj["tcpPort"]       = customPort;
            cfgObj["discv5UdpPort"] = 9000 + (customPort - 60000);
            qDebug() << "InferencePlugin: custom tcpPort" << customPort;
        }
        const QString cfg = QString::fromUtf8(
            QJsonDocument(cfgObj).toJson(QJsonDocument::Compact));
        if (!invokeBool("createNode", "createNode", cfg)) {
            setStatus(3);
            return false;
        }
        m_createNodeDone = true;
    }

    // Register handlers BEFORE start() so the first events aren't missed.
    m_deliveryObject = m_deliveryClient->requestObject("delivery_module");
    if (m_deliveryObject) {
        m_deliveryClient->onEvent(m_deliveryObject, "messageReceived",
            [this](const QString&, const QVariantList& data) {
                handleMessageReceived(data);
            });

        m_deliveryClient->onEvent(m_deliveryObject, "connectionStateChanged",
            [this](const QString&, const QVariantList& data) {
                if (data.isEmpty()) return;
                const QString s = data[0].toString();
                if (s.contains("Connected", Qt::CaseInsensitive)) setStatus(2);
                else if (!s.isEmpty()) setStatus(1);
            });

        m_deliveryClient->onEvent(m_deliveryObject, "messageError",
            [](const QString&, const QVariantList& data) {
                if (data.size() >= 3) qWarning() << "inference: send error:" << data[2];
            });
    } else {
        qWarning() << "InferencePlugin: no delivery_module object — events will be missed";
    }

    if (!invokeBool("start", "start")) {
        setStatus(3);
        return false;
    }

    // Responder: receive every prompt anyone publishes on the prompt topic.
    invokeBool("subscribe", "subscribe", PROMPT_TOPIC);

    m_started = true;
    // Optimistic "connected": the logos.dev preset's bootstrap peers don't
    // currently handshake, so connectionStateChanged may never reach
    // "Connected" against the public network even though start() succeeded.
    // Self-echo over gossipsub still works, so a single-node demo functions.
    if (m_status < 2) setStatus(2);
    qDebug() << "InferencePlugin: listening on" << PROMPT_TOPIC;
    return true;
}

bool InferencePlugin::stop()
{
    if (!m_started) return true;

    if (m_deliveryClient) {
        invokeBool("unsubscribe", "unsubscribe", PROMPT_TOPIC);
        for (const QString& rt : m_replySubs) {
            m_deliveryClient->invokeRemoteMethod("delivery_module", "unsubscribe", rt);
        }
        invokeBool("stop", "stop");
    }

    m_replySubs.clear();
    m_deliveryObject = nullptr;
    m_started        = false;
    setStatus(0);
    return true;
}

int InferencePlugin::status() { return m_status; }

// ── Responder side ───────────────────────────────────────────────────

QString InferencePlugin::takePending()
{
    const QString out = wrapJson(m_pending);
    m_pending.clear();   // keep m_seenPrompts so re-echoes after drain aren't re-queued
    return out;
}

bool InferencePlugin::reply(const QString& replyTopic,
                            const QString& id,
                            const QString& answer)
{
    if (!m_deliveryClient) return false;

    QJsonObject obj;
    obj["id"]     = id;
    obj["answer"] = answer;
    const QString payload = QString::fromUtf8(
        QJsonDocument(obj).toJson(QJsonDocument::Compact));

    const QVariant r = m_deliveryClient->invokeRemoteMethod(
        "delivery_module", "send", replyTopic, payload);
    if (!r.isValid()) {
        qWarning() << "InferencePlugin: reply send RPC failed";
        return false;
    }
    return true;
}

// ── Requester side ───────────────────────────────────────────────────

bool InferencePlugin::ask(const QString& id, const QString& prompt)
{
    if (id.isEmpty()) return false;
    if (!m_started && !start()) return false;

    // Subscribe to this request's reply topic before publishing, so we don't
    // miss a fast answer.
    const QString rt = replyTopicFor(id);
    invokeBool("subscribe", "subscribe", rt);
    m_replySubs.insert(rt);

    QJsonObject obj;
    obj["id"]     = id;
    obj["prompt"] = prompt;
    obj["reply"]  = rt;
    const QString payload = QString::fromUtf8(
        QJsonDocument(obj).toJson(QJsonDocument::Compact));

    const QVariant r = m_deliveryClient->invokeRemoteMethod(
        "delivery_module", "send", PROMPT_TOPIC, payload);
    if (!r.isValid()) {
        qWarning() << "InferencePlugin: ask send RPC failed";
        return false;
    }
    return true;
}

QString InferencePlugin::takeReplies()
{
    const QString out = wrapJson(m_replies);
    m_replies.clear();
    return out;
}

// ── Private helpers ──────────────────────────────────────────────────

QString InferencePlugin::replyTopicFor(const QString& id) const
{
    return REPLY_PREFIX + id + REPLY_SUFFIX;
}

void InferencePlugin::handleMessageReceived(const QVariantList& data)
{
    // delivery_module.messageReceived layout:
    //   data[0] hash, data[1] contentTopic, data[2] payload(base64), data[3] timestamp_ns
    if (data.size() < 3) return;

    const QString    topic   = data[1].toString();
    const QByteArray payload = QByteArray::fromBase64(data[2].toString().toUtf8());

    QJsonParseError err{};
    const QJsonDocument doc = QJsonDocument::fromJson(payload, &err);
    if (err.error != QJsonParseError::NoError || !doc.isObject()) return;
    const QJsonObject obj = doc.object();

    const QString id = obj.value("id").toString();
    if (id.isEmpty()) return;

    // NOTE: we only ever QUEUE here — never send. Calling delivery_module.send
    // synchronously from inside its own event dispatch deadlocks the main
    // thread (delivery guide, Gotcha #9). reply()/ask() send from separate
    // RPC calls, which is safe.
    if (topic == PROMPT_TOPIC) {
        if (m_seenPrompts.contains(id)) return;
        m_seenPrompts.insert(id);
        QJsonObject e;
        e["id"]     = id;
        e["prompt"] = obj.value("prompt").toString();
        e["reply"]  = obj.value("reply").toString();
        m_pending.append(e);
        qDebug() << "InferencePlugin: queued prompt" << id;
    } else if (topic.startsWith(REPLY_PREFIX) && topic.endsWith(REPLY_SUFFIX)) {
        if (m_seenReplies.contains(id)) return;
        m_seenReplies.insert(id);
        QJsonObject e;
        e["id"]     = id;
        e["answer"] = obj.value("answer").toString();
        m_replies.append(e);
        qDebug() << "InferencePlugin: queued reply" << id;
    }
}

void InferencePlugin::setStatus(int status)
{
    if (m_status == status) return;
    m_status = status;
    emit eventResponse("statusChanged", QVariantList{ status });
}

// Sentinel-wrapped, base64-encoded JSON. The `infer` CLI greps for
// INFERJSON:<base64>:ENDJSON regardless of how `logoscore call` decorates
// stdout, then base64-decodes — robust against any prompt/answer content.
QString InferencePlugin::wrapJson(const QList<QJsonObject>& items) const
{
    QJsonArray arr;
    for (const QJsonObject& o : items) arr.append(o);
    const QByteArray j = QJsonDocument(arr).toJson(QJsonDocument::Compact);
    return "INFERJSON:" + QString::fromLatin1(j.toBase64()) + ":ENDJSON";
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
    // Newer delivery_module returns LogosResult instead of a plain bool;
    // r.toBool() is always false on the wrapped struct, so unwrap it first.
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
