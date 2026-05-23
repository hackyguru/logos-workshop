#include "shared_color_plugin.h"
#include "logos_api.h"
#include "logos_api_client.h"
#include "logos_object.h"

#include <QDateTime>
#include <QDebug>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonParseError>
#include <QTimer>
#include <QUuid>

// Single shared topic — every peer joins the same one.
// /<app>/<version>/<subtopic>/<format> per LIP-23.
static const QString TOPIC = "/shared-color/1/main/json";

SharedColorPlugin::SharedColorPlugin(QObject* parent)
    : QObject(parent)
    , m_myId(QUuid::createUuid().toString(QUuid::WithoutBraces))
{
    qDebug() << "SharedColorPlugin: created, myId =" << m_myId;
}

SharedColorPlugin::~SharedColorPlugin() = default;

void SharedColorPlugin::initLogos(LogosAPI* api)
{
    logosAPI = api;
    qDebug() << "SharedColorPlugin: LogosAPI wired up";
}

// ── Delivery lifecycle ───────────────────────────────────────────────

bool SharedColorPlugin::startDelivery()
{
    if (m_started) return true;

    // Mark "connecting" before start() — the connectionStateChanged event may
    // fire synchronously during start(), and we'd clobber it if we set status
    // after.
    setDeliveryStatus(1);

    m_deliveryClient = logosAPI->getClient("delivery_module");
    if (!m_deliveryClient) {
        qWarning() << "SharedColorPlugin: delivery_module client unavailable";
        setDeliveryStatus(3);
        return false;
    }

    if (!m_createNodeDone) {
        // logos.dev preset: cluster 2, auto-sharded, built-in bootstrap peers.
        // BUT: the bundled logos.dev bootstrap peer IDs are stale upstream —
        // libp2p dials them, gets a different PeerID back, drops with a noise
        // mismatch, and we never reach "Connected". Same-machine peers won't
        // discover each other through that broken fleet, so colors don't sync.
        //
        // Same fix as xAlisher/scorched-earth-basecamp: hand-pick two
        // deterministic nodeKeys (instance A=…1f20, instance B=…1f21) so each
        // peer's libp2p PeerID is known up front, then list the sibling in
        // `staticNodes` so they dial each other directly over loopback. We
        // keep the logos.dev preset so wider-network discovery is still
        // attempted, but local sync no longer depends on it.
        //
        // SHARED_COLOR_TCPPORT unset → instance A (port 60000, key …1f20).
        // SHARED_COLOR_TCPPORT=60001 → instance B (port 60001, key …1f21).
        const int  customPort  = qEnvironmentVariableIntValue("SHARED_COLOR_TCPPORT");
        const bool isInstanceB = (customPort > 0);
        const int  tcpPort     = isInstanceB ? customPort        : 60000;
        const int  udpPort     = isInstanceB ? 9000 + (tcpPort - 60000) : 9000;

        // Keys + their deterministic PeerIDs — verified against scorched-earth.
        static const QString KEY_A    = "0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20";
        static const QString KEY_B    = "0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f21";
        static const QString PEERID_A = "16Uiu2HAm4Ms862Gnqafssgvik4JJ1LuqWMcKNipq4nm2UaoLRbeP";
        static const QString PEERID_B = "16Uiu2HAmAD6tSgCQZNS1aNwyQS94ud45VoW7uXdw7UhiCwp247iq";

        const QString nodeKey = isInstanceB ? KEY_B : KEY_A;
        const QString peerMultiAddr = isInstanceB
            ? QString("/ip4/127.0.0.1/tcp/60000/p2p/%1").arg(PEERID_A)
            : QString("/ip4/127.0.0.1/tcp/60001/p2p/%1").arg(PEERID_B);

        QJsonObject cfgObj;
        cfgObj["logLevel"]      = "INFO";
        cfgObj["mode"]          = "Core";
        cfgObj["preset"]        = "logos.dev";
        cfgObj["relay"]         = true;  // gossipsub layer — required for same-shard message relay
        cfgObj["tcpPort"]       = tcpPort;
        cfgObj["discv5UdpPort"] = udpPort;
        cfgObj["nodeKey"]       = nodeKey;
        cfgObj["staticNodes"]   = QJsonArray{ peerMultiAddr };

        qDebug() << "SharedColorPlugin: instance" << (isInstanceB ? "B" : "A")
                 << "tcpPort=" << tcpPort << "udpPort=" << udpPort
                 << "staticPeer=" << peerMultiAddr;

        const QString cfg = QString::fromUtf8(
            QJsonDocument(cfgObj).toJson(QJsonDocument::Compact));
        if (!invokeBool("createNode", "createNode", cfg)) {
            setDeliveryStatus(3);
            return false;
        }
        m_createNodeDone = true;
    }

    // Register handlers BEFORE start() so we don't miss the first
    // connectionStateChanged event.
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
                // Match "Connected" and "PartiallyConnected" (per-shard variant).
                if (status.contains("Connected", Qt::CaseInsensitive)) {
                    setDeliveryStatus(2);
                } else if (!status.isEmpty()) {
                    setDeliveryStatus(1);
                }
                // NB: subscribe is NOT triggered from here — it runs
                // synchronously right after start() below, matching the
                // scorched-earth/tictactoe pattern. Subscribing twice (once
                // here, once in startDelivery) used to race and could leave
                // gossipsub mesh formation half-built; that's the asymmetric
                // "A→B works, B→A doesn't" symptom.
            });

        m_deliveryClient->onEvent(m_deliveryObject, "messageError",
            [](const QString&, const QVariantList& data) {
                if (data.size() >= 3)
                    qWarning() << "shared_color: delivery send error:" << data[2];
            });
    } else {
        qWarning() << "SharedColorPlugin: no delivery_module object — events will be missed";
    }

    if (!invokeBool("start", "start")) {
        setDeliveryStatus(3);
        return false;
    }

    // Subscribe synchronously, right after start, BEFORE marking m_started.
    // Why sync here when polling defers via QTimer: gossipsub uses the
    // order-of-events around subscribe to decide mesh membership for a
    // topic. With staticNodes and 2 peers, deferring subscribe creates a
    // window where the libp2p connection is up but neither side has
    // announced its subscription yet — gossipsub falls back to fanout-only
    // for the late peer, and you see the asymmetric "A→B works, B→A doesn't"
    // bug. Sync subscribe matches the scorched-earth/tictactoe pattern that's
    // known to give symmetric mesh formation.
    if (!invokeBool("subscribe", "subscribe", TOPIC)) {
        setDeliveryStatus(3);
        return false;
    }
    m_subscribed = true;
    m_started    = true;

    // Optimistic flip — only relevant when running solo (no second peer to
    // dial). With a sibling instance reachable via staticNodes, the real
    // connectionStateChanged event will fire shortly and confirm Connected.
    if (m_deliveryStatus < 2) setDeliveryStatus(2);
    return true;
}

