# Part 8 — Headless inference responder (CLI)

> 🚧 **Reference / work in progress.** This builds on `logos-delivery-module`,
> whose public `logos.dev` bootstrap peers don't currently handshake (see the
> note in [`/docs/delivery-guide.md`](../docs/delivery-guide.md) Gotcha #10).
> So the *single-node self-echo demo below works today*; true cross-machine
> messaging needs a network whose peers actually connect (custom `entryNodes`
> or `twn`).

A command-line tool that runs **private inference over Logos messaging**. Run
`infer start` on a headless box (e.g. a VPS) and it listens for prompts on a
Logos content topic, runs each through a **local Ollama model**, and publishes
the answer back to whoever asked — no GUI, no data leaving the machine.

```
  peer ──(prompt)──▶  /inference/1/prompt/json  ──▶  infer start (responder)
                                                       │  runs Ollama locally
  peer ◀──(answer)──  /inference/1/reply-<id>/json ◀──┘
```

## Why it's split in two

Receiving messages requires a **C++ Logos core module** — `delivery_module`
delivers messages via event callbacks that only fire inside the `logos_host`
process; `logoscore call` alone is one-shot and can't "listen". So:

- **`inference-core/`** — a tiny C++ plugin that does **transport only**:
  subscribe to the prompt topic, queue incoming prompts, and expose
  `takePending()` / `reply()` (responder) plus `ask()` / `takeReplies()`
  (requester). It never runs a model.
- **[`infer`](infer)** — a bash CLI. `infer start` boots a headless
  `logoscore` daemon, loads the module, then runs the
  `poll queue → run Ollama → publish answer` loop. Inference stays in a sane
  runtime; the daemon just moves bytes.

This split also dodges the delivery deadlock (Gotcha #9): the C++ handler only
*queues*; every `send` happens from a separate RPC call, never from inside the
message-received callback.

## Prerequisites

Everything below the GUI is **Nix-built** — `logoscore` is *not* shipped in the
Basecamp app, so Nix (with flakes) is required.

- **Nix** with flakes enabled.
- **Ollama** running locally with a model pulled:
  ```bash
  ollama serve &           # if not already running
  ollama pull llama3       # or set INFER_MODEL to whatever you pulled
  ```
- **`logoscore`** — the headless runtime, built from its own flake:
  ```bash
  nix build 'github:logos-co/logos-logoscore-cli' --out-link ./logos   # → ./logos/bin/logoscore
  ```
- **`lgpm`** — the CLI package manager that installs `.lgx` files headlessly:
  ```bash
  nix build 'github:logos-co/logos-package-manager#cli' --out-link ./pm  # → ./pm/bin/lgpm
  ```
- **delivery_module** — the messaging transport (NOT bundled in recent Basecamp
  builds; install it into the same modules dir, see below).
- `python3` (JSON handling; present on macOS).

## Build & install — fully headless (no GUI)

Pick a modules dir and install both plugins into it with `lgpm`:

```bash
MODULES_DIR=./modules                 # or wherever you want to keep plugins
mkdir -p "$MODULES_DIR"

# 1. delivery_module (transport) — first build pulls the Nim/libp2p closure (~15–30 min)
nix build 'github:logos-co/logos-delivery-module' --out-link result-delivery
./pm/bin/lgpm --modules-dir "$MODULES_DIR" install --file result-delivery/*.lgx

# 2. our inference module
cd inference-core
nix build '.#lgx-portable' --out-link result-portable
../pm/bin/lgpm --modules-dir "$MODULES_DIR" install --file result-portable/*.lgx
cd ..
```

Then point the CLI at that dir (and at the logoscore you built) when you run it:

```bash
export LOGOSCORE="$PWD/logos/bin/logoscore"
export MODULES_DIR="$PWD/modules"
```

`infer` also auto-detects `./logos/bin/logoscore` next to itself, so if you keep
the `logos` build alongside the script you can skip the `LOGOSCORE` export.

## Run it — local self-echo demo (one machine)

Gossipsub echoes your own publishes back to you, so a single node both asks and
answers — enough to prove the full request/response loop without a second peer.

**Terminal A — the responder:**
```bash
./infer start
# [infer] responder up — model 'llama3', topic /inference/1/prompt/json
```

**Terminal B — ask it something:**
```bash
./infer ask "Explain content topics in one sentence."
# …waits, then prints the model's answer
```

Stop with Ctrl-C in Terminal A, or `./infer stop`.

## Deploying the responder on a VPS

```bash
# on the VPS, inside a tmux/screen so it survives your SSH session:
INFER_MODEL=llama3 ./infer start
```

It serves answers for as long as the process is alive. For peers on *other*
machines to reach it you need a working network — supply custom bootstrap
peers via the module's `createNode` config (`entryNodes`) or move to `twn`.
Until then, exercise it locally with `infer ask`.

## Configuration

| Env var | Default | Purpose |
| --- | --- | --- |
| `INFER_MODEL` | `llama3` | Ollama model name |
| `OLLAMA_URL` | `http://localhost:11434/api/generate` | Ollama endpoint |
| `LOGOSCORE` | auto-detected | Path to the `logoscore` binary |
| `MODULES_DIR` | macOS Basecamp modules dir | Where the plugins live |
| `INFER_POLL_INTERVAL` | `1` | Seconds between queue polls |
| `INFERENCE_TCPPORT` | `60000` | Override P2P port for a 2nd node on one host |

## Module API (for reference)

All `Q_INVOKABLE`, callable via `logoscore call inference <method> …`:

| Method | Role | Purpose |
| --- | --- | --- |
| `start()` | both | createNode → start → subscribe to prompt topic |
| `stop()` | both | unsubscribe + stop |
| `status()` | both | 0=off 1=connecting 2=connected 3=error |
| `takePending()` | responder | drain queued prompts (sentinel-wrapped base64 JSON) |
| `reply(replyTopic, id, answer)` | responder | publish an answer |
| `ask(id, prompt)` | requester | subscribe to reply topic + publish prompt |
| `takeReplies()` | requester | drain queued answers |

The `take*` methods return `INFERJSON:<base64>:ENDJSON` so the bash CLI can
recover the payload regardless of how `logoscore` formats its stdout.
