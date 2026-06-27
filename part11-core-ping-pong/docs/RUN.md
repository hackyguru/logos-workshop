# Part 11 — Run: Core Ping ⟷ Pong

Two halves: the **Basecamp pinger** (`ping-core` + `ping-ui`) and the **headless CLI
ponger** (`cli-ponger/`). Because a `logoscore` daemon and Basecamp can't share a
machine (see [BRIEF](BRIEF.md#key-constraints-discovered)), run them on two machines —
or run the ponger with Basecamp closed.

---

## A. Build & install the Basecamp side

Needs the Logos nix toolchain (the off-PATH nix at `/nix/var/nix/profiles/default/bin/nix`
on the workshop Macs). Build the core module, then the UI:

```bash
cd part11-core-ping-pong/ping-core
nix build '.#default'          # produces the ping core .lgx
# or the portable bundle target if your installer expects it:
#   nix build '.#lgx-portable'

cd ../ping-ui
nix build '.#default'          # resolves the sibling ping-core via flake input
```

Install both resulting `.lgx` bundles into Basecamp the usual way (Package Manager →
install from file, or the workshop's reinstall drill). After install you should see a
**Ping ⟷ Pong** app in Basecamp.

> Dependency wiring: `ping` declares `delivery_module` in `metadata.json`; `ping_ui`
> declares `ping`. The loader pulls `delivery_module` in automatically.

---

## B. Run the headless ponger

On the **second machine** (or the same machine with Basecamp quit):

```bash
cd part11-core-ping-pong/cli-ponger

# one-time: copy delivery_module into ./modules so the daemon can load it.
# Uses the local Basecamp install by default; override with DELIVERY_SRC=<dir>.
./setup-modules.sh

# start listening on /pingpong/1/lobby/json
./pong-responder.sh lobby
```

Expected output:

```
[ponger] logoscore: …/logos-logoscore-cli/bin/logoscore
[ponger] starting logoscore daemon (log: /tmp/logoscore-ponger.log)
[ponger] daemon is up
[ponger] delivery_module loaded
[ponger] createNode (tcpPort=60010, discv5UdpPort=9010)…
[ponger] ready — listening on /pingpong/1/lobby/json
[ponger] ponger id: cli-ponger-1a2b
──────────────────────────────────────────────────────────────
```

Leave it running. `Ctrl+C` stops the daemon it started.

If `logoscore` isn't on your `PATH`:
```bash
LOGOSCORE=/path/to/logoscore ./pong-responder.sh lobby
```

---

## C. Drive it from Basecamp

1. Open **Ping ⟷ Pong**.
2. Set **Room** to `lobby` (must match the ponger's room) and press **Join**.
3. Press **Start** — the status dot goes amber → green (the local node is up).
4. Press **Send Ping**.

Each ping appears in the list as `⏳ waiting for pong…`, then flips to
`🏓 pong from cli-ponger-xxxx · NN ms` when the CLI answers. The ponger terminal logs
`ping <id> from <you> → pong sent` for every one.

---

## Running two delivery nodes on one host (optional)

If you must run a ponger and a delivery node on the same host (e.g. quick local test
with two terminals and two *non-Basecamp* cores), give them different Waku ports so they
don't fight over 60000:

```bash
PINGPONG_TCPPORT=60012 ./pong-responder.sh lobby     # ponger on 60012 / udp 9012
```
The Basecamp module honours the same env var (`PINGPONG_TCPPORT`) for its node.

---

## Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| Daemon won't start; log shows `capability_module … Failed to connect to token socket` / `QProcess::Crashed` | Another Logos core (usually **Basecamp**) is running as the same user. Quit it, or run the ponger on another machine. |
| `delivery_module not found in …/modules` | Run `./setup-modules.sh` first (and check `DELIVERY_SRC` if you have no Basecamp install). |
| `logoscore binary not found` | Put `logoscore` on `PATH` or set `LOGOSCORE=/path/to/logoscore`. |
| Pings stay `⏳ waiting` forever | (1) Rooms differ — both sides must use the same room. (2) The two nodes haven't peered yet on the delivery network — give it up to a minute, and confirm both show **Connected**. (3) On one host, ensure different `PINGPONG_TCPPORT`s. |
| `createNode returned non-zero (node may already exist)` | Harmless on a re-run — createNode is once-per-process; the script continues. |
| Want to watch raw traffic | In another terminal: `logoscore watch delivery_module --event messageReceived --json` |

## What was verified locally vs. needs the 2-machine run

- **Verified here** (without disturbing a running Basecamp): the ponger's NDJSON
  decode → pong-construct logic, `setup-modules.sh`, script syntax, and every
  `logoscore` subcommand/flag against the installed binary + its source.
- **Needs the real run** (two cores that can actually peer): the live
  `load-module delivery_module` on the CLI, the Waku round-trip, and the on-screen
  round-trip timing in Basecamp.
