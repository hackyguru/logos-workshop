#include "logos_wallet_plugin.h"

#include <QCryptographicHash>
#include <QDebug>
#include <QDir>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QRandomGenerator>
#include <QRegularExpression>
#include <QTimer>

// ── Network identity ─────────────────────────────────────────────────
static const QString NODE_VERSION = QStringLiteral("0.2.0");
static const QStringList BOOTSTRAP_PEERS = {
    "/ip4/65.109.51.37/udp/3000/quic-v1/p2p/12D3KooWFrouXfmrR4nsLMtE7wu15DoMJ6VtoUtHinREZCvbWHar",
    "/ip4/65.109.51.37/udp/3001/quic-v1/p2p/12D3KooWJRGau8M1rjT7R5e4YYsgdFhsMX35nRDtMwCDjxQkXAHz",
    "/ip4/65.109.51.37/udp/3002/quic-v1/p2p/12D3KooWQXJavMDTRscjauFSgVAB1VLB6Rzpy2uY5SU9Tk7927tb",
    "/ip4/65.109.51.37/udp/50001/quic-v1/p2p/12D3KooWSQc7CcGtvWDPF1yCbBthFnQjprfCVHmfmNDUrSmqQsU1",
};
static const QString NET_PORT  = QStringLiteral("13000");
static const QString HTTP_ADDR = QStringLiteral("127.0.0.1:18080");

static const QString LEZ = QStringLiteral("logos_execution_zone");
static const QString LEZ_SEQUENCER = QStringLiteral("https://testnet.lez.logos.co");
static const int     LEZ_SYNC_CHUNK = 1000;
// The zone's genesis PoW faucet account (base58 EfQhKQAkX2FJiwNii2WFQsGndjvF1Mzd7RuVe7QdPLw7).
static const QString PINATA_ID =
    QStringLiteral("cafecafecafecafecafecafecafecafecafecafecafecafecafecafecafecafe");
static const QString PINATA_B58 =
    QStringLiteral("EfQhKQAkX2FJiwNii2WFQsGndjvF1Mzd7RuVe7QdPLw7");
// Testnet base↔LEZ bridge channel (verified live).
static const QString BRIDGE_CHANNEL =
    QStringLiteral("0101010101010101010101010101010101010101010101010101010101010101");

static QString releaseUrl()
{
#if defined(Q_OS_MACOS)
    const QString os = QStringLiteral("macos");
#else
    const QString os = QStringLiteral("linux");
#endif
#if defined(Q_PROCESSOR_ARM)
    const QString arch = QStringLiteral("aarch64");
#else
    const QString arch = QStringLiteral("x86_64");
#endif
    return QStringLiteral("https://github.com/logos-blockchain/logos-blockchain/releases/download/"
                          "%1/logos-blockchain-node-%2-%3-%1.tar.gz").arg(NODE_VERSION, os, arch);
}

// ── HTTP + JSON helpers ──────────────────────────────────────────────
// Absolute curl path: module hosts don't resolve bare "curl". QML's
// XMLHttpRequest also doesn't work inside Basecamp, so the core does all HTTP.
static QByteArray curlGet(const QString& url, int seconds = 3)
{
    QProcess p;
    p.start(QStringLiteral("/usr/bin/curl"),
            {QStringLiteral("-sf"), QStringLiteral("-m"), QString::number(seconds), url});
    if (!p.waitForFinished((seconds + 1) * 1000) || p.exitCode() != 0)
        return {};
    return p.readAllStandardOutput();
}

static bool curlPost(const QString& url, const QByteArray& json, QByteArray& out, int seconds = 10)
{
    QProcess p;
    p.start(QStringLiteral("/usr/bin/curl"),
            {QStringLiteral("-s"), QStringLiteral("-m"), QString::number(seconds),
             QStringLiteral("-X"), QStringLiteral("POST"),
             QStringLiteral("-H"), QStringLiteral("Content-Type: application/json"),
             QStringLiteral("--data-binary"), QString::fromUtf8(json),
             QStringLiteral("-w"), QStringLiteral("\n%{http_code}"), url});
    if (!p.waitForFinished((seconds + 2) * 1000)) { out = "no reply"; return false; }
    const QByteArray r = p.readAllStandardOutput();
    const int nl = r.lastIndexOf('\n');
    const int code = r.mid(nl + 1).trimmed().toInt();
    out = r.left(qMax(nl, 0)).trimmed();
    return code >= 200 && code < 300;
}

static QString dump(const QJsonObject& o)
{
    return QString::fromUtf8(QJsonDocument(o).toJson(QJsonDocument::Compact));
}

// Wallet metadata lives in a plain JSON file next to storage.json — NOT
// QSettings. macOS's cfprefsd caches QSettings and serves stale/empty values
// to a freshly launched process, which made the wallet "forget" it existed
// on every restart. A co-located file is deterministic.
static QJsonObject metaRead(const QString& path)
{
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly)) return {};
    return QJsonDocument::fromJson(f.readAll()).object();
}
static void metaWrite(const QString& path, const QJsonObject& o)
{
    QFile f(path);
    if (f.open(QIODevice::WriteOnly)) f.write(QJsonDocument(o).toJson(QJsonDocument::Compact));
}
static QString errJson(const QString& m)
{
    return dump(QJsonObject{{"ok", false}, {"error", m}});
}
static QString amountLe16Hex(qulonglong v)
{
    QByteArray le(16, '\0');
    for (int i = 0; i < 8; ++i) { le[i] = char(v & 0xff); v >>= 8; }
    return QString::fromLatin1(le.toHex());
}
static QString toB58(const QString& hex)
{
    static const char* A = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
    const QByteArray bytes = QByteArray::fromHex(hex.toLatin1());
    int zeros = 0;
    while (zeros < bytes.size() && bytes[zeros] == 0) ++zeros;
    std::vector<int> digits;
    for (unsigned char b : bytes) {
        int carry = b;
        for (int& d : digits) { carry += d * 256; d = carry % 58; carry /= 58; }
        while (carry > 0) { digits.push_back(carry % 58); carry /= 58; }
    }
    QString out(zeros, QLatin1Char('1'));
    for (auto it = digits.rbegin(); it != digits.rend(); ++it) out += QLatin1Char(A[*it]);
    return out;
}

// ── Lifecycle ────────────────────────────────────────────────────────
LogosWalletPlugin::LogosWalletPlugin(QObject* parent) : QObject(parent)
{
    qDebug() << "LogosWalletPlugin: created" << NODE_VERSION;
}
LogosWalletPlugin::~LogosWalletPlugin()
{
    // The node is a DETACHED daemon on purpose — do not kill it here; it
    // outlives the UI. Only the inscribe sequencer (a child) is cleaned up.
    if (m_seq && m_seq->state() != QProcess::NotRunning) {
        m_seq->terminate();
        m_seq->waitForFinished(2000);
    }
}
void LogosWalletPlugin::initLogos(LogosAPI* api)
{
    logosAPI = api;
    qDebug() << "LogosWalletPlugin: LogosAPI wired up";
}

