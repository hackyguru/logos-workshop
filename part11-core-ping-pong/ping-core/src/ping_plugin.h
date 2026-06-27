#ifndef PING_PLUGIN_H
#define PING_PLUGIN_H

#include <QObject>
#include <QString>
#include <QList>
#include <QVariant>
#include "ping_interface.h"
#include "logos_api.h"
#include "logos_api_client.h"
#include "logos_object.h"
#include "logos_sdk.h"

// One ping I have sent, and whether a pong came back for it.
struct PingRec {
    QString id;
    qint64  sentMs   = 0;
    bool    ponged   = false;
    qint64  rttMs    = -1;
    QString ponger;        // who answered (from the pong payload)
};

class PingPlugin : public QObject, public PingInterface
{
    Q_OBJECT
    Q_PLUGIN_METADATA(IID PingInterface_iid FILE "metadata.json")
    Q_INTERFACES(PingInterface PluginInterface)

public:
    explicit PingPlugin(QObject* parent = nullptr);
    ~PingPlugin() override;

    QString name() const override { return "ping"; }
    QString version() const override { return "0.1.0"; }

    Q_INVOKABLE void initLogos(LogosAPI* api);

    Q_INVOKABLE bool    startDelivery() override;
    Q_INVOKABLE bool    stopDelivery() override;
    Q_INVOKABLE int     deliveryStatus() override;

    Q_INVOKABLE bool    joinRoom(const QString& room) override;
    Q_INVOKABLE QString room() override;

    Q_INVOKABLE QString sendPing() override;

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

    QString          m_myId;
    QString          m_room = "lobby";
    QList<PingRec>   m_pings;   // newest first

    LogosAPIClient* m_deliveryClient = nullptr;
    LogosObject*    m_deliveryObject = nullptr;
    int             m_deliveryStatus = 0;
    bool            m_started        = false;
    // delivery_module's createNode is "call once per process" — calling it twice
    // returns "context already initialized". Track it so a Stop+Start cycle skips
    // createNode and goes straight to start(). (Same gotcha as part3-polling.)
    bool            m_createNodeDone = false;
    bool            m_subscribed     = false;
};

#endif
