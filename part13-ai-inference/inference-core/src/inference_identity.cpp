#include "inference_identity.h"
#include "logos_api.h"
#include "logos_api_client.h"

#include <QDebug>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QRegularExpression>

#include <openssl/evp.h>
#include <openssl/hmac.h>
#include <openssl/rand.h>
#include <openssl/sha.h>

// The BIP-32 path whose private key becomes our 32-byte root secret. Standard
// Ethereum path so the same mnemonic also yields the account wallet_module
// would use for stake/payments later.
static const char* kRootPath = "m/44'/60'/0'/0/0";

InferenceIdentity::InferenceIdentity(LogosAPI* api, const QString& role)
    : m_api(api)
    , m_role(role)
{
    loadRoot();
}

// ── Storage ──────────────────────────────────────────────────────────

QString InferenceIdentity::keyFilePath() const
{
    QString dir = qEnvironmentVariable("LOGOS_IDENTITY_DIR");
    if (dir.isEmpty())
        dir = QDir::homePath() + "/.logos-inference";
    return dir + "/identity-" + m_role + ".key";
}

void InferenceIdentity::loadRoot()
{
    QFile f(keyFilePath());
    if (!f.exists() || !f.open(QIODevice::ReadOnly)) return;

    // Format: "<backend>:<64 hex chars>\n" (backend tag is informational only)
    const QList<QByteArray> parts = f.readAll().trimmed().split(':');
    if (parts.size() != 2) return;
    const QByteArray root = QByteArray::fromHex(parts[1]);
    if (root.size() != 32) return;

    m_root    = root;
    m_backend = QString::fromUtf8(parts[0]);
    qDebug() << "InferenceIdentity:" << m_role << "loaded, fingerprint" << fingerprint();
}

bool InferenceIdentity::saveRoot(const QByteArray& root, const QString& backendName)
{
    const QString path = keyFilePath();
    QDir().mkpath(QFileInfo(path).absolutePath());

    QFile f(path);
    if (!f.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
        qWarning() << "InferenceIdentity: cannot write" << path;
        return false;
    }
    f.write(backendName.toUtf8() + ":" + root.toHex() + "\n");
    f.close();
    f.setPermissions(QFileDevice::ReadOwner | QFileDevice::WriteOwner);

    m_root    = root;
    m_backend = backendName;
    qDebug() << "InferenceIdentity:" << m_role << "saved, fingerprint" << fingerprint();
    return true;
}

// ── accounts_module backend ──────────────────────────────────────────

QString InferenceIdentity::callAccounts(const QString& method,
                                        const QVariantList& args, bool* ok) const
{
    if (ok) *ok = false;
    LogosAPIClient* client = m_api ? m_api->getClient("accounts_module") : nullptr;
    if (!client) return QString();

    const QVariant r = client->invokeRemoteMethod("accounts_module", method, args);
    if (!r.isValid()) return QString();

    QString value;
    if (r.canConvert<LogosResult>()) {
        const LogosResult lr = r.value<LogosResult>();
        if (!lr.success) {
            qWarning() << "InferenceIdentity: accounts_module." << method
                       << "failed:" << lr.error.toString();
            return QString();
        }
        value = lr.value.toString();
    } else {
        value = r.toString();
    }
    if (ok) *ok = !value.isEmpty();
    return value;
}

bool InferenceIdentity::rootFromMnemonic(const QString& mnemonic,
                                         const QString& passphrase,
                                         QByteArray& rootOut)
{
    bool ok = false;
    const QString xprv = callAccounts("createExtKeyFromMnemonic",
                                      { mnemonic, passphrase }, &ok);
    if (!ok) return false;

    const QString derived = callAccounts("deriveExtKey",
                                         { xprv, QString::fromLatin1(kRootPath) }, &ok);
    if (!ok) return false;

    QString privHex = callAccounts("extKeyToECDSA", { derived }, &ok);
    if (!ok) return false;

    if (privHex.startsWith("0x")) privHex.remove(0, 2);
    rootOut = QByteArray::fromHex(privHex.toUtf8());
    return rootOut.size() == 32;
}

// ── Account lifecycle ────────────────────────────────────────────────

