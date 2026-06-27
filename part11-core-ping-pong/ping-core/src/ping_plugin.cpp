#include "ping_plugin.h"
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
// See https://lip.logos.co/messaging/informational/23/topics.html#content-topics
// The responder (logoscore CLI ponger) subscribes to the exact same topic.
static const QString TOPIC_PREFIX = "/pingpong/1/";
static const QString TOPIC_SUFFIX = "/json";

PingPlugin::PingPlugin(QObject* parent)
    : QObject(parent)
    , m_myId(QUuid::createUuid().toString(QUuid::WithoutBraces).left(8))
{
    qDebug() << "PingPlugin: created, myId =" << m_myId;
}

PingPlugin::~PingPlugin() = default;

void PingPlugin::initLogos(LogosAPI* api)
{
    logosAPI = api;
    qDebug() << "PingPlugin: LogosAPI wired up";
}

qint64 PingPlugin::nowMs()
{
    return QDateTime::currentMSecsSinceEpoch();
}

// ── Delivery lifecycle ───────────────────────────────────────────────

bool PingPlugin::startDelivery()
{
    if (m_started) return true;

    // Mark "connecting" upfront. connectionStateChanged may fire synchronously
    // inside start() below — if we set status after start(), we'd clobber it.
    setDeliveryStatus(1);

    m_deliveryClient = logosAPI->getClient("delivery_module");
    if (!m_deliveryClient) {
        qWarning() << "PingPlugin: delivery_module client unavailable";
        setDeliveryStatus(3);
        return false;
    }

    // createNode is "call once per process" — skip it on re-Start.
    if (!m_createNodeDone) {
        // logos.dev preset = cluster 2, built-in bootstrap nodes, auto-sharded.
        // Running a second Basecamp on one machine? Set PINGPONG_TCPPORT=60003
        // (or any free port) to avoid the 60000 port clash.
        QJsonObject cfgObj;
        cfgObj["logLevel"] = "INFO";
        cfgObj["mode"]     = "Core";
        cfgObj["preset"]   = "logos.dev";
        const int customPort = qEnvironmentVariableIntValue("PINGPONG_TCPPORT");
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

    // Register event handlers BEFORE start so we don't miss the first event.
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
                if (data.size() >= 3) qWarning() << "ping: delivery send error:" << data[2];
            });
    } else {
        qWarning() << "PingPlugin: no delivery_module object — events will be missed";
    }

    if (!invokeBool("start", "start")) {
        setDeliveryStatus(3);
        return false;
    }
    m_started = true;

    // Subscribe to the current room's topic.
    if (invokeBool("subscribe", "subscribe", topicForRoom(m_room))) {
        m_subscribed = true;
        qDebug() << "PingPlugin: subscribed to" << topicForRoom(m_room);
    }

    // Optimistically flip to "connected (locally up)". The real
    // connectionStateChanged from delivery_module can take 1–2 minutes (and is
    // flaky on logos.dev's stale bootstrap peers). Treat start() succeeding as
    // ready for the workshop UX; the event handler can still adjust us. Same
    // rationale as part3-polling.
    if (m_deliveryStatus < 2) setDeliveryStatus(2);
    return true;
}

bool PingPlugin::stopDelivery()
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

int PingPlugin::deliveryStatus() { return m_deliveryStatus; }

// ── Rooms ────────────────────────────────────────────────────────────

bool PingPlugin::joinRoom(const QString& room)
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
    qDebug() << "PingPlugin: joined room" << m_room << "topic" << topicForRoom(m_room);
    emit eventResponse("roomChanged", QVariantList{ m_room });
    return true;
}

QString PingPlugin::room() { return m_room; }

// ── Ping ─────────────────────────────────────────────────────────────