QString LogosWalletPlugin::baseDir() const        { return QDir::homePath() + "/.logos-wallet"; }
QString LogosWalletPlugin::binPath() const        { return baseDir() + "/bin/logos-blockchain-node"; }
QString LogosWalletPlugin::nodeConfigPath() const { return baseDir() + "/user_config.yaml"; }
QString LogosWalletPlugin::nodeKeystorePath() const { return baseDir() + "/keystore.yaml"; }
QString LogosWalletPlugin::nodePidPath() const    { return baseDir() + "/node.pid"; }
QString LogosWalletPlugin::lezDir() const         { return baseDir() + "/lez"; }

// ── Bedrock: node daemon lifecycle ───────────────────────────────────

bool LogosWalletPlugin::nodeAlive() const
{
    return !curlGet(QStringLiteral("http://") + HTTP_ADDR + "/cryptarchia/info", 2).isEmpty();
}

qint64 LogosWalletPlugin::daemonPid() const
{
    QFile f(nodePidPath());
    if (!f.open(QIODevice::ReadOnly)) return 0;
    const qint64 pid = f.readAll().trimmed().toLongLong();
    if (pid <= 0) return 0;
    // kill(pid, 0) via /bin/kill -0; alive => exit 0.
    return (QProcess::execute(QStringLiteral("/bin/kill"),
                              {QStringLiteral("-0"), QString::number(pid)}) == 0) ? pid : 0;
}

QString LogosWalletPlugin::nodeStatus()
{
    QJsonObject out{{"hasBinary", QFile::exists(binPath())},
                    {"hasConfig", QFile::exists(nodeConfigPath())},
                    {"setupBusy", m_nodeBusy},
                    {"stage", m_nodeStage},
                    {"setupError", m_nodeError},
                    {"httpAddr", HTTP_ADDR},
                    {"nodeVersion", NODE_VERSION}};
    const bool up = nodeAlive();
    out["running"] = up;
    if (up) {
        const QByteArray ci = curlGet(QStringLiteral("http://") + HTTP_ADDR + "/cryptarchia/info", 2);
        const QJsonObject info = QJsonDocument::fromJson(ci).object();
        const QJsonObject c = info.value("cryptarchia_info").toObject();
        out["height"] = c.value("height");
        out["slot"] = c.value("slot");
        QJsonValue m = info.value("mode");
        if (m.isObject()) { const QJsonObject mo = m.toObject(); if (!mo.isEmpty()) m = mo.begin().value(); }
        out["mode"] = m.toString();
        const QByteArray ni = curlGet(QStringLiteral("http://") + HTTP_ADDR + "/network/info", 2);
        const QJsonObject n = QJsonDocument::fromJson(ni).object();
        out["peerId"] = n.value("peer_id");
        out["nPeers"] = n.value("n_peers");
        out["nConnections"] = n.value("n_connections");
    }
    return dump(out);
}

QString LogosWalletPlugin::startNode()
{
    if (m_nodeBusy)
        return dump(QJsonObject{{"ok", true}, {"accepted", false}, {"busy", true}});
    // Re-adopt a node that's already up OR whose restart-loop daemon is still
    // running from a prior session (avoid launching a second loop).
    if (nodeAlive() || daemonPid() > 0) {
        emit eventResponse("nodeSetupFinished", {dump(QJsonObject{{"ok", true}})});
        return dump(QJsonObject{{"ok", true}, {"accepted", false}, {"alreadyRunning", true}});
    }
    m_nodeBusy = true;
    m_nodeError.clear();
    stepDownload();
    return dump(QJsonObject{{"ok", true}, {"accepted", true}});
}

QString LogosWalletPlugin::stopNode()
{
    // Break the restart loop (remove guard), kill the loop, then the node.
    QFile::remove(baseDir() + "/node.run");
    const qint64 pid = daemonPid();
    if (pid > 0) QProcess::execute(QStringLiteral("/bin/kill"), {QString::number(pid)});
    QProcess::execute(QStringLiteral("/usr/bin/pkill"), {QStringLiteral("-f"), binPath()});
    QFile::remove(nodePidPath());
    return dump(QJsonObject{{"ok", true}});
}

void LogosWalletPlugin::finishNodeSetup(bool ok, const QString& error)
{
    m_nodeBusy = false;
    m_nodeStage.clear();
    m_nodeError = ok ? QString() : error;
    emit eventResponse("nodeSetupFinished",
                       {ok ? dump(QJsonObject{{"ok", true}}) : errJson(error)});
}

void LogosWalletPlugin::stepDownload()
{
    if (QFile::exists(binPath())) { stepInitConfig(); return; }
    QDir().mkpath(baseDir() + "/bin");
    m_nodeStage = QStringLiteral("downloading");
    QProcess* p = new QProcess(this);
    p->setWorkingDirectory(baseDir() + "/bin");
    connect(p, QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished), this,
            [this, p](int code, QProcess::ExitStatus) {
                p->deleteLater();
                if (code != 0) { finishNodeSetup(false, "Download failed (check your connection)."); return; }
                stepExtract();
            });
    p->start(QStringLiteral("/usr/bin/curl"),
             {QStringLiteral("-sfL"), QStringLiteral("--retry"), QStringLiteral("2"),
              QStringLiteral("-o"), QStringLiteral("node.tar.gz"), releaseUrl()});
}

void LogosWalletPlugin::stepExtract()
{
    QProcess* p = new QProcess(this);
    p->setWorkingDirectory(baseDir() + "/bin");
    connect(p, QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished), this,
            [this, p](int code, QProcess::ExitStatus) {
                p->deleteLater();
                QFile::remove(baseDir() + "/bin/node.tar.gz");
                if (code != 0 || !QFile::exists(binPath())) { finishNodeSetup(false, "Unpack failed."); return; }
                stepInitConfig();
            });
    p->start(QStringLiteral("/usr/bin/tar"), {QStringLiteral("-xzf"), QStringLiteral("node.tar.gz")});
}

