#ifndef LOGOS_WALLET_PLUGIN_H
#define LOGOS_WALLET_PLUGIN_H

#include <QObject>
#include <QProcess>
#include <QString>
#include <QTimer>
#include <QVariant>
#include "logos_wallet_interface.h"
#include "logos_api.h"
#include "logos_api_client.h"
#include "logos_sdk.h"

// Unified wallet for both Logos layers:
//   • Bedrock (base chain) — manages the official logos-blockchain-node
//     binary as a detached daemon (survives UI/Basecamp quit, re-adopted on
//     load); reads status/balances over the node's local HTTP API.
//   • LEZ (execution zone) — drives the Basecamp-bundled logos_execution_zone
//     module, which is the only build version-matched to the deployed
//     testnet. This module is the SOLE owner of that wallet.
class LogosWalletPlugin : public QObject, public LogosWalletInterface
{
    Q_OBJECT
    Q_PLUGIN_METADATA(IID LogosWalletInterface_iid FILE "metadata.json")
    Q_INTERFACES(LogosWalletInterface PluginInterface)

public:
    explicit LogosWalletPlugin(QObject* parent = nullptr);
    ~LogosWalletPlugin() override;

    QString name() const override { return "logos_wallet"; }
    QString version() const override { return "0.1.0"; }

    Q_INVOKABLE void initLogos(LogosAPI* api);

    // Bedrock
    Q_INVOKABLE QString nodeStatus() override;
    Q_INVOKABLE QString startNode() override;
    Q_INVOKABLE QString stopNode() override;
    Q_INVOKABLE QString baseAccounts() override;
    Q_INVOKABLE QString baseSend(const QString& toAddress, const QString& amount) override;
    Q_INVOKABLE QString inscribe(const QString& text) override;

    // LEZ
    Q_INVOKABLE QString lezStatus() override;
    Q_INVOKABLE QString lezOpen() override;
    Q_INVOKABLE QString lezAccounts() override;
    Q_INVOKABLE QString lezCreateAccount(const QString& kind) override;
    Q_INVOKABLE QString lezFund() override;
    Q_INVOKABLE QString lezTransfer(const QString& kind, const QString& fromAccountHex,
                                    const QString& toAccountHex, const QString& amount) override;
    Q_INVOKABLE QString lezReceiveAddress(const QString& accountHex) override;
    Q_INVOKABLE QString lezBridgeIn(const QString& amount) override;
    Q_INVOKABLE QString lezClaimVault(const QString& amount) override;

signals:
    void eventResponse(const QString& eventName, const QVariantList& args);

private:
    // ── paths ────────────────────────────────────────────────────────
    QString baseDir() const;          // ~/.logos-wallet
    QString binPath() const;
    QString nodeConfigPath() const;
    QString nodeKeystorePath() const;
    QString nodePidPath() const;
    QString lezDir() const;

    // ── Bedrock: node daemon ─────────────────────────────────────────
    bool    nodeAlive() const;        // HTTP API answers = a node is up
    qint64  daemonPid() const;        // pid from pidfile, 0 if none/stale
    void    stepDownload();
    void    stepExtract();
    void    stepInitConfig();
    void    launchDaemon();           // setsid-detached; writes pidfile
    void    finishNodeSetup(bool ok, const QString& error);
    QString leaderPk();               // base ★ LeaderFunding key

    // ── Bedrock: inscribe sequencer (long-lived) ─────────────────────
    void    ensureSequencer();
    void    writeAndConfirm(const QString& text);
    void    finishInscribe(const QString& json);
    QString channelTip();

    // ── LEZ module client ────────────────────────────────────────────
    struct Reply { bool ok; QVariant value; QString error; };
    LogosAPIClient* lezClient();
    Reply           lezCall(const QString& method, const QVariantList& args = {},
                            int timeoutMs = 20000);
    void            lezSave();
    bool            lezSyncFully(QString* err);   // blocking loop; caller is off-event-loop
    QString         lezPublicAccount();           // create+register+persist a public account
    QString         lezPrivateSource(qulonglong need);  // a private acct that can cover `need`

    // ── state ────────────────────────────────────────────────────────
    QProcess* m_seq = nullptr;        // inscribe sequencer
    bool      m_seqReady = false;
    QString   m_seqBuf;
    QString   m_channelId;
    QString   m_pendingText;
    QTimer*   m_confirmTimer = nullptr;
    int       m_confirmTries = 0;
    QString   m_prevTip;

    bool      m_nodeBusy = false;
    QString   m_nodeStage;
    QString   m_nodeError;

    void            startBackgroundSync();   // keeps private balances current
    QTimer*   m_lezSyncTimer = nullptr;

    LogosAPIClient* m_lez = nullptr;
    bool      m_lezOpen = false;
    bool      m_lezBusy = false;
    bool      m_lezSyncing = false;   // background sync in flight (NOT user-busy)
    QString   m_lezStage;
    QString   m_lezAccount;           // private account
    QString   m_lezPublicAccount;
    QString   m_lezError;
};

#endif
