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
    m_identity = new InferenceIdentity(logosAPI, "user");
    if (m_identity->isInitialized()) {
        qDebug() << "InferencePlugin: identity loaded, fingerprint"
                 << m_identity->fingerprint();
    }
    qDebug() << "InferencePlugin: LogosAPI wired up";
}

// ── Identity ─────────────────────────────────────────────────────────
// The UI drives create/import; nothing is auto-created. The identity never
// goes on the wire (prompts stay pseudonymous) — it anchors the future RLN
// membership + payment keys and gives the user a stable, recoverable root.

QString InferencePlugin::identityStatus()
{
    QJsonObject o;
    const bool init = m_identity && m_identity->isInitialized();
    o["initialized"] = init;
    o["backend"]     = init ? m_identity->backend() : QString();
    o["fingerprint"] = init ? m_identity->fingerprint() : QString();
    o["signPk"]      = init ? QString::fromLatin1(m_identity->signPublicKey().toBase64()) : QString();
    o["boxPk"]       = init ? QString::fromLatin1(m_identity->boxPublicKey().toBase64()) : QString();
    return QString::fromUtf8(QJsonDocument(o).toJson(QJsonDocument::Compact));
}

QString InferencePlugin::createAccount(const QString& passphrase)
{
    if (!m_identity) return QString();
    const QString mnemonic = m_identity->createAccount(passphrase);
    if (m_identity->isInitialized())
        emit eventResponse("identityChanged", QVariantList{ m_identity->fingerprint() });
    return mnemonic;
}

