#include "pong_plugin.h"
#include "logos_api.h"
#include "logos_api_client.h"
#include "logos_object.h"

#include <QDebug>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonParseError>
#include <QTimer>
#include <QUuid>

// Must match the pinger (part11 ping-core / ping-ui).
static const QString TOPIC_PREFIX = "/pingpong/1/";
static const QString TOPIC_SUFFIX = "/json";

PongPlugin::PongPlugin(QObject* parent)
    : QObject(parent)
    , m_id("cli-pong-" + QUuid::createUuid().toString(QUuid::WithoutBraces).left(4))
{
    qDebug() << "PongPlugin: created, id =" << m_id;
}

PongPlugin::~PongPlugin() = default;

void PongPlugin::initLogos(LogosAPI* api)
{
    logosAPI = api;
    qDebug() << "PongPlugin: LogosAPI wired up";
}

bool PongPlugin::start(const QString& room)
{
    const QString clean = room.trimmed().isEmpty() ? QStringLiteral("lobby") : room.trimmed();

    if (m_started) {
        // Already running — just (re)subscribe if the room changed.
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
        qWarning() << "PongPlugin: delivery_module client unavailable";
        return false;
    }

    if (!m_createNodeDone) {
        // Default to tcpPort 60010 so a standalone CLI node doesn't collide with
        // a co-running Basecamp's delivery node on 60000. Override with
        // PINGPONG_TCPPORT. (discv5 UDP derived as 9000 + offset.)
        QJsonObject cfgObj;
        cfgObj["logLevel"] = "INFO";
        cfgObj["mode"]     = "Core";
        cfgObj["preset"]   = "logos.dev";
        int customPort = qEnvironmentVariableIntValue("PINGPONG_TCPPORT");
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
        qWarning() << "PongPlugin: no delivery_module object — cannot hear pings";
        return false;
    }

    if (!invokeBool("start", "start")) return false;
    m_started = true;

    if (!invokeBool("subscribe", "subscribe", topicForRoom(m_room))) return false;

    qDebug() << "PongPlugin:" << m_id << "listening on" << topicForRoom(m_room);
    emit eventResponse("listening", QVariantList{ m_room, m_id });
    return true;
}

bool PongPlugin::stop()
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

QString PongPlugin::stats()
{
    QJsonObject o;
    o["id"]         = m_id;
    o["room"]       = m_room;
    o["listening"]  = m_started;
    o["pingsSeen"]  = m_pingsSeen;
    o["pongsSent"]  = m_pongsSent;
    o["lastPingId"] = m_lastPingId;
    o["lastFrom"]   = m_lastFrom;
    return QString::fromUtf8(QJsonDocument(o).toJson(QJsonDocument::Compact));
}

QString PongPlugin::responderId() { return m_id; }

QString PongPlugin::topicForRoom(const QString& room) const
{
    return TOPIC_PREFIX + room + TOPIC_SUFFIX;
}

void PongPlugin::handleMessageReceived(const QVariantList& data)
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
    if (obj.value("type").toString() != "ping") return;   // only answer pings

    const QString id   = obj.value("id").toString();
    const QString from = obj.value("from").toString();
    if (id.isEmpty()) return;

    ++m_pingsSeen;
    m_lastPingId = id;
    m_lastFrom   = from;
    qDebug() << "PongPlugin: ping" << id << "from" << from << "→ replying pong";

    // Build the pong, then send it DEFERRED — calling delivery_module.send
    // synchronously from inside its own event dispatch re-enters the module and
    // deadlocks the main thread (delivery-guide gotcha #9).
    QJsonObject resp;
    resp["type"] = "pong";
    resp["id"]   = id;
    resp["from"] = m_id;
    resp["to"]   = from;
    const QString respPayload = QString::fromUtf8(
        QJsonDocument(resp).toJson(QJsonDocument::Compact));
    const QString topicCopy = topic;
    QTimer::singleShot(0, this, [this, topicCopy, respPayload]() {
        if (!m_deliveryClient) return;
        const QVariant r = m_deliveryClient->invokeRemoteMethod(
            "delivery_module", "send", topicCopy, respPayload);
        if (r.isValid()) {
            ++m_pongsSent;
            emit eventResponse("pongSent", QVariantList{ m_lastPingId, m_lastFrom });
        } else {
            qWarning() << "PongPlugin: pong send RPC failed";
        }
    });
}

bool PongPlugin::invokeBool(const char* what,
                            const QString& method,
                            const QVariant& arg)
{
    const QVariant r = arg.isValid()
        ? m_deliveryClient->invokeRemoteMethod("delivery_module", method, arg)
        : m_deliveryClient->invokeRemoteMethod("delivery_module", method);
    if (!r.isValid()) {
        qWarning() << "PongPlugin:" << what << "RPC failed (invalid QVariant)";
        return false;
    }
    if (r.canConvert<LogosResult>()) {
        const LogosResult lr = r.value<LogosResult>();
        if (!lr.success) {
            qWarning() << "PongPlugin:" << what << "failed:" << lr.error.toString();
            return false;
        }
        return true;
    }
    if (!r.toBool()) {
        qWarning() << "PongPlugin:" << what << "returned false:" << r;
        return false;
    }
    return true;
}