void LogosWalletPlugin::stepInitConfig()
{
    if (QFile::exists(nodeConfigPath())) { launchDaemon(); return; }  // wallet already exists
    m_nodeStage = QStringLiteral("configuring");
    QStringList args{QStringLiteral("init-config"),
                     QStringLiteral("-o"), nodeConfigPath(),
                     QStringLiteral("-k"), nodeKeystorePath(),
                     QStringLiteral("--http-host"), HTTP_ADDR,
                     QStringLiteral("--net-port"), NET_PORT,
                     QStringLiteral("--log-backend"), QStringLiteral("stdout"),
                     QStringLiteral("--log-level"), QStringLiteral("info"),
                     QStringLiteral("--ibd"),
                     QStringLiteral("--state-path"), baseDir() + "/state",
                     QStringLiteral("--storage-path"), QStringLiteral("db")};
    for (const QString& peer : BOOTSTRAP_PEERS) args << QStringLiteral("-p") << peer;
    QProcess* p = new QProcess(this);
    p->setWorkingDirectory(baseDir());
    connect(p, QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished), this,
            [this, p](int code, QProcess::ExitStatus) {
                const QString err = QString::fromUtf8(p->readAllStandardError()).right(300);
                p->deleteLater();
                if (code != 0 || !QFile::exists(nodeConfigPath())) {
                    finishNodeSetup(false, "Could not create the node config: " + err); return;
                }
                launchDaemon();
            });
    p->start(binPath(), args);
}

void LogosWalletPlugin::launchDaemon()
{
    m_nodeStage = QStringLiteral("starting");
    // Detached restart-loop daemon: (1) startDetached makes it independent of
    // the module host, so it survives quitting the UI/Basecamp and is
    // re-adopted on next load; (2) the `while` loop respawns the node when
    // 0.2.0's IBD race near tip makes it self-exit — each run resumes from
    // the db, so it eventually stays up. A guard file lets stopNode break the
    // loop. Logs to node.log.
    const QString guard = baseDir() + "/node.run";
    QFile g(guard); if (g.open(QIODevice::WriteOnly)) { g.write("1"); g.close(); }
    const QString cmd = QStringLiteral(
        "while [ -f '%4' ]; do '%1' '%2' >> '%3' 2>&1; sleep 2; done")
        .arg(binPath(), nodeConfigPath(), baseDir() + "/node.log", guard);
    qint64 pid = 0;
    const bool ok = QProcess::startDetached(QStringLiteral("/bin/sh"),
                                            {QStringLiteral("-c"), cmd}, baseDir(), &pid);
    if (!ok) { finishNodeSetup(false, "Could not launch the node."); return; }
    QFile f(nodePidPath());
    if (f.open(QIODevice::WriteOnly)) { f.write(QByteArray::number(pid)); f.close(); }
    finishNodeSetup(true, {});
}

// ── Bedrock: base wallet ─────────────────────────────────────────────

QString LogosWalletPlugin::leaderPk()
{
    QFile f(nodeKeystorePath());
    if (!f.open(QIODevice::ReadOnly | QIODevice::Text)) return {};
    static const QRegularExpression re(QStringLiteral("^\\s+LeaderFunding:\\s*([0-9a-fA-F]{64})\\s*$"));
    while (!f.atEnd()) {
        const auto m = re.match(QString::fromUtf8(f.readLine()));
        if (m.hasMatch()) return m.captured(1).toLower();
    }
    return {};
}

QString LogosWalletPlugin::baseAccounts()
{
    QFile f(nodeKeystorePath());
    if (!f.open(QIODevice::ReadOnly | QIODevice::Text))
        return errJson(QStringLiteral("No wallet yet — start the node first."));
    QJsonArray list;
    bool in = false;
    static const QRegularExpression entry(QStringLiteral("^\\s+(\\w+):\\s*([0-9a-fA-F]{64})\\s*$"));
    while (!f.atEnd()) {
        const QString line = QString::fromUtf8(f.readLine());
        if (line.startsWith(QLatin1String("public_keys:"))) { in = true; continue; }
        if (in) {
            if (!line.startsWith(QLatin1Char(' ')) && !line.trimmed().isEmpty()) break;
            const auto m = entry.match(line);
            if (m.hasMatch()) {
                const QString addr = m.captured(2).toLower();
                double bal = -1;
                const QByteArray b = curlGet(QStringLiteral("http://%1/wallet/%2/balance").arg(HTTP_ADDR, addr), 2);
                if (!b.isEmpty()) bal = QJsonDocument::fromJson(b).object().value("balance").toDouble(0);
                list.append(QJsonObject{{"role", m.captured(1)}, {"address", addr}, {"balance", bal}});
            }
        }
    }
    return dump(QJsonObject{{"ok", true}, {"accounts", list}});
}

QString LogosWalletPlugin::baseSend(const QString& toAddress, const QString& amount)
{
    static const QRegularExpression hex64(QStringLiteral("^[0-9a-fA-F]{64}$"));
    if (!hex64.match(toAddress).hasMatch())
        return errJson(QStringLiteral("Recipient must be 64 hex characters."));
    bool ok = false;
    const qulonglong v = amount.trimmed().toULongLong(&ok);
    if (!ok || v == 0) return errJson(QStringLiteral("Amount must be a positive whole number."));
    if (!nodeAlive()) return errJson(QStringLiteral("The node is not running."));
    const QString pk = leaderPk();
    if (pk.isEmpty()) return errJson(QStringLiteral("No base wallet key found."));

    const QByteArray info = curlGet(QStringLiteral("http://") + HTTP_ADDR + "/cryptarchia/info", 3);
    const QString tip = QJsonDocument::fromJson(info).object()
                            .value("cryptarchia_info").toObject().value("tip").toString();
    if (tip.isEmpty()) return errJson(QStringLiteral("Could not read the chain tip."));
    const QJsonObject body{{"tip", tip}, {"change_public_key", pk},
                           {"funding_public_keys", QJsonArray{pk}},
                           {"recipient_public_key", toAddress.toLower()},
                           {"amount", static_cast<qint64>(v)}};
    QByteArray reply;
    if (!curlPost(QStringLiteral("http://") + HTTP_ADDR + "/wallet/transactions/transfer-funds",
                  QJsonDocument(body).toJson(QJsonDocument::Compact), reply))
        return errJson("The node rejected the transfer: " + QString::fromUtf8(reply.right(300)));
    QString tx = QJsonDocument::fromJson(reply).object().value("hash").toString();
    if (tx.isEmpty()) tx = QString::fromUtf8(reply).trimmed().remove(QLatin1Char('"')).left(64);
    return dump(QJsonObject{{"ok", true}, {"tx", tx}});
}

// ── Bedrock: inscribe (long-lived sequencer) ─────────────────────────

QString LogosWalletPlugin::channelTip()
{
    if (m_channelId.isEmpty()) return {};
    const QByteArray b = curlGet(QStringLiteral("http://%1/channel/%2").arg(HTTP_ADDR, m_channelId), 2);
    return b.isEmpty() ? QString()
                       : QJsonDocument::fromJson(b).object().value("tip_message").toString();
}

