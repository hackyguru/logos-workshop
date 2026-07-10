#include "easy_node_plugin.h"

#include <QCoreApplication>
#include <QCryptographicHash>
#include <QDebug>
#include <QDir>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QRandomGenerator>
#include <QRegularExpression>
#include <QSettings>
#include <QTimer>

// ── Network identity ─────────────────────────────────────────────────
// The official node release this module installs and runs. Bump both when a
// new release ships (assets: logos-blockchain-node-{macos,linux}-{arch}-{v}.tar.gz).
static const QString NODE_VERSION = QStringLiteral("0.2.0");

// Testnet bootstrap peers (0.2.0 genesis — rotate on genesis resets; source:
// logos-blockchain release notes / logosnode/logosup network.yml).
static const QStringList BOOTSTRAP_PEERS = {
    "/ip4/65.109.51.37/udp/3000/quic-v1/p2p/12D3KooWFrouXfmrR4nsLMtE7wu15DoMJ6VtoUtHinREZCvbWHar",
    "/ip4/65.109.51.37/udp/3001/quic-v1/p2p/12D3KooWJRGau8M1rjT7R5e4YYsgdFhsMX35nRDtMwCDjxQkXAHz",
    "/ip4/65.109.51.37/udp/3002/quic-v1/p2p/12D3KooWQXJavMDTRscjauFSgVAB1VLB6Rzpy2uY5SU9Tk7927tb",
    "/ip4/65.109.51.37/udp/50001/quic-v1/p2p/12D3KooWSQc7CcGtvWDPF1yCbBthFnQjprfCVHmfmNDUrSmqQsU1",
};

// Non-default ports: a logosup Docker node (or the stock Blockchain plugin's
// node) may already own 3000/udp and 8080 on this machine.
static const QString NET_PORT  = QStringLiteral("13000");
static const QString HTTP_ADDR = QStringLiteral("127.0.0.1:18080");

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
                          "%1/logos-blockchain-node-%2-%3-%1.tar.gz")
        .arg(NODE_VERSION, os, arch);
}

// ── JSON helpers ─────────────────────────────────────────────────────

// Local HTTP GET via curl. QML's XMLHttpRequest never fires inside
// Basecamp's QML runtime, so the UI can't poll the node itself; localhost
// round-trips are a few ms, well within the IPC reply budget.
static QByteArray curlGet(const QString& url)
{
    QProcess p;
    // Absolute path: the module host's PATH doesn't resolve bare "curl".
    p.start(QStringLiteral("/usr/bin/curl"), {QStringLiteral("-sf"), QStringLiteral("-m"),
                                              QStringLiteral("2"), url});
    if (!p.waitForFinished(3000) || p.exitCode() != 0)
        return {};
    return p.readAllStandardOutput();
}

// POST returning success flag + response body (also on errors — the node's
// rejection text is the useful part of a failed transfer).
static bool curlPost(const QString& url, const QByteArray& json, QByteArray& bodyOut)
{
    QProcess p;
    p.start(QStringLiteral("/usr/bin/curl"),
            {QStringLiteral("-s"), QStringLiteral("-m"), QStringLiteral("10"),
             QStringLiteral("-X"), QStringLiteral("POST"),
             QStringLiteral("-H"), QStringLiteral("Content-Type: application/json"),
             QStringLiteral("--data-binary"), QString::fromUtf8(json),
             QStringLiteral("-w"), QStringLiteral("\n%{http_code}"), url});
    if (!p.waitForFinished(12000)) {
        bodyOut = QByteArrayLiteral("no reply from the node");
        return false;
    }
    const QByteArray out = p.readAllStandardOutput();
    const int nl = out.lastIndexOf('\n');
    const int code = out.mid(nl + 1).trimmed().toInt();
    bodyOut = out.left(qMax(nl, 0)).trimmed();
    return code >= 200 && code < 300;
}

static QString dump(const QJsonObject& obj)
{
    return QString::fromUtf8(QJsonDocument(obj).toJson(QJsonDocument::Compact));
}

static QString errJson(const QString& message)
{
    return dump(QJsonObject{{"ok", false}, {"error", message}});
}

// ── Lifecycle ────────────────────────────────────────────────────────

EasyNodePlugin::EasyNodePlugin(QObject* parent)
    : QObject(parent)
{
    qDebug() << "EasyNodePlugin: created (binary manager," << NODE_VERSION << ")";
}

EasyNodePlugin::~EasyNodePlugin()
{
    m_userStopped = true;
    if (m_seq && m_seq->state() != QProcess::NotRunning) {
        m_seq->terminate();
        m_seq->waitForFinished(2000);
    }
    if (m_node && m_node->state() != QProcess::NotRunning) {
        m_node->terminate();
        m_node->waitForFinished(5000);
    }
}

void EasyNodePlugin::initLogos(LogosAPI* api)
{
    logosAPI = api;
    qDebug() << "EasyNodePlugin: LogosAPI wired up";
}

QString EasyNodePlugin::baseDir() const     { return QDir::homePath() + "/.logos-easy-node"; }
QString EasyNodePlugin::binPath() const     { return baseDir() + "/bin/logos-blockchain-node"; }
QString EasyNodePlugin::configPath() const  { return baseDir() + "/user_config.yaml"; }
QString EasyNodePlugin::keystorePath() const{ return baseDir() + "/keystore.yaml"; }

bool EasyNodePlugin::nodeRunning() const
{
    return m_node && m_node->state() == QProcess::Running;
}

// ── API ──────────────────────────────────────────────────────────────

QString EasyNodePlugin::status()
{
    return dump(QJsonObject{
        {"running", nodeRunning()},
        {"hasConfig", QFile::exists(configPath())},
        {"hasBinary", QFile::exists(binPath())},
        {"setupBusy", m_setupBusy},
        {"setupError", m_setupError},
        {"stage", m_stage},
        {"restarts", m_restarts},
        {"httpAddr", HTTP_ADDR},
        {"nodeVersion", NODE_VERSION},
    });
}

