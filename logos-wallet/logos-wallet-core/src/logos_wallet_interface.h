#ifndef LOGOS_WALLET_INTERFACE_H
#define LOGOS_WALLET_INTERFACE_H

#include <QObject>
#include <QString>
#include "interface.h"

// Every method returns a compact JSON string (the QML bridge can carry
// QString but not the LogosResult structs the underlying modules return).
// Slow operations return {"accepted":true} immediately and deliver their
// result via an eventResponse(<name>Finished, [json]) signal — the host's
// IPC reply times out at ~20s and a late reply after timeout double-frees,
// so nothing that can exceed that runs synchronously.
class LogosWalletInterface : public PluginInterface
{
public:
    virtual ~LogosWalletInterface() = default;

    // ── Bedrock (base chain) ─────────────────────────────────────────
    // {"running","hasBinary","hasConfig","stage","setupError","httpAddr",
    //  "restarts","mode","height","slot","peerId","nPeers","nConnections"}
    Q_INVOKABLE virtual QString nodeStatus() = 0;
    // Download (first run) + generate config/keys + daemonize the node.
    // Deferred → nodeSetupFinished. The node is a detached daemon: it keeps
    // running when the UI/Basecamp closes and is re-adopted on next load.
    Q_INVOKABLE virtual QString startNode() = 0;
    Q_INVOKABLE virtual QString stopNode() = 0;
    // {"ok","accounts":[{"role","address","balance"}]}
    Q_INVOKABLE virtual QString baseAccounts() = 0;
    // Base-chain transfer. {"ok","tx","error"}
    Q_INVOKABLE virtual QString baseSend(const QString& toAddress,
                                         const QString& amount) = 0;
    // Inscribe text on the base chain (built-in sequencer). Deferred →
    // inscribeFinished with {"ok","output"|"error"}.
    Q_INVOKABLE virtual QString inscribe(const QString& text) = 0;

    // ── LEZ (execution zone) ─────────────────────────────────────────
    // {"ready","busy","account","publicAccount","privateBalance",
    //  "publicBalance","vault","lastSynced","height","stage","error"}
    Q_INVOKABLE virtual QString lezStatus() = 0;
    // Open the persisted LEZ wallet, or create it on first run (mnemonic in
    // the finished event). This module is the SOLE owner of the shared
    // logos_execution_zone wallet. Deferred → lezOpenFinished.
    Q_INVOKABLE virtual QString lezOpen() = 0;
    // Every account in the wallet, each tagged public/private with its own
    // balance — the stock-wallet model. {"ok":bool,"accounts":[
    //   {"id":"<hex>","idB58":"...","isPublic":bool,"balance":"<string>"}]}
    Q_INVOKABLE virtual QString lezAccounts() = 0;
    // Create a new account. kind = "public" | "private". Public accounts are
    // registered on-chain. Deferred → lezAccountCreated with the new id.
    Q_INVOKABLE virtual QString lezCreateAccount(const QString& kind) = 0;
    // Fund a public account via the zone's built-in PoW faucet (pinata):
    // full sync → create/register public account → claim 150. Deferred →
    // lezFundFinished with {"ok","account","prize"|"error"}.
    Q_INVOKABLE virtual QString lezFund() = 0;
    // Transfers. kind = "public" | "shielded" (public→private) |
    // "deshielded" (private→public) | "private" (private→private). Amount is a
    // u64 decimal string. fromAccountHex names the sending account explicitly
    // (empty = auto-pick: the public account, or any private account with
    // enough balance). Deferred → lezTransferFinished.
    Q_INVOKABLE virtual QString lezTransfer(const QString& kind,
                                            const QString& fromAccountHex,
                                            const QString& toAccountHex,
                                            const QString& amount) = 0;
    // A private account's shareable receiving address — encodes the viewing +
    // nullifier public keys a sender needs to pay it privately (an account id
    // alone is NOT enough for a shielded transfer). Hand this to whoever wants
    // to pay you privately. {"ok","address"} | {"error"}.
    Q_INVOKABLE virtual QString lezReceiveAddress(const QString& accountHex) = 0;

    // Bridge base→LEZ: channel-deposit from the base ★ key, crediting the
    // LEZ account's vault (visible after L1 finality). Deferred →
    // lezBridgeFinished.
    Q_INVOKABLE virtual QString lezBridgeIn(const QString& amount) = 0;
    // Claim vault → private balance. Deferred → lezBridgeFinished.
    Q_INVOKABLE virtual QString lezClaimVault(const QString& amount) = 0;
};

#define LogosWalletInterface_iid "org.logos.LogosWalletInterface"
Q_DECLARE_INTERFACE(LogosWalletInterface, LogosWalletInterface_iid)

#endif