QString InferenceIdentity::createAccount(const QString& passphrase)
{
    if (isInitialized()) {
        qWarning() << "InferenceIdentity: identity already exists at" << keyFilePath()
                   << "— refusing to overwrite. Delete the file to reset.";
        return QString();
    }

    bool ok = false;
    const QString mnemonic =
        callAccounts("createRandomMnemonicWithDefaultLength", {}, &ok);
    if (ok) {
        QByteArray root;
        if (rootFromMnemonic(mnemonic, passphrase, root) &&
            saveRoot(root, "accounts_module")) {
            return mnemonic;
        }
        qWarning() << "InferenceIdentity: derivation failed, falling back to seed-file";
    } else {
        qWarning() << "InferenceIdentity: accounts_module unavailable — using a"
                   << "random seed (no mnemonic; back up" << keyFilePath() << ")";
    }

    QByteArray root(32, 0);
    if (RAND_bytes(reinterpret_cast<unsigned char*>(root.data()), 32) != 1)
        return QString();
    saveRoot(root, "seed-file");
    return QString();   // no mnemonic on this backend
}

bool InferenceIdentity::importAccount(const QString& mnemonic, const QString& passphrase)
{
    if (isInitialized()) {
        qWarning() << "InferenceIdentity: identity already exists — refusing to overwrite";
        return false;
    }

    const QString clean = mnemonic.trimmed();
    if (clean.isEmpty()) return false;

    // Raw 32-byte root as hex (seed-file backend / scripted tests).
    static const QRegularExpression hex64("^(0x)?[0-9a-fA-F]{64}$");
    if (hex64.match(clean).hasMatch()) {
        QString h = clean;
        if (h.startsWith("0x")) h.remove(0, 2);
        return saveRoot(QByteArray::fromHex(h.toUtf8()), "seed-file");
    }

    QByteArray root;
    if (!rootFromMnemonic(clean, passphrase, root)) {
        qWarning() << "InferenceIdentity: mnemonic import failed (is accounts_module"
                   << "loaded, and the mnemonic valid?)";
        return false;
    }
    return saveRoot(root, "accounts_module");
}

// ── Key derivation + crypto (OpenSSL) ────────────────────────────────

QByteArray InferenceIdentity::appKey(const QByteArray& domain) const
{
    if (!isInitialized()) return QByteArray();
    QByteArray out(32, 0);
    unsigned int len = 32;
    HMAC(EVP_sha256(),
         m_root.constData(), m_root.size(),
         reinterpret_cast<const unsigned char*>(domain.constData()), domain.size(),
         reinterpret_cast<unsigned char*>(out.data()), &len);
    return out;
}

// In OpenSSL the Ed25519 "raw private key" IS the 32-byte seed; X25519 takes
// any 32 bytes (clamped internally). So appKey() output feeds both directly.
static QByteArray rawPublicKey(int type, const QByteArray& secret)
{
    if (secret.size() != 32) return QByteArray();
    EVP_PKEY* pkey = EVP_PKEY_new_raw_private_key(
        type, nullptr,
        reinterpret_cast<const unsigned char*>(secret.constData()), 32);
    if (!pkey) return QByteArray();

    QByteArray pub(32, 0);
    size_t len = 32;
    const int rc = EVP_PKEY_get_raw_public_key(
        pkey, reinterpret_cast<unsigned char*>(pub.data()), &len);
    EVP_PKEY_free(pkey);
    return (rc == 1 && len == 32) ? pub : QByteArray();
}

QByteArray InferenceIdentity::signPublicKey() const
{
    return rawPublicKey(EVP_PKEY_ED25519, appKey("inference/v1/sign"));
}

QByteArray InferenceIdentity::boxPublicKey() const
{
    return rawPublicKey(EVP_PKEY_X25519, appKey("inference/v1/box"));
}

QByteArray InferenceIdentity::sign(const QByteArray& msg) const
{
    const QByteArray seed = appKey("inference/v1/sign");
    if (seed.size() != 32) return QByteArray();

    EVP_PKEY* pkey = EVP_PKEY_new_raw_private_key(
        EVP_PKEY_ED25519, nullptr,
        reinterpret_cast<const unsigned char*>(seed.constData()), 32);
    if (!pkey) return QByteArray();

    QByteArray sig(64, 0);
    size_t siglen = 64;
    EVP_MD_CTX* ctx = EVP_MD_CTX_new();
    bool okSig = ctx
        && EVP_DigestSignInit(ctx, nullptr, nullptr, nullptr, pkey) == 1
        && EVP_DigestSign(ctx,
               reinterpret_cast<unsigned char*>(sig.data()), &siglen,
               reinterpret_cast<const unsigned char*>(msg.constData()),
               msg.size()) == 1;
    if (ctx) EVP_MD_CTX_free(ctx);
    EVP_PKEY_free(pkey);
    return (okSig && siglen == 64) ? sig : QByteArray();
}