QString EasyNodePlugin::setupAndStart()
{
    if (m_setupBusy)
        return dump(QJsonObject{{"ok", true}, {"accepted", false}, {"busy", true}});
    if (nodeRunning())
        return dump(QJsonObject{{"ok", true}, {"accepted", false}, {"alreadyRunning", true}});

    m_setupBusy = true;
    m_setupError.clear();
    m_userStopped = false;
    m_restarts = 0;
    stepDownload();
    return dump(QJsonObject{{"ok", true}, {"accepted", true}});
}

QString EasyNodePlugin::stopNode()
{
    m_userStopped = true;
    if (m_seq && m_seq->state() != QProcess::NotRunning)
        m_seq->terminate(); // its finished-handler resets the inscribe state
    if (m_node && m_node->state() != QProcess::NotRunning) {
        m_node->terminate();
        QProcess* node = m_node;
        QTimer::singleShot(5000, this, [node]() {
            if (node && node->state() != QProcess::NotRunning)
                node->kill();
        });
    }
    return dump(QJsonObject{{"ok", true}});
}

// Addresses come from the keystore the node generated: a `public_keys:`
// block of `Role: <64-hex>` lines. LeaderFunding is the one the faucet
// should fund (it pays for inscriptions and consensus participation).
QString EasyNodePlugin::accounts()
{
    QFile f(keystorePath());
    if (!f.open(QIODevice::ReadOnly | QIODevice::Text))
        return errJson(QStringLiteral("No wallet yet — start the node first."));

    QJsonArray list;
    bool inBlock = false;
    static const QRegularExpression entry(QStringLiteral("^\\s+(\\w+):\\s*([0-9a-fA-F]{64})\\s*$"));
    while (!f.atEnd()) {
        const QString line = QString::fromUtf8(f.readLine());
        if (line.startsWith(QLatin1String("public_keys:"))) { inBlock = true; continue; }
        if (inBlock) {
            if (!line.startsWith(QLatin1Char(' ')) && !line.trimmed().isEmpty())
                break; // left the block
            const auto m = entry.match(line);
            if (m.hasMatch()) {
                const QString addr = m.captured(2).toLower();
                // Balance from the node HTTP API; -1 = unknown (node not
                // answering), 0 = known key with no funds yet.
                double balance = -1;
                const QByteArray body =
                    curlGet(QStringLiteral("http://%1/wallet/%2/balance").arg(HTTP_ADDR, addr));
                if (!body.isEmpty()) {
                    const QJsonObject o = QJsonDocument::fromJson(body).object();
                    balance = o.value(QStringLiteral("balance")).toDouble(0);
                }
                list.append(QJsonObject{{"role", m.captured(1)},
                                        {"address", addr},
                                        {"balance", balance}});
            }
        }
    }
    return dump(QJsonObject{{"ok", true}, {"accounts", list}});
}

QString EasyNodePlugin::nodeInfo()
{
    // No process check: the HTTP API is the source of truth (it also covers
    // the orphaned-node window right after a Basecamp restart).
    const QByteArray chain = curlGet(QStringLiteral("http://") + HTTP_ADDR + "/cryptarchia/info");
    const QByteArray net = curlGet(QStringLiteral("http://") + HTTP_ADDR + "/network/info");
    QJsonObject out{{"ok", true}};
    out["chain"] = chain.isEmpty() ? QJsonValue(QJsonValue::Null)
                                   : QJsonValue(QJsonDocument::fromJson(chain).object());
    out["net"] = net.isEmpty() ? QJsonValue(QJsonValue::Null)
                               : QJsonValue(QJsonDocument::fromJson(net).object());
    return dump(out);
}

// ── Setup pipeline (all async — see header) ──────────────────────────

void EasyNodePlugin::finishSetup(bool ok, const QString& error)
{
    m_setupBusy = false;
    m_stage.clear();
    m_setupError = ok ? QString() : error;
    emit eventResponse("setupFinished",
                       {ok ? dump(QJsonObject{{"ok", true}}) : errJson(error)});
}

void EasyNodePlugin::stepDownload()
{
    if (QFile::exists(binPath())) { stepInitConfig(); return; }

    QDir().mkpath(baseDir() + "/bin");
    m_stage = QStringLiteral("downloading");
    m_step = new QProcess(this);
    m_step->setWorkingDirectory(baseDir() + "/bin");
    connect(m_step, QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished), this,
            [this](int code, QProcess::ExitStatus) {
                m_step->deleteLater();
                if (code != 0) {
                    finishSetup(false, QStringLiteral("Could not download the node "
                                                      "(check your internet connection)."));
                    return;
                }
                stepExtract();
            });
    m_step->start(QStringLiteral("curl"),
                  {QStringLiteral("-sfL"), QStringLiteral("--retry"), QStringLiteral("2"),
                   QStringLiteral("-o"), QStringLiteral("node.tar.gz"), releaseUrl()});
}

void EasyNodePlugin::stepExtract()
{
    m_step = new QProcess(this);
    m_step->setWorkingDirectory(baseDir() + "/bin");
    connect(m_step, QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished), this,
            [this](int code, QProcess::ExitStatus) {
                m_step->deleteLater();
                QFile::remove(baseDir() + "/bin/node.tar.gz");
                if (code != 0 || !QFile::exists(binPath())) {
                    finishSetup(false, QStringLiteral("Could not unpack the node."));
                    return;
                }
                stepInitConfig();
            });
    m_step->start(QStringLiteral("tar"), {QStringLiteral("-xzf"), QStringLiteral("node.tar.gz")});
}

void EasyNodePlugin::stepInitConfig()
{
    // The keystore holds the wallet keys: an existing config is an existing
    // wallet, never regenerate over it.
    if (QFile::exists(configPath())) { stepSpawnNode(); return; }

    m_stage = QStringLiteral("configuring");
    QStringList args{
        QStringLiteral("init-config"),
        QStringLiteral("-o"), configPath(),
        QStringLiteral("-k"), keystorePath(),
        QStringLiteral("--http-host"), HTTP_ADDR,
        QStringLiteral("--net-port"), NET_PORT,
        QStringLiteral("--log-backend"), QStringLiteral("stdout"),
        QStringLiteral("--log-level"), QStringLiteral("info"),
        QStringLiteral("--ibd"),
        QStringLiteral("--state-path"), baseDir() + "/state",
        QStringLiteral("--storage-path"), QStringLiteral("db"),
    };
    for (const QString& p : BOOTSTRAP_PEERS)
        args << QStringLiteral("-p") << p;

    m_step = new QProcess(this);
    m_step->setWorkingDirectory(baseDir());
    connect(m_step, QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished), this,
            [this](int code, QProcess::ExitStatus) {
                const QString errOut = QString::fromUtf8(m_step->readAllStandardError()).right(400);
                m_step->deleteLater();
                if (code != 0 || !QFile::exists(configPath())) {
                    finishSetup(false, QStringLiteral("Could not create the node configuration: ")
                                           + errOut);
                    return;
                }
                stepSpawnNode();
            });
    m_step->start(binPath(), args);
}

