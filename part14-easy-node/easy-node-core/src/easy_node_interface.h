#ifndef EASY_NODE_INTERFACE_H
#define EASY_NODE_INTERFACE_H

#include <QObject>
#include <QString>
#include "interface.h"

// All methods return compact JSON strings so the QML JS bridge can carry
// them verbatim (it can serialize QString but not blockchain_module's
// LogosResult struct — that's the whole reason this core module exists).
class EasyNodeInterface : public PluginInterface
{
public:
    virtual ~EasyNodeInterface() = default;

    // {"running":bool,"hasConfig":bool,"mode":"Online|Bootstrapping|",
    //  "height":n,"slot":n,"peerId":"..."}
    Q_INVOKABLE virtual QString status() = 0;

    // First run: generates config + wallet keys, remembers the path, starts.
    // Later runs: just starts. {"ok":bool,"configPath":"...","error":"..."}
    Q_INVOKABLE virtual QString setupAndStart() = 0;

    // {"ok":bool,"error":"..."}
    Q_INVOKABLE virtual QString stopNode() = 0;

    // {"ok":bool,"accounts":[{"role":"...","address":"<hex64>","balance":n|-1}],"error":"..."}
    Q_INVOKABLE virtual QString accounts() = 0;

    // Chain + network state proxied from the node's local HTTP API (QML's
    // XMLHttpRequest doesn't work inside Basecamp):
    // {"ok":bool,"chain":<cryptarchia/info body or null>,"net":<network/info body or null>}
    Q_INVOKABLE virtual QString nodeInfo() = 0;

    // Publishes text on-chain via the node's built-in text sequencer.
    // Returns {accepted:true}; the result arrives via the inscribeFinished
    // event once the channel tip confirms on-chain.
    Q_INVOKABLE virtual QString inscribe(const QString& text) = 0;

    // Base-chain transfer from one of this wallet's addresses.
    // Amount is a u64 decimal string. {"ok":bool,"tx":"<hash>","error":"..."}
    Q_INVOKABLE virtual QString transfer(const QString& fromAddress,
                                         const QString& toAddress,
                                         const QString& amount) = 0;

    // ── Private wallet on the LEZ (wraps the bundled logos_execution_zone
    //    module — same LogosResult-over-JSON adapter as everything above).
    // {"ready":bool,"busy":bool,"syncing":bool,"account":"<hex64>",
    //  "balance":"<string>","lastSynced":n,"height":n,"error":"..."}
    Q_INVOKABLE virtual QString lezStatus() = 0;
    // Create-or-open the private wallet + one private account (deferred;
    // result via lezSetupFinished event, incl. the mnemonic on first run).
    Q_INVOKABLE virtual QString lezSetup() = 0;
    // One bounded sync chunk toward the sequencer tip (deferred; result via
    // lezSyncFinished event with {done:bool,lastSynced,height}).
    Q_INVOKABLE virtual QString lezSync() = 0;
    // Private transfer to another LEZ account (hex id). Deferred — zk
    // proving is slow; result via lezTransferFinished event.
    Q_INVOKABLE virtual QString lezTransfer(const QString& toAccountHex,
                                            const QString& amount) = 0;

    // Bridge base→LEZ: channel-deposit `amount` from the base wallet's ★
    // key, metadata = the private account's raw 32 bytes. Deferred; result
    // via lezDepositFinished. Funds reach the zone vault after L1 finality
    // (~1 h on this testnet) — claim separately.
    Q_INVOKABLE virtual QString lezDeposit(const QString& amount) = 0;
    // Claim vault balance into the private account (vault_claim_private).
    // Deferred; result via lezClaimFinished.
    Q_INVOKABLE virtual QString lezClaimVault(const QString& amount) = 0;
    // Mine the zone's built-in proof-of-work faucet (the "pinata") and
    // claim the 150-token prize directly into the private account — no
    // bridge, no L1 finality wait. Deferred; result via lezMineFinished.
    Q_INVOKABLE virtual QString lezMine() = 0;

    // Bridge LEZ→base: deshield private→public zone account, then
    // bridge_withdraw to the base wallet's ★ key. Deferred; result via
    // lezWithdrawFinished.
    Q_INVOKABLE virtual QString lezWithdraw(const QString& amount) = 0;
};

#define EasyNodeInterface_iid "org.logos.EasyNodeInterface"
Q_DECLARE_INTERFACE(EasyNodeInterface, EasyNodeInterface_iid)

#endif
