# Part 13 — Run: AI Inference

Two halves: the **provider** (`cli-provider/`, a headless logoscore node running
ollama) and the **user** (`inference-core` + `inference-ui` in Basecamp). They meet
on the content topic `/inference/1/<room>/json`.

---

## A. Provider — headless ollama node

Needs **ollama** with the model pulled, plus `logoscore`, `jq`, `curl`.

```bash
# ollama (the Ollama app running is enough, or:)
ollama serve &
ollama pull tinyllama

cd part13-ai-inference/cli-provider
./setup-modules.sh                 # one-time: nix-builds the dev delivery_module + inference_provider
./inference-provider.sh lobby      # answer prompts on /inference/1/lobby/json
```

Expected:

```
[provider] ollama up, model 'tinyllama' available
[provider] daemon is up
[provider] inference_provider loaded
[provider] start(room=lobby, model=tinyllama, tcpPort=60010)...
[provider] ready — answering prompts on /inference/1/lobby/json with 'tinyllama'
[provider] provider id: cli-llm-1a2b
```

Leave it running. `Ctrl+C` stops it. Use a different model with
`INFERENCE_MODEL=llama3.2 ./inference-provider.sh`.

> First `setup-modules.sh` build pulls the delivery_module Nim/Rust deps and
> compiles two modules — minutes on a cold cache, cached after. Skip a rebuild by
> pointing at prebuilt packages: `DELIVERY_LGX=… PROVIDER_LGX=… ./setup-modules.sh`.

---

## B. User — Basecamp app

On a machine with the Logos nix toolchain:

```bash
cd part13-ai-inference/inference-core && nix build '.#lgx-portable'
cd ../inference-ui                     && nix build '.#lgx-portable'
```

Install both resulting `.lgx` into Basecamp (Package Manager → install from file,
or the workshop reinstall drill). You'll get an **AI Inference** app.

> Dependency wiring: `inference` declares `delivery_module`; `inference_ui`
> declares `inference`. The loader pulls `delivery_module` in automatically.

Runs fine alongside the provider on one machine: Basecamp's delivery node uses
Waku port `60000`, the provider uses `60010` (set via `INFERENCE_TCPPORT`).

---

## C. Drive it

1. Open **AI Inference** in Basecamp.
2. Set **Room** to `lobby` (must match the provider) and **Join**.
3. **Start** — the status dot goes green (local node up).
4. Type a prompt, **Send prompt** (or Ctrl+Enter).

The entry shows `🤖 thinking… Ns`, then flips to the model's answer with
`tinyllama · cli-llm-xxxx · NN ms`. The provider terminal logs
`prompts: N · responses: N`.

---

## Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| `ollama not reachable` | Start ollama (`ollama serve` / the app) and check `OLLAMA_URL`. |
| `model 'tinyllama' not found` | `ollama pull tinyllama` (or set `INFERENCE_MODEL` to one you have). |
| `inference_provider not staged` | Run `./setup-modules.sh` first. |
| daemon won't start; capability_module crash | A stale daemon — `./inference-provider.sh` again, or `logoscore stop`. Basecamp running is fine. |
| `logoscore binary not found` | Put `logoscore` on PATH or set `LOGOSCORE=…`. The script auto-skips the newer `config-dir` CLI. |
| prompts stay `🤖 thinking…` forever | (1) Same room on both sides. (2) Give the two delivery nodes time to peer on the network. (3) Keep the provider running. (4) On one host, ensure distinct Waku ports (default 60000 vs 60010). |
| response is `[inference failed …]` | The provider reached ollama but generation failed — check the model is pulled and `curl $OLLAMA_URL/api/generate` works directly. |

## What was verified vs. needs a 2-node run

- **Verified locally**: ollama + tinyllama answer via `/api/generate`; the
  prompt→ollama→response pipeline and the message protocol.
- **Needs the real run**: the live cross-node prompt→response over the delivery
  network (provider node ↔ Basecamp node peering), same dependency as part11.