void EasyNodePlugin::stepSpawnNode()
{
    m_stage = QStringLiteral("starting");
    spawnNode();
    finishSetup(true, {});
}

void EasyNodePlugin::spawnNode()
{
    if (nodeRunning()) return;

    // A node from a previous Basecamp session can survive as an orphan (a
    // hard quit skips our destructor) and keeps the ports — the fresh spawn
    // would crash-loop on bind. The path is unique to this module, so kill
    // by path.
    QProcess::execute(QStringLiteral("pkill"), {QStringLiteral("-f"), binPath()});

    if (!m_node) {
        m_node = new QProcess(this);
        m_node->setWorkingDirectory(baseDir());
        m_node->setStandardOutputFile(baseDir() + "/node.log", QIODevice::Truncate);
        m_node->setProcessChannelMode(QProcess::MergedChannels);
        // Docker-style `restart: unless-stopped`: 0.2.0's IBD has a known
        // race near tip (AlreadyApplied → AllPeersFailed → self-shutdown).
        // Each run resumes from the db, so restarting until the race is won
        // is the intended operating mode; once Online it stays up.
        connect(m_node, QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished), this,
                [this](int, QProcess::ExitStatus) {
                    if (m_userStopped) return;
                    ++m_restarts;
                    QTimer::singleShot(2000, this, [this]() {
                        if (!m_userStopped) spawnNode();
                    });
                });
    }
    m_node->start(binPath(), {configPath()});
}

// ── Inscribe (the node binary's built-in text sequencer) ─────────────
// One long-lived sequencer process for the whole session: bootstrap is paid
// once (it re-scans the channel's history, which takes tens of seconds on a
// used channel), each inscription is then a single stdin line, and the
// process stays alive so pending publishes actually land. Success is judged
// by the channel tip changing on-chain, not by process output.

QString EasyNodePlugin::fetchChannelTip()
{
    if (m_channelId.isEmpty())
        return {};
    const QByteArray body =
        curlGet(QStringLiteral("http://%1/channel/%2").arg(HTTP_ADDR, m_channelId));
    if (body.isEmpty())
        return {};
    return QJsonDocument::fromJson(body).object().value(QStringLiteral("tip_message")).toString();
}

QString EasyNodePlugin::inscribe(const QString& text)
{
    if (text.trimmed().isEmpty())
        return errJson(QStringLiteral("Nothing to inscribe."));
    if (!nodeRunning())
        return errJson(QStringLiteral("The node is not running."));
    if (m_inscribeBusy)
        return dump(QJsonObject{{"ok", true}, {"accepted", false}, {"busy", true}});

    m_inscribeBusy = true;
    if (m_seq && m_seqReady) {
        writeAndConfirm(text.trimmed());
    } else {
        m_pendingText = text.trimmed();
        ensureSequencer();
    }
    return dump(QJsonObject{{"ok", true}, {"accepted", true}});
}

void EasyNodePlugin::finishInscribe(const QString& resultJson)
{
    if (m_confirmTimer) {
        m_confirmTimer->stop();
        m_confirmTimer->deleteLater();
        m_confirmTimer = nullptr;
    }
    m_inscribeBusy = false;
    emit eventResponse("inscribeFinished", {resultJson});
}

void EasyNodePlugin::ensureSequencer()
{
    if (m_seq)
        return; // already booting; the pending message flushes on Ready

    m_seqBuf.clear();
    m_seqReady = false;
    m_seq = new QProcess(this);
    m_seq->setWorkingDirectory(baseDir());
    m_seq->setProcessChannelMode(QProcess::MergedChannels);

    connect(m_seq, &QProcess::readyReadStandardOutput, this, [this]() {
        m_seqBuf += QString::fromUtf8(m_seq->readAllStandardOutput());
        if (m_channelId.isEmpty()) {
            static const QRegularExpression chan(
                QStringLiteral("Channel ID:\\s*([0-9a-fA-F]{64})"));
            const auto m = chan.match(m_seqBuf);
            if (m.hasMatch())
                m_channelId = m.captured(1).toLower();
        }
        if (!m_seqReady && m_seqBuf.contains(QLatin1String("Ready."))) {
            m_seqReady = true;
            qDebug() << "EasyNodePlugin: sequencer ready, channel" << m_channelId;
            if (!m_pendingText.isEmpty()) {
                const QString text = m_pendingText;
                m_pendingText.clear();
                writeAndConfirm(text);
            }
        }
    });

    connect(m_seq, QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished), this,
            [this](int, QProcess::ExitStatus) {
                m_seq->deleteLater();
                m_seq = nullptr;
                m_seqReady = false;
                m_pendingText.clear();
                if (m_inscribeBusy)
                    finishInscribe(errJson(QStringLiteral(
                        "The inscription helper stopped — try again.")));
            });

    // Backstop for a bootstrap that never reaches Ready (node unreachable).
    QProcess* proc = m_seq;
    QTimer::singleShot(120000, this, [this, proc]() {
        if (m_seq == proc && !m_seqReady && proc->state() != QProcess::NotRunning) {
            qWarning() << "EasyNodePlugin: sequencer bootstrap timed out";
            proc->terminate();
        }
    });

    m_seq->start(binPath(),
                 {QStringLiteral("inscribe"),
                  QStringLiteral("--node-url"), QStringLiteral("http://") + HTTP_ADDR,
                  QStringLiteral("--key-path"), baseDir() + "/sequencer.key"});
}