QString LogosWalletPlugin::inscribe(const QString& text)
{
    if (text.trimmed().isEmpty()) return errJson(QStringLiteral("Nothing to inscribe."));
    if (!nodeAlive()) return errJson(QStringLiteral("The node is not running."));
    if (m_seq && m_seqReady) writeAndConfirm(text.trimmed());
    else { m_pendingText = text.trimmed(); ensureSequencer(); }
    return dump(QJsonObject{{"ok", true}, {"accepted", true}});
}

void LogosWalletPlugin::finishInscribe(const QString& json)
{
    if (m_confirmTimer) { m_confirmTimer->stop(); m_confirmTimer->deleteLater(); m_confirmTimer = nullptr; }
    emit eventResponse("inscribeFinished", {json});
}

void LogosWalletPlugin::ensureSequencer()
{
    if (m_seq) return;
    m_seqBuf.clear(); m_seqReady = false;
    m_seq = new QProcess(this);
    m_seq->setWorkingDirectory(baseDir());
    m_seq->setProcessChannelMode(QProcess::MergedChannels);
    connect(m_seq, &QProcess::readyReadStandardOutput, this, [this]() {
        m_seqBuf += QString::fromUtf8(m_seq->readAllStandardOutput());
        if (m_channelId.isEmpty()) {
            static const QRegularExpression re(QStringLiteral("Channel ID:\\s*([0-9a-fA-F]{64})"));
            const auto m = re.match(m_seqBuf);
            if (m.hasMatch()) m_channelId = m.captured(1).toLower();
        }
        if (!m_seqReady && m_seqBuf.contains(QLatin1String("Ready."))) {
            m_seqReady = true;
            if (!m_pendingText.isEmpty()) { const QString t = m_pendingText; m_pendingText.clear(); writeAndConfirm(t); }
        }
    });
    connect(m_seq, QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished), this,
            [this](int, QProcess::ExitStatus) {
                m_seq->deleteLater(); m_seq = nullptr; m_seqReady = false; m_pendingText.clear();
                if (m_confirmTimer) finishInscribe(errJson(QStringLiteral("The inscription helper stopped.")));
            });
    m_seq->start(binPath(), {QStringLiteral("inscribe"),
                             QStringLiteral("--node-url"), QStringLiteral("http://") + HTTP_ADDR,
                             QStringLiteral("--key-path"), baseDir() + "/sequencer.key"});
}

void LogosWalletPlugin::writeAndConfirm(const QString& text)
{
    m_prevTip = channelTip();
    m_seq->write((text + QLatin1Char('\n')).toUtf8());
    m_confirmTries = 0;
    m_confirmTimer = new QTimer(this);
    m_confirmTimer->setInterval(3000);
    connect(m_confirmTimer, &QTimer::timeout, this, [this]() {
        const QString tip = channelTip();
        if (!tip.isEmpty() && tip != m_prevTip) {
            finishInscribe(dump(QJsonObject{{"ok", true}, {"tip", tip}, {"channel", m_channelId}}));
        } else if (++m_confirmTries >= 40) {
            finishInscribe(errJson(QStringLiteral("Sent but not confirmed yet — may appear shortly.")));
        }
    });
    m_confirmTimer->start();
}

// ── LEZ: module client ───────────────────────────────────────────────
// Drives the Basecamp-bundled logos_execution_zone module — the only build
// version-matched to the deployed testnet (verified: register + pinata
// claims land on-chain). This module is the SOLE owner of that wallet.

LogosAPIClient* LogosWalletPlugin::lezClient()
{
    if (m_lez && m_lez->isConnected()) return m_lez;
    if (logosAPI) m_lez = logosAPI->getClient(LEZ);
    return m_lez;
}

LogosWalletPlugin::Reply LogosWalletPlugin::lezCall(const QString& method,
                                                    const QVariantList& args, int timeoutMs)
{
    LogosAPIClient* c = lezClient();
    if (!c || !c->isConnected())
        return {false, {}, QStringLiteral("logos_execution_zone is not loaded")};
    QVariant r;
    const Timeout t(timeoutMs);
    switch (args.size()) {
    case 0: r = c->invokeRemoteMethod(LEZ, method, QVariantList(), t); break;
    case 1: r = c->invokeRemoteMethod(LEZ, method, args[0], t); break;
    case 2: r = c->invokeRemoteMethod(LEZ, method, args[0], args[1], t); break;
    default: r = c->invokeRemoteMethod(LEZ, method, args[0], args[1], args[2], t); break;
    }
    if (!r.isValid()) return {false, {}, QStringLiteral("no reply from logos_execution_zone")};
    if (r.canConvert<LogosResult>()) {
        const LogosResult lr = r.value<LogosResult>();
        return {lr.success, lr.value, lr.error.toString()};
    }
    return {true, r, {}};
}

// The wallet-ffi is in-memory: without save() nothing reaches disk and the
// next open() gets a broken handle. Call after every mutating op.
void LogosWalletPlugin::lezSave()
{
    LogosAPIClient* c = lezClient();
    if (c && c->isConnected())
        c->invokeRemoteMethod(LEZ, QStringLiteral("save"), QVariantList(), Timeout(30000));
}

// Keep the wallet synced to the tip in the background so private-account
// balances (which only appear once sync_to_block scans the note's block)
// stay current. One chunk per tick; skips while another op is running.
void LogosWalletPlugin::startBackgroundSync()
{
    if (m_lezSyncTimer) return;
    m_lezSyncTimer = new QTimer(this);
    m_lezSyncTimer->setInterval(6000);
    connect(m_lezSyncTimer, &QTimer::timeout, this, [this]() {
        // Yield to any real user op, and never re-enter. Crucially this uses a
        // SEPARATE flag (m_lezSyncing), NOT m_lezBusy — background sync must not
        // look "busy", or it would disable the UI Send and make lezTransfer
        // reject the user's transfer (module calls serialize safely anyway).
        if (!m_lezOpen || m_lezBusy || m_lezSyncing) return;
        const Reply h = lezCall(QStringLiteral("get_current_block_height"), {}, 10000);
        const Reply l = lezCall(QStringLiteral("get_last_synced_block"), {}, 10000);
        if (!h.ok || !l.ok) return;
        const qlonglong height = h.value.toLongLong(), last = l.value.toLongLong();
        if (last >= height) return;                       // caught up
        m_lezSyncing = true;
        lezCall(QStringLiteral("sync_to_block"),
                {QVariant::fromValue(int(qMin(last + LEZ_SYNC_CHUNK, height)))}, 120000);
        lezSave();
        m_lezSyncing = false;
    });
    m_lezSyncTimer->start();
}

