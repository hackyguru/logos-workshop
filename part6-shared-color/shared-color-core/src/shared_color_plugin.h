#ifndef SHARED_COLOR_PLUGIN_H
#define SHARED_COLOR_PLUGIN_H

#include <QObject>
#include <QString>
#include <QVariant>
#include "shared_color_interface.h"
#include "logos_api.h"
#include "logos_api_client.h"
#include "logos_object.h"
#include "logos_sdk.h"

class SharedColorPlugin : public QObject, public SharedColorInterface
{
    Q_OBJECT
    Q_PLUGIN_METADATA(IID SharedColorInterface_iid FILE "metadata.json")
    Q_INTERFACES(SharedColorInterface PluginInterface)

public:
    explicit SharedColorPlugin(QObject* parent = nullptr);
    ~SharedColorPlugin() override;

    QString name() const override { return "shared_color"; }
    QString version() const override { return "0.1.0"; }

    Q_INVOKABLE void initLogos(LogosAPI* api);

    Q_INVOKABLE bool    startDelivery() override;
    Q_INVOKABLE bool    stopDelivery() override;
    Q_INVOKABLE int     deliveryStatus() override;

    Q_INVOKABLE bool    setColor(const QString& hex) override;
    Q_INVOKABLE QString currentColor() override;
    Q_INVOKABLE QString currentSenderId() override;
    Q_INVOKABLE QString myId() override;

signals:
    void eventResponse(const QString& eventName, const QVariantList& args);

private:
    void    handleMessageReceived(const QVariantList& data);
    void    setDeliveryStatus(int status);
    bool    invokeBool(const char* what, const QString& method,
                       const QVariant& arg = QVariant());
    bool    broadcastColor(const QString& hex, qint64 ts);

    QString m_myId;
    QString m_currentColor;     // "" until first set
    QString m_currentSenderId;  // who set m_currentColor
    qint64  m_currentTs = 0;    // ms since epoch — used for LWW convergence

    LogosAPIClient* m_deliveryClient = nullptr;
    LogosObject*    m_deliveryObject = nullptr;
    int             m_deliveryStatus = 0;
    bool            m_started        = false;
    bool            m_subscribed     = false;
    // See polling_plugin.h — createNode is once-per-process, so a second Start
    // in the same process must skip it or the user sees an Error toast.
    bool            m_createNodeDone = false;
};

#endif