void EasyNodePlugin::writeAndConfirm(const QString& text)
{
    m_prevTip = fetchChannelTip();
    m_seq->write((text + QLatin1Char('\n')).toUtf8()); // stdin stays open

    m_confirmTries = 0;
    m_confirmTimer = new QTimer(this);
    m_confirmTimer->setInterval(3000);
    connect(m_confirmTimer, &QTimer::timeout, this, [this]() {
        const QString tip = fetchChannelTip();
        if (!tip.isEmpty() && tip != m_prevTip) {
            finishInscribe(dump(QJsonObject{{"ok", true},
                                            {"tip", tip},
                                            {"channel", m_channelId}}));
            return;
        }
        if (++m_confirmTries >= 40) { // ~2 minutes
            finishInscribe(errJson(QStringLiteral(
                "Message sent but not confirmed on-chain yet — it may still "
                "appear in the next blocks.")));
        }
    });
    m_confirmTimer->start();
}

// ── Transfer (base-chain, via the node's wallet HTTP API) ────────────
// logosup's recipe: current tip from /cryptarchia/info, then POST
// /wallet/transactions/transfer-funds with the funding key also taking the
// change. Success = the node returns the transaction hash; the balance
// change (a few blocks later) is the user-visible confirmation.

QString EasyNodePlugin::transfer(const QString& fromAddress,
                                 const QString& toAddress,
                                 const QString& amount)
{
    static const QRegularExpression hex64(QStringLiteral("^[0-9a-fA-F]{64}$"));
    if (!hex64.match(fromAddress).hasMatch() || !hex64.match(toAddress).hasMatch())
        return errJson(QStringLiteral("Addresses must be 64 hex characters."));
    bool amountOk = false;
    const qulonglong value = amount.trimmed().toULongLong(&amountOk);
    if (!amountOk || value == 0)
        return errJson(QStringLiteral("Amount must be a positive whole number."));
    if (!nodeRunning())
        return errJson(QStringLiteral("The node is not running."));

    const QByteArray info =
        curlGet(QStringLiteral("http://") + HTTP_ADDR + "/cryptarchia/info");
    const QString tip = QJsonDocument::fromJson(info).object()
                            .value(QStringLiteral("cryptarchia_info")).toObject()
                            .value(QStringLiteral("tip")).toString();
    if (tip.isEmpty())
        return errJson(QStringLiteral("Could not read the chain tip — is the node synced?"));

    const QJsonObject payload{
        {"tip", tip},
        {"change_public_key", fromAddress.toLower()},
        {"funding_public_keys", QJsonArray{fromAddress.toLower()}},
        {"recipient_public_key", toAddress.toLower()},
        {"amount", static_cast<qint64>(value)},
    };
    QByteArray reply;
    const bool sent =
        curlPost(QStringLiteral("http://") + HTTP_ADDR + "/wallet/transactions/transfer-funds",
                 QJsonDocument(payload).toJson(QJsonDocument::Compact), reply);
    if (!sent)
        return errJson(QStringLiteral("The node rejected the transfer: ")
                       + QString::fromUtf8(reply.right(300)));

    // Reply carries the tx hash — as JSON {"hash": ...} or a bare string.
    QString tx = QJsonDocument::fromJson(reply).object()
                     .value(QStringLiteral("hash")).toString();
    if (tx.isEmpty())
        tx = QString::fromUtf8(reply).trimmed().remove(QLatin1Char('"')).left(64);
    return dump(QJsonObject{{"ok", true}, {"tx", tx}});
}

// ── LEZ private wallet (wraps the bundled logos_execution_zone) ──────
// The LEZ is where privacy-preserving transactions live. This is the same
// LogosResult→JSON adapter pattern as the rest of this module — the QML
// bridge can't consume logos_execution_zone directly. Slow calls (wallet
// create, sync chunks, zk-proving transfers) run deferred with generous
// Timeouts; the UI pauses its polling while one is in flight so timed-out
// IPC replies can't pile up (that path double-frees inside the host).

static const QString LEZ = QStringLiteral("logos_execution_zone");
static const QString LEZ_SEQUENCER = QStringLiteral("https://testnet.lez.logos.co");
static const int LEZ_SYNC_CHUNK = 1000;

LogosAPIClient* EasyNodePlugin::lezClient()
{
    if (m_lez && m_lez->isConnected())
        return m_lez;
    if (logosAPI)
        m_lez = logosAPI->getClient(LEZ);
    return m_lez;
}

// The wallet FFI is in-memory: without an explicit save() nothing reaches
// disk, and the next open() gets a broken handle (every call → FFI error 1).
// Call after every state-changing operation.
void EasyNodePlugin::lezSave()
{
    LogosAPIClient* c = lezClient();
    if (c && c->isConnected())
        c->invokeRemoteMethod(LEZ, QStringLiteral("save"), QVariantList(), Timeout(30000));
}

EasyNodePlugin::Reply EasyNodePlugin::lezCall(const QString& method, const QVariantList& args,
                                              int timeoutMs)
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
    if (!r.isValid())
        return {false, {}, QStringLiteral("no reply from logos_execution_zone (timeout?)")};
    if (r.canConvert<LogosResult>()) {
        const LogosResult lr = r.value<LogosResult>();
        return {lr.success, lr.value, lr.error.toString()};
    }
    return {true, r, {}};
}

QString EasyNodePlugin::lezStatus()
{
    QJsonObject out{{"ready", m_lezOpen && !m_lezAccount.isEmpty()},
                    {"busy", m_lezBusy},
                    {"syncing", m_lezSyncing},
                    {"account", m_lezAccount},
                    {"error", m_lezError},
                    {"hasWallet", QSettings("Logos", "EasyNode").value("lezCreated").toBool()}};
    out["bridgeStage"] = m_bridgeStage;
    if (m_lezOpen && !m_lezAccount.isEmpty()) {
        const Reply bal = lezCall(QStringLiteral("get_balance"), {m_lezAccount, false}, 8000);
        out["balance"] = bal.ok ? bal.value.toString() : QString();
        // Public gateway balance — pinata prizes land here before shielding,
        // and it's visible without a private-sync.
        const QString pub = QSettings("Logos", "EasyNode").value("lezPublicAccount").toString();
        if (!pub.isEmpty()) {
            const Reply pb = lezCall(QStringLiteral("get_balance"), {pub, true}, 8000);
            out["publicBalance"] = pb.ok ? pb.value.toString() : QString();
        }
        const Reply vault = lezCall(QStringLiteral("get_vault_balance"), {m_lezAccount}, 8000);
        out["vault"] = vault.ok ? vault.value.toString() : QString();
        const Reply last = lezCall(QStringLiteral("get_last_synced_block"), {}, 8000);
        const Reply height = lezCall(QStringLiteral("get_current_block_height"), {}, 8000);
        out["lastSynced"] = last.ok ? last.value.toDouble() : -1;
        out["height"] = height.ok ? height.value.toDouble() : -1;
    }
    return dump(out);
}

