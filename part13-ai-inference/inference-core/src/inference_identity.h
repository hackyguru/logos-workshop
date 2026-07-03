#ifndef INFERENCE_IDENTITY_H
#define INFERENCE_IDENTITY_H

#include <QByteArray>
#include <QString>
#include <QVariantList>

class LogosAPI;

// ─────────────────────────────────────────────────────────────────────────
// InferenceIdentity — the identity facade for part13.
//
// One account = one BIP-39 mnemonic. Everything else — the Ed25519 signing
// key, the X25519 encryption key, the fingerprint that becomes a provider's
// id — is derived deterministically from it. The mnemonic is the only thing
// a user ever backs up; re-importing it on any machine recreates the exact
// same identity. Protocol code never sees a mnemonic, an xprv, or a keystore:
// it only ever consumes appKey()/sign()/fingerprint().
//
// Backends (picked automatically):
//   - accounts_module (go-wallet-sdk): real BIP-39 mnemonics + BIP-32
//     derivation (m/44'/60'/0'/0/0 → 32-byte root secret). NOTE: its
//     *SignHash methods return empty strings (verified broken), so all
//     signing happens here via OpenSSL instead — accounts_module is used
//     for mnemonic/derivation only.
//   - seed-file fallback: a random 32-byte root secret with no mnemonic
//     (the key file itself is the backup). Used when accounts_module is
//     not loaded. importAccount() also accepts a 64-hex-char raw root for
//     this backend, which is handy for scripted tests.
//
// At rest only the 32-byte root secret is stored (hex, chmod 600) at
//   $LOGOS_IDENTITY_DIR/identity-<role>.key   (default: ~/.logos-inference/)
// The <role> ("provider" / "user") keeps a provider and a user on the same
// machine from silently sharing one identity.
//
// Key derivation: subkey = HMAC-SHA256(key = root, msg = domain). The root is
// uniformly random, so HMAC as a PRF gives independent, domain-separated
// 32-byte subkeys ("inference/v1/sign" → Ed25519 seed, "inference/v1/box" →
// X25519 secret, "inference/v1/rln" → reserved for the RLN identity).
// ─────────────────────────────────────────────────────────────────────────
class InferenceIdentity
{
public:
    InferenceIdentity(LogosAPI* api, const QString& role);

    bool    isInitialized() const { return m_root.size() == 32; }

    // Create a fresh account. Returns the mnemonic — show it ONCE, it is never
    // stored — or "" on the seed-file backend (no mnemonic exists) and on
    // failure. Check isInitialized() to tell those apart. Refuses to overwrite
    // an existing identity.
    QString createAccount(const QString& passphrase = QString());

    // Recreate an identity from its BIP-39 mnemonic (needs accounts_module),
    // or from a 64-hex-char raw root secret (works on any backend).
    bool    importAccount(const QString& mnemonic, const QString& passphrase = QString());

    // 32-byte secret derived for `domain`. The root never leaves this class.
    QByteArray appKey(const QByteArray& domain) const;

    QByteArray signPublicKey() const;                 // Ed25519, 32 bytes
    QByteArray boxPublicKey() const;                  // X25519, 32 bytes
    QByteArray sign(const QByteArray& msg) const;     // Ed25519 detached, 64 bytes
    static bool verify(const QByteArray& msg, const QByteArray& sig,
                       const QByteArray& publicKey);

    // hex(sha256(signPublicKey))[0..40) — the self-certifying short id.
    QString fingerprint() const;
    // Same digest for someone else's announced signing key (roster checks).
    static QString fingerprintOf(const QByteArray& signPublicKey);

    // "accounts_module" | "seed-file" | "" (uninitialized)
    QString backend() const { return m_backend; }

    // ── Sealed boxes ─────────────────────────────────────────────────
    // ECIES equivalent of libsodium's crypto_box_seal, built from the OpenSSL
    // primitives we already link: fresh X25519 keypair per box, ECDH with the
    // recipient key, HMAC-SHA256 KDF (bound to both public keys) into a
    // ChaCha20-Poly1305 key+nonce. Wire format: ephPk(32) ‖ ciphertext ‖ tag(16).
    // The one-shot ephemeral key makes the derived nonce single-use by
    // construction. Anyone can seal to a public key; only the holder of the
    // matching secret opens it.

    // Fresh X25519 keypair — the user side calls this per prompt and keeps
    // `secretOut` until the response arrives (that's the reply channel).
    static bool genEphemeralKeypair(QByteArray& secretOut, QByteArray& publicOut);
    // Returns the sealed wire bytes ("" on failure).
    static QByteArray seal(const QByteArray& recipientPublicKey,
                           const QByteArray& plaintext);
    // Open with an explicit X25519 secret (e.g. a per-prompt ephemeral).
    static QByteArray openWith(const QByteArray& secretKey, const QByteArray& sealed);
    // Open with this identity's box key.
    QByteArray open(const QByteArray& sealed) const;

private:
    QString keyFilePath() const;
    void    loadRoot();
    bool    saveRoot(const QByteArray& root, const QString& backendName);
    bool    rootFromMnemonic(const QString& mnemonic, const QString& passphrase,
                             QByteArray& rootOut);
    QString callAccounts(const QString& method, const QVariantList& args,
                         bool* ok) const;

    LogosAPI*  m_api;
    QString    m_role;
    QByteArray m_root;      // 32 bytes once initialized
    QString    m_backend;
};

#endif
