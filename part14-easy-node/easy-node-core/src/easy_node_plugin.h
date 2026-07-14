#ifndef EASY_NODE_PLUGIN_H
#define EASY_NODE_PLUGIN_H

#include <QObject>
#include <QProcess>
#include <QString>
#include <QTimer>
#include <QVariant>
#include "easy_node_interface.h"
#include "logos_api.h"
#include "logos_api_client.h"
#include "logos_sdk.h"

// Manages the official logos-blockchain-node release binary as a supervised
// subprocess (the logosup recipe, natively): download → init-config →
// spawn → auto-restart. Chain state, peers and balances are read by the UI
// straight from the node's local HTTP API; this module only owns the
// process lifecycle, the keystore-derived address list, and inscriptions
// (the node binary's built-in text sequencer).
class EasyNodePlugin : public QObject, public EasyNodeInterface
{
    Q_OBJECT
    Q_PLUGIN_METADATA(IID EasyNodeInterface_iid FILE "metadata.json")
    Q_INTERFACES(EasyNodeInterface PluginInterface)

public:
    explicit EasyNodePlugin(QObject* parent = nullptr);
    ~EasyNodePlugin() override;

    QString name() const override { return "easy_node"; }
    QString version() const override { return "0.2.0"; }

    Q_INVOKABLE void initLogos(LogosAPI* api);

    Q_INVOKABLE QString status() override;
    Q_INVOKABLE QString setupAndStart() override;
    Q_INVOKABLE QString stopNode() override;
    Q_INVOKABLE QString accounts() override;
    Q_INVOKABLE QString nodeInfo() override;
    Q_INVOKABLE QString inscribe(const QString& text) override;
    Q_INVOKABLE QString transfer(const QString& fromAddress,
                                 const QString& toAddress,
                                 const QString& amount) override;
    Q_INVOKABLE QString lezStatus() override;
    Q_INVOKABLE QString lezSetup() override;
    Q_INVOKABLE QString lezSync() override;
    Q_INVOKABLE QString lezTransfer(const QString& toAccountHex,
                                    const QString& amount) override;
    Q_INVOKABLE QString lezDeposit(const QString& amount) override;
    Q_INVOKABLE QString lezClaimVault(const QString& amount) override;
    Q_INVOKABLE QString lezWithdraw(const QString& amount) override;
    Q_INVOKABLE QString lezMine() override;

signals:
    void eventResponse(const QString& eventName, const QVariantList& args);

private:
    // Async setup pipeline. Never blocks the event loop: every step is a
    // QProcess wired by finished-signals. (Blocking >20s here starves the
    // host's IPC reply timeout, whose timeout+late-reply path double-frees
    // and crashes Basecamp.)
    void stepDownload();
    void stepExtract();
    void stepInitConfig();
    void stepSpawnNode();
    void finishSetup(bool ok, const QString& error);
    void spawnNode();

    bool nodeRunning() const;

    QString baseDir() const;
    QString binPath() const;
    QString configPath() const;
    QString keystorePath() const;

    // The sequencer is a long-lived interactive process: spawned once
    // (channel bootstrap takes seconds on a fresh channel, tens of seconds
    // on one with history), then fed one line per inscription. It must stay
    // alive until a publish confirms — exiting right after a write loses
    // the pending message. Success = the channel tip actually changes.
    void ensureSequencer();
    void writeAndConfirm(const QString& text);
    void finishInscribe(const QString& resultJson);
    QString fetchChannelTip();

    QProcess* m_node = nullptr;
    QProcess* m_step = nullptr;     // current setup-step process

    QProcess* m_seq = nullptr;      // long-lived text sequencer
    bool      m_seqReady = false;
    QString   m_seqBuf;
    QString   m_channelId;
    QString   m_pendingText;        // message queued while the sequencer boots
    QString   m_prevTip;
    QTimer*   m_confirmTimer = nullptr;
    int       m_confirmTries = 0;

    bool    m_setupBusy = false;
    QString m_setupError;
    QString m_stage;                // "downloading" | "configuring" | "starting" | ""
    bool    m_inscribeBusy = false;
    bool    m_userStopped = false;
    int     m_restarts = 0;

    // ── LEZ private wallet (logos_execution_zone) ────────────────────
    struct Reply {
        bool ok;
        QVariant value;
        QString error;
    };
    LogosAPIClient* lezClient();
    Reply lezCall(const QString& method, const QVariantList& args = {},
                  int timeoutMs = 20000);
    void lezSave();                 // persist wallet state to disk

    LogosAPIClient* m_lez = nullptr;
    bool    m_lezOpen = false;
    bool    m_lezBusy = false;      // setup, transfer or bridge op in flight
    bool    m_lezSyncing = false;
    QString m_lezAccount;
    QString m_lezError;

    // Bridge helpers
    QString leaderPk();             // base wallet's ★ LeaderFunding key
    QString lezPublicAccount();     // lazily-created public zone account (bridge gateway)
    QString m_bridgeStage;          // surfaced via lezStatus for the UI
};

#endif