QString EasyNodePlugin::lezSetup()
{
    if (m_lezBusy)
        return dump(QJsonObject{{"ok", true}, {"accepted", false}, {"busy", true}});
    m_lezBusy = true;
    m_lezError.clear();

    QTimer::singleShot(0, this, [this]() {
        const QString dir = baseDir() + "/lez";
        const QString cfg = dir + "/config.json";
        // storage_path is a FILE the wallet reads/writes (from_path → File::open,
        // save_to_path → write), NOT a directory. Passing a dir means save()
        // silently fails and the next open() gets a broken handle.
        const QString storage = dir + "/storage.json";
        QDir().mkpath(dir);
        if (!QFile::exists(cfg)) {
            QFile f(cfg);
            f.open(QIODevice::WriteOnly);
            f.write(QJsonDocument(QJsonObject{
                        {"sequencer_addr", LEZ_SEQUENCER},
                        {"seq_poll_timeout", "30s"},
                        {"seq_tx_poll_max_blocks", 15},
                        {"seq_poll_max_retries", 10},
                        {"seq_block_poll_max_amount", 100},
                    }).toJson(QJsonDocument::Compact));
        }

        QSettings s("Logos", "EasyNode");
        QString mnemonic;
        if (!m_lezOpen) {
            if (s.value("lezCreated").toBool()) {
                const Reply r = lezCall(QStringLiteral("open"), {cfg, storage}, 60000);
                if (!r.ok) {
                    m_lezBusy = false;
                    m_lezError = "Could not open the private wallet: " + r.error;
                    emit eventResponse("lezSetupFinished", {errJson(m_lezError)});
                    return;
                }
            } else {
                // Local wallet-encryption password; kept in settings so the
                // one-button UX survives restarts. Testnet-grade convenience —
                // the mnemonic (shown once) is the real recovery path.
                QString pw = s.value("lezPassword").toString();
                if (pw.isEmpty()) {
                    pw = QString::number(QRandomGenerator::global()->generate64(), 16)
                         + QString::number(QRandomGenerator::global()->generate64(), 16);
                    s.setValue("lezPassword", pw);
                }
                const Reply r = lezCall(QStringLiteral("create_new"), {cfg, storage, pw}, 120000);
                if (!r.ok) {
                    m_lezBusy = false;
                    m_lezError = "Could not create the private wallet: " + r.error;
                    emit eventResponse("lezSetupFinished", {errJson(m_lezError)});
                    return;
                }
                mnemonic = r.value.toString();
                lezSave();
                s.setValue("lezCreated", true);
            }
            m_lezOpen = true;
        }

        m_lezAccount = s.value("lezAccount").toString();
        if (m_lezAccount.isEmpty()) {
            const Reply r = lezCall(QStringLiteral("create_account_private"), {}, 120000);
            if (!r.ok) {
                m_lezBusy = false;
                m_lezError = "Could not create a private account: " + r.error;
                emit eventResponse("lezSetupFinished", {errJson(m_lezError)});
                return;
            }
            m_lezAccount = r.value.toString();
            lezSave();
            s.setValue("lezAccount", m_lezAccount);
        }

        m_lezBusy = false;
        emit eventResponse("lezSetupFinished",
                           {dump(QJsonObject{{"ok", true},
                                             {"account", m_lezAccount},
                                             {"mnemonic", mnemonic}})});
    });
    return dump(QJsonObject{{"ok", true}, {"accepted", true}});
}

QString EasyNodePlugin::lezSync()
{
    if (m_lezSyncing || m_lezBusy)
        return dump(QJsonObject{{"ok", true}, {"accepted", false}, {"busy", true}});
    if (!m_lezOpen)
        return errJson(QStringLiteral("Private wallet not set up yet."));
    m_lezSyncing = true;

    QTimer::singleShot(0, this, [this]() {
        const Reply height = lezCall(QStringLiteral("get_current_block_height"), {}, 30000);
        const Reply last = lezCall(QStringLiteral("get_last_synced_block"), {}, 30000);
        if (!height.ok || !last.ok) {
            m_lezSyncing = false;
            emit eventResponse("lezSyncFinished",
                               {errJson("Could not reach the LEZ sequencer: "
                                        + (height.ok ? last.error : height.error))});
            return;
        }
        const qlonglong h = height.value.toLongLong();
        const qlonglong l = last.value.toLongLong();
        if (l >= h) {
            m_lezSyncing = false;
            emit eventResponse("lezSyncFinished",
                               {dump(QJsonObject{{"ok", true}, {"done", true},
                                                 {"lastSynced", double(l)}, {"height", double(h)}})});
            return;
        }
        const qlonglong target = qMin(l + LEZ_SYNC_CHUNK, h);
        const Reply r = lezCall(QStringLiteral("sync_to_block"),
                                {QVariant::fromValue(int(target))}, 180000);
        m_lezSyncing = false;
        if (!r.ok) {
            emit eventResponse("lezSyncFinished", {errJson("Sync failed: " + r.error)});
            return;
        }
        lezSave();   // persist scan progress so a restart resumes, not restarts
        emit eventResponse("lezSyncFinished",
                           {dump(QJsonObject{{"ok", true}, {"done", target >= h},
                                             {"lastSynced", double(target)}, {"height", double(h)}})});
    });
    return dump(QJsonObject{{"ok", true}, {"accepted", true}});
}

