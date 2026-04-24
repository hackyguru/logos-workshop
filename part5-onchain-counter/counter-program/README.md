# counter — SPEL program

An on-chain counter: one PDA holds a single `u64`, one instruction increments it.

## What's here

```
counter-program/
├── Cargo.toml               # Workspace
├── Makefile                 # build / idl / setup / deploy / cli / inspect-counter
├── spel.toml                # points spel CLI at the IDL + binary
├── counter_core/            # shared state struct (guest + host)
├── methods/
│   └── guest/               # the RISC Zero zkVM guest — the actual on-chain program
│       └── src/bin/counter.rs
└── examples/
    └── src/bin/
        ├── generate_idl.rs  # alternate IDL-gen entry (Makefile uses `spel generate-idl` instead)
        └── counter_cli.rs   # `spel::run()` — auto-generates CLI from IDL
```

## Instructions

| Instruction  | Auth   | Effect                                                            |
|--------------|--------|-------------------------------------------------------------------|
| `initialize` | signer | Claims the counter PDA (seed `"counter"`). Sets `count = 0`.       |
| `increment`  | signer | Reads the state, `count += 1`, writes it back. Anyone can call.    |
| `read`       | none   | No-op. Follow with `spel inspect <pda> --type CounterState` to decode current value. |

Account data type (`#[account_type]`):

```rust
pub struct CounterState {
    pub count: u64,
}
```

## End-to-end

```bash
make build idl               # build zkVM guest + generate IDL (~7 min first time)
make setup                   # create a signer account
make deploy                  # push the ELF to the sequencer

make cli ARGS="initialize"   # claim the counter PDA (once, ever)
make cli ARGS="increment"    # +1
make cli ARGS="increment"    # +1 again
make inspect-counter         # show the decoded state
# { "count": "2" }
```

## Prerequisites

- `cargo-risczero` (RISC Zero toolchain)
- `spel` CLI (from [logos-co/spel](https://github.com/logos-co/spel))
- `wallet` CLI (from [logos-blockchain/logos-execution-zone](https://github.com/logos-blockchain/logos-execution-zone))
- `logos-blockchain-circuits` extracted to `~/.logos-blockchain-circuits/`
- A **running sequencer** — either the public devnet at `devnet.blockchain.logos.co`, or
  a local instance via `docker compose up` on a clone of logos-execution-zone
- Docker (for the deterministic RISC Zero guest build)

See the top-level [part5-onchain-counter/README.md](../README.md) for the full setup recipe.

## Notes vs whisper-wall

This program is whisper-wall with every complication stripped out:

- ❌ No `ChainedCall` — nothing atomic with another program
- ❌ No `auth-transfer` integration — no tokens move
- ❌ No `admin` field, no authorisation checks beyond the runtime's signer requirement
- ❌ No private / `Private/` accounts, no privacy cascade
- ❌ No tip threshold / outbid logic

All we keep:

- ✅ `#[account_type]` struct (one `u64`)
- ✅ `#[lez_program]` module
- ✅ `#[instruction]` functions with `#[account(...)]` parameter attributes
- ✅ `pda = literal("counter")` PDA seed
- ✅ `borsh` encode/decode of the state bytes
- ✅ `spel inspect` decoding via the IDL

That's the absolute minimum surface to write, deploy, and interact with an on-chain program on LEZ.
