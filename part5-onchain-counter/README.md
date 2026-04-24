# Part 5 — On-chain Counter (work in progress)

> 🚧 **Status: not yet in a working state.** The code here is structurally complete and follows the SPEL/LEZ integration pattern from [`logos-co/whisper-wall`](https://github.com/logos-co/whisper-wall), but the end-to-end deploy + increment + read round-trip hasn't been validated on a live sequencer yet. Two upstream gates: the public devnet (`devnet.blockchain.logos.co`) has been returning 502 since the 2026-04-24 `v0.1.3-rc.3` upgrade, and self-hosting the `logos-execution-zone` docker-compose stack on macOS hits known RISC-Zero / `ruint` toolchain conflicts (SPEL #140). Ship-worthy fix is pending upstream. See the "Runtime prereqs" and "Known gaps to validate" sections below.

A number that lives on the Logos blockchain. Click the button, `count += 1`, and everyone pointed at the same sequencer sees the new value.

This part is modelled on [`logos-co/whisper-wall`](https://github.com/logos-co/whisper-wall) — the official SPEL/LEZ reference demo — with every non-essential feature stripped out so the focus stays on **"write a program, deploy it, call it from a Basecamp plugin."**

## Layout

```
part5-onchain-counter/
├── counter-program/         # The SPEL program (Rust → RISC-Zero zkVM guest)
│   ├── counter_core/         # Shared state struct
│   ├── methods/guest/        # On-chain logic
│   └── examples/             # IDL generator + CLI wrapper
├── counter-core/            # Basecamp C++ plugin — shells out to `spel` + `wallet`
└── counter-ui/              # QML sidebar tab — big number + Increment button
```

## What Part 5 teaches (one new primitive)

| Part | New primitive |
|---|---|
| 1 | QML UI |
| 2 | Local persistence (SQLite) |
| 3 | P2P pub/sub (Waku) |
| 4 | Content-addressable storage (Codex) |
| **5** | **On-chain state (LEZ program + zkVM proof)** |

The counter program is three `#[instruction]` functions totalling ~70 lines of Rust. Everything else — the wallet, the sequencer, the zkVM prover — is off-the-shelf Logos stack.

## Runtime prereqs

Two host-installed binaries + a reachable sequencer.

### 1. Install `spel` + `wallet` + `cargo-risczero`

```bash
# RISC-Zero zkVM toolchain
cargo install cargo-risczero     # only if not already installed

# spel (SPEL program framework CLI)
git clone https://github.com/logos-co/spel
cargo install --path spel/spel-cli

# wallet CLI (manages accounts, deploys programs, sets sequencer endpoint)
git clone --branch v0.2.0-rc1 https://github.com/logos-blockchain/logos-execution-zone
cargo install --path logos-execution-zone/wallet

# Extract logos-blockchain-circuits to the expected path
gh release download v0.4.2 -R logos-blockchain/logos-blockchain-circuits \
    -p "logos-blockchain-circuits-v0.4.2-macos-aarch64.tar.gz"           # or -linux-x86_64
mkdir -p ~/.logos-blockchain-circuits
tar xzf logos-blockchain-circuits-*.tar.gz -C ~/.logos-blockchain-circuits --strip-components=1
```

### 2. Point the wallet at a sequencer

**Option A — public devnet** (preferred when available):

```bash
export NSSA_WALLET_HOME_DIR=~/.logos-wallet
mkdir -p "$NSSA_WALLET_HOME_DIR"
wallet config set sequencer-addr https://devnet.blockchain.logos.co
wallet check-health
```

**Option B — self-hosted local** (when public devnet is down or for offline work):

```bash
git clone https://github.com/logos-blockchain/logos-execution-zone lez
cd lez && docker compose up -d
# wait ~10 min for images to build + services to come up
wallet config set sequencer-addr http://127.0.0.1:3040
wallet check-health
```

> On macOS you may need `DOCKER_DEFAULT_PLATFORM=linux/amd64` to bypass a known
> SPEL build issue with `ruint@1.18.0` under the custom Rust toolchain inside the
> service containers.

### 3. Build + deploy the counter program

```bash
cd part5-onchain-counter/counter-program
make build          # zkVM guest build — ~7 min first time
make idl            # generate counter-idl.json
make setup          # create a signer account
make deploy         # push the ELF to the sequencer

# Initialise the counter PDA (once, ever, per sequencer)
make cli ARGS="initialize"
make inspect-counter
# → { "count": "0" }
```

### 4. Build + install the Basecamp plugin pair

```bash
cd ../counter-core
nix build '.#lgx-portable' --out-link result-portable

cd ../counter-ui
nix build --override-input counter path:../counter-core '.#lgx-portable' --out-link result-portable
```

Install both `.lgx` packages via Basecamp's **Modules → Install LGX Package** menu.

## How the pieces talk

```
┌─────────────────────────── Basecamp (your laptop) ──────────────────────────┐
│                                                                             │
│   counter-ui/Main.qml  ──logos.callModule("counter", "increment")──▶         │
│                                                                             │
│                        counter-core/counter_plugin.cpp                       │
│                          │                                                   │
│                          │  QProcess("spel", ["--", "increment"])            │
│                          ▼                                                   │
│                      spel CLI (your host binary)                             │
│                          │                                                   │
└──────────────────────────┼──────────────────────────────────────────────────┘
                           │  HTTP JSON-RPC
                           ▼
                   ┌─────────────────┐     ┌─────────────────┐
                   │   sequencer     │────▶│   bedrock node  │  (consensus, blocks)
                   │ (3040 or :443)  │     └─────────────────┘
                   └─────────────────┘
                           │
                           └── hosts program ELF + counter PDA state
```

The Basecamp plugin doesn't speak JSON-RPC itself. It shells out to `spel`, which is the IDL-driven client that reads `spel.toml` (program path, IDL, sequencer URL) and builds the TX, generates the zk proof if needed, and submits to the sequencer. That's the same pattern whisper-wall uses in its `make cli` target.

## Why shell out instead of using a `chain_module`?

Unlike `delivery_module` (Part 3) and `storage_module` (Part 4), there is no `chain_module` that wraps the blockchain behind Basecamp's IPC. So the plugin talks to the chain through the host-installed `spel` + `wallet` CLIs via `QProcess`. This is the same pattern `storage_module` uses internally (it launches `libstorage` as a subprocess) — just one layer higher. It keeps our plugin loosely coupled to the rapidly-moving `logos-execution-zone` Rust API.

## What's stripped out relative to whisper-wall

| Feature | whisper-wall | counter |
|---|---|---|
| On-chain state | `WhisperState` (5 fields) | `CounterState` (1 field) |
| Auth checks | admin-only `drain_jar` | none beyond signer |
| Token payments | `ChainedCall` to `auth-transfer` | none |
| Privacy cascade | `Public/` and `Private/` signer paths | public only |
| Instructions | 5 | 3 |

Programs that want any of those features can be built by adding them back on top of this counter skeleton — whisper-wall's own source is the tutorial for that.

## Known gaps to validate

- [ ] End-to-end `make build && make deploy && make cli ARGS="increment"` against a live sequencer (public or local)
- [ ] `counter-core` QProcess shell-out — untested until a sequencer is reachable
- [ ] Does `spel pda counter --seed-arg` work at runtime? The command is documented in `spel --help` but I haven't exercised it
- [ ] Does a second Basecamp instance on a different machine see the same count after one calls `increment`? (The point of the demo — depends entirely on both pointing at the same sequencer.)