QString EasyNodePlugin::lezTransfer(const QString& toAccountHex, const QString& amount)
{
    static const QRegularExpression hex64(QStringLiteral("^[0-9a-fA-F]{64}$"));
    if (!hex64.match(toAccountHex).hasMatch())
        return errJson(QStringLiteral("Recipient must be a valid LEZ account id."));
    bool amountOk = false;
    const qulonglong value = amount.trimmed().toULongLong(&amountOk);
    if (!amountOk || value == 0)
        return errJson(QStringLiteral("Amount must be a positive whole number."));
    if (!m_lezOpen || m_lezAccount.isEmpty())
        return errJson(QStringLiteral("Private wallet not set up yet."));
    if (m_lezBusy)
        return dump(QJsonObject{{"ok", true}, {"accepted", false}, {"busy", true}});
    m_lezBusy = true;

    // Amounts cross the FFI as 16-byte little-endian hex (the stock wallet's
    // amountToLe16Hex convention).
    QByteArray le(16, '\0');
    qulonglong v = value;
    for (int i = 0; i < 8; ++i) { le[i] = char(v & 0xff); v >>= 8; }
    const QString amountHex = QString::fromLatin1(le.toHex());

    const QString to = toAccountHex.toLower();
    QTimer::singleShot(0, this, [this, to, amountHex]() {
        // zk proving makes this the slowest call in the whole plugin.
        const Reply r = lezCall(QStringLiteral("transfer_private"),
                                {m_lezAccount, to, amountHex}, 300000);
        if (r.ok) lezSave();
        m_lezBusy = false;
        emit eventResponse("lezTransferFinished",
                           {r.ok ? dump(QJsonObject{{"ok", true},
                                                    {"result", r.value.toString()}})
                                 : errJson("Private transfer failed: " + r.error)});
    });
    return dump(QJsonObject{{"ok", true}, {"accepted", true}});
}

// ── Bridge: base chain ⇄ LEZ ─────────────────────────────────────────
// Verified against logos-execution-zone @ a0ba600 and logos-blockchain
// @ 22574c2 (see part14 README):
//   • deposit metadata = the recipient zone account id's raw 32 bytes
//     (borsh of a single [u8;32] field — bad metadata burns the deposit);
//   • the LEZ bridge channel on this testnet is 0x01 × 32 (verified live:
//     single accredited sequencer key, active tip, nonzero balance);
//   • deposits credit a per-owner vault PDA only after L1 *finality*
//     (~1 h lag on this testnet) — claiming is a separate, user-visible step;
//   • withdrawals need a public zone sender; arriving funds become ordinary
//     L1 notes, no claim needed.

static const QString LEZ_BRIDGE_CHANNEL =
    QStringLiteral("0101010101010101010101010101010101010101010101010101010101010101");

QString EasyNodePlugin::leaderPk()
{
    QFile f(keystorePath());
    if (!f.open(QIODevice::ReadOnly | QIODevice::Text))
        return {};
    static const QRegularExpression leader(
        QStringLiteral("^\\s+LeaderFunding:\\s*([0-9a-fA-F]{64})\\s*$"));
    while (!f.atEnd()) {
        const auto m = leader.match(QString::fromUtf8(f.readLine()));
        if (m.hasMatch())
            return m.captured(1).toLower();
    }
    return {};
}

QString EasyNodePlugin::lezPublicAccount()
{
    QSettings s("Logos", "EasyNode");
    QString acct = s.value("lezPublicAccount").toString();
    if (!acct.isEmpty())
        return acct;
    const Reply r = lezCall(QStringLiteral("create_account_public"), {}, 120000);
    if (!r.ok)
        return {};
    acct = r.value.toString();
    lezSave();
    s.setValue("lezPublicAccount", acct);
    return acct;
}

// 16-byte little-endian hex for in-zone u128 amounts.
static QString amountLe16Hex(qulonglong v)
{
    QByteArray le(16, '\0');
    for (int i = 0; i < 8; ++i) { le[i] = char(v & 0xff); v >>= 8; }
    return QString::fromLatin1(le.toHex());
}

QString EasyNodePlugin::lezDeposit(const QString& amount)
{
    bool amountOk = false;
    const qulonglong value = amount.trimmed().toULongLong(&amountOk);
    if (!amountOk || value == 0)
        return errJson(QStringLiteral("Amount must be a positive whole number."));
    if (!nodeRunning())
        return errJson(QStringLiteral("The node is not running."));
    if (!m_lezOpen || m_lezAccount.isEmpty())
        return errJson(QStringLiteral("Private wallet not set up yet."));
    const QString pk = leaderPk();
    if (pk.isEmpty())
        return errJson(QStringLiteral("No base wallet key found."));
    if (m_lezBusy)
        return dump(QJsonObject{{"ok", true}, {"accepted", false}, {"busy", true}});
    m_lezBusy = true;
    m_bridgeStage = QStringLiteral("preparing");

    // The deposit op consumes whole notes, so we need a note worth exactly
    // `amount`: self-transfer to mint one, poll until it lands, then deposit.
    auto finish = [this](const QString& json) {
        m_lezBusy = false;
        m_bridgeStage.clear();
        emit eventResponse("lezDepositFinished", {json});
    };

    auto findExactNote = [this, pk, value]() -> QString {
        const QByteArray body =
            curlGet(QStringLiteral("http://%1/wallet/%2/balance").arg(HTTP_ADDR, pk));
        const QJsonObject notes =
            QJsonDocument::fromJson(body).object().value(QStringLiteral("notes")).toObject();
        for (auto it = notes.constBegin(); it != notes.constEnd(); ++it)
            if (qulonglong(it.value().toDouble()) == value)
                return it.key();
        return {};
    };

    auto doDeposit = [this, pk, finish](const QString& noteId) {
        m_bridgeStage = QStringLiteral("depositing");
        QJsonArray metadata;
        // Raw account-id bytes, JSON-encoded as byte numbers.
        const QByteArray acct = QByteArray::fromHex(m_lezAccount.toLatin1());
        for (const char b : acct)
            metadata.append(int(quint8(b)));
        const QJsonObject body{
            {"tip", QJsonValue::Null},
            {"deposit", QJsonObject{{"channel_id", LEZ_BRIDGE_CHANNEL},
                                    {"inputs", QJsonArray{noteId}},
                                    {"metadata", metadata}}},
            {"change_public_key", pk},
            {"funding_public_keys", QJsonArray{pk}},
            {"max_tx_fee", 100},
        };
        QByteArray reply;
        const bool sent = curlPost(QStringLiteral("http://") + HTTP_ADDR + "/channel/deposit",
                                   QJsonDocument(body).toJson(QJsonDocument::Compact), reply);
        if (!sent) {
            finish(errJson(QStringLiteral("The node rejected the deposit: ")
                           + QString::fromUtf8(reply.right(300))));
            return;
        }
        const QString tx = QJsonDocument::fromJson(reply).object()
                               .value(QStringLiteral("hash")).toString();
        finish(dump(QJsonObject{{"ok", true}, {"tx", tx}}));
    };

    QTimer::singleShot(0, this, [this, pk, value, finish, findExactNote, doDeposit]() {
        const QString existing = findExactNote();
        if (!existing.isEmpty()) { doDeposit(existing); return; }
        // Mint an exact-value note by transferring to ourselves.
        const QString selfTransfer = transfer(pk, pk, QString::number(value));
        const QJsonObject r = QJsonDocument::fromJson(selfTransfer.toUtf8()).object();
        if (!r.value(QStringLiteral("ok")).toBool()) {
            finish(selfTransfer);
            return;
        }
        m_bridgeStage = QStringLiteral("waiting-note");
        auto tries = std::make_shared<int>(0);
        QTimer* poll = new QTimer(this);
        poll->setInterval(4000);
        connect(poll, &QTimer::timeout, this, [this, poll, tries, findExactNote, doDeposit, finish]() {
            const QString note = findExactNote();
            if (!note.isEmpty()) {
                poll->stop(); poll->deleteLater();
                doDeposit(note);
                return;
            }
            if (++*tries >= 45) { // ~3 minutes
                poll->stop(); poll->deleteLater();
                finish(errJson(QStringLiteral(
                    "Timed out preparing the deposit note — your balance is unchanged, try again.")));
            }
        });
        poll->start();
    });
    return dump(QJsonObject{{"ok", true}, {"accepted", true}});
}

