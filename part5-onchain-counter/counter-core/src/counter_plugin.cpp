#include "counter_plugin.h"

#include <QDateTime>
#include <QDebug>
#include <QDir>
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonObject>
#include <QStandardPaths>
#include <QStringList>
#include <QTimer>

// ── implementation notes ─────────────────────────────────────────────
//
// Part 5 talks to the blockchain through TWO host-installed CLIs:
//
//   spel    — invokes an instruction on the deployed counter program,
//             and `spel inspect <pda> --type CounterState` decodes the PDA
//             into JSON.
//   wallet  — manages accounts and the sequencer endpoint config.
//
// We shell out via QProcess rather than linking against the Rust crates
// because: (a) those crates are built with `wallet v0.1.0` / `nssa_core
// v0.2.0-rc1` tagged revs, their API surface isn't stable yet, and (b)
// Basecamp modules already have a pattern of using external binaries
// (e.g. `storage_module` runs libstorage in a subprocess). The CLIs ship
// with sensible defaults (NSSA_WALLET_HOME_DIR for the wallet config dir,
// spel.toml for the program/IDL paths) so we don't need to re-implement
// JSON-RPC against the sequencer.
//
// The counter program itself must be deployed separately before this
// plugin is useful — see the top-level Part 5 README for the recipe
// (`cd counter-program && make build idl setup deploy`).

namespace {

// Where QProcess looks for `spel` and `wallet`. The nix-built Basecamp
// subprocess won't see the user's shell PATH by default, so we probe common
// locations (cargo home, homebrew) and the current PATH.
QString findBin(const QString& name)
{
    const QStringList candidates = {
        QDir::homePath() + "/.cargo/bin/" + name,      // default cargo install dir
        "/usr/local/bin/" + name,
        "/opt/homebrew/bin/" + name,
    };
    for (const QString& path : candidates) {
        if (QFileInfo::exists(path)) return path;
    }
    return name;   // fall back to PATH lookup by QProcess
}

} // namespace

// ── lifecycle ────────────────────────────────────────────────────────

CounterPlugin::CounterPlugin(QObject* parent)
    : QObject(parent)
{
    qDebug() << "CounterPlugin: created";
}

CounterPlugin::~CounterPlugin()
{
    if (m_inflightProc) m_inflightProc->kill();
}

void CounterPlugin::initLogos(LogosAPI* api)
{
    logosAPI = api;
    // Auto-populate sequencer URL from wallet config. If wallet isn't
    // installed or configured, we leave m_sequencerUrl blank and the UI
    // prompts the user to set one.
    const QString raw = runCli({"config", "get", "sequencer-addr"}, 5000);
    m_sequencerUrl = raw.trimmed();
    qInfo().noquote() << "CounterPlugin: wallet sequencer-addr =" << m_sequencerUrl;

    // Probe the chain once at startup. Everything below is async so we
    // return control quickly; the UI's first poll will see either
    // m_chainStatus == 2 (ready) or 3 (unreachable) depending on whether
    // inspect succeeded.
    kickRefresh();
}

// ── getters ──────────────────────────────────────────────────────────

int     CounterPlugin::chainStatus() { return m_chainStatus; }
QString CounterPlugin::lastError()   { return m_lastError; }
QString CounterPlugin::sequencerUrl(){ return m_sequencerUrl; }

QString CounterPlugin::currentCount()
{
    QJsonObject o;
    o["count"]     = QString::number(m_lastCount);
    o["fetchedAt"] = m_fetchedAtSecs > 0
        ? QDateTime::fromSecsSinceEpoch(m_fetchedAtSecs).toUTC().toString(Qt::ISODate)
        : QString();
    return QString::fromUtf8(QJsonDocument(o).toJson(QJsonDocument::Compact));
}

// ── sequencer URL ────────────────────────────────────────────────────

bool CounterPlugin::setSequencerUrl(const QString& url)
{
    const QString trimmed = url.trimmed();
    if (trimmed.isEmpty()) return false;
    const QString result = runCli({"config", "set", "sequencer-addr", trimmed}, 5000);
    m_sequencerUrl = trimmed;
    qInfo().noquote() << "CounterPlugin: sequencer-addr set to" << trimmed
                      << "(wallet reply:" << result.left(120) << ")";
    kickRefresh();
    return true;
}

