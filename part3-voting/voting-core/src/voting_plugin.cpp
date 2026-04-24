#include "voting_plugin.h"
#include "logos_api.h"
#include "logos_api_client.h"
#include "logos_object.h"

#include <QDebug>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonParseError>
#include <QTimer>
#include <QUuid>

// Content-topic format: /<app>/<version>/<subtopic>/<format>
// See https://lip.logos.co/messaging/informational/23/topics.html#content-topics
static const QString TOPIC_PREFIX = "/voting/1/poll-";
static const QString TOPIC_SUFFIX = "/json";

VotingPlugin::VotingPlugin(QObject* parent)
    : QObject(parent)
    , m_voterId(QUuid::createUuid().toString(QUuid::WithoutBraces))
{
    qDebug() << "VotingPlugin: created, voterId =" << m_voterId;
}

VotingPlugin::~VotingPlugin() = default;

void VotingPlugin::initLogos(LogosAPI* api)
{
    logosAPI = api;
    qDebug() << "VotingPlugin: LogosAPI wired up";
}

// ── Delivery lifecycle ───────────────────────────────────────────────

bool VotingPlugin::startDelivery()
{
    if (m_started) return true;

    // Mark "connecting" upfront. The connectionStateChanged event may fire
    // synchronously during start() below — if we set status to 1 AFTER start(),
    // we'd clobber a "Connected" update from the event handler.
    setDeliveryStatus(1);

    m_deliveryClient = logosAPI->getClient("delivery_module");
    if (!m_deliveryClient) {
        qWarning() << "VotingPlugin: delivery_module client unavailable";
        setDeliveryStatus(3);
        return false;
    }

    // logos.dev preset = cluster 2, built-in bootstrap nodes, auto-sharded.
    // See DeliveryModulePlugin::createNode docstring in logos-co/logos-delivery-module.
    // For running two Basecamps on one machine, set VOTING_TCPPORT=60001 (or
    // any free port) on the second instance to avoid the 60000 port clash.
    // Individual config keys override the preset's defaults.
    QJsonObject cfgObj;
    cfgObj["logLevel"] = "INFO";
    cfgObj["mode"]     = "Core";
    cfgObj["preset"]   = "logos.dev";
    const int customPort = qEnvironmentVariableIntValue("VOTING_TCPPORT");
    if (customPort > 0) {
        cfgObj["tcpPort"]       = customPort;
        // discv5 uses its own UDP port (default 9000). Auto-derive a unique one
        // so a second instance doesn't collide with the first's UDP bind.
        // 60001 → 9001, 60002 → 9002, etc.
        const int udpPort = 9000 + (customPort - 60000);
        cfgObj["discv5UdpPort"] = udpPort;
        qDebug() << "VotingPlugin: using custom tcpPort" << customPort
                 << "and discv5UdpPort" << udpPort
                 << "(from VOTING_TCPPORT env)";
    }
    const QString cfg = QString::fromUtf8(
        QJsonDocument(cfgObj).toJson(QJsonDocument::Compact));
    if (!invokeBool("createNode", "createNode", cfg)) {
        setDeliveryStatus(3);
        return false;
    }

    // Register event handlers BEFORE start so we don't miss the first connectionStateChanged.
    m_deliveryObject = m_deliveryClient->requestObject("delivery_module");
    if (m_deliveryObject) {
        m_deliveryClient->onEvent(m_deliveryObject, "messageReceived",
            [this](const QString&, const QVariantList& data) {
                handleMessageReceived(data);
            });

        m_deliveryClient->onEvent(m_deliveryObject, "connectionStateChanged",
            [this](const QString&, const QVariantList& data) {
                // data[0] is a status string. Current liblogosdelivery emits
                // "Connected" | "PartiallyConnected" | "Connecting" | "Disconnected" —
                // the "Partially…" variant was added when the Waku node started
                // surfacing per-shard connectivity independently. Treat any
                // non-empty "…connected" string as green.
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
                if (data.size() >= 3) qWarning() << "voting: delivery send error:" << data[2];
            });
    } else {
        qWarning() << "VotingPlugin: no delivery_module object — events will be missed";
    }

    if (!invokeBool("start", "start")) {
        setDeliveryStatus(3);
        return false;
    }

    m_started = true;
    // Do NOT set status here — the event handler already did (or will).
    return true;
}

bool VotingPlugin::stopDelivery()
{
    if (!m_started) return true;

    if (m_deliveryClient) {
        for (auto it = m_polls.constBegin(); it != m_polls.constEnd(); ++it) {
            m_deliveryClient->invokeRemoteMethod(
                "delivery_module", "unsubscribe", topicFor(it.key()));
        }
        invokeBool("stop", "stop");
    }

    m_deliveryObject = nullptr;
    m_started        = false;
    setDeliveryStatus(0);
    return true;
}

