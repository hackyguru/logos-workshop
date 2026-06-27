#ifndef PONG_INTERFACE_H
#define PONG_INTERFACE_H

#include <QObject>
#include <QString>
#include "interface.h"

// pong_responder: a HEADLESS Logos module meant to run inside the logoscore CLI.
// It subscribes to the ping/pong content topic and answers every "ping" with a
// "pong" — entirely in-process (it wires delivery_module's messageReceived
// directly, the same way Basecamp modules do, instead of the CLI's `watch`).
class PongInterface : public PluginInterface
{
public:
    virtual ~PongInterface() = default;

    // Bring up the delivery node and start answering pings on /pingpong/1/<room>/json.
    // Returns true once createNode/start/subscribe succeed. Idempotent.
    Q_INVOKABLE virtual bool    start(const QString& room) = 0;
    Q_INVOKABLE virtual bool    stop() = 0;

    // Compact JSON: { room, listening, pingsSeen, pongsSent, lastPingId, lastFrom, id }
    Q_INVOKABLE virtual QString stats() = 0;
    Q_INVOKABLE virtual QString responderId() = 0;
};

#define PongInterface_iid "org.logos.PongInterface"
Q_DECLARE_INTERFACE(PongInterface, PongInterface_iid)

#endif
