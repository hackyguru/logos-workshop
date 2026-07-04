#ifndef INFERENCE_PLUGIN_H
#define INFERENCE_PLUGIN_H

#include <QObject>
#include <QString>
#include <QHash>
#include <QJsonObject>
#include <QList>
#include <QSet>
#include <QTimer>
#include <QVariant>
#include "inference_interface.h"
#include "inference_identity.h"
#include "logos_api.h"
#include "logos_api_client.h"
#include "logos_object.h"
#include "logos_sdk.h"

// One prompt I have sent, and the response (if it has come back yet).
struct PromptRec {
    QString id;
    QString prompt;
    qint64  sentMs   = 0;
    bool    answered = false;
    qint64  rttMs    = -1;
    QString text;          // the model's reply
    QString provider;      // who answered (from the response payload)
    QString model;         // which model produced it
    // E2E: one ephemeral X25519 secret PER attempt. Each sealed (re)send uses a
    // fresh reply key, and a valid answer may come from any provider we tried —
    // so we keep every secret and try them all when a response arrives (first
    // answer wins). Cleared only once answered. The matching public keys ride
    // inside the sealed prompts; nothing links two prompts to each other.
    QList<QByteArray> ephSks;
    bool    sealed   = false;
    // Failover: which providers we've already tried, and when we last sent.
    QStringList tried;
    int     retries    = 0;
    bool    failed     = false;
    qint64  lastSendMs = 0;
};

// A provider we've heard a (signature-verified) announce from — either in the
// current room (legacy v2) or on the global discovery topic (v3 capability
// card). `topic` is where prompts for it go: the room topic for room
// providers, its own session topic for marketplace ones.
struct ProviderRec {
    QByteArray  signPk;     // Ed25519 — verifies its responses
    QByteArray  boxPk;      // X25519 — we seal prompts to this
    QString     model;      // primary model (first of models)
    QStringList models;     // every model served (v3; [model] for v2)
    QString     topic;      // where to send prompts for this provider
    QString     origin;     // "room" | "discovery"
    QString     price;      // price scheme ("free" until LEZ payments land)
    int         cap        = 0;   // concurrency capacity (v3; 0 = unknown)
    int         load       = 0;
    qint64      lastSeenMs = 0;
};

class InferencePlugin : public QObject, public InferenceInterface
{
    Q_OBJECT
    Q_PLUGIN_METADATA(IID InferenceInterface_iid FILE "metadata.json")
    Q_INTERFACES(InferenceInterface PluginInterface)

public:
    explicit InferencePlugin(QObject* parent = nullptr);
    ~InferencePlugin() override;

    QString name() const override { return "inference"; }
    QString version() const override { return "0.1.0"; }

    Q_INVOKABLE void initLogos(LogosAPI* api);

    Q_INVOKABLE bool    startDelivery() override;
    Q_INVOKABLE bool    stopDelivery() override;
    Q_INVOKABLE int     deliveryStatus() override;

    Q_INVOKABLE bool    joinRoom(const QString& room) override;
    Q_INVOKABLE QString room() override;

    Q_INVOKABLE QString sendPrompt(const QString& prompt) override;

    Q_INVOKABLE QString listExchanges() override;
    Q_INVOKABLE bool    clearExchanges() override;
    Q_INVOKABLE QString myId() override;

    Q_INVOKABLE QString identityStatus() override;
    Q_INVOKABLE QString createAccount(const QString& passphrase) override;
    Q_INVOKABLE bool    importAccount(const QString& mnemonic,
                                      const QString& passphrase) override;
    Q_INVOKABLE QString listProviders() override;
    Q_INVOKABLE bool    unlock(const QString& passphrase) override;
    Q_INVOKABLE bool    setRequireEncryption(bool required) override;
    Q_INVOKABLE bool    setPreferredProvider(const QString& fingerprint) override;
    Q_INVOKABLE bool    setModelFilter(const QString& model) override;

signals:
    void eventResponse(const QString& eventName, const QVariantList& args);

private:
    QString topicForRoom(const QString& room) const;
    QString providerTopic(const QString& fingerprint) const;
    void    handleMessageReceived(const QVariantList& data);
    void    handleAnnounce(const QJsonObject& obj);
    void    handleResponse(const QJsonObject& obj);
    const ProviderRec* pickProvider(QString& fpOut, const QStringList& exclude) const;
    bool    dispatchPrompt(PromptRec& rec);
    void    sweepPending();
    void    pruneHistory();
    void    setDeliveryStatus(int status);
    bool    invokeBool(const char* what, const QString& method,
                       const QVariant& arg = QVariant());
    static qint64 nowMs();

    QString           m_myId;
    QString           m_room = "lobby";
    QList<PromptRec>  m_prompts;   // newest first
    QHash<QString, ProviderRec> m_providers;   // fingerprint → verified announce
    QSet<QString>     m_sessionSubs;           // provider session topics we joined
    QString           m_preferredProvider;     // "" = auto (least loaded)
    QString           m_modelFilter;           // "" = any model
    bool              m_requireEncryption = false;
    qint64            m_timeoutMs = 90000;     // INFERENCE_TIMEOUT_MS override
    int               m_maxRetries = 2;
    QTimer*           m_sweepTimer = nullptr;

    LogosAPIClient* m_deliveryClient = nullptr;
    LogosObject*    m_deliveryObject = nullptr;
    InferenceIdentity* m_identity    = nullptr;
    int             m_deliveryStatus = 0;
    bool            m_started        = false;
    bool            m_createNodeDone = false;
    bool            m_subscribed     = false;
};

#endif