int VotingPlugin::deliveryStatus() { return m_deliveryStatus; }

// ── Polls ────────────────────────────────────────────────────────────

bool VotingPlugin::openPoll(const QString& pollId, const QString& question)
{
    if (pollId.isEmpty()) return false;
    if (!m_started && !startDelivery()) return false;

    if (m_polls.contains(pollId)) {
        if (!question.isEmpty()) m_polls[pollId].question = question;
        emit eventResponse("pollOpened",
            QVariantList{ pollId, m_polls[pollId].question });
        return true;
    }

    m_polls.insert(pollId, PollState{ question, {} });
    if (!invokeBool("subscribe", "subscribe", topicFor(pollId))) {
        m_polls.remove(pollId);
        return false;
    }

    qDebug() << "VotingPlugin: opened poll" << pollId << "topic" << topicFor(pollId);
    emit eventResponse("pollOpened", QVariantList{ pollId, question });

    // Request/announce on open:
    //   - If we know the question → broadcast an announce so subscribed peers pick it up.
    //   - If we don't → broadcast a requestQuestion; any peer who knows it replies
    //     with an announce and we adopt it.
    if (m_started) {
        QJsonObject obj;
        if (!question.isEmpty()) {
            obj["type"]     = "announce";
            obj["question"] = question;
        } else {
            obj["type"] = "requestQuestion";
        }
        const QString payload = QString::fromUtf8(
            QJsonDocument(obj).toJson(QJsonDocument::Compact));
        m_deliveryClient->invokeRemoteMethod(
            "delivery_module", "send", topicFor(pollId), payload);
    }
    return true;
}

bool VotingPlugin::closePoll(const QString& pollId)
{
    if (!m_polls.contains(pollId)) return false;

    if (m_deliveryClient) {
        invokeBool("unsubscribe", "unsubscribe", topicFor(pollId));
    }
    m_polls.remove(pollId);
    emit eventResponse("pollClosed", QVariantList{ pollId });
    return true;
}

bool VotingPlugin::vote(const QString& pollId, bool yes)
{
    if (!m_polls.contains(pollId)) return false;
    if (!m_started) return false;

    // Optimistic local update — also covers offline use.
    m_polls[pollId].votes.insert(m_voterId, yes);
    emit eventResponse("voteReceived", QVariantList{ pollId, m_voterId, yes });

    QJsonObject obj;
    obj["type"]  = "vote";
    obj["voter"] = m_voterId;
    obj["yes"]   = yes;
    // Piggyback the question — joiners who missed the announce still learn
    // it as soon as they see any vote come in.
    if (!m_polls[pollId].question.isEmpty()) {
        obj["question"] = m_polls[pollId].question;
    }
    const QString payload = QString::fromUtf8(
        QJsonDocument(obj).toJson(QJsonDocument::Compact));

    const QVariant r = m_deliveryClient->invokeRemoteMethod(
        "delivery_module", "send", topicFor(pollId), payload);
    if (!r.isValid()) {
        qWarning() << "VotingPlugin: delivery_module.send RPC failed";
        return false;
    }
    return true;
}

// ── Query helpers ────────────────────────────────────────────────────

QString VotingPlugin::listPolls()
{
    QJsonArray arr;
    for (auto it = m_polls.constBegin(); it != m_polls.constEnd(); ++it) {
        int yes = 0, no = 0;
        for (bool v : it.value().votes.values()) {
            if (v) ++yes; else ++no;
        }
        QJsonObject o;
        o["id"]       = it.key();
        o["question"] = it.value().question;
        o["yes"]      = yes;
        o["no"]       = no;
        o["total"]    = yes + no;
        o["myVote"]   = it.value().votes.contains(m_voterId)
            ? (it.value().votes[m_voterId] ? QStringLiteral("yes") : QStringLiteral("no"))
            : QString();
        arr.append(o);
    }
    return QString::fromUtf8(QJsonDocument(arr).toJson(QJsonDocument::Compact));
}

QString VotingPlugin::tally(const QString& pollId)
{
    QJsonObject o;
    o["id"] = pollId;
    if (!m_polls.contains(pollId)) {
        o["error"] = "poll not open";
        return QString::fromUtf8(QJsonDocument(o).toJson(QJsonDocument::Compact));
    }
    int yes = 0, no = 0;
    for (bool v : m_polls[pollId].votes.values()) {
        if (v) ++yes; else ++no;
    }
    o["yes"]   = yes;
    o["no"]    = no;
    o["total"] = yes + no;
    return QString::fromUtf8(QJsonDocument(o).toJson(QJsonDocument::Compact));
}

