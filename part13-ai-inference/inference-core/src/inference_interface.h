#ifndef INFERENCE_INTERFACE_H
#define INFERENCE_INTERFACE_H

#include <QObject>
#include <QString>
#include "interface.h"

// inference-core: send a prompt into a Logos delivery content topic and listen
// for the model's response. The inference *provider* lives elsewhere — a headless
// logoscore CLI node that runs ollama (tinyllama). See part13's cli-provider/.
// Same shape as part11's ping-core, but the "pong" is an LLM completion.
class InferenceInterface : public PluginInterface
{
public:
    virtual ~InferenceInterface() = default;

    // Delivery lifecycle — 0=off, 1=connecting, 2=connected, 3=error
    Q_INVOKABLE virtual bool    startDelivery() = 0;
    Q_INVOKABLE virtual bool    stopDelivery() = 0;
    Q_INVOKABLE virtual int     deliveryStatus() = 0;

    // Room = the shared content topic /inference/1/<room>/json. Both the user
    // (this module) and the provider (CLI) must use the same room to meet.
    Q_INVOKABLE virtual bool    joinRoom(const QString& room) = 0;
    Q_INVOKABLE virtual QString room() = 0;

    // Send a prompt into the current room. Returns the prompt id (empty on failure).
    Q_INVOKABLE virtual QString sendPrompt(const QString& prompt) = 0;

    // Query helpers (return compact JSON)
    Q_INVOKABLE virtual QString listExchanges() = 0;  // my prompts + their responses
    Q_INVOKABLE virtual bool    clearExchanges() = 0;
    Q_INVOKABLE virtual QString myId() = 0;
};

#define InferenceInterface_iid "org.logos.InferenceInterface"
Q_DECLARE_INTERFACE(InferenceInterface, InferenceInterface_iid)

#endif