// Blocking sync loop — call only from a deferred (off-event-loop) context.
// Every write is proven against the SYNCED view; an unsynced wallet's proofs
// are built on empty state and the sequencer drops the tx.
bool LogosWalletPlugin::lezSyncFully(QString* err)
{
    for (int i = 0; i < 200; ++i) {
        const Reply h = lezCall(QStringLiteral("get_current_block_height"), {}, 30000);
        const Reply l = lezCall(QStringLiteral("get_last_synced_block"), {}, 30000);
        if (!h.ok || !l.ok) { if (err) *err = h.ok ? l.error : h.error; return false; }
        const qlonglong height = h.value.toLongLong(), last = l.value.toLongLong();
        if (last >= height) return true;
        const Reply s = lezCall(QStringLiteral("sync_to_block"),
                                {QVariant::fromValue(int(qMin(last + LEZ_SYNC_CHUNK, height)))}, 180000);
        if (!s.ok) { if (err) *err = s.error; return false; }
    }
    return true;
}

// A public account, created + registered on-chain (register uses
// authenticated_transfer) + persisted. Bridge/pinata/withdraw all need one.
QString LogosWalletPlugin::lezPublicAccount()
{
    const QString metaPath = lezDir() + "/meta.json";
    QJsonObject meta = metaRead(metaPath);
    QString acct = meta.value("lezPublicAccount").toString();
    if (!acct.isEmpty()) return acct;
    const Reply c = lezCall(QStringLiteral("create_account_public"), {}, 120000);
    if (!c.ok) return {};
    acct = c.value.toString();
    lezCall(QStringLiteral("register_public_account"), {acct}, 300000);   // on-chain init
    lezSave();
    meta["lezPublicAccount"] = acct;
    metaWrite(metaPath, meta);
    m_lezPublicAccount = acct;
    return acct;
}

// ── LEZ: status + open ───────────────────────────────────────────────

QString LogosWalletPlugin::lezStatus()
{
    const QJsonObject meta = metaRead(lezDir() + "/meta.json");
    // A wallet exists iff its storage file is on disk — the real source of
    // truth. (The meta flag can lag; the file cannot.)
    const bool hasWallet = QFile::exists(lezDir() + "/storage.json")
                           || meta.value("lezCreated").toBool();
    QJsonObject out{{"ready", m_lezOpen && !m_lezAccount.isEmpty()},
                    {"busy", m_lezBusy},
                    {"stage", m_lezStage},
                    {"error", m_lezError},
                    {"hasWallet", hasWallet},
                    {"account", m_lezAccount},
                    {"accountB58", m_lezAccount.isEmpty() ? QString() : toB58(m_lezAccount)},
                    {"publicAccount", m_lezPublicAccount},
                    {"publicAccountB58", m_lezPublicAccount.isEmpty() ? QString() : toB58(m_lezPublicAccount)}};
    // A balance the wallet can read but is empty (no notes / fresh account)
    // is 0, not unknown — show "0", never a blank that renders as "…".
    auto balOf = [](const Reply& r) -> QString {
        if (!r.ok) return QString();                 // genuine read failure → "…"
        const QString v = r.value.toString().trimmed();
        return v.isEmpty() ? QStringLiteral("0") : v;
    };
    if (m_lezOpen && !m_lezBusy && !m_lezAccount.isEmpty()) {
        // Private balance: only the wallet can compute it (viewing key).
        out["privateBalance"] = balOf(lezCall(QStringLiteral("get_balance"), {m_lezAccount, false}, 8000));
        out["vault"] = balOf(lezCall(QStringLiteral("get_vault_balance"), {m_lezAccount}, 8000));
        // Public balance: transparent state — read straight from the
        // sequencer RPC (authoritative, and immune to the wallet's local
        // get_balance going flaky after a shield).
        QString pubBal = QStringLiteral("0");
        if (!m_lezPublicAccount.isEmpty()) {
            const QString b58 = toB58(m_lezPublicAccount);
            QByteArray reply;
            if (curlPost(LEZ_SEQUENCER,
                         ("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getAccountBalance\",\"params\":[\""
                          + b58.toUtf8() + "\"]}"), reply, 6)) {
                const QJsonValue res = QJsonDocument::fromJson(reply).object().value("result");
                if (res.isDouble()) pubBal = QString::number(qulonglong(res.toDouble()));
            }
        }
        out["publicBalance"] = pubBal;
        const Reply ls = lezCall(QStringLiteral("get_last_synced_block"), {}, 8000);
        const Reply hh = lezCall(QStringLiteral("get_current_block_height"), {}, 8000);
        out["lastSynced"] = ls.ok ? ls.value.toDouble() : -1;
        out["height"] = hh.ok ? hh.value.toDouble() : -1;
    }
    return dump(out);
}

QString LogosWalletPlugin::lezOpen()
{
    if (m_lezBusy) return dump(QJsonObject{{"ok", true}, {"accepted", false}, {"busy", true}});
    if (m_lezOpen && !m_lezAccount.isEmpty())
        return dump(QJsonObject{{"ok", true}, {"accepted", false}, {"alreadyOpen", true}});
    m_lezBusy = true; m_lezError.clear();
    QTimer::singleShot(0, this, [this]() {
        auto finish = [this](const QString& json) {
            m_lezBusy = false; m_lezStage.clear();
            emit eventResponse("lezOpenFinished", {json});
        };
        const QString dir = lezDir();
        const QString cfg = dir + "/config.json";
        const QString storage = dir + "/storage.json";   // a FILE (from_path/save_to_path)
        QDir().mkpath(dir);
        if (!QFile::exists(cfg)) {
            QFile f(cfg); f.open(QIODevice::WriteOnly);
            f.write(QJsonDocument(QJsonObject{{"sequencer_addr", LEZ_SEQUENCER},
                                              {"seq_poll_timeout", "30s"},
                                              {"seq_tx_poll_max_blocks", 60},
                                              {"seq_poll_max_retries", 30},
                                              {"seq_block_poll_max_amount", 100}})
                        .toJson(QJsonDocument::Compact));
        }
        const QString metaPath = dir + "/meta.json";
        QJsonObject meta = metaRead(metaPath);
        // If the storage file exists, ALWAYS open it — never create over an
        // existing wallet (that would orphan funds). The file is the truth.
        const bool exists = QFile::exists(storage);
        QString mnemonic;
        if (exists) {
            const Reply r = lezCall(QStringLiteral("open"), {cfg, storage}, 60000);
            if (!r.ok) { m_lezError = r.error; finish(errJson("Could not open the private wallet: " + r.error)); return; }
        } else {
            QString pw = meta.value("lezPassword").toString();
            if (pw.isEmpty()) {
                pw = QString::number(QRandomGenerator::global()->generate64(), 16)
                   + QString::number(QRandomGenerator::global()->generate64(), 16);
                meta["lezPassword"] = pw;
            }
            const Reply r = lezCall(QStringLiteral("create_new"), {cfg, storage, pw}, 120000);
            if (!r.ok) { m_lezError = r.error; finish(errJson("Could not create the private wallet: " + r.error)); return; }
            mnemonic = r.value.toString();
            lezSave();
            meta["lezCreated"] = true;
            metaWrite(metaPath, meta);
        }
        m_lezOpen = true;
        m_lezPublicAccount = meta.value("lezPublicAccount").toString();
        m_lezAccount = meta.value("lezAccount").toString();
        if (m_lezAccount.isEmpty()) {
            const Reply r = lezCall(QStringLiteral("create_account_private"), {}, 120000);
            if (!r.ok) { finish(errJson("Could not create a private account: " + r.error)); return; }
            m_lezAccount = r.value.toString();
            lezSave();
            meta["lezAccount"] = m_lezAccount;
            metaWrite(metaPath, meta);
        }
        startBackgroundSync();   // keep private balances current from here on
        finish(dump(QJsonObject{{"ok", true}, {"account", m_lezAccount},
                                {"accountB58", toB58(m_lezAccount)}, {"mnemonic", mnemonic}}));
    });
    return dump(QJsonObject{{"ok", true}, {"accepted", true}});
}

