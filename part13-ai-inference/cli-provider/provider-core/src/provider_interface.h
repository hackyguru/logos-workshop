#ifndef PROVIDER_INTERFACE_H
#define PROVIDER_INTERFACE_H

#include <QObject>
#include <QString>
#include "interface.h"

// inference_provider: a HEADLESS Logos module meant to run inside the logoscore
// CLI. It subscribes to the inference content topic, and for every "prompt" it
// runs a local LLM (ollama / tinyllama) and sends back the "response" — entirely
// in-process (it wires delivery_module's messageReceived directly, the way
// Basecamp modules do). Same shape as part11's pong_responder, but the reply is
// an LLM completion instead of a static "pong".
class ProviderInterface : public PluginInterface
{
public:
    virtual ~ProviderInterface() = default;

    // Bring up the delivery node and start answering prompts on
    // /inference/1/<room>/json. Returns true once createNode/start/subscribe
    // succeed. Idempotent.
    Q_INVOKABLE virtual bool    start(const QString& room) = 0;
    Q_INVOKABLE virtual bool    stop() = 0;

    // Compact JSON: { id, room, listening, model, promptsSeen, responsesSent,
    //                 lastPromptId, lastFrom }
    Q_INVOKABLE virtual QString stats() = 0;
    Q_INVOKABLE virtual QString providerId() = 0;
};

#define ProviderInterface_iid "org.logos.ProviderInterface"
Q_DECLARE_INTERFACE(ProviderInterface, ProviderInterface_iid)

#endif