bool InferenceIdentity::verify(const QByteArray& msg, const QByteArray& sig,
                               const QByteArray& publicKey)
{
    if (sig.size() != 64 || publicKey.size() != 32) return false;
    EVP_PKEY* pkey = EVP_PKEY_new_raw_public_key(
        EVP_PKEY_ED25519, nullptr,
        reinterpret_cast<const unsigned char*>(publicKey.constData()), 32);
    if (!pkey) return false;

    EVP_MD_CTX* ctx = EVP_MD_CTX_new();
    bool okVerify = ctx
        && EVP_DigestVerifyInit(ctx, nullptr, nullptr, nullptr, pkey) == 1
        && EVP_DigestVerify(ctx,
               reinterpret_cast<const unsigned char*>(sig.constData()), 64,
               reinterpret_cast<const unsigned char*>(msg.constData()),
               msg.size()) == 1;
    if (ctx) EVP_MD_CTX_free(ctx);
    EVP_PKEY_free(pkey);
    return okVerify;
}

QString InferenceIdentity::fingerprint() const
{
    return fingerprintOf(signPublicKey());
}

QString InferenceIdentity::fingerprintOf(const QByteArray& signPublicKey)
{
    if (signPublicKey.size() != 32) return QString();
    unsigned char digest[SHA256_DIGEST_LENGTH];
    SHA256(reinterpret_cast<const unsigned char*>(signPublicKey.constData()),
           signPublicKey.size(), digest);
    return QString::fromLatin1(
        QByteArray(reinterpret_cast<char*>(digest), 20).toHex());
}

// ── Sealed boxes (X25519 ECDH → HMAC KDF → ChaCha20-Poly1305) ────────

static const int kBoxTagLen = 16;

bool InferenceIdentity::genEphemeralKeypair(QByteArray& secretOut, QByteArray& publicOut)
{
    EVP_PKEY* pkey = nullptr;
    EVP_PKEY_CTX* ctx = EVP_PKEY_CTX_new_id(EVP_PKEY_X25519, nullptr);
    const bool made = ctx
        && EVP_PKEY_keygen_init(ctx) == 1
        && EVP_PKEY_keygen(ctx, &pkey) == 1;
    if (ctx) EVP_PKEY_CTX_free(ctx);
    if (!made || !pkey) return false;

    secretOut.resize(32); publicOut.resize(32);
    size_t skLen = 32, pkLen = 32;
    const bool got =
        EVP_PKEY_get_raw_private_key(pkey,
            reinterpret_cast<unsigned char*>(secretOut.data()), &skLen) == 1 &&
        EVP_PKEY_get_raw_public_key(pkey,
            reinterpret_cast<unsigned char*>(publicOut.data()), &pkLen) == 1;
    EVP_PKEY_free(pkey);
    return got && skLen == 32 && pkLen == 32;
}

static QByteArray x25519Shared(const QByteArray& secretKey, const QByteArray& peerPublic)
{
    if (secretKey.size() != 32 || peerPublic.size() != 32) return QByteArray();
    EVP_PKEY* priv = EVP_PKEY_new_raw_private_key(
        EVP_PKEY_X25519, nullptr,
        reinterpret_cast<const unsigned char*>(secretKey.constData()), 32);
    EVP_PKEY* peer = EVP_PKEY_new_raw_public_key(
        EVP_PKEY_X25519, nullptr,
        reinterpret_cast<const unsigned char*>(peerPublic.constData()), 32);

    QByteArray shared(32, 0);
    size_t len = 32;
    EVP_PKEY_CTX* ctx = priv ? EVP_PKEY_CTX_new(priv, nullptr) : nullptr;
    const bool okDerive = ctx && peer
        && EVP_PKEY_derive_init(ctx) == 1
        && EVP_PKEY_derive_set_peer(ctx, peer) == 1
        && EVP_PKEY_derive(ctx,
               reinterpret_cast<unsigned char*>(shared.data()), &len) == 1;
    if (ctx)  EVP_PKEY_CTX_free(ctx);
    if (priv) EVP_PKEY_free(priv);
    if (peer) EVP_PKEY_free(peer);
    return (okDerive && len == 32) ? shared : QByteArray();
}

// key + nonce from the shared secret, bound to both public keys so a box for
// one recipient can never decrypt as a box for another.
static void sealKdf(const QByteArray& shared, const QByteArray& ephPk,
                    const QByteArray& recipientPk,
                    QByteArray& keyOut, QByteArray& nonceOut)
{
    const QByteArray binding  = ephPk + recipientPk;
    const QByteArray keyMsg   = QByteArray("inference/v1/seal-key")   + binding;
    const QByteArray nonceMsg = QByteArray("inference/v1/seal-nonce") + binding;

    unsigned int len = 32;
    keyOut.resize(32);
    HMAC(EVP_sha256(), shared.constData(), shared.size(),
         reinterpret_cast<const unsigned char*>(keyMsg.constData()), keyMsg.size(),
         reinterpret_cast<unsigned char*>(keyOut.data()), &len);

    QByteArray nonceFull(32, 0);
    HMAC(EVP_sha256(), shared.constData(), shared.size(),
         reinterpret_cast<const unsigned char*>(nonceMsg.constData()), nonceMsg.size(),
         reinterpret_cast<unsigned char*>(nonceFull.data()), &len);
    nonceOut = nonceFull.left(12);
}