// ── LEZ: accounts as a list (the stock-wallet model) ─────────────────
// Every account the wallet holds, each tagged public/private with its own
// balance. Public balances come from the sequencer RPC (transparent,
// reliable); private balances from the wallet (viewing key required).

QString LogosWalletPlugin::lezAccounts()
{
    if (!m_lezOpen) return errJson(QStringLiteral("Open the wallet first."));
    const Reply list = lezCall(QStringLiteral("list_accounts"), {}, 15000);
    if (!list.ok) return errJson("Could not list accounts: " + list.error);

    QJsonArray out;
    const QVariantList entries = list.value.toList();
    for (const QVariant& e : entries) {
        // Entry is {account_id: hex, is_public: bool} (possibly JSON string).
        QJsonObject o;
        if (e.canConvert<QString>())
            o = QJsonDocument::fromJson(e.toString().toUtf8()).object();
        else
            o = QJsonObject::fromVariantMap(e.toMap());
        const QString id = o.value("account_id").toString();
        if (id.isEmpty()) continue;
        const bool isPublic = o.value("is_public").toBool();

        QString balance = QStringLiteral("0");
        if (isPublic) {
            QByteArray reply;
            if (curlPost(LEZ_SEQUENCER,
                         ("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getAccountBalance\",\"params\":[\""
                          + toB58(id).toUtf8() + "\"]}"), reply, 6)) {
                const QJsonValue r = QJsonDocument::fromJson(reply).object().value("result");
                if (r.isDouble()) balance = QString::number(qulonglong(r.toDouble()));
            }
        } else {
            const Reply b = lezCall(QStringLiteral("get_balance"), {id, false}, 8000);
            if (b.ok) { const QString v = b.value.toString().trimmed(); balance = v.isEmpty() ? "0" : v; }
        }
        out.append(QJsonObject{{"id", id}, {"idB58", toB58(id)},
                               {"isPublic", isPublic}, {"balance", balance}});
    }
    return dump(QJsonObject{{"ok", true}, {"accounts", out}});
}

QString LogosWalletPlugin::lezCreateAccount(const QString& kind)
{
    if (!m_lezOpen) return errJson(QStringLiteral("Open the wallet first."));
    if (m_lezBusy) return dump(QJsonObject{{"ok", true}, {"accepted", false}, {"busy", true}});
    const bool wantPublic = (kind == QLatin1String("public"));
    m_lezBusy = true;
    QTimer::singleShot(0, this, [this, wantPublic]() {
        m_lezStage = QStringLiteral("creating account");
        const Reply c = lezCall(wantPublic ? QStringLiteral("create_account_public")
                                           : QStringLiteral("create_account_private"), {}, 120000);
        if (!c.ok) { m_lezBusy = false; m_lezStage.clear();
            emit eventResponse("lezAccountCreated", {errJson("Could not create account: " + c.error)}); return; }
        const QString id = c.value.toString();
        if (wantPublic)                                   // public accounts need on-chain init
            lezCall(QStringLiteral("register_public_account"), {id}, 300000);
        lezSave();
        m_lezBusy = false; m_lezStage.clear();
        emit eventResponse("lezAccountCreated",
                           {dump(QJsonObject{{"ok", true}, {"id", id}, {"idB58", toB58(id)},
                                             {"isPublic", wantPublic}})});
    });
    return dump(QJsonObject{{"ok", true}, {"accepted", true}});
}

// ── LEZ: funding via the pinata PoW faucet (proven on testnet) ───────

