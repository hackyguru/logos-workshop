# Part 9 — p2p-poker

Trustless multiplayer **Texas Hold'em** played peer-to-peer over
`logos-delivery-module` (the same Waku pub/sub core module Parts 3 and 6 use).
No server, no trusted dealer: the deck is shuffled and dealt with **mental
poker** cryptography so that every player's hole cards stay secret and nobody
controls the shuffle.

> Like Parts 4 & 5 this is **reference / workshop code**. The cryptography and
> protocol are implemented end-to-end and follow the proven Part 6 delivery
> pattern, but a full Nix build (first build pulls the delivery_module closure
> **and** OpenSSL) plus a live two-Basecamp playthrough may not have been
> exercised in your environment yet — see *Status & limitations* below.

```
part9-p2p-poker/
├── poker-core/                 # C++ Qt plugin "poker" (delivery + crypto + game engine)
│   └── src/
│       ├── poker_interface.h   # Q_INVOKABLE API surface
│       ├── poker_crypto.{h,cpp}# SRA commutative cipher (OpenSSL BIGNUM)
│       ├── poker_game.{h,cpp}  # betting state machine + 5-of-7 hand evaluator
│       └── poker_plugin.{h,cpp}# delivery wiring + mental-poker protocol orchestration
└── poker-ui/                   # QML table view (depends on poker)
    └── Main.qml
```

## Why mental poker?

`delivery_module` is **broadcast** pub/sub — every peer receives every byte
published on a content topic. That's fine for Part 6 (a shared colour everyone
should see) but fatal for poker, where your two hole cards must stay private and
no single party may rig the shuffle.

The classic solution is **mental poker** (Shamir–Rivest–Adleman, 1979), built on
a *commutative* cipher: `c = mᵉ mod p`, `m = cᵈ mod p` with `d = e⁻¹ mod (p-1)`.
Because `(mᵃ)ᵇ ≡ (mᵇ)ᵃ`, several players can each encrypt the deck in turn and
later peel their layers off in any order.

`p` is RFC 3526 MODP Group 14, a 2048-bit **safe** prime, and the 52 cards are
encoded as quadratic residues so a ciphertext's Legendre symbol leaks nothing.
This is the workshop's **first module to link an external library** (OpenSSL's
`libcrypto`) — wired through `metadata.json` (`nix.packages.runtime: ["openssl"]`)
plus `FIND_PACKAGES`/`LINK_LIBRARIES` in `CMakeLists.txt`.

## The protocol

All messages are JSON on `/p2p-poker/1/table/json`, discriminated by a `type`
field and deduplicated by a per-message id. Players act in a deterministic order
(sorted by peer id); the lowest id is "coordinator" and only sequences hand
start — it has **no** cryptographic privilege.

1. **Join** — peers announce `{type:"join"}` and take a seat (1000 play-money chips).
2. **Start** — the coordinator broadcasts the participant list, chip counts and
   dealer button; everyone adopts the same hand and generates fresh keys.
3. **Shuffle** — each player in turn encrypts all 52 cards with their whole-deck
   key and shuffles. After everyone, the deck is encrypted by all and in an order
   nobody knows.
4. **Lock** — each player removes their whole-deck key and re-encrypts every
   *position* with a distinct per-card key (no reshuffle). Now each fixed position
   is locked under every player's per-position key.
5. **Deal** — position `2k,2k+1` are seat *k*'s hole cards; the next five are the
   board. To let seat *k* read its hole cards, every *other* player publishes their
   per-position decryption key for those positions (`type:"key"`). Seat *k* applies
   them plus its own key — only it can, because its own key is never published.
   **This is the encrypted broadcast**: the partial keys are public, but only the
   intended owner can finish the decryption.
6. **Betting** — `preflop → flop → turn → river`, with `fold/check/call/raise`.
   Every peer runs the identical deterministic betting engine, so they all agree
   on the pot, the turn order and the result. The flop/turn/river are revealed by
   *all* players publishing their keys for those board positions when the street
   opens.
7. **Showdown** — surviving players publish their own hole keys; everyone now has
   every key, decrypts all live hands, runs the 5-of-7 evaluator and awards the
   pot. Deterministic ⇒ all peers compute the same winner.

## Build

```bash
# Core (first build is long — delivery_module Nim closure + OpenSSL)
cd poker-core
nix flake update
nix build '.#lgx-portable' --out-link result-portable

# UI — point its `poker` input at the sibling core
cd ../poker-ui
nix build --override-input poker path:../poker-core '.#lgx-portable' --out-link result-portable
```

Install both `result-portable/*.lgx` from Basecamp's **Modules → Install LGX
Package** (core first, then UI).

## Run two peers on one machine

Poker needs ≥ 2 players. Like Part 6, only the P2P ports collide, so the core
reads `POKER_TCPPORT` and uses deterministic Instance-A/B node keys + static
nodes so the two instances dial each other directly over loopback.

```bash
# Instance A — default ports (60000 TCP / 9000 UDP)
open -n "/Applications/LogosBasecamp.app"

# Instance B — overridden ports (60001 TCP / 9001 UDP)
open -n "/Applications/LogosBasecamp.app" --env POKER_TCPPORT=60001
```

In **each** instance: **Start net → Join table** (type a name). Then in the
*coordinator* (the one whose id sorts first — it shows the **Deal hand** button)
press **Deal hand**. Cards appear; bet from the action bar when it's your turn.

> Start networking and Join on every peer **before** dealing the first hand, so
> all joins have propagated. Between runs, clear stragglers:
> `pkill -9 -f LogosBasecamp.bin; pkill -9 -f logos_host`.

## Status & limitations

- **First external-lib module.** OpenSSL is wired via `find_package(OpenSSL)` +
  `OpenSSL::Crypto`. If the Nix build can't locate OpenSSL, that CMake wiring is
  the place to adjust (e.g. `OPENSSL_ROOT_DIR`).
- **No zero-knowledge shuffle proof.** SRA gives card *secrecy* and prevents any
  single party from fixing the deal, but a malicious peer could still inject a
  bad shuffle. A production build would add a verifiable-shuffle proof; here the
  honest-but-curious model is assumed (peers follow the protocol; everyone *can*
  reconstruct the full 52-card deck once a hand ends to sanity-check it).
- **Simplified betting.** Single main pot, no side pots; a short stack goes all-in
  for its chips and stays eligible for the whole pot. Fixed blinds (SB 5 / BB 10),
  rotating button.
- **Chips are coordinator-synced at each hand start** to avoid drift if a peer
  missed messages. Join everyone before hand 1 for clean accounting.
- **Crypto cost.** Per hand each player does a few hundred 2048-bit modular
  exponentiations (shuffle + lock + reveals). One-off per hand; fine for a demo.

## Licence

MIT and Apache-2.0 — pick whichever works for you.
