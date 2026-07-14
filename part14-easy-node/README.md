# Part 14 — Easy Node: a one-button Logos blockchain node

A Basecamp plugin for people who have never touched a terminal. Open the tab
and either your node is already running — showing your wallet address,
balance, connected peers and sync status — or there is exactly one button:

> **▶ Set up & start my node**

One press generates the node config **and** the wallet keys, remembers where
they live, and starts the node. From then on the same button just says
"Start my node". No YAML, no peer lists, no curl.

Once running you can also **inscribe** — write a short text message
permanently onto the chain.

## What's in here

```
part14-easy-node/
├── easy-node-core/      # core module "easy_node" (C++) — wraps blockchain_module
│   └── src/easy_node_plugin.{h,cpp}, easy_node_interface.h
└── easy-node-ui/        # ui_qml plugin "easy_node_ui" — one QML file
    └── Main.qml
```

The node itself is `blockchain_module`, which Basecamp already bundles (the
in-process Cryptarchia node). `easy_node` wraps it behind five methods that
return **plain JSON strings**.

### Why the core module exists (the LogosResult trap)

The first cut of this part was pure QML calling `blockchain_module` directly
via `logos.callModule(Async)` — the same single-hop pattern as Part 4's
`filesharing_ui`. It doesn't work, and the failure mode is instructive:

Every `blockchain_module` method returns a `LogosResult` struct. The QML JS
bridge (`LogosQmlBridge` in `logos-view-module-runtime`) serializes remote
returns with `QJsonValue::fromVariant(...)`, which cannot convert that custom
struct — the reply arrives in QML as literal `null`, even though the module
executed the call. Plain `QString`/`bool` returns (inference, storage) cross
the bridge fine. So: **a core module that talks LogosResult in C++**
(`r.value<LogosResult>()`, same as Part 3's polling plugin does for
delivery_module) **and returns QString JSON to the UI**. This is also why the
stock Blockchain plugin ships a compiled QtRO backend instead of pure QML.

## The easy_node API

| Method | Returns | Notes |
|---|---|---|
| `status()` | `{running, hasConfig, mode, height, slot, peerId}` | `get_cryptarchia_info` + cached `get_peer_id`. |
| `setupAndStart()` | `{ok, configPath, error}` | First run: `generate_user_config` ×2 with peers baked in, `ibd: true`, `http_addr 127.0.0.1:8080`, `log_filter info`, `use_persistence_paths: true`, `output: easy-node/user_config.yaml` — creating the config **and all wallet keys** — then `start(config, "")`. The path is persisted in `QSettings("Logos","EasyNode")`. Called twice because the first call reveals the module's persistence base dir; the second pins `state/db/logs` under `easy-node/` so nothing collides with the stock Blockchain plugin's default paths (whose config would otherwise be overwritten — regenerating rotates wallet keys!). |
| `stopNode()` | `{ok, error}` | |
| `accounts()` | `{ok, accounts: [{address, balance}]}` | Address = 64-char hex — exactly what the faucet's "Destination Public Key (Hex)" field wants. Balance = raw u64 string. |
| `inscribe(text)` | `{accepted}` → `inscribeFinished` event | The node binary's built-in text sequencer, kept alive as one long-lived process (0.2.0 re-bootstraps a used channel very slowly, and a sequencer that exits right after writing loses the pending publish). Success = the channel tip visibly changes on-chain (`/channel/:id`), reported with the new message hash. Needs no funds. |
| `transfer(from, to, amount)` | `{ok, tx, error}` | Base-chain transfer: current tip from `/cryptarchia/info`, then `POST /wallet/transactions/transfer-funds` (funding key doubles as change key) — the logosup wallet recipe. |
| `lezDeposit(amount)` / `lezClaimVault(amount)` / `lezWithdraw(amount)` | events | **Bridge base ⇄ LEZ** (source-verified against logos-execution-zone@a0ba600). Deposit: mint an exact-value note via self-transfer, then `POST /channel/deposit` into the testnet bridge channel (`0x01`×32, verified live) with metadata = the private account id's raw 32 bytes (borsh `[u8;32]` — wrong metadata burns the deposit). Funds credit a per-owner vault PDA after **L1 finality (~1 h on this testnet)**; `vault_claim_private` moves vault → private balance. Withdraw: `transfer_deshielded` (private → public gateway account, zk-slow) then `bridge_withdraw(pub, ★pk, u64)` — arrives as ordinary L1 notes, no claim. In-zone amounts are 16-byte LE hex (u128). |
| `lezSetup()` / `lezStatus()` / `lezSync()` / `lezTransfer(to, amount)` | events | **Private wallet on the LEZ**, wrapping the Basecamp-bundled `logos_execution_zone` module (same LogosResult→JSON adapter). Setup writes a wallet config (`~/.logos-easy-node/lez/`, sequencer `testnet.lez.logos.co`), `create_new` → mnemonic (shown once), one `create_account_private`. Sync happens in bounded `sync_to_block` chunks; `transfer_private` amounts cross the FFI as 16-byte LE hex. The UI **pauses all polling while a LEZ call is in flight** — these calls block easy_node's loop (zk proving can take a minute) and queued-up timed-out IPC replies trip the host's double-free. Account ids display as Base58 (stock wallet convention, `Base58.js`). |