bool SharedColorPlugin::stopDelivery()
{
    if (!m_started) return true;

    if (m_deliveryClient) {
        if (m_subscribed) {
            m_deliveryClient->invokeRemoteMethod(
                "delivery_module", "unsubscribe", TOPIC);
            m_subscribed = false;
        }
        invokeBool("stop", "stop");
    }

    m_deliveryObject = nullptr;
    m_started        = false;
    setDeliveryStatus(0);
    return true;
}

int SharedColorPlugin::deliveryStatus() { return m_deliveryStatus; }

// ── Color ────────────────────────────────────────────────────────────

bool SharedColorPlugin::setColor(const QString& hex)
{
    const QString h = hex.trimmed();
    if (h.isEmpty()) return false;
    if (!m_started && !startDelivery()) return false;

    const qint64 ts = QDateTime::currentMSecsSinceEpoch();

    // Apply locally first (optimistic) and emit so the UI updates instantly,
    // even before the message round-trips through gossipsub.
    m_currentColor    = h;
    m_currentSenderId = m_myId;
    m_currentTs       = ts;
    emit eventResponse("colorChanged", QVariantList{ h, m_myId });

    return broadcastColor(h, ts);
}

QString SharedColorPlugin::currentColor()    { return m_currentColor; }
QString SharedColorPlugin::currentSenderId() { return m_currentSenderId; }
QString SharedColorPlugin::myId()            { return m_myId; }