QString VotingPlugin::myVoterId() { return m_voterId; }

// ── Private helpers ──────────────────────────────────────────────────

QString VotingPlugin::topicFor(const QString& pollId) const
{
    return TOPIC_PREFIX + pollId + TOPIC_SUFFIX;
}

QString VotingPlugin::pollIdFromTopic(const QString& topic) const
{
    if (!topic.startsWith(TOPIC_PREFIX) || !topic.endsWith(TOPIC_SUFFIX)) return QString();
    return topic.mid(TOPIC_PREFIX.size(),
                     topic.size() - TOPIC_PREFIX.size() - TOPIC_SUFFIX.size());
}

void VotingPlugin::handleMessageReceived(const QVariantList& data)
{
    // delivery_module.messageReceived layout:
    //   data[0] QString — message hash
    //   data[1] QString — content topic
    //   data[2] QString — payload (base64)
    //   data[3] QString — timestamp (ns since epoch)
    if (data.size() < 3) {
        qWarning() << "VotingPlugin: messageReceived payload too short:" << data.size();
        return;
    }

    const QString topic  = data[1].toString();
    const QString pollId = pollIdFromTopic(topic);
    if (pollId.isEmpty()) return;   // not one of ours
    if (!m_polls.contains(pollId)) return;

    const QByteArray payload =
        QByteArray::fromBase64(data[2].toString().toUtf8());

    QJsonParseError err{};
    const QJsonDocument doc = QJsonDocument::fromJson(payload, &err);
    if (err.error != QJsonParseError::NoError || !doc.isObject()) {
        qWarning() << "VotingPlugin: invalid JSON payload:" << payload;
        return;
    }
    const QJsonObject obj  = doc.object();
    const QString     type = obj.value("type").toString("vote");  // legacy payloads = vote

    // Adopt the question if we don't already have one locally. Both announces
    // and (piggybacked) votes can carry it — first one wins.
    const QString incomingQuestion = obj.value("question").toString();
    if (!incomingQuestion.isEmpty() && m_polls[pollId].question.isEmpty()) {
        m_polls[pollId].question = incomingQuestion;
        emit eventResponse("pollOpened", QVariantList{ pollId, incomingQuestion });
    }

    if (type == "requestQuestion") {
        // A peer just joined without a question and wants it. Reply with an
        // announce if we know it — but DEFER the send via QTimer::singleShot
        // so we don't re-enter delivery_module from inside its own event
        // dispatch (that would deadlock the main thread).
        if (!m_polls[pollId].question.isEmpty()) {
            const QString q     = m_polls[pollId].question;
            const QString topic = topicFor(pollId);
            QTimer::singleShot(0, this, [this, q, topic]() {
                if (!m_deliveryClient) return;
                QJsonObject resp;
                resp["type"]     = "announce";
                resp["question"] = q;
                const QString payload = QString::fromUtf8(
                    QJsonDocument(resp).toJson(QJsonDocument::Compact));
                m_deliveryClient->invokeRemoteMethod(
                    "delivery_module", "send", topic, payload);
            });
        }
        return;
    }

    if (type == "announce") {
        return;   // nothing else to do — the question adoption above already happened
    }

    const QString voter = obj["voter"].toString();
    const bool    yes   = obj["yes"].toBool();
    if (voter.isEmpty()) return;

    // Latest-wins by voter id, so duplicate deliveries of the same vote don't double-count.
    m_polls[pollId].votes.insert(voter, yes);
    emit eventResponse("voteReceived", QVariantList{ pollId, voter, yes });
}

void VotingPlugin::setDeliveryStatus(int status)
{
    if (m_deliveryStatus == status) return;
    m_deliveryStatus = status;
    emit eventResponse("deliveryStatusChanged", QVariantList{ status });
}

bool VotingPlugin::invokeBool(const char* what,
                              const QString& method,
                              const QVariant& arg)
{
    const QVariant r = arg.isValid()
        ? m_deliveryClient->invokeRemoteMethod("delivery_module", method, arg)
        : m_deliveryClient->invokeRemoteMethod("delivery_module", method);
    if (!r.isValid()) {
        qWarning() << "VotingPlugin:" << what << "RPC failed (invalid QVariant)";
        return false;
    }
    if (!r.toBool()) {
        qWarning() << "VotingPlugin:" << what << "returned false:" << r;
        return false;
    }
    return true;
}
