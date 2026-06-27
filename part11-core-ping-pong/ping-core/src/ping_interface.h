#ifndef PING_INTERFACE_H
#define PING_INTERFACE_H

#include <QObject>
#include <QString>
#include "interface.h"

// ping-core: send a "ping" into a Logos delivery content topic and listen for the
// matching "pong". The responder lives elsewhere (e.g. a headless logoscore CLI
// node — see part11's cli-ponger/). Round-trip latency is measured per ping.
class PingInterface : public PluginInterface
{
public:
    virtual ~PingInterface() = default;

    // Delivery lifecycle — 0=off, 1=connecting, 2=connected, 3=error
    Q_INVOKABLE virtual bool    startDelivery() = 0;
    Q_INVOKABLE virtual bool    stopDelivery() = 0;
    Q_INVOKABLE virtual int     deliveryStatus() = 0;

    // Room = the shared content topic /pingpong/1/<room>/json. Both the pinger
    // (this module) and the ponger (CLI) must use the same room to meet.
    Q_INVOKABLE virtual bool    joinRoom(const QString& room) = 0;
    Q_INVOKABLE virtual QString room() = 0;

    // Fire a ping into the current room. Returns the ping id (empty on failure).
    Q_INVOKABLE virtual QString sendPing() = 0;

    // Query helpers (return compact JSON)
    Q_INVOKABLE virtual QString listExchanges() = 0;  // my pings + their pong status
    Q_INVOKABLE virtual bool    clearExchanges() = 0;
    Q_INVOKABLE virtual QString myId() = 0;
};

#define PingInterface_iid "org.logos.PingInterface"
Q_DECLARE_INTERFACE(PingInterface, PingInterface_iid)

#endif
