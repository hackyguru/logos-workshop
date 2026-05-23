#ifndef SHARED_COLOR_INTERFACE_H
#define SHARED_COLOR_INTERFACE_H

#include <QObject>
#include <QString>
#include "interface.h"

class SharedColorInterface : public PluginInterface
{
public:
    virtual ~SharedColorInterface() = default;

    // Delivery lifecycle — 0=off, 1=connecting, 2=connected, 3=error
    Q_INVOKABLE virtual bool    startDelivery() = 0;
    Q_INVOKABLE virtual bool    stopDelivery() = 0;
    Q_INVOKABLE virtual int     deliveryStatus() = 0;

    // Color sync — single shared topic /shared-color/1/main/json.
    // `hex` is "#RRGGBB" (or any string the UI hands us — we don't validate).
    Q_INVOKABLE virtual bool    setColor(const QString& hex) = 0;
    Q_INVOKABLE virtual QString currentColor() = 0;       // "" if none yet
    Q_INVOKABLE virtual QString currentSenderId() = 0;    // "" if none yet
    Q_INVOKABLE virtual QString myId() = 0;
};

#define SharedColorInterface_iid "org.logos.SharedColorInterface"
Q_DECLARE_INTERFACE(SharedColorInterface, SharedColorInterface_iid)

#endif