bool InferencePlugin::importAccount(const QString& mnemonic, const QString& passphrase)
{
    if (!m_identity) return false;
    const bool ok = m_identity->importAccount(mnemonic, passphrase);
    if (ok)
        emit eventResponse("identityChanged", QVariantList{ m_identity->fingerprint() });
    return ok;
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

// Choose a provider from the verified roster: freshest announces only
// (heard within 30s), lowest load first, most recently seen as tiebreak.
const ProviderRec* InferencePlugin::pickProvider(QString& fpOut) const
{
    const qint64 cutoff = nowMs() - 30000;
    const ProviderRec* best = nullptr;
    for (auto it = m_providers.constBegin(); it != m_providers.constEnd(); ++it) {
        const ProviderRec& p = it.value();
        if (p.lastSeenMs < cutoff) continue;
        if (!best || p.load < best->load ||
            (p.load == best->load && p.lastSeenMs > best->lastSeenMs)) {
            best  = &it.value();
            fpOut = it.key();
        }
    }
    return best;
}

QString InferencePlugin::sendPrompt(const QString& prompt)
{
    const QString text = prompt.trimmed();
    if (text.isEmpty()) return QString();
    if (!m_started && !startDelivery()) return QString();

    PromptRec rec;
    rec.id     = QUuid::createUuid().toString(QUuid::WithoutBraces).left(8);
    rec.prompt = text;
    rec.sentMs = nowMs();

    QJsonObject obj;
    obj["type"] = "prompt";
    obj["id"]   = rec.id;

    // E2E when we know a live provider: seal {prompt, replyPk} to its box key.
    // On the wire that leaves only routing crumbs (to + id) — no prompt text,
    // no sender id, and a fresh reply key each time so prompts are unlinkable.
    QString providerFp;
    const ProviderRec* prov = pickProvider(providerFp);
    QByteArray ephPk;
    if (prov && InferenceIdentity::genEphemeralKeypair(rec.ephSk, ephPk)) {
        QJsonObject inner;
        inner["prompt"]  = text;
        inner["replyPk"] = QString::fromLatin1(ephPk.toBase64());
        const QByteArray sealed = InferenceIdentity::seal(
            prov->boxPk, QJsonDocument(inner).toJson(QJsonDocument::Compact));
        if (!sealed.isEmpty()) {
            rec.sealed   = true;
            rec.provider = providerFp;   // who we asked (confirmed on answer)
            obj["v"]   = 2;
            obj["to"]  = providerFp;
            obj["box"] = QString::fromLatin1(sealed.toBase64());
        }
    }
    if (!rec.sealed) {
        // No verified provider heard from yet (or sealing failed): legacy
        // plaintext broadcast, so the demo still works against old providers.
        obj["from"]   = m_myId;
        obj["ts"]     = rec.sentMs;
        obj["prompt"] = text;
        rec.provider.clear();
    }

    m_prompts.prepend(rec);

    const QString payload = QString::fromUtf8(
        QJsonDocument(obj).toJson(QJsonDocument::Compact));
    const QVariant r = m_deliveryClient->invokeRemoteMethod(
        "delivery_module", "send", topicForRoom(m_room), payload);
    if (!r.isValid()) {
        qWarning() << "InferencePlugin: delivery_module.send RPC failed";
    }

    qDebug() << "InferencePlugin: sent" << (rec.sealed ? "sealed" : "plaintext")
             << "prompt" << rec.id << "to" << topicForRoom(m_room)
             << (rec.sealed ? "provider " + rec.provider : QString());
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
        o["sealed"]   = p.sealed;
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

    if (type == "announce")      handleAnnounce(obj);
    else if (type == "response") handleResponse(obj);
    // prompts are the provider's business, not ours
}

// Verify a provider announce and upsert the roster. Self-certifying: the id
// must be the fingerprint of the signing key, and the announce must verify
// under that key — so nobody can advertise a box key under someone else's id.
void InferencePlugin::handleAnnounce(const QJsonObject& obj)
{
    const QString id        = obj.value("id").toString();
    const QString signPkB64 = obj.value("signPk").toString();
    const QString boxPkB64  = obj.value("boxPk").toString();
    const QString model     = obj.value("model").toString();
    const int     load      = obj.value("load").toInt();
    const qint64  ts        = static_cast<qint64>(obj.value("ts").toDouble());
    const QByteArray sig    = QByteArray::fromBase64(obj.value("sig").toString().toLatin1());
    const QByteArray signPk = QByteArray::fromBase64(signPkB64.toLatin1());
    const QByteArray boxPk  = QByteArray::fromBase64(boxPkB64.toLatin1());
    if (id.isEmpty() || signPk.size() != 32 || boxPk.size() != 32) return;

    if (InferenceIdentity::fingerprintOf(signPk) != id) {
        qWarning() << "InferencePlugin: announce id/key mismatch for" << id << "— ignored";
        return;
    }
    const QByteArray canon = QString("inference/v1/announce|%1|%2|%3|%4|%5|%6")
        .arg(id, signPkB64, boxPkB64, model,
             QString::number(load), QString::number(ts)).toUtf8();
    if (!InferenceIdentity::verify(canon, sig, signPk)) {
        qWarning() << "InferencePlugin: bad announce signature from" << id << "— ignored";
        return;
    }

    const bool isNew = !m_providers.contains(id);
    ProviderRec& p = m_providers[id];
    p.signPk = signPk;
    p.boxPk  = boxPk;
    p.model  = model;
    p.load   = load;
    p.lastSeenMs = nowMs();
    if (isNew) {
        qDebug() << "InferencePlugin: provider" << id << "joined roster (" << model << ")";
        emit eventResponse("providersChanged", QVariantList{ m_providers.size() });
    }
}

void InferencePlugin::handleResponse(const QJsonObject& obj)
{
    const QString id   = obj.value("id").toString();
    const QString from = obj.value("from").toString();
    if (id.isEmpty()) return;

    for (PromptRec& p : m_prompts) {
        if (p.id != id || p.answered) continue;

        QString text, model;
        if (obj.value("v").toInt() >= 2 && p.sealed) {
            // Sealed response: only our per-prompt ephemeral key opens it, and
            // the signature must match the provider we know under `from`.
            const QString    boxB64 = obj.value("box").toString();
            const QByteArray inner  = InferenceIdentity::openWith(
                p.ephSk, QByteArray::fromBase64(boxB64.toLatin1()));
            if (inner.isEmpty()) return;   // not for us / tampered

            const auto it = m_providers.constFind(from);
            if (it != m_providers.constEnd()) {
                const QByteArray canon =
                    QString("inference/v1/response|%1|%2").arg(id, boxB64).toUtf8();
                const QByteArray sig =
                    QByteArray::fromBase64(obj.value("sig").toString().toLatin1());
                if (!InferenceIdentity::verify(canon, sig, it->signPk)) {
                    qWarning() << "InferencePlugin: response" << id
                               << "has a bad signature for" << from << "— dropped";
                    return;
                }
            } else {
                qWarning() << "InferencePlugin: response" << id << "from unknown provider"
                           << from << "— accepted unverified (no announce seen)";
            }
            const QJsonDocument d = QJsonDocument::fromJson(inner);
            if (!d.isObject()) return;
            text  = d.object().value("text").toString();
            model = d.object().value("model").toString();
        } else if (!p.sealed) {
            // Legacy plaintext response to a plaintext prompt.
            text  = obj.value("text").toString();
            model = obj.value("model").toString();
        } else {
            return;   // plaintext answer to a sealed prompt — not acceptable
        }

        p.answered = true;
        p.rttMs    = nowMs() - p.sentMs;
        p.text     = text;
        p.provider = from;
        p.model    = model;
        p.ephSk.clear();   // reply channel closed — key no longer needed
        qDebug() << "InferencePlugin: response for" << id << "from" << from
                 << (p.sealed ? "(sealed)" : "(plaintext)")
                 << "rtt" << p.rttMs << "ms" << "(" << p.text.size() << "chars )";
        emit eventResponse("responseReceived",
            QVariantList{ id, from, static_cast<double>(p.rttMs) });
        return;
    }
}

QString InferencePlugin::listProviders()
{
    QJsonArray arr;
    const qint64 now = nowMs();
    for (auto it = m_providers.constBegin(); it != m_providers.constEnd(); ++it) {
        QJsonObject o;
        o["id"]    = it.key();
        o["model"] = it->model;
        o["load"]  = it->load;
        o["ageMs"] = static_cast<double>(now - it->lastSeenMs);
        o["live"]  = (now - it->lastSeenMs) < 30000;
        arr.append(o);
    }
    return QString::fromUtf8(QJsonDocument(arr).toJson(QJsonDocument::Compact));
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