QString PingPlugin::sendPing()
{
    if (!m_started && !startDelivery()) return QString();

    PingRec rec;
    rec.id     = QUuid::createUuid().toString(QUuid::WithoutBraces).left(8);
    rec.sentMs = nowMs();
    m_pings.prepend(rec);

    QJsonObject obj;
    obj["type"] = "ping";
    obj["id"]   = rec.id;
    obj["from"] = m_myId;
    obj["ts"]   = rec.sentMs;
    const QString payload = QString::fromUtf8(
        QJsonDocument(obj).toJson(QJsonDocument::Compact));

    const QVariant r = m_deliveryClient->invokeRemoteMethod(
        "delivery_module", "send", topicForRoom(m_room), payload);
    if (!r.isValid()) {
        qWarning() << "PingPlugin: delivery_module.send RPC failed";
        // Keep the record so the UI shows the attempt; it just never gets ponged.
    }

    qDebug() << "PingPlugin: sent ping" << rec.id << "to" << topicForRoom(m_room);
    emit eventResponse("pingSent", QVariantList{ rec.id, m_room });
    return rec.id;
}

// ── Query helpers ────────────────────────────────────────────────────

QString PingPlugin::listExchanges()
{
    QJsonArray arr;
    const qint64 now = nowMs();
    for (const PingRec& p : m_pings) {
        QJsonObject o;
        o["id"]     = p.id;
        o["sentMs"] = p.sentMs;
        o["ageMs"]  = now - p.sentMs;
        o["ponged"] = p.ponged;
        o["rttMs"]  = static_cast<double>(p.rttMs);
        o["ponger"] = p.ponger;
        arr.append(o);
    }
    return QString::fromUtf8(QJsonDocument(arr).toJson(QJsonDocument::Compact));
}

bool PingPlugin::clearExchanges()
{
    m_pings.clear();
    emit eventResponse("cleared", QVariantList{});
    return true;
}

QString PingPlugin::myId() { return m_myId; }

// ── Private helpers ──────────────────────────────────────────────────

QString PingPlugin::topicForRoom(const QString& room) const
{
    return TOPIC_PREFIX + room + TOPIC_SUFFIX;
}

void PingPlugin::handleMessageReceived(const QVariantList& data)
{
    // delivery_module.messageReceived layout:
    //   data[0] QString — message hash
    //   data[1] QString — content topic
    //   data[2] QString — payload (base64)
    //   data[3] QString — timestamp (ns since epoch)
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

    // We only care about pongs that answer one of our pings. (We never echo our
    // own pings back over gossipsub, and we deliberately don't answer others'
    // pings — that's the responder's job.)
    if (type != "pong") return;

    const QString id   = obj.value("id").toString();
    const QString from = obj.value("from").toString();
    if (id.isEmpty()) return;

    for (PingRec& p : m_pings) {
        if (p.id == id && !p.ponged) {
            p.ponged = true;
            p.rttMs  = nowMs() - p.sentMs;
            p.ponger = from;
            qDebug() << "PingPlugin: pong for" << id << "from" << from
                     << "rtt" << p.rttMs << "ms";
            emit eventResponse("pongReceived",
                QVariantList{ id, from, static_cast<double>(p.rttMs) });
            return;
        }
    }
}

void PingPlugin::setDeliveryStatus(int status)
{
    if (m_deliveryStatus == status) return;
    m_deliveryStatus = status;
    emit eventResponse("deliveryStatusChanged", QVariantList{ status });
}

bool PingPlugin::invokeBool(const char* what,
                            const QString& method,
                            const QVariant& arg)
{
    const QVariant r = arg.isValid()
        ? m_deliveryClient->invokeRemoteMethod("delivery_module", method, arg)
        : m_deliveryClient->invokeRemoteMethod("delivery_module", method);
    if (!r.isValid()) {
        qWarning() << "PingPlugin:" << what << "RPC failed (invalid QVariant)";
        return false;
    }
    // Newer delivery_module returns LogosResult instead of a plain bool; unwrap
    // and check `.success`. Fall back to the legacy bool path for older builds.
    if (r.canConvert<LogosResult>()) {
        const LogosResult lr = r.value<LogosResult>();
        if (!lr.success) {
            qWarning() << "PingPlugin:" << what << "failed:" << lr.error.toString();
            return false;
        }
        return true;
    }
    if (!r.toBool()) {
        qWarning() << "PingPlugin:" << what << "returned false:" << r;
        return false;
    }
    return true;
}