The UI polls `status()` every 2.5 s (plus the forwarded `newBlock` event for
live height bumps) and reads peer counts from the node's local HTTP API
(`GET 127.0.0.1:18080/network/info`) — the module API doesn't expose network
info.

**Ports:** Easy Node deliberately avoids the defaults — p2p on **13000/udp**
(not 3000) and HTTP on **127.0.0.1:18080** (not 8080) — so it can coexist
with a logosup Docker node or the stock Blockchain plugin's node, both of
which claim 3000/8080.

Slow operations (`setupAndStart`, `inscribe`) return `{accepted: true}`
immediately and deliver their real result via `setupFinished` /
`inscribeFinished` events: `blockchain_module.start()` blocks 30–60 s while
the node boots, far beyond the host's ~20 s IPC reply timeout — and worse,
piled-up timed-out async calls trip a double-free in the host IPC library
that crashes Basecamp. For the same reason `easy_node` fail-fasts
(`isConnected()`) instead of blocking when `blockchain_module` isn't loaded.

## Build & install

```bash
# 1. Core
cd part14-easy-node/easy-node-core
nix build '.#lgx-portable' --out-link result-portable

# 2. UI (input already points at the sibling core)
cd ../easy-node-ui
nix build '.#lgx-portable' --out-link result-portable
```

Then Basecamp → **Modules → Install LGX Package** for each (core first), and
restart Basecamp. `easy_node` installs into `modules/`, `easy_node_ui` into
`plugins/`.

## Getting test tokens

Balances start at 0. The plugin shows a "Get test tokens" helper: copy your
address, open the faucet
(<https://testnet.blockchain.logos.co/web/faucet/>), paste, request. Tokens
arrive in ~1–2 minutes. (The faucet is web-only — there is no API to automate
this step.) The ~3.5 h "token aging" you may read about only gates
*consensus participation*, not seeing or spending your balance.

## Caveats

- **⚠️ The Basecamp-bundled node is currently too old for the testnet.**
  Easy Node deliberately uses `blockchain_module` exactly as Basecamp ships
  it (composability: one node implementation, shared by every plugin). As of
  Basecamp 0.2.0-RC4 that bundle predates the testnet's 0.2.0 genesis reset,
  so the node starts, gets `remote peer does not support
  /logos-blockchain/chainsync/…` from every peer, logs
  `Initial Block Download failed: AllPeersFailed` and shuts itself down —
  height stays 0 and the balance/faucet/inscribe flow can't complete. The UI
  surfaces this as "The node stopped by itself…". Everything unlocks
  automatically once Basecamp ships a bundle built against the current node
  (no plugin changes needed). Verified root cause: a logosup Docker node
  built from the same repo at tag 0.2.0 syncs with the exact same bootstrap
  peers.
- **Bootstrap peers rotate.** The peer multiaddrs live in one
  `BOOTSTRAP_PEERS` constant at the top of
  `easy-node-core/src/easy_node_plugin.cpp` (currently the 0.2.0 testnet set,
  source: `logosnode/logosup`'s `network.yml`). A genesis reset rotates the
  peer IDs — update the constant from the `logos-blockchain` release notes
  and rebuild.
- **Inscribe ≠ the node binary's text sequencer.** `logosup inscribe` uses a
  standalone sequencer built into the `logos-blockchain-node` binary; that
  path isn't exposed through `blockchain_module`. This plugin's Inscribe is
  the module-level equivalent: a channel deposit carrying the text as
  metadata — readable on-chain, but not zone blocks from the official text
  sequencer.
- **Balance units are raw.** Neither the node API nor the stock UIs apply
  decimals or a token symbol; this plugin shows the same raw integer.
- If the stock **Blockchain** plugin already runs a node with its own config,
  Easy Node detects it (shows its info instead of the button), but the peers
  row may show "—" if that config picked a different HTTP port than 8080.
