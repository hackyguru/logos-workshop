# Part 11 — Core Ping ⟷ Pong

A **ping/pong over the Logos delivery network**, where the responder is not another
Basecamp app but a **headless [`logos-logoscore-cli`](https://github.com/logos-co/logos-logoscore-cli)
node**. Basecamp sends a `ping` onto a content topic; a logoscore CLI process —
running a `load-module` / `subscribe` / `watch` / `send` pipeline — hears it and
replies `pong`.

> The idea in one line: **the same content topic, two very different clients.** A GUI
> Basecamp module and a scriptable headless CLI talk to each other over `logos_delivery`
> with no server in between — proving a Logos module and the core CLI are interchangeable
> messaging peers.

```
   Basecamp (ping-ui + ping-core)                 logoscore CLI (cli-ponger)
   ──────────────────────────────                 ──────────────────────────
   sendPing()  ──▶ delivery_module.send ─┐
                                          │   /pingpong/1/<room>/json
                                          ▼   (Logos delivery / Waku)
                              ┌───────────────────────┐
                              │  content topic on the │
                              │   Logos delivery net  │
                              └───────────────────────┘
                                          │
            pongReceived ◀── delivery_module ◀── logoscore call … send  (pong)
            (round-trip ms)                       ▲ logoscore watch … (the listener)
```

## How it works

- **The rendezvous is a content topic:** `/pingpong/1/<room>/json`
  ([content-topic format](https://lip.logos.co/messaging/informational/23/topics.html#content-topics)).
  Both sides subscribe to the same topic via `delivery_module`; the network does the rest.
- **The pinger (Basecamp):** `ping-core` (C++ module) sends `{"type":"ping","id":…,"from":…,"ts":…}`
  and listens for the matching `{"type":"pong","id":…}` to compute round-trip latency. `ping-ui`
  (QML) is a fire-a-ping / watch-the-pong screen.
- **The ponger (CLI):** `cli-ponger/pong-responder.sh` drives the `logoscore` binary —
  `load-module delivery_module` → `createNode` → `start` → `subscribe` → `watch` the
  `messageReceived` event stream → `call … send` a pong for every ping. No custom module,
  no GUI: just the CLI's own commands.

See **[docs/BRIEF.md](docs/BRIEF.md)** for the design and the message protocol, and
**[docs/RUN.md](docs/RUN.md)** to build, install, and run the loop.

## Layout

```
part11-core-ping-pong/
├── ping-core/            # C++ core module — sends pings, times pongs
│   ├── src/ping_interface.h          # API contract
│   ├── src/ping_plugin.{h,cpp}       # delivery lifecycle + ping/pong logic
│   ├── CMakeLists.txt  metadata.json  flake.nix
├── ping-ui/              # QML UI — Start/Stop, room, "Send Ping", round-trip list
│   ├── Main.qml  metadata.json  flake.nix  icons/ping.png
├── cli-ponger/           # the headless responder, built from logoscore-cli
│   ├── setup-modules.sh  pong-responder.sh  README.md
└── docs/                 # BRIEF.md (design + protocol)  ·  RUN.md (build + run)
```

## Quick start

```bash
# 1. build the Basecamp side (on a machine with the Logos nix toolchain)
cd ping-core && nix build '.#default'
cd ../ping-ui && nix build '.#default'     # install both .lgx into Basecamp

# 2. run the headless responder (on a SECOND machine, or with Basecamp closed)
cd ../cli-ponger
./setup-modules.sh
./pong-responder.sh lobby

# 3. in Basecamp: open "Ping ⟷ Pong" → room "lobby" → Start → Send Ping
#    the CLI prints "ping <id> … → pong sent"; the UI shows the round-trip ms
```

## ⚠️ One Logos core per machine

A `logoscore` daemon and Basecamp can't run as the same user on one machine at once —
they clash on fixed Qt Remote Object socket names. Run the ponger on a **second machine**
(the decentralized, intended setup) or **close Basecamp first**. Details in
[cli-ponger/README.md](cli-ponger/README.md#-one-core-per-machine).

## Status

Implementation complete. Verified without disrupting a running Basecamp: the ponger's
event-parse → pong-construct pipeline (against synthetic `watch` NDJSON), `setup-modules.sh`,
script syntax, and every CLI command/flag against the installed `logoscore` binary and its
source. The Basecamp modules follow the proven part3-polling delivery pattern verbatim. The
live two-node round-trip is validated by a real run per [docs/RUN.md](docs/RUN.md).