// ── Private ──────────────────────────────────────────────────────────

bool SharedColorPlugin::broadcastColor(const QString& hex, qint64 ts)
{
    if (!m_deliveryClient) return false;

    QJsonObject obj;
    obj["color"]    = hex;
    obj["senderId"] = m_myId;
    obj["ts"]       = ts;
    const QString payload = QString::fromUtf8(
        QJsonDocument(obj).toJson(QJsonDocument::Compact));

    const QVariant r = m_deliveryClient->invokeRemoteMethod(
        "delivery_module", "send", TOPIC, payload);
    if (!r.isValid()) {
        qWarning() << "SharedColorPlugin: delivery_module.send RPC failed";
        return false;
    }
    return true;
}

void SharedColorPlugin::handleMessageReceived(const QVariantList& data)
{
    // delivery_module.messageReceived: [hash, contentTopic, payload_base64, ts_ns]
    if (data.size() < 3) return;
    if (data[1].toString() != TOPIC) return;

    const QByteArray payload =
        QByteArray::fromBase64(data[2].toString().toUtf8());

    QJsonParseError err{};
    const QJsonDocument doc = QJsonDocument::fromJson(payload, &err);
    if (err.error != QJsonParseError::NoError || !doc.isObject()) {
        qWarning() << "SharedColorPlugin: invalid JSON payload:" << payload;
        return;
    }
    const QJsonObject obj    = doc.object();
    const QString     hex    = obj.value("color").toString();
    const QString     sender = obj.value("senderId").toString();
    const qint64      ts     = static_cast<qint64>(obj.value("ts").toDouble());
    if (hex.isEmpty()) return;

    // Last-write-wins by sender-supplied timestamp. Without this, two peers
    // who click at roughly the same time can converge to different colors
    // depending on gossipsub delivery order. Ties are broken by sender id
    // so every peer agrees on the winner.
    if (ts < m_currentTs) return;
    if (ts == m_currentTs && sender <= m_currentSenderId) return;

    m_currentColor    = hex;
    m_currentSenderId = sender;
    m_currentTs       = ts;
    emit eventResponse("colorChanged", QVariantList{ hex, sender });
}

void SharedColorPlugin::setDeliveryStatus(int status)
{
    if (m_deliveryStatus == status) return;
    m_deliveryStatus = status;
    emit eventResponse("deliveryStatusChanged", QVariantList{ status });
}

bool SharedColorPlugin::invokeBool(const char* what,
                                   const QString& method,
                                   const QVariant& arg)
{
    const QVariant r = arg.isValid()
        ? m_deliveryClient->invokeRemoteMethod("delivery_module", method, arg)
        : m_deliveryClient->invokeRemoteMethod("delivery_module", method);
    if (!r.isValid()) {
        // delivery_module v1.0.0 declares start() as `void`, so the QtRO RPC
        // returns an invalid QVariant on every successful call. Treat that as
        // benign for `start` — the real readiness signal arrives later via
        // connectionStateChanged. Other methods get the strict check.
        if (method == QStringLiteral("start")) {
            qDebug() << "SharedColorPlugin: start RPC returned void (v1.0.0 behavior); waiting on connectionStateChanged";
            return true;
        }
        qWarning() << "SharedColorPlugin:" << what << "RPC failed (invalid QVariant)";
        return false;
    }
    // Newer delivery_module returns LogosResult; QVariant::toBool() on the
    // wrapped struct silently returns false, so unwrap properly first.
    if (r.canConvert<LogosResult>()) {
        const LogosResult lr = r.value<LogosResult>();
        if (!lr.success) {
            qWarning() << "SharedColorPlugin:" << what << "failed:" << lr.error.toString();
            return false;
        }
        return true;
    }
    if (!r.toBool()) {
        qWarning() << "SharedColorPlugin:" << what << "returned false:" << r;
        return false;
    }
    return true;
}