QString EasyNodePlugin::lezClaimVault(const QString& amount)
{
    bool amountOk = false;
    const qulonglong value = amount.trimmed().toULongLong(&amountOk);
    if (!amountOk || value == 0)
        return errJson(QStringLiteral("Amount must be a positive whole number."));
    if (!m_lezOpen || m_lezAccount.isEmpty())
        return errJson(QStringLiteral("Private wallet not set up yet."));
    if (m_lezBusy)
        return dump(QJsonObject{{"ok", true}, {"accepted", false}, {"busy", true}});
    m_lezBusy = true;
    m_bridgeStage = QStringLiteral("claiming");

    QTimer::singleShot(0, this, [this, value]() {
        const Reply r = lezCall(QStringLiteral("vault_claim_private"),
                                {m_lezAccount, amountLe16Hex(value)}, 300000);
        if (r.ok) lezSave();
        m_lezBusy = false;
        m_bridgeStage.clear();
        emit eventResponse("lezClaimFinished",
                           {r.ok ? dump(QJsonObject{{"ok", true}})
                                 : errJson("Claim failed: " + r.error)});
    });
    return dump(QJsonObject{{"ok", true}, {"accepted", true}});
}

QString EasyNodePlugin::lezWithdraw(const QString& amount)
{
    bool amountOk = false;
    const qulonglong value = amount.trimmed().toULongLong(&amountOk);
    if (!amountOk || value == 0)
        return errJson(QStringLiteral("Amount must be a positive whole number."));
    if (!m_lezOpen || m_lezAccount.isEmpty())
        return errJson(QStringLiteral("Private wallet not set up yet."));
    const QString pk = leaderPk();
    if (pk.isEmpty())
        return errJson(QStringLiteral("No base wallet key found."));
    if (m_lezBusy)
        return dump(QJsonObject{{"ok", true}, {"accepted", false}, {"busy", true}});
    m_lezBusy = true;
    m_bridgeStage = QStringLiteral("deshielding");

    QTimer::singleShot(0, this, [this, pk, value]() {
        auto finish = [this](const QString& json) {
            m_lezBusy = false;
            m_bridgeStage.clear();
            emit eventResponse("lezWithdrawFinished", {json});
        };

        const QString pub = lezPublicAccount();
        if (pub.isEmpty()) {
            finish(errJson(QStringLiteral("Could not create the public gateway account.")));
            return;
        }
        // Private → public inside the zone (bridge withdrawals need a public
        // sender). zk proving — the slow part.
        const Reply de = lezCall(QStringLiteral("transfer_deshielded"),
                                 {m_lezAccount, pub, amountLe16Hex(value)}, 300000);
        if (!de.ok) {
            finish(errJson("Could not move funds to the gateway account: " + de.error));
            return;
        }
        lezSave();

        // Wait until the zone credits the public account, then withdraw.
        m_bridgeStage = QStringLiteral("withdrawing");
        auto tries = std::make_shared<int>(0);
        QTimer* poll = new QTimer(this);
        poll->setInterval(5000);
        connect(poll, &QTimer::timeout, this, [this, poll, tries, pub, pk, value, finish]() {
            const Reply bal = lezCall(QStringLiteral("get_balance"), {pub, true}, 15000);
            if (bal.ok && bal.value.toString().toULongLong() >= value) {
                poll->stop(); poll->deleteLater();
                const Reply w = lezCall(QStringLiteral("bridge_withdraw"),
                                        {pub, pk, int(value)}, 300000);
                if (w.ok) lezSave();
                finish(w.ok
                           ? dump(QJsonObject{{"ok", true}})
                           : errJson("Withdraw failed: " + w.error));
                return;
            }
            if (++*tries >= 36) { // ~3 minutes
                poll->stop(); poll->deleteLater();
                finish(errJson(QStringLiteral(
                    "The gateway account was not credited in time — the funds are in your "
                    "public zone account; try the withdraw again shortly.")));
            }
        });
        poll->start();
    });
    return dump(QJsonObject{{"ok", true}, {"accepted", true}});
}

