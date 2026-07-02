# Part 13 — Brief: AI Inference

## Goal

Run **AI inference as a Logos service**: an inference *user* (Basecamp module)
publishes a prompt to a content topic; an inference *provider* (headless logoscore
CLI node running a local LLM) consumes it, generates a completion with ollama, and
publishes the response. No central inference API — just Logos delivery between a
user and a provider, exactly like part11's ping/pong but with an LLM in the
responder.

## Architecture

```
        Basecamp (user)                              logoscore CLI (provider)
 ┌────────────────────────┐                    ┌──────────────────────────────┐
 │ inference-ui (QML)      │  logos.callModule  │ inference-provider.sh         │
 │   prompt box + Send ────┼──────────┐         │   logoscore load-module …     │
 │   response list         │          ▼         │   call inference_provider start│
 │ inference-core (C++)     │   sendPrompt()     │            │                  │
 │   delivery_module        │          │         │            ▼                  │
 └───────────┬─────────────┘          │         │   inference_provider (C++)    │
             │ delivery.send  {prompt} │         │     on prompt → ollama        │
             ▼                         │         │     curl /api/generate        │
   ╔══════════════════════════════════════════════════════╗   │                 │
   ║   content topic /inference/1/<room>/json (Waku)       ║   ▼                 │
   ╚══════════════════════════════════════════════════════╝  ollama (tinyllama)  │
             ▲                         │         │            │                  │
             │ delivery {response} ◀───┼─────────┼── delivery.send {response} ◀──┘
   inference-core.handleMessageReceived          └──────────────────────────────┘
```

Both ends `subscribe` to the identical topic; gossip routing carries the prompt
to the provider and the response back to the user.

## Message protocol

JSON, sent as the (plaintext) payload of a delivery message; on receipt
`delivery_module` hands it back **base64-encoded** in `messageReceived`'s third
field.

**prompt** (user → topic):
```json
{ "type": "prompt", "id": "8-char-id", "from": "<userId>", "ts": 1719300000000, "prompt": "explain CRDTs in one line" }
```

**response** (provider → topic):
```json
{ "type": "response", "id": "<same id as the prompt>", "from": "cli-llm-xxxx", "to": "<userId>", "text": "<model output>", "model": "tinyllama" }
```

- `id` is the correlation key. The user matches a response to its prompt by `id`
  and computes latency = `now - prompt.ts`.
- The provider only reacts to `type:"prompt"`; the user only reacts to
  `type:"response"`. No feedback loop (and gossipsub doesn't echo your own
  publishes back to you).

## How the provider runs the model

The `inference_provider` module, on `messageReceived` for a prompt:
1. **Defers** the work with `QTimer::singleShot(0, …)` — never call back into
   `delivery_module` from inside its own event dispatch (delivery-guide gotcha #9).
2. Runs ollama **asynchronously** via `QProcess`:
   `curl -sS $OLLAMA_URL/api/generate -d '{"model":"tinyllama","prompt":"…","stream":false}'`
   (request body on stdin → no shell escaping). Async so generation never blocks
   the node's event loop.
3. On `QProcess::finished`, parses `.response` and publishes the `response`
   message via `delivery_module.send` (safe here — outside delivery's dispatch).

Why `curl` and not Qt Network? It keeps the module's build to Qt Core only
(`QProcess` is Core), and the ollama server is already running on `$OLLAMA_URL`.
`curl` is on the base PATH (`/usr/bin/curl`); `ollama` at `/usr/local/bin/ollama`.

## Config / knobs

| Key | Default | Where |
|-----|---------|-------|
| topic room | `lobby` | both sides — must match |
| `INFERENCE_MODEL` | `tinyllama` | provider (ollama model) |
| `OLLAMA_URL` | `http://localhost:11434` | provider |
| `INFERENCE_TCPPORT` | provider `60010`, Basecamp `60000` | Waku port (distinct so both run on one machine) |

## Key constraints (shared with part11)

- **Dev variant required.** The standalone logoscore CLI loads modules via a dev
  `logos_host` and looks up `manifest.main["darwin-arm64-dev"]`; `setup-modules.sh`
  builds the `.#lgx` (dev) packages for both `delivery_module` and
  `inference_provider`.
- **Two cores coexist** on one machine (instance-scoped Qt sockets) — the provider
  daemon and Basecamp run together with different Waku ports.
- **Network reachability.** Prompt↔response only flows once the two delivery nodes
  peer on the configured network (the logos.dev/bootstrap caveat from part11
  applies here too).

## Files of interest

- `cli-provider/provider-core/src/provider_plugin.cpp` — the prompt → ollama →
  response pipeline.
- `inference-core/src/inference_plugin.cpp` — send prompt, match response, latency.
- `inference-ui/Main.qml` — the prompt/response screen.
