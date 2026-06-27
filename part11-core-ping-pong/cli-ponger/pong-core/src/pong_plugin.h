#ifndef PONG_PLUGIN_H
#define PONG_PLUGIN_H

#include <QObject>
#include <QString>
#include <QVariant>
#include "pong_interface.h"
#include "logos_api.h"
#include "logos_api_client.h"
#include "logos_object.h"
#include "logos_sdk.h"

class PongPlugin : public QObject, public PongInterface
{
    Q_OBJECT
    Q_PLUGIN_METADATA(IID PongInterface_iid FILE "metadata.json")
    Q_INTERFACES(PongInterface PluginInterface)

public:
    explicit PongPlugin(QObject* parent = nullptr);
    ~PongPlugin() override;

    QString name() const override { return "pong_responder"; }
    QString version() const override { return "0.1.0"; }

    Q_INVOKABLE void initLogos(LogosAPI* api);

    Q_INVOKABLE bool    start(const QString& room) override;
    Q_INVOKABLE bool    stop() override;
    Q_INVOKABLE QString stats() override;
    Q_INVOKABLE QString responderId() override;

signals:
    void eventResponse(const QString& eventName, const QVariantList& args);

private:
    QString topicForRoom(const QString& room) const;
    void    handleMessageReceived(const QVariantList& data);
    bool    invokeBool(const char* what, const QString& method,
                       const QVariant& arg = QVariant());

    QString          m_id;
    QString          m_room;
    bool             m_started        = false;
    bool             m_createNodeDone = false;
    int              m_pingsSeen      = 0;
    int              m_pongsSent      = 0;
    QString          m_lastPingId;
    QString          m_lastFrom;

    LogosAPIClient*  m_deliveryClient = nullptr;
    LogosObject*     m_deliveryObject = nullptr;
};

#endif
