# Logos Workshop

This repository contains code and documentation for 4 beginner-friendly applications that can be built to run on Logos Basecamp as `.lgx` files:

- **Part 1** — A simple hello world UI plugin
- **Part 2** — A Todo app with a UI plugin and a Core module (SQLite-backed persistence)
- **Part 3** — A real-time polling app that uses `logos-delivery-module` — the pre-installed Logos Messaging core module — to broadcast votes peer-to-peer over Waku pub/sub
- **Part 4** — *🚧 Work in progress — not yet in a working state.* A file-sharing app that uploads files into `logos-storage-module`, surfaces the resulting CIDs, and lets you download / remove content by CID. The integration pattern is in place as reference code, but end-to-end upload/download doesn't currently function; see the note at the top of [`part4-filesharing/`](part4-filesharing/) before digging in.

## Prerequisites

- **Nix** with flakes enabled. `experimental-features = nix-command flakes` in `~/.config/nix/nix.conf`.
- **Logos Basecamp** — [download the latest release](https://github.com/logos-co/logos-basecamp/releases) for your platform. Required to install and run the resulting `.lgx` packages.
- A terminal and git. No prior Qt / QML / C++ plugin experience is assumed.

First build of Part 3 pulls the whole `logos-delivery-module` closure (Nim + libp2p + zerokit + libpq) — budget **15–30 minutes**. Every subsequent build is seconds.

Part 4 pulls `logos-storage-module` (libstorage, also Nim) the first time — similar order of magnitude. `storage_module` is **not** pre-installed on Basecamp, so you'll need to install it once before Part 4's `.lgx` can load (see Part 4 notes below).

## Docs

- [`/docs/workshop.md`](docs/workshop.md) — Step-by-step walkthrough for building all three applications. Use this as the primary reference when working through the tutorial.
- [`/docs/delivery-guide.md`](docs/delivery-guide.md) — Self-contained reference for integrating `logos-delivery-module` into any project. Official docs for `logos-delivery-module` were still a work in progress when this workshop was hosted — check the upstream repo for newer guidance.
- [`/docs/cheatsheet.md`](docs/cheatsheet.md) — Condensed one-pager with the essentials.

## Codebase

```
.
├── part1-hello-world-ui/         # Hello world (ui_qml only — no C++)
├── part2-todo/
│   ├── todo-core/                # Todo backend (C++, Qt SQL / SQLite)
│   └── todo-ui/                  # Todo UI (QML)
├── part3-polling/
│   ├── polling-core/              # Polling backend (C++, integrates delivery_module)
│   └── polling-ui/                # Polling UI (QML)
└── part4-filesharing/
    ├── filesharing-core/         # File sharing backend (C++, integrates storage_module)
    └── filesharing-ui/           # File sharing UI (QML)
```

`core` modules are C++ Qt plugins that expose `Q_INVOKABLE` methods. They install into Basecamp's `modules/` directory and have no UI of their own. `ui_qml` modules are QML-only (no compile step) and install into Basecamp's `plugins/` directory as sidebar tabs — they call into core modules via `logos.callModule(...)`.

## Build & install

Each module builds independently with Nix. Standard flow for a standalone core or UI-only module:

```bash
cd <module-dir>
nix flake update                              # first time only
nix build '.#lgx-portable' --out-link result-portable
```

UI modules that depend on a sibling core need to override the input path at build time:

```bash
# e.g. from part2-todo/todo-ui
nix build --override-input todo path:../todo-core '.#lgx-portable' --out-link result-portable

# e.g. from part3-polling/polling-ui
nix build --override-input polling path:../polling-core '.#lgx-portable' --out-link result-portable

# e.g. from part4-filesharing/filesharing-ui
nix build --override-input filesharing path:../filesharing-core '.#lgx-portable' --out-link result-portable
```

### Part 4 — installing `storage_module`

> 🚧 **Part 4 is work in progress and not yet in a working state.** The steps below build and install the module, but end-to-end upload/download does not currently function. Ship-worthy fix is pending upstream.

Part 4's core depends on `storage_module`, which Basecamp does **not** ship with. Install it into Basecamp's `modules/` directory before importing the Part 4 `.lgx`:

```bash
nix build github:logos-co/logos-storage-module --out-link /tmp/storage
cp /tmp/storage/lib/* "$HOME/Library/Application Support/Logos/LogosBasecamp/modules/"
# Linux equivalent:
# cp /tmp/storage/lib/* "$HOME/.local/share/Logos/LogosBasecamp/modules/"
```

Restart Basecamp, then install `filesharing-core.lgx` and `filesharing-ui.lgx` through **Modules → Install LGX Package**.

Produced `.lgx` file is at `result-portable/*.lgx`. Import it from Basecamp's **Modules → Install LGX Package** menu, or drop it manually — see the Install section of [`/docs/workshop.md`](docs/workshop.md) for the exact paths on macOS and Linux.

## Debugging & running multiple instances

**Run one Basecamp, import an `.lgx` via the UI** — simplest path.

**Run multiple Basecamps on one machine** (useful when demonstrating peer-to-peer polling without a second device). Only `delivery_module`'s P2P ports collide between instances, so our polling core reads a `POLLING_TCPPORT` env var and auto-derives a paired UDP port:

```bash
# Instance A — default ports (60000 TCP / 9000 UDP)
open -n "/Applications/LogosBasecamp.app"

# Instance B — override ports so both can run (60001 TCP / 9001 UDP)
open -n "/Applications/LogosBasecamp.app" --env POLLING_TCPPORT=60001

# Instance C (if needed)
open -n "/Applications/LogosBasecamp.app" --env POLLING_TCPPORT=60002
```

Adjust the `.app` path to wherever your copy of Basecamp lives. `open -n` forces a new instance (macOS normally single-instances apps on second launch); `--env` passes env vars into the launched bundle. Regular shell `VAR=value open …` does not work here because `open` goes through launchservices.

Between runs, kill any stragglers so stale `logos_host` subprocesses don't hold on to old `.dylib` files:

```bash
pkill -9 -f "LogosBasecamp.bin"
pkill -9 -f "logos_host"
```

## Licence

Both MIT and Apache-2.0 — pick whichever works for you.
