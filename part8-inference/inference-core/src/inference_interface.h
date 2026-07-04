#ifndef INFERENCE_INTERFACE_H
#define INFERENCE_INTERFACE_H

#include <QObject>
#include <QString>
#include "interface.h"

// Headless prompt-responder over logos-delivery.
//
// Transport only: this module never runs a model. It subscribes to a prompt
// content topic, queues every incoming request, and exposes that queue to a
// CLI (`infer`) which runs the actual inference (local Ollama) and hands the
// answer back via reply(). Keeping inference OUT of C++ is deliberate — the
// daemon just moves bytes; the model lives in whatever runtime you like.
//
//   responder:  start() → [takePending() → reply()]*        (the `infer start` loop)
//   requester:  ask(id, prompt) → [takeReplies()]*           (the `infer ask` flow)
//
// Topics (LIP-23 content-topic format /<app>/<version>/<subtopic>/<format>):
//   prompts go out on   /inference/1/prompt/json
//   each answer comes back on  /inference/1/reply-<id>/json
class InferenceInterface : public PluginInterface
{
public:
    virtual ~InferenceInterface() = default;

    // Delivery lifecycle — status: 0=off, 1=connecting, 2=connected, 3=error
    Q_INVOKABLE virtual bool    start() = 0;   // bring up node + subscribe to prompt topic
    Q_INVOKABLE virtual bool    stop()  = 0;
    Q_INVOKABLE virtual int     status() = 0;

    // Responder side
    Q_INVOKABLE virtual QString takePending() = 0;   // drain queued prompts (sentinel-wrapped JSON)
    Q_INVOKABLE virtual bool    reply(const QString& replyTopic,
                                      const QString& id,
                                      const QString& answer) = 0;

    // Requester side (used by `infer ask`, also drives the local self-echo demo)
    Q_INVOKABLE virtual bool    ask(const QString& id, const QString& prompt) = 0;
    Q_INVOKABLE virtual QString takeReplies() = 0;   // drain queued answers (sentinel-wrapped JSON)
};

#define InferenceInterface_iid "org.logos.InferenceInterface"
Q_DECLARE_INTERFACE(InferenceInterface, InferenceInterface_iid)

#endif
