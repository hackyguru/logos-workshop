#ifndef INFERENCE_INTERFACE_H
#define INFERENCE_INTERFACE_H

#include <QObject>
#include <QString>
#include "interface.h"

// inference-core: send a prompt into a Logos delivery content topic and listen
// for the model's response. The inference *provider* lives elsewhere — a headless
// logoscore CLI node that runs ollama (tinyllama). See part13's cli-provider/.
// Same shape as part11's ping-core, but the "pong" is an LLM completion.
class InferenceInterface : public PluginInterface
{
public:
    virtual ~InferenceInterface() = default;

    // Delivery lifecycle — 0=off, 1=connecting, 2=connected, 3=error
    Q_INVOKABLE virtual bool    startDelivery() = 0;
    Q_INVOKABLE virtual bool    stopDelivery() = 0;
    Q_INVOKABLE virtual int     deliveryStatus() = 0;

    // Room = the shared content topic /inference/1/<room>/json. Both the user
    // (this module) and the provider (CLI) must use the same room to meet.
    Q_INVOKABLE virtual bool    joinRoom(const QString& room) = 0;
    Q_INVOKABLE virtual QString room() = 0;

    // Send a prompt into the current room. Returns the prompt id (empty on failure).
    Q_INVOKABLE virtual QString sendPrompt(const QString& prompt) = 0;

    // Query helpers (return compact JSON)
    Q_INVOKABLE virtual QString listExchanges() = 0;  // my prompts + their responses
    Q_INVOKABLE virtual bool    clearExchanges() = 0;
    Q_INVOKABLE virtual QString myId() = 0;

    // ── Identity (InferenceIdentity facade) ──────────────────────────
    // One account = one BIP-39 mnemonic; the signing/box keys and the
    // fingerprint are derived from it. The UI drives create/import — nothing
    // is auto-created here. NOTE: the user's identity never goes on the wire
    // (prompts stay pseudonymous); it anchors the future RLN membership and
    // payment keys.

    // Compact JSON: { initialized, backend, fingerprint, signPk, boxPk }
    Q_INVOKABLE virtual QString identityStatus() = 0;
    // Returns the mnemonic (display once, never stored); "" on the seed-file
    // backend (no mnemonic exists) or if an identity already exists.
    Q_INVOKABLE virtual QString createAccount(const QString& passphrase) = 0;
    // Accepts a BIP-39 mnemonic (needs accounts_module) or a 64-hex raw root.
    Q_INVOKABLE virtual bool    importAccount(const QString& mnemonic,
                                              const QString& passphrase) = 0;

    // Verified provider roster, from signed announces. Compact JSON array:
    // [{ id, model, load, ageMs, live }]. Prompts are sealed (E2E) to the
    // preferred provider if set and live, else the least-loaded live one;
    // with no live provider they fall back to the legacy plaintext broadcast
    // (unless requireEncryption is on). Unanswered prompts are retried on the
    // next-best provider after a timeout (INFERENCE_TIMEOUT_MS, default 90s),
    // then marked failed.
    Q_INVOKABLE virtual QString listProviders() = 0;

    // Decrypt a passphrase-protected identity key file (identityStatus
    // reports locked:true until this succeeds).
    Q_INVOKABLE virtual bool    unlock(const QString& passphrase) = 0;
    // Refuse to send plaintext: with no live provider, sendPrompt fails
    // instead of broadcasting in the clear.
    Q_INVOKABLE virtual bool    setRequireEncryption(bool required) = 0;
    // Pin prompts to one provider fingerprint ("" = auto, least loaded).
    Q_INVOKABLE virtual bool    setPreferredProvider(const QString& fingerprint) = 0;
};

#define InferenceInterface_iid "org.logos.InferenceInterface"
Q_DECLARE_INTERFACE(InferenceInterface, InferenceInterface_iid)

#endif