// ── Pinata: the zone's permissionless PoW faucet ─────────────────────
// A genesis system account (id 0xcafe…, 1.5M balance, difficulty 3) whose
// program pays 150 tokens to anyone presenting `solution: u128` such that
// SHA256(seed ‖ solution_le16) starts with `difficulty` zero bytes; the
// seed rotates on every claim. Difficulty 3 ≈ 16M hashes — under a minute
// on a laptop. Claiming into a private account uses the *_not_initialized /
// *_already_initialized variants (the facade fetches the Merkle proof
// itself, so dummy proof args are fine).

static const QString PINATA_ID =
    QStringLiteral("cafecafecafecafecafecafecafecafecafecafecafecafecafecafecafecafe");

QString EasyNodePlugin::lezMine()
{
    if (!m_lezOpen || m_lezAccount.isEmpty())
        return errJson(QStringLiteral("Private wallet not set up yet."));
    if (m_lezBusy)
        return dump(QJsonObject{{"ok", true}, {"accepted", false}, {"busy", true}});
    m_lezBusy = true;
    m_bridgeStage = QStringLiteral("mining");

    QTimer::singleShot(0, this, [this]() {
        auto finish = [this](const QString& json) {
            m_lezBusy = false;
            m_bridgeStage.clear();
            emit eventResponse("lezMineFinished", {json});
        };

        // ── Full sync first ──────────────────────────────────────────
        // Every write is proven against the wallet's SYNCED view; an
        // unsynced wallet builds proofs against empty state and the
        // sequencer drops the tx. Drive sync_to_block in a loop until the
        // wallet catches up to the sequencer tip. (The old UI-triggered
        // sync never fired because it gated on a status call that timed
        // out — this core-driven loop is unconditional.)
        m_bridgeStage = QStringLiteral("syncing");
        for (int i = 0; i < 200; ++i) {
            const Reply h = lezCall(QStringLiteral("get_current_block_height"), {}, 30000);
            const Reply l = lezCall(QStringLiteral("get_last_synced_block"), {}, 30000);
            if (!h.ok || !l.ok) {
                finish(errJson("Could not reach the LEZ sequencer to sync: "
                               + (h.ok ? l.error : h.error)));
                return;
            }
            const qlonglong height = h.value.toLongLong();
            const qlonglong last = l.value.toLongLong();
            qDebug() << "EasyNodePlugin: LEZ sync" << last << "/" << height;
            if (last >= height) break;
            const qlonglong target = qMin(last + 1000, height);
            const Reply s = lezCall(QStringLiteral("sync_to_block"),
                                    {QVariant::fromValue(int(target))}, 180000);
            if (!s.ok) { finish(errJson("Sync failed: " + s.error)); return; }
        }
        lezSave();

        // Read the faucet account fresh from the sequencer's JSON-RPC — the
        // wallet's local copy lags sync, and the puzzle seed rotates on
        // every claim, so a stale seed mines a dead solution.
        m_bridgeStage = QStringLiteral("mining");
        QByteArray rpcReply;
        curlPost(LEZ_SEQUENCER,
                 QByteArrayLiteral("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getAccount\","
                                   "\"params\":[\"EfQhKQAkX2FJiwNii2WFQsGndjvF1Mzd7RuVe7QdPLw7\"]}"),
                 rpcReply);
        const QJsonArray dataArr = QJsonDocument::fromJson(rpcReply).object()
                                       .value(QStringLiteral("result")).toObject()
                                       .value(QStringLiteral("data")).toArray();
        QByteArray data;
        for (const QJsonValue& v : dataArr)
            data.append(char(v.toInt()));
        if (data.size() != 33) {
            finish(errJson(QStringLiteral("Could not read the faucet from the sequencer — "
                                          "check your connection and try again.")));
            return;
        }
        const int difficulty = quint8(data[0]);
        const QByteArray seed = data.mid(1);

        // Brute-force the puzzle. u64 counter is ample for difficulty ≤ 4.
        QByteArray buf = seed + QByteArray(16, '\0');
        qulonglong solution = 0;
        bool found = false;
        for (; solution < Q_UINT64_C(0xFFFFFFFFFF); ++solution) {
            qulonglong v = solution;
            for (int i = 0; i < 8; ++i) { buf[32 + i] = char(v & 0xff); v >>= 8; }
            const QByteArray digest =
                QCryptographicHash::hash(buf, QCryptographicHash::Sha256);
            bool zero = true;
            for (int i = 0; i < difficulty; ++i)
                if (digest[i] != 0) { zero = false; break; }
            if (zero) { found = true; break; }
        }
        if (!found) {
            finish(errJson(QStringLiteral("Mining failed — try again.")));
            return;
        }
        qDebug() << "EasyNodePlugin: pinata solution" << solution;

        // Claim into a PUBLIC account, then shield public→private. Claiming
        // straight into a private account trips a zkVM circuit assertion
        // ("modified but not claimed"); whisper-wall's proven flow also
        // claims to a public account first.
        const QString pub = lezPublicAccount();
        if (pub.isEmpty()) {
            finish(errJson(QStringLiteral("Could not create the receiving account.")));
            return;
        }

        // Register (initialize) the public account on-chain BEFORE claiming —
        // pinata refuses an uninitialized recipient. register_public_account
        // uses the authenticated_transfer program, so if THIS lands on the
        // testnet, the bundled module's program version matches the
        // deployment (the whole open question).
        m_bridgeStage = QStringLiteral("registering");
        const Reply reg = lezCall(QStringLiteral("register_public_account"), {pub}, 300000);
        if (reg.ok) lezSave();
        qDebug() << "EasyNodePlugin: register_public_account ok=" << reg.ok
                 << "err=" << reg.error;

        m_bridgeStage = QStringLiteral("claiming");
        const QString solutionHex = amountLe16Hex(solution);
        const Reply claim = lezCall(QStringLiteral("claim_pinata"),
                                    {PINATA_ID, pub, solutionHex}, 300000);
        if (!claim.ok) {
            finish(errJson("Claim failed (register ok=" + QString(reg.ok ? "yes" : "no")
                           + "): " + claim.error));
            return;
        }
        lezSave();
        // Report the public account so the UI/log can verify the balance
        // landed on-chain (the definitive version-match proof).
        finish(dump(QJsonObject{{"ok", true}, {"prize", 150}, {"account", pub}}));
    });
    return dump(QJsonObject{{"ok", true}, {"accepted", true}});
}