QString LogosWalletPlugin::lezFund()
{
    if (!m_lezOpen) return errJson(QStringLiteral("Open the wallet first."));
    if (m_lezBusy) return dump(QJsonObject{{"ok", true}, {"accepted", false}, {"busy", true}});
    m_lezBusy = true;
    QTimer::singleShot(0, this, [this]() {
        auto finish = [this](const QString& json) {
            m_lezBusy = false; m_lezStage.clear();
            emit eventResponse("lezFundFinished", {json});
        };
        m_lezStage = QStringLiteral("syncing");
        QString err;
        if (!lezSyncFully(&err)) { finish(errJson("Sync failed: " + err)); return; }
        lezSave();

        // Fresh faucet state from the sequencer RPC (seed rotates per claim).
        m_lezStage = QStringLiteral("mining");
        QByteArray rpc;
        curlPost(LEZ_SEQUENCER,
                 ("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getAccount\",\"params\":[\""
                  + PINATA_B58.toUtf8() + "\"]}"), rpc, 8);
        const QJsonArray da = QJsonDocument::fromJson(rpc).object()
                                  .value("result").toObject().value("data").toArray();
        QByteArray data;
        for (const QJsonValue& v : da) data.append(char(v.toInt()));
        if (data.size() != 33) { finish(errJson("Could not read the faucet — try again.")); return; }
        const int difficulty = quint8(data[0]);
        const QByteArray seed = data.mid(1);
        QByteArray buf = seed + QByteArray(16, '\0');
        qulonglong solution = 0; bool found = false;
        for (; solution < Q_UINT64_C(0xFFFFFFFFFF); ++solution) {
            qulonglong v = solution;
            for (int i = 0; i < 8; ++i) { buf[32 + i] = char(v & 0xff); v >>= 8; }
            const QByteArray d = QCryptographicHash::hash(buf, QCryptographicHash::Sha256);
            bool zero = true;
            for (int i = 0; i < difficulty; ++i) if (d[i] != 0) { zero = false; break; }
            if (zero) { found = true; break; }
        }
        if (!found) { finish(errJson("Mining failed — try again.")); return; }

        const QString pub = lezPublicAccount();   // create + register + persist
        if (pub.isEmpty()) { finish(errJson("Could not create the receiving account.")); return; }
        m_lezStage = QStringLiteral("claiming");
        const Reply claim = lezCall(QStringLiteral("claim_pinata"),
                                    {PINATA_ID, pub, amountLe16Hex(solution)}, 300000);
        if (!claim.ok) { finish(errJson("Claim failed: " + claim.error)); return; }
        lezSave();

        // Shield the prize into the PRIVATE account so it shows as private
        // balance and is ready for fully-hidden private→private payments.
        // Re-sync first so the wallet sees the just-claimed public note
        // (shielding an unseen note fails with InsufficientFunds).
        m_lezStage = QStringLiteral("shielding");
        QString serr;
        lezSyncFully(&serr);
        const Reply shield = lezCall(QStringLiteral("transfer_shielded_owned"),
                                     {pub, m_lezAccount, amountLe16Hex(150)}, 300000);
        if (shield.ok) { lezSave();
            finish(dump(QJsonObject{{"ok", true}, {"prize", 150}, {"shielded", true}}));
        } else {
            // The 150 is safely in the public account; shielding can be
            // retried. Report success with a note rather than losing it.
            finish(dump(QJsonObject{{"ok", true}, {"prize", 150}, {"shielded", false},
                                    {"account", pub}, {"note", shield.error}}));
        }
    });
    return dump(QJsonObject{{"ok", true}, {"accepted", true}});
}

// ── LEZ: transfers (public / shielded public→private / private→private) ─

// Pick a private account that can cover `need`: prefer the primary account,
// otherwise any owned private account holding enough. A wallet can shield into
// whichever private account it likes, so the funded one isn't always the
// primary — spend from wherever the notes actually are.
QString LogosWalletPlugin::lezPrivateSource(qulonglong need)
{
    auto balOf = [this](const QString& id) -> qulonglong {
        const Reply b = lezCall(QStringLiteral("get_balance"), {id, false}, 8000);
        return b.ok ? b.value.toString().trimmed().toULongLong() : 0ULL;
    };
    if (!m_lezAccount.isEmpty() && balOf(m_lezAccount) >= need) return m_lezAccount;
    const Reply list = lezCall(QStringLiteral("list_accounts"), {}, 15000);
    if (list.ok) {
        for (const QVariant& e : list.value.toList()) {
            const QJsonObject o = e.canConvert<QString>()
                ? QJsonDocument::fromJson(e.toString().toUtf8()).object()
                : QJsonObject::fromVariantMap(e.toMap());
            if (o.value("is_public").toBool()) continue;
            const QString id = o.value("account_id").toString();
            if (id.isEmpty() || id == m_lezAccount) continue;
            if (balOf(id) >= need) return id;
        }
    }
    return m_lezAccount;   // fall back to primary; an insufficient balance surfaces as the FFI error
}

QString LogosWalletPlugin::lezReceiveAddress(const QString& accountHex)
{
    static const QRegularExpression hex64(QStringLiteral("^[0-9a-fA-F]{64}$"));
    const QString id = accountHex.trimmed().toLower();
    if (!hex64.match(id).hasMatch()) return errJson(QStringLiteral("Not a valid account id."));
    if (!m_lezOpen) return errJson(QStringLiteral("Open the wallet first."));
    // The shielded receiving keys (viewing + nullifier public keys). Only this
    // wallet can produce them, and only for accounts it owns.
    const Reply k = lezCall(QStringLiteral("get_private_account_keys"), {id}, 10000);
    if (!k.ok) return errJson("Could not read the receiving keys: " + k.error);
    // Wrap the keys JSON as one opaque, pasteable token.
    const QString token = QStringLiteral("lezpriv1")
        + QString::fromUtf8(k.value.toString().toUtf8().toBase64());
    return dump(QJsonObject{{"ok", true}, {"address", token}});
}

QString LogosWalletPlugin::lezTransfer(const QString& kind, const QString& fromAccountHex,
                                       const QString& toAccountHex, const QString& amount)
{
    static const QRegularExpression hex64(QStringLiteral("^[0-9a-fA-F]{64}$"));
    const QString toRaw = toAccountHex.trimmed();
    const bool toIsHex  = hex64.match(toRaw).hasMatch();
    const bool toIsAddr = toRaw.startsWith(QLatin1String("lezpriv1"));
    if (!toIsHex && !toIsAddr)
        return errJson(QStringLiteral("Recipient must be a valid account id or receiving address."));
    const QString explicitFrom = fromAccountHex.trimmed().toLower();
    if (!explicitFrom.isEmpty() && !hex64.match(explicitFrom).hasMatch())
        return errJson(QStringLiteral("Sender must be a valid account id."));
    bool ok = false;
    const qulonglong v = amount.trimmed().toULongLong(&ok);
    if (!ok || v == 0) return errJson(QStringLiteral("Amount must be a positive whole number."));
    if (!m_lezOpen) return errJson(QStringLiteral("Open the wallet first."));
    if (m_lezBusy) return dump(QJsonObject{{"ok", true}, {"accepted", false}, {"busy", true}});

    // Method + which side funds the transfer. When the caller names a sender
    // explicitly we use it verbatim; otherwise we auto-pick (deferred into the
    // worker below, since for private sources it scans balances and for public
    // it may create/register an account on-chain — neither can run
    // synchronously on the UI thread).
    QString method;
    bool privSource, privDest = false;
    if (kind == QLatin1String("private")) {
        method = QStringLiteral("transfer_private");    privSource = true; privDest = true; // private→private
    } else if (kind == QLatin1String("shielded")) {
        method = QStringLiteral("transfer_shielded_owned"); privSource = false; // public→private (owned)
    } else if (kind == QLatin1String("deshielded")) {
        method = QStringLiteral("transfer_deshielded"); privSource = true;   // private→public
    } else {
        method = QStringLiteral("transfer_public");     privSource = false;  // public→public
    }
    m_lezBusy = true;
    QTimer::singleShot(0, this, [this, method, privSource, privDest, explicitFrom, toRaw, toIsAddr, v]() {
        m_lezStage = QStringLiteral("transferring");   // zk proving — slow
        auto finishErr = [this](const QString& e) {
            m_lezBusy = false; m_lezStage.clear();
            emit eventResponse("lezTransferFinished", {errJson(e)});
        };
        const QString from = !explicitFrom.isEmpty()
            ? explicitFrom
            : (privSource ? lezPrivateSource(v)
                          : (m_lezPublicAccount.isEmpty() ? lezPublicAccount() : m_lezPublicAccount));
        if (from.isEmpty()) { finishErr(QStringLiteral("No sending account.")); return; }

        // A private recipient is named by its shielded keys JSON, not an id.
        // Accept either a receiving address (lezpriv1…) or — for accounts this
        // wallet owns — a plain id we resolve to keys ourselves.
        QString to;
        if (privDest) {
            if (toIsAddr) {
                to = QString::fromUtf8(QByteArray::fromBase64(toRaw.mid(8).toUtf8()));
            } else {
                const Reply k = lezCall(QStringLiteral("get_private_account_keys"), {toRaw.toLower()}, 10000);
                if (!k.ok) { finishErr(QStringLiteral("For a private payment, paste the recipient's receiving "
                                                      "address — a bare account id only works for your own accounts.")); return; }
                to = k.value.toString();
            }
        } else {
            if (toIsAddr) { finishErr(QStringLiteral("That's a private receiving address; pick a private recipient.")); return; }
            to = toRaw.toLower();
        }

        const Reply r = lezCall(method, {from, to, amountLe16Hex(v)}, 300000);
        if (r.ok) lezSave();
        m_lezBusy = false; m_lezStage.clear();
        emit eventResponse("lezTransferFinished",
                           {r.ok ? dump(QJsonObject{{"ok", true}})
                                 : errJson("Transfer failed: " + r.error)});
    });
    return dump(QJsonObject{{"ok", true}, {"accepted", true}});
}