// ── actions ──────────────────────────────────────────────────────────

bool CounterPlugin::increment()
{
    // `spel` reads the program binary, IDL, and signer from spel.toml /
    // the wallet's default signer. If either isn't configured the CLI
    // fails noisily; the message lands in m_lastError via runCli's capture.
    qInfo() << "CounterPlugin: increment() dispatch";
    const QString result = runCli({"--", "increment"}, 120 * 1000);
    if (m_chainStatus == 3) return false;
    emit eventResponse("incrementSubmitted", QVariantList{ result.left(200) });
    // Refresh to pick up the new count.
    kickRefresh();
    return true;
}

bool CounterPlugin::refresh()
{
    kickRefresh();
    return true;
}

void CounterPlugin::kickRefresh()
{
    if (m_refreshInFlight) return;
    m_refreshInFlight = true;

    // The counter PDA has seed "counter" — matches `pda = literal("counter")`
    // in methods/guest/src/bin/counter.rs. `spel pda counter` computes its
    // address; then `spel inspect <pda> --type CounterState` reads the
    // account and decodes its data into {"count": N}.
    QTimer::singleShot(0, this, [this]() {
        const QString pda = runCli({"pda", "counter"}, 5000).trimmed();
        if (pda.isEmpty()) {
            m_refreshInFlight = false;
            return;
        }
        const QString json = runCli({"inspect", pda, "--type", "CounterState"}, 15 * 1000);
        m_refreshInFlight = false;
        if (m_chainStatus == 3) return;

        QJsonParseError err{};
        const QJsonDocument doc = QJsonDocument::fromJson(json.toUtf8(), &err);
        if (err.error != QJsonParseError::NoError || !doc.isObject()) {
            m_lastError = "inspect JSON parse failed: " + err.errorString();
            setChainStatus(3);
            return;
        }
        const QJsonObject obj = doc.object();
        // count arrives as a string (u64 → base-10 string) per spel's
        // default number-as-string encoding for large ints.
        m_lastCount = obj.value("count").toVariant().toLongLong();
        m_fetchedAtSecs = QDateTime::currentSecsSinceEpoch();
        m_lastError.clear();
        setChainStatus(2);
        emit eventResponse("countUpdated",
            QVariantList{ QVariant::fromValue(m_lastCount) });
    });
}

// ── QProcess shell-out ───────────────────────────────────────────────

QString CounterPlugin::runCli(const QStringList& args, int timeoutMs)
{
    // First arg decides which binary. Args prefixed with our-own-flags
    // go to `spel`; args starting with a wallet subcommand name go to
    // `wallet`. This is a simple heuristic that works for every call
    // we make below.
    static const QStringList walletCmds = {
        "config", "account", "auth-transfer", "check-health", "deploy-program"
    };
    const bool useWallet = !args.isEmpty() && walletCmds.contains(args.first());
    const QString bin = findBin(useWallet ? "wallet" : "spel");

    QProcess proc;
    proc.setProcessChannelMode(QProcess::MergedChannels);
    proc.start(bin, args);
    if (!proc.waitForStarted(3000)) {
        m_lastError = bin + " failed to start — is the binary installed and on PATH? "
                      "(~/.cargo/bin/" + (useWallet ? "wallet" : "spel") + ")";
        qWarning().noquote() << "CounterPlugin:" << m_lastError;
        setChainStatus(3);
        return QString();
    }
    if (!proc.waitForFinished(timeoutMs)) {
        m_lastError = bin + " timed out after " + QString::number(timeoutMs) + " ms";
        qWarning().noquote() << "CounterPlugin:" << m_lastError;
        proc.kill();
        proc.waitForFinished(1000);
        setChainStatus(3);
        return QString();
    }
    const QString out = QString::fromUtf8(proc.readAll());
    if (proc.exitCode() != 0) {
        m_lastError = bin + " exited " + QString::number(proc.exitCode()) +
                      ": " + out.left(400);
        qWarning().noquote() << "CounterPlugin:" << m_lastError;
        setChainStatus(3);
        return out;
    }
    return out;
}

void CounterPlugin::setChainStatus(int status)
{
    if (m_chainStatus == status) return;
    m_chainStatus = status;
    emit eventResponse("chainStatusChanged", QVariantList{ status });
}
