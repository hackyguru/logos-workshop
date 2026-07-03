#ifndef PROVIDER_PLUGIN_H
#define PROVIDER_PLUGIN_H

#include <QObject>
#include <QString>
#include <QTimer>
#include <QVariant>
#include "provider_interface.h"
#include "inference_identity.h"
#include "logos_api.h"
#include "logos_api_client.h"
#include "logos_object.h"
#include "logos_sdk.h"

class ProviderPlugin : public QObject, public ProviderInterface
{
    Q_OBJECT
    Q_PLUGIN_METADATA(IID ProviderInterface_iid FILE "metadata.json")
    Q_INTERFACES(ProviderInterface PluginInterface)

public:
    explicit ProviderPlugin(QObject* parent = nullptr);
    ~ProviderPlugin() override;

    QString name() const override { return "inference_provider"; }
    QString version() const override { return "0.1.0"; }

    Q_INVOKABLE void initLogos(LogosAPI* api);

    Q_INVOKABLE bool    start(const QString& room) override;
    Q_INVOKABLE bool    stop() override;
    Q_INVOKABLE QString stats() override;
    Q_INVOKABLE QString providerId() override;

    Q_INVOKABLE QString identityStatus() override;
    Q_INVOKABLE QString createAccount(const QString& passphrase) override;
    Q_INVOKABLE bool    importAccount(const QString& mnemonic,
                                      const QString& passphrase) override;

signals:
    void eventResponse(const QString& eventName, const QVariantList& args);

private:
    void    ensureIdentity();
    void    sendAnnounce();
    QString topicForRoom(const QString& room) const;
    void    handleMessageReceived(const QVariantList& data);
    void    runInference(const QString& id, const QString& replyPkB64,
                         const QString& prompt, const QString& topic);
    void    sendResponse(const QString& id, const QString& replyPkB64,
                         const QString& text, const QString& topic);
    bool    invokeBool(const char* what, const QString& method,
                       const QVariant& arg = QVariant());

    QString          m_id;
    QString          m_room;
    QString          m_model;       // ollama model (INFERENCE_MODEL, default tinyllama)
    QString          m_ollamaUrl;   // OLLAMA_URL, default http://localhost:11434
    bool             m_started        = false;
    bool             m_createNodeDone = false;
    int              m_promptsSeen    = 0;
    int              m_responsesSent  = 0;
    int              m_inflight       = 0;   // prompts being answered right now
    QString          m_lastPromptId;
    QString          m_lastFrom;
    QTimer*          m_announceTimer  = nullptr;

    LogosAPIClient*  m_deliveryClient = nullptr;
    LogosObject*     m_deliveryObject = nullptr;
    InferenceIdentity* m_identity     = nullptr;
};

#endif
