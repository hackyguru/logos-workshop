# cli-ponger — a headless ping responder built from `logoscore`

This is the **responder** half of part11. It turns
[`logos-logoscore-cli`](https://github.com/logos-co/logos-logoscore-cli) into a
listener: it subscribes to a Logos delivery content topic and answers every
`ping` with a `pong` — no GUI, no custom module, just the CLI's own
`load-module` / `call` / `watch` commands wired together in a shell script.

```
ping  (Basecamp ping-ui)  ── /pingpong/1/<room>/json ──▶  pong  (this script)
                          ◀──────────  pong  ───────────
```

## Files

| File | Purpose |
|------|---------|
| `setup-modules.sh`  | Assembles `./modules/delivery_module/` (copies a delivery_module bundle) so the daemon can load it. Run once. |
| `pong-responder.sh` | Starts the daemon, loads delivery_module, subscribes to the topic, and replies pong to every ping. |
| `modules/`          | Created by `setup-modules.sh` (git-ignored — large platform binaries). |

## Quick start

```bash
cd cli-ponger
./setup-modules.sh          # copy delivery_module into ./modules
./pong-responder.sh lobby   # listen on /pingpong/1/lobby/json
```

Leave it running. In Basecamp, open the **Ping ⟷ Pong** app, join the same room
(`lobby`), press **Start**, then **Send Ping**. Each ping prints here as
`ping <id> … → pong sent`, and the Basecamp UI shows the round-trip time.

Stop with `Ctrl+C` (it stops the daemon it started).

## The CLI pipeline (what the script runs for you)

```bash
logoscore -D -m ./modules -m <bundle>/modules         # 1. start daemon
logoscore load-module delivery_module                 # 2. load the bus
logoscore call delivery_module createNode '{"preset":"logos.dev","mode":"Core","tcpPort":60010,"discv5UdpPort":9010}'
logoscore call delivery_module start                  # 3. bring up the Waku node
logoscore call delivery_module subscribe '/pingpong/1/lobby/json'
logoscore watch delivery_module --event messageReceived --json   # 4. listen…
logoscore call delivery_module send '/pingpong/1/lobby/json' '{"type":"pong",...}'   # …reply
```

`watch --json` emits one NDJSON line per message; the script base64-decodes
`data.arg2`, and if the payload is `{"type":"ping",...}` it sends back
`{"type":"pong","id":<same id>,...}` on the same topic.

## ⚠️ One core per machine

A `logoscore` daemon and Basecamp **cannot run at the same time as the same user
on one machine**. Both are Logos cores and bind the *same* fixed Qt Remote Object
socket names (`local:logos_core_manager`, `logos_token_<module>`), so the second
one's `capability_module` fails with *"Failed to connect to token socket"* and the
daemon exits. So pick one:

- **Two machines (recommended):** run Basecamp + ping-ui on machine A, run this
  ponger on machine B. They meet over the Logos delivery network — the natural,
  decentralized setup.
- **One machine:** close Basecamp before running the ponger (you then drive pings
  from another Basecamp/machine on the same topic).

If you run two delivery nodes on the *same* host (e.g. testing), give them
different Waku ports: Basecamp's node uses `60000`; this script defaults to
`60010`. Override with `PINGPONG_TCPPORT=60012 ./pong-responder.sh`.

## Configuration

| Env / arg | Default | Meaning |
|-----------|---------|---------|
| `$1` / `ROOM` | `lobby` | Room → topic `/pingpong/1/<room>/json` |
| `PINGPONG_TCPPORT` | `60010` | Waku libp2p TCP port (discv5 UDP derived as `9000+offset`) |
| `LOGOSCORE` | auto | Path to the `logoscore` binary (PATH, else nix store) |
| `DELIVERY_SRC` | Basecamp install | Source dir for `setup-modules.sh` to copy delivery_module from |
| `DAEMON_LOG` | `/tmp/logoscore-ponger.log` | Daemon stdout/stderr |

## Requirements

- `logoscore` (the logos-logoscore-cli binary) on `PATH` or via `$LOGOSCORE`
- `jq` and `base64`
- A `delivery_module` bundle to copy (Basecamp install, or point `DELIVERY_SRC` at one)
