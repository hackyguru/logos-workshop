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

- **Rendezvous:** the content topic `/inference/1/<room>/json`. Both sides
  subscribe via `delivery_module`; the network carries prompts and responses.
- **User (Basecamp):** `inference-core` (C++) sends
  `{"type":"prompt","id":…,"from":…,"prompt":…}` and matches the returning
  `{"type":"response","id":…,"text":…}` by id to compute latency. `inference-ui`
  (QML) is a prompt/response chat screen.
- **Provider (CLI):** `cli-provider/inference-provider.sh` loads the
  `inference_provider` module into logoscore. On each prompt it runs
  `ollama` (via `curl $OLLAMA_URL/api/generate`, async) and publishes the answer.

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
cd cli-provider && ./setup-modules.sh && ./inference-provider.sh lobby

# 2. user (Basecamp, on a machine with the Logos nix toolchain): build + install
cd ../inference-core && nix build '.#lgx-portable'
cd ../inference-ui   && nix build '.#lgx-portable'    # install both .lgx into Basecamp

# 3. in Basecamp: open "AI Inference" → room "lobby" → Start → type a prompt → Send
```

## Status

Implementation complete, modeled on the verified part11 architecture. The ollama
path is verified locally (`tinyllama` answers via `/api/generate`); the live
two-node prompt→response round-trip is exercised by a real run per
[docs/RUN.md](docs/RUN.md).
