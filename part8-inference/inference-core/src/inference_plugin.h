#ifndef INFERENCE_PLUGIN_H
#define INFERENCE_PLUGIN_H

#include <QObject>
#include <QString>
#include <QList>
#include <QSet>
#include <QJsonObject>
#include <QVariant>
#include "inference_interface.h"
#include "logos_api.h"
#include "logos_api_client.h"
#include "logos_object.h"
#include "logos_sdk.h"

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

    Q_INVOKABLE bool    start() override;
    Q_INVOKABLE bool    stop() override;
    Q_INVOKABLE int     status() override;

    Q_INVOKABLE QString takePending() override;
    Q_INVOKABLE bool    reply(const QString& replyTopic,
                              const QString& id,
                              const QString& answer) override;

    Q_INVOKABLE bool    ask(const QString& id, const QString& prompt) override;
    Q_INVOKABLE QString takeReplies() override;

signals:
    void eventResponse(const QString& eventName, const QVariantList& args);

private:
    QString replyTopicFor(const QString& id) const;
    void    handleMessageReceived(const QVariantList& data);
    void    setStatus(int status);
    bool    invokeBool(const char* what, const QString& method,
                       const QVariant& arg = QVariant());
    QString wrapJson(const QList<QJsonObject>& items) const;

    LogosAPI*       logosAPI         = nullptr;
    LogosAPIClient* m_deliveryClient = nullptr;
    LogosObject*    m_deliveryObject = nullptr;
    int             m_status         = 0;
    bool            m_started        = false;
    // delivery_module's createNode is "call once per process" — see the
    // delivery guide, Gotcha #8. Track it so a second start() in the same
    // daemon skips createNode and goes straight to start().
    bool            m_createNodeDone = false;

    // Inbound queues. Filled on the host's event-loop thread by
    // handleMessageReceived; drained on the same thread by the take* RPCs,
    // so no locking is needed. Dedup by id guards against gossipsub
    // re-delivering the same message (notably self-echo on one node).
    QList<QJsonObject> m_pending;        // {id, prompt, reply} awaiting inference
    QList<QJsonObject> m_replies;        // {id, answer} we asked for
    QSet<QString>      m_seenPrompts;
    QSet<QString>      m_seenReplies;
    QSet<QString>      m_replySubs;      // reply topics we subscribed to (for clean unsubscribe)
};

#endif
