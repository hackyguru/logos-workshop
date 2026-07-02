#ifndef INFERENCE_PLUGIN_H
#define INFERENCE_PLUGIN_H

#include <QObject>
#include <QString>
#include <QList>
#include <QVariant>
#include "inference_interface.h"
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

signals:
    void eventResponse(const QString& eventName, const QVariantList& args);

private:
    QString topicForRoom(const QString& room) const;
    void    handleMessageReceived(const QVariantList& data);
    void    setDeliveryStatus(int status);
    bool    invokeBool(const char* what, const QString& method,
                       const QVariant& arg = QVariant());
    static qint64 nowMs();

    QString           m_myId;
    QString           m_room = "lobby";
    QList<PromptRec>  m_prompts;   // newest first

    LogosAPIClient* m_deliveryClient = nullptr;
    LogosObject*    m_deliveryObject = nullptr;
    int             m_deliveryStatus = 0;
    bool            m_started        = false;
    bool            m_createNodeDone = false;
    bool            m_subscribed     = false;
};

#endif