QByteArray InferenceIdentity::seal(const QByteArray& recipientPublicKey,
                                   const QByteArray& plaintext)
{
    QByteArray ephSk, ephPk;
    if (!genEphemeralKeypair(ephSk, ephPk)) return QByteArray();
    const QByteArray shared = x25519Shared(ephSk, recipientPublicKey);
    if (shared.isEmpty()) return QByteArray();

    QByteArray key, nonce;
    sealKdf(shared, ephPk, recipientPublicKey, key, nonce);

    QByteArray ct(plaintext.size(), 0);
    QByteArray tag(kBoxTagLen, 0);
    int len = 0, fin = 0;
    EVP_CIPHER_CTX* c = EVP_CIPHER_CTX_new();
    const bool okEnc = c
        && EVP_EncryptInit_ex(c, EVP_chacha20_poly1305(), nullptr, nullptr, nullptr) == 1
        && EVP_CIPHER_CTX_ctrl(c, EVP_CTRL_AEAD_SET_IVLEN, 12, nullptr) == 1
        && EVP_EncryptInit_ex(c, nullptr, nullptr,
               reinterpret_cast<const unsigned char*>(key.constData()),
               reinterpret_cast<const unsigned char*>(nonce.constData())) == 1
        && EVP_EncryptUpdate(c,
               reinterpret_cast<unsigned char*>(ct.data()), &len,
               reinterpret_cast<const unsigned char*>(plaintext.constData()),
               plaintext.size()) == 1
        && EVP_EncryptFinal_ex(c,
               reinterpret_cast<unsigned char*>(ct.data()) + len, &fin) == 1
        && EVP_CIPHER_CTX_ctrl(c, EVP_CTRL_AEAD_GET_TAG, kBoxTagLen, tag.data()) == 1;
    if (c) EVP_CIPHER_CTX_free(c);
    if (!okEnc) return QByteArray();

    return ephPk + ct + tag;    // 32 ‖ n ‖ 16
}

QByteArray InferenceIdentity::openWith(const QByteArray& secretKey,
                                       const QByteArray& sealed)
{
    if (sealed.size() < 32 + kBoxTagLen) return QByteArray();
    const QByteArray ephPk = sealed.left(32);
    const QByteArray ct    = sealed.mid(32, sealed.size() - 32 - kBoxTagLen);
    QByteArray tag         = sealed.right(kBoxTagLen);

    const QByteArray recipientPk = rawPublicKey(EVP_PKEY_X25519, secretKey);
    const QByteArray shared      = x25519Shared(secretKey, ephPk);
    if (recipientPk.isEmpty() || shared.isEmpty()) return QByteArray();

    QByteArray key, nonce;
    sealKdf(shared, ephPk, recipientPk, key, nonce);

    QByteArray pt(ct.size(), 0);
    int len = 0, fin = 0;
    EVP_CIPHER_CTX* c = EVP_CIPHER_CTX_new();
    const bool okDec = c
        && EVP_DecryptInit_ex(c, EVP_chacha20_poly1305(), nullptr, nullptr, nullptr) == 1
        && EVP_CIPHER_CTX_ctrl(c, EVP_CTRL_AEAD_SET_IVLEN, 12, nullptr) == 1
        && EVP_DecryptInit_ex(c, nullptr, nullptr,
               reinterpret_cast<const unsigned char*>(key.constData()),
               reinterpret_cast<const unsigned char*>(nonce.constData())) == 1
        && EVP_DecryptUpdate(c,
               reinterpret_cast<unsigned char*>(pt.data()), &len,
               reinterpret_cast<const unsigned char*>(ct.constData()), ct.size()) == 1
        && EVP_CIPHER_CTX_ctrl(c, EVP_CTRL_AEAD_SET_TAG, kBoxTagLen, tag.data()) == 1
        && EVP_DecryptFinal_ex(c,
               reinterpret_cast<unsigned char*>(pt.data()) + len, &fin) == 1;
    if (c) EVP_CIPHER_CTX_free(c);
    return okDec ? pt : QByteArray();   // tag mismatch ⇒ empty
}

QByteArray InferenceIdentity::open(const QByteArray& sealed) const
{
    return openWith(appKey("inference/v1/box"), sealed);
}
