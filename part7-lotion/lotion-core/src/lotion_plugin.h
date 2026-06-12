#ifndef LOTION_PLUGIN_H
#define LOTION_PLUGIN_H

#include <QByteArray>
#include <QJsonObject>
#include <QObject>
#include <QString>
#include <QVariantList>

#include "lotion_interface.h"
#include "logos_api.h"

// We deliberately do NOT include logos_sdk.h / use StorageModule here —
// any C++→storage_module call hangs on macOS (see lotion_interface.h
// header comment). storage operations live in the QML UI.

class LotionPlugin : public QObject, public LotionInterface
{
    Q_OBJECT
    Q_PLUGIN_METADATA(IID LotionInterface_iid FILE "metadata.json")
    Q_INTERFACES(LotionInterface PluginInterface)

public:
    explicit LotionPlugin(QObject* parent = nullptr);
    ~LotionPlugin() override;

    QString name()    const override { return "lotion"; }
    QString version() const override { return "0.1.0"; }

    Q_INVOKABLE void initLogos(LogosAPI* api);

    Q_INVOKABLE int     createDocument() override;
    Q_INVOKABLE int     createChildDocument(const QString& parentId) override;
    Q_INVOKABLE bool    renameDocument(const QString& id, const QString& title) override;
    Q_INVOKABLE bool    setIcon(const QString& id, const QString& icon) override;
    Q_INVOKABLE bool    setParent(const QString& id, const QString& parentId) override;
    Q_INVOKABLE int     duplicateDocument(const QString& id) override;
    Q_INVOKABLE bool    saveDocument(const QString& id, const QString& title,
                                     const QString& body, const QString& cover,
                                     const QString& isPrivate) override;
    Q_INVOKABLE QString listDocuments() override;
    Q_INVOKABLE QString getDocument(const QString& id) override;
    Q_INVOKABLE bool    deleteDocument(const QString& id) override;
    Q_INVOKABLE bool    markPublished(const QString& id, const QString& cid) override;
    Q_INVOKABLE QString importCoverImage(const QString& srcUrl,
                                         const QString& destDir) override;
    Q_INVOKABLE QString ensureCoversDir(const QString& destDir) override;

    Q_INVOKABLE QString prepareEnvelopeFile(const QString& title,
                                            const QString& body,
                                            const QString& password,
                                            const QString& metaJson) override;
    Q_INVOKABLE QString consumeEnvelopeFile(const QString& path,
                                            const QString& password) override;

signals:
    void eventResponse(const QString& eventName, const QVariantList& args);

private:
    // ── envelope + crypto ────────────────────────────────────────────────
    QByteArray buildEnvelope(const QString& title, const QString& body,
                             const QString& password,
                             const QJsonObject& metaObj,
                             QString* errOut);

    // PBKDF2-HMAC-SHA256 → 32-byte key. OpenSSL.
    static QByteArray deriveKey(const QString& password,
                                const QByteArray& salt, int iterations);
    // AES-256-GCM encrypt / decrypt. 12-byte nonce, 16-byte tag.
    static bool aesGcmEncrypt(const QByteArray& key, const QByteArray& nonce,
                              const QByteArray& plaintext,
                              QByteArray* ciphertext, QByteArray* tag);
    static bool aesGcmDecrypt(const QByteArray& key, const QByteArray& nonce,
                              const QByteArray& ciphertext, const QByteArray& tag,
                              QByteArray* plaintext);

    // ── sqlite history ───────────────────────────────────────────────────
    bool openDatabase();

    // ── temp file plumbing ───────────────────────────────────────────────
    QString writeTempBlob(const QByteArray& bytes, const QString& tag);
};

#endif
