# Logos Wallet — Bedrock + LEZ in one module

A clean, single wallet for both Logos layers, built on what a long night of
reverse-engineering *proved* works:

- **Base chain (Bedrock)** — runs the official `logos-blockchain-node` binary
  as a **detached daemon** (survives quitting the UI/Basecamp, re-adopted on
  next load). Base wallet, transfers, and on-chain inscriptions.
- **Private zone (LEZ)** — drives the **Basecamp-bundled `logos_execution_zone`
  module**, which is the *only* build version-matched to the deployed
  testnet. Private/shielded transfers, the piñata faucet, and the
  base↔LEZ bridge.

```
logos-wallet/
├── logos-wallet-core/   # C++ core — sole owner of node daemon + LEZ wallet
└── logos-wallet-ui/     # QML — two tabs: Base chain | Private (LEZ)
```

## The two hard-won findings this module is built on

1. **You cannot write to the hosted LEZ testnet from a source-built wallet.**
   risc0 program image IDs are build-specific; a wallet built from the
   `v0.2.0-rc1` tag *or* default branch produces IDs that don't match the
   deployment (`authenticated_transfer = bcfebbdc…`, `pinata = 8da5f666…` on
   `testnet.lez.logos.co`). `check-health` rejects it and the sequencer drops
   its transactions. Even zonescan's hardcoded "rc5" table doesn't match the
   live values — reading tolerates skew, **writing does not**.

2. **The Basecamp-bundled module DOES match** (it's the official build).
   Verified empirically: driving `register_public_account` + `claim_pinata`
   through it dropped the testnet piñata balance by exactly 150 and rotated
   its seed — a real on-chain write. So this module drives that bundled
   module for every LEZ write. **Do not run the stock LEZ Wallet plugin
   alongside it** — the module holds one wallet at a time and they'd contend.

## Core API (all return compact JSON; slow ops finish via events)

**Base chain:** `nodeStatus`, `startNode`/`stopNode` (daemon), `baseAccounts`,
`baseSend`, `inscribe`.

**LEZ:** `lezStatus`, `lezOpen` (reliable reload of the persisted wallet),
`lezFund` (piñata: sync → create+register public account → claim 150),
`lezTransfer(kind, to, amount)` with kind ∈ `private` | `shielded` | `public`,
`lezBridgeIn`, `lezClaimVault`.

## What each fix addresses (bugs from the prototype)

| Symptom before | Fix here |
|---|---|
| Node died when UI quit | `QProcess::startDetached` daemon + pidfile; re-adopt a live node instead of restarting |
| LEZ wallet "not persistent" | `storage.json` is a **file** (the FFI does `File::open`/`save_to_path`), `save()` after every mutating call, and this module is the **sole** wallet owner |
| Balance showed "…" | status reports private **and** public balances explicitly |
| Writes silently dropped | full core-driven sync before any write (proofs need the synced view) |
| Basecamp crashed | slow ops deferred → completion events (host IPC reply timeout + late-reply double-free) |

## Build & install

```bash
cd logos-wallet/logos-wallet-core
nix build '.#lgx-portable' --out-link result-portable          # core
cd ../logos-wallet-ui
nix build --override-input logos_wallet path:../logos-wallet-core '.#lgx-portable' --out-link result-portable
```

Install the core into `modules/`, the UI into `plugins/`, restart Basecamp.
`logos_execution_zone` is already bundled with Basecamp.

## Caveats

- **Anonymity model:** a recipient's account id is discoverable (they must
  share it to be paid), but individual private transfers are unlinkable and
  amounts hidden — Zcash-style shielded semantics.
- **Bridge finality:** base→LEZ credits your vault only after ~1h L1 finality.
- **Testnet peers rotate** on genesis resets — update `BOOTSTRAP_PEERS` in the
  core from the `logos-blockchain` release notes.
- The LEZ private layer depends on a **centralized sequencer** (the hosted
  testnet). That's inherent to the LEZ today, not this module.
