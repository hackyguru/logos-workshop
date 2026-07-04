# Part 13 — AI Inference

**Decentralized AI inference over the Logos messaging network.** An inference
**user** (a Basecamp module) sends a prompt into a content topic; an inference
**provider** (a headless [`logos-logoscore-cli`](https://github.com/logos-co/logos-logoscore-cli)
node running **ollama / tinyllama**) hears it, generates a completion, and sends
the response back over the same topic.

> The idea in one line: **same content topic, two roles** — a GUI Basecamp app
> asks, a headless CLI node answers with a local LLM. No inference server, no
> API key; just Logos delivery between a user and a provider.

```
   Basecamp (inference-ui + inference-core)         logoscore CLI (cli-provider)
   ────────────────────────────────────────        ───────────────────────────
   sendPrompt("explain CRDTs")  ──▶ delivery ─┐
                                               │  /inference/1/<room>/json
                                               ▼  (Logos delivery / Waku)
                                  ┌──────────────────────────┐
                                  │   content topic on the   │
                                  │     Logos delivery net    │
                                  └──────────────────────────┘
                                               │
   responseReceived ◀── delivery ◀── inference_provider ◀── ollama (tinyllama)
   (answer + latency)                  (listens, runs the model, replies)
```

This is part11's **ping ⟷ pong** with the "pong" replaced by an LLM completion —
the architecture is identical (see [part11-core-ping-pong](../part11-core-ping-pong)).

## How it works

- **Rendezvous, two ways:**
  - *Room* (legacy/local): the shared topic `/inference/1/<room>/json` — both
    sides pick the same room and meet there, part11-style.
  - *Marketplace* (discovery): providers publish **signed capability cards**
    (models served, load/capacity, price scheme) every ~30s (jittered; load
    changes announce immediately) on the well-known
    topic `/inference/1/discovery/json`, and take prompts on their **own
    session topic** `/inference/1/p-<fingerprint>/json`. Users browse the
    global roster and reach any provider anywhere — no shared room needed.
- **User (Basecamp):** `inference-core` (C++) builds a verified roster from
  announces (v2 room / v3 discovery), seals prompts E2E to the chosen
  provider (auto = least-loaded, or pinned, optionally filtered by model),
  and matches sealed responses by id to compute latency. `inference-ui`
  (QML) is a prompt/response chat screen with a marketplace browser.
- **Provider (CLI):** `cli-provider/inference-provider.sh` loads the
  `inference_provider` module into logoscore. On each prompt it runs
  `ollama` (via `curl $OLLAMA_URL/api/generate`, async) and publishes the
  answer on the topic the prompt arrived on. `INFERENCE_MODELS=a,b,c`
  advertises multiple models; sealed prompts may request any of them.
- **Economics seam:** every v3 card carries a `price` object —
  `{"scheme":"free"}` today. When LEZ private payments land, the scheme and
  terms slot in here (the card signature already covers them).

See **[docs/BRIEF.md](docs/BRIEF.md)** for the design + message protocol and
**[docs/RUN.md](docs/RUN.md)** to build, install, and run it end to end.

## Layout

```
part13-ai-inference/
├── inference-core/        # C++ module — sends prompts, receives responses
│   ├── src/inference_interface.h  ·  inference_plugin.{h,cpp}
│   ├── CMakeLists.txt  metadata.json  flake.nix
├── inference-ui/          # QML UI — prompt box + response list
│   ├── Main.qml  metadata.json  flake.nix  icons/inference.png
├── cli-provider/          # the headless provider, built from logoscore-cli
│   ├── provider-core/     # the inference_provider module (runs ollama)
│   ├── setup-modules.sh  inference-provider.sh  README.md
└── docs/                  # BRIEF.md (design + protocol)  ·  RUN.md (build + run)
```

## Quick start

```bash
# 1. provider (a machine with ollama): pull the model, stage + run
ollama pull tinyllama
cd cli-provider && ./setup-modules.sh && ./inference-provider.sh agora

# 2. user (Basecamp, on a machine with the Logos nix toolchain): build + install
cd ../inference-core && nix build '.#lgx-portable'
cd ../inference-ui   && nix build '.#lgx-portable'    # install both .lgx into Basecamp

# 3. in Basecamp: open "AI Inference" → room "agora" → Start → type a prompt → Send
```

## Status

Implementation complete, modeled on the verified part11 architecture. The ollama
path is verified locally (`tinyllama` answers via `/api/generate`); the live
two-node prompt→response round-trip is exercised by a real run per
[docs/RUN.md](docs/RUN.md).
