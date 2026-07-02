# cli-provider — a headless AI inference provider built from `logoscore`

This is the **provider** half of part13. It turns
[`logos-logoscore-cli`](https://github.com/logos-co/logos-logoscore-cli) into an
inference node: it subscribes to a Logos delivery content topic, and for every
`prompt` it runs a local LLM via **ollama** (`tinyllama`) and publishes the
`response` back. No GUI — a headless Logos module (`inference_provider`) loaded
into the logoscore daemon.

```
prompt  (Basecamp inference-ui)  ── /inference/1/<room>/json ──▶  ollama  (this)
                                 ◀──────────  response  ──────────
```

It's the same shape as part11's `cli-ponger`, but the reply is an LLM completion
instead of a static "pong".

## Files

| File | Purpose |
|------|---------|
| `provider-core/`        | the `inference_provider` Logos module (C++): subscribes, runs ollama, replies |
| `setup-modules.sh`      | builds/stages `delivery_module` + `inference_provider` (dev variants) into `./modules` |
| `inference-provider.sh` | starts the daemon, loads the module, answers prompts; prints live counts |
| `modules/`              | created by `setup-modules.sh` (git-ignored — large platform binaries) |

## Prerequisites

- **ollama running** with the model pulled:
  ```bash
  ollama serve            # or just have the Ollama app running
  ollama pull tinyllama
  ```
- `logoscore`, `jq`, `curl`.

## Quick start

```bash
cd cli-provider
./setup-modules.sh                 # one-time (nix-builds the dev modules)
./inference-provider.sh lobby      # listen + answer on /inference/1/lobby/json
```

Leave it running. In Basecamp, open **AI Inference**, join room `lobby`, Start,
type a prompt, Send. Each prompt prints here as `prompts: N · responses: N`, and
the Basecamp UI shows the model's reply.

## The CLI pipeline (what the script runs)

```bash
logoscore -D -m ./modules
logoscore load-module inference_provider                 # pulls in delivery_module
logoscore call inference_provider start lobby            # createNode/start/subscribe
logoscore call inference_provider stats                  # promptsSeen / responsesSent
```

Inside the module, each prompt becomes:
`curl -sS $OLLAMA_URL/api/generate -d '{"model":"tinyllama","prompt":"…","stream":false}'`
→ the `.response` is published back as `{"type":"response","id":…,"text":…}`.

## Configuration

| Env / arg | Default | Meaning |
|-----------|---------|---------|
| `$1` / `ROOM` | `lobby` | Room → topic `/inference/1/<room>/json` |
| `INFERENCE_MODEL` | `tinyllama` | ollama model to run |
| `OLLAMA_URL` | `http://localhost:11434` | ollama HTTP endpoint |
| `INFERENCE_TCPPORT` | `60010` | Waku TCP port (Basecamp uses 60000; distinct so both coexist) |
| `LOGOSCORE` | auto | path to the `logoscore` binary |

## Notes

- A logoscore daemon and Basecamp can run on one machine at once (Qt sockets are
  instance-scoped); the two delivery nodes just use different Waku ports.
- The script auto-selects the **daemon.json-model** logoscore (it skips the newer
  `config-dir` CLI, which uses an incompatible daemon model).
- The module calls ollama **asynchronously** (QProcess) and defers the call out of
  delivery's event dispatch, so generation never blocks the node.