// ── LEZ: bridge base→LEZ ─────────────────────────────────────────────

QString LogosWalletPlugin::lezBridgeIn(const QString& amount)
{
    bool ok = false;
    const qulonglong v = amount.trimmed().toULongLong(&ok);
    if (!ok || v == 0) return errJson(QStringLiteral("Amount must be a positive whole number."));
    if (!nodeAlive()) return errJson(QStringLiteral("The node is not running."));
    if (!m_lezOpen || m_lezAccount.isEmpty()) return errJson(QStringLiteral("Open the wallet first."));
    const QString pk = leaderPk();
    if (pk.isEmpty()) return errJson(QStringLiteral("No base wallet key found."));
    if (m_lezBusy) return dump(QJsonObject{{"ok", true}, {"accepted", false}, {"busy", true}});
    m_lezBusy = true;
    QTimer::singleShot(0, this, [this, pk, v]() {
        auto finish = [this](const QString& json) {
            m_lezBusy = false; m_lezStage.clear();
            emit eventResponse("lezBridgeFinished", {json});
        };
        m_lezStage = QStringLiteral("preparing");
        auto exactNote = [this, pk, v]() -> QString {
            const QByteArray b = curlGet(QStringLiteral("http://%1/wallet/%2/balance").arg(HTTP_ADDR, pk), 3);
            const QJsonObject notes = QJsonDocument::fromJson(b).object().value("notes").toObject();
            for (auto it = notes.constBegin(); it != notes.constEnd(); ++it)
                if (qulonglong(it.value().toDouble()) == v) return it.key();
            return {};
        };
        auto deposit = [this, pk, finish](const QString& note) {
            m_lezStage = QStringLiteral("depositing");
            QJsonArray meta;
            for (char b : QByteArray::fromHex(m_lezAccount.toLatin1())) meta.append(int(quint8(b)));
            const QJsonObject body{{"tip", QJsonValue::Null},
                {"deposit", QJsonObject{{"channel_id", BRIDGE_CHANNEL},
                                        {"inputs", QJsonArray{note}}, {"metadata", meta}}},
                {"change_public_key", pk}, {"funding_public_keys", QJsonArray{pk}}, {"max_tx_fee", 100}};
            QByteArray reply;
            if (!curlPost(QStringLiteral("http://") + HTTP_ADDR + "/channel/deposit",
                          QJsonDocument(body).toJson(QJsonDocument::Compact), reply))
                { finish(errJson("Deposit rejected: " + QString::fromUtf8(reply.right(300)))); return; }
            finish(dump(QJsonObject{{"ok", true}, {"kind", "deposit"},
                                    {"tx", QJsonDocument::fromJson(reply).object().value("hash").toString()}}));
        };
        const QString existing = exactNote();
        if (!existing.isEmpty()) { deposit(existing); return; }
        // Mint an exact-value note via a self-transfer, then deposit it.
        const QString st = baseSend(pk, QString::number(v));
        if (!QJsonDocument::fromJson(st.toUtf8()).object().value("ok").toBool()) { finish(st); return; }
        m_lezStage = QStringLiteral("waiting-note");
        auto tries = std::make_shared<int>(0);
        QTimer* poll = new QTimer(this);
        poll->setInterval(4000);
        connect(poll, &QTimer::timeout, this, [this, poll, tries, exactNote, deposit, finish]() {
            const QString n = exactNote();
            if (!n.isEmpty()) { poll->stop(); poll->deleteLater(); deposit(n); return; }
            if (++*tries >= 45) { poll->stop(); poll->deleteLater();
                finish(errJson("Timed out preparing the deposit note — balance unchanged, try again.")); }
        });
        poll->start();
    });
    return dump(QJsonObject{{"ok", true}, {"accepted", true}});
}

QString LogosWalletPlugin::lezClaimVault(const QString& amount)
{
    bool ok = false;
    const qulonglong v = amount.trimmed().toULongLong(&ok);
    if (!ok || v == 0) return errJson(QStringLiteral("Amount must be a positive whole number."));
    if (!m_lezOpen || m_lezAccount.isEmpty()) return errJson(QStringLiteral("Open the wallet first."));
    if (m_lezBusy) return dump(QJsonObject{{"ok", true}, {"accepted", false}, {"busy", true}});
    m_lezBusy = true;
    QTimer::singleShot(0, this, [this, v]() {
        m_lezStage = QStringLiteral("claiming");
        const Reply r = lezCall(QStringLiteral("vault_claim_private"),
                                {m_lezAccount, amountLe16Hex(v)}, 300000);
        if (r.ok) lezSave();
        m_lezBusy = false; m_lezStage.clear();
        emit eventResponse("lezBridgeFinished",
                           {r.ok ? dump(QJsonObject{{"ok", true}, {"kind", "claim"}})
                                 : errJson("Claim failed: " + r.error)});
    });
    return dump(QJsonObject{{"ok", true}, {"accepted", true}});
}
