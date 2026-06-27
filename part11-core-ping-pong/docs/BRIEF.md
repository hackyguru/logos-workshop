# Part 11 — Brief: Core Ping ⟷ Pong

## Goal

Show that a **Logos GUI module** (running in Basecamp) and the **headless Logos core
CLI** (`logos-logoscore-cli`) are interchangeable peers on the same messaging fabric.
A ping sent from Basecamp is answered by a pong from a CLI process, over a shared
Logos delivery content topic, with no server mediating.

This is the smallest possible end-to-end demonstration of:
1. publishing to a content topic with `delivery_module` from a Basecamp module, and
2. using the `logoscore` CLI itself (`load-module` / `call` / `watch`) as a long-running
   listener/responder — not as a one-shot command.

## Architecture

```
        Basecamp                                   logoscore CLI (cli-ponger)
 ┌────────────────────┐                        ┌────────────────────────────┐
 │ ping-ui (QML)      │  logos.callModule      │ pong-responder.sh          │
 │   Send Ping  ──────┼──────────────┐         │   logoscore watch  ───────┐│
 │   round-trip list  │              ▼         │   logoscore call … send   ▲│
 │ ping-core (C++)    │       ping_plugin      │            │              ││
 │   delivery_module  │       .sendPing()      │            ▼              ││
 └─────────┬──────────┘              │         │     delivery_module       ││
           │ delivery_module.send    │         └────────────┼──────────────┘│
           ▼                         │                      │
   ╔═══════════════════════════════════════════════════════════════════════╗
   ║      content topic   /pingpong/1/<room>/json   (Logos delivery / Waku) ║
   ╚═══════════════════════════════════════════════════════════════════════╝
```

Both ends `subscribe` to the identical topic. Gossip routing on the delivery network
carries the ping to the CLI and the pong back to Basecamp.

## The message protocol

JSON, sent as the (plaintext) payload of a delivery message. On receipt,
`delivery_module` hands the payload back **base64-encoded** in the `messageReceived`
event's third field.

**ping** (Basecamp → topic):
```json
{ "type": "ping", "id": "8-char-id", "from": "<senderId>", "ts": 1719300000000 }
```

**pong** (CLI → topic):
```json
{ "type": "pong", "id": "<same id as the ping>", "from": "cli-ponger-xxxx", "to": "<senderId>" }
```

- `id` is the correlation key. The pinger matches an incoming pong to the ping it sent
  by `id` and computes round-trip = `now - ping.ts`.
- The responder only ever reacts to `type:"ping"`. It never reacts to `pong`, so there
  is no feedback loop. (Gossipsub also doesn't echo your own publishes back to you.)
- `ping-core` deliberately does **not** answer pings — answering is the CLI's job. This
  keeps "who replies" unambiguous for the demo.

## Why drive the CLI from a shell script (not a custom module)?

The task is to demonstrate **`logos-logoscore-cli` as a listener**. The CLI already
exposes everything needed as first-class commands:

| Step | Command |
|------|---------|
| start runtime | `logoscore -D -m <modules>` |
| load the bus  | `logoscore load-module delivery_module` |
| open a node   | `logoscore call delivery_module createNode '<cfg>'` + `… start` |
| join a topic  | `logoscore call delivery_module subscribe '<topic>'` |
| **listen**    | `logoscore watch delivery_module --event messageReceived --json` |
| **respond**   | `logoscore call delivery_module send '<topic>' '<pong>'` |

`watch --json` streams one NDJSON object per event; a `while read` loop decodes each
payload and fires a `send` back. The script *is* the demonstration — it's the CLI doing
the listening, with shell only gluing `watch`'s output to `send`'s input.

## Key constraints discovered

- **One core per machine/user.** `logoscore` (a Logos core) and Basecamp (a Logos core)
  both bind fixed Qt Remote Object socket names — `local:logos_core_manager` and
  per-module `logos_token_<name>`. Two cores as the same user on one host collide: the
  second core's `capability_module` dies with *"Failed to connect to token socket"*. So
  the ponger runs on a second machine, or with Basecamp stopped. This is *why* the demo
  reads naturally as two hosts talking over the network.
- **delivery_module isn't bundled with the CLI.** The CLI ships only `capability_module`.
  `setup-modules.sh` copies a `delivery_module` bundle (plugin + its sibling libs +
  manifest) into `cli-ponger/modules/` so the daemon can `load-module` it. Discovery
  matches `manifest.main["darwin-arm64"]` (the CLI's platform variant) → the plugin lib.
- **Same-host port hygiene.** Each delivery node binds a libp2p TCP port (default 60000)
  and a discv5 UDP port. If you ever run two nodes on one host, give the ponger a distinct
  port (`PINGPONG_TCPPORT`, default 60010 → UDP 9010); the Basecamp side honours
  `PINGPONG_TCPPORT` too.
- **createNode is once-per-process.** Both `ping-core` and the script guard re-entry so a
  Stop→Start (or a re-run against a live daemon) doesn't error on "already initialized".

## Files of interest

- `ping-core/src/ping_plugin.cpp` — delivery lifecycle (mirrors part3-polling), `sendPing`,
  and the `messageReceived` → pong-matching handler.
- `cli-ponger/pong-responder.sh` — the listener/responder pipeline.
- `cli-ponger/setup-modules.sh` — makes delivery_module available to the CLI daemon.
