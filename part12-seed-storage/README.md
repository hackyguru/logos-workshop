# Part 12 — Seed Storage

A **headless file seeder** built on the
[`logos-logoscore-cli`](https://github.com/logos-co/logos-logoscore-cli) and the
[`logos-storage-module`](https://github.com/logos-co/logos-storage-module). You
run a storage node from the command line, **seed (pin) files** into Logos Storage,
and get back a **CID** for each. While the node runs, anyone on the same network
— including a Basecamp user — can **fetch those files by CID from your peer**.

> The idea in one line: **your laptop becomes a content-addressed seedbox.** The
> CLI hosts a Logos Storage node; you add files and hand out CIDs; the network
> resolves each CID back to your running node.

```
   you (CLI seeder)                         someone on Basecamp
   ───────────────                          ───────────────────
   ./seeder.sh seed report.pdf
        │  uploadUrl → CID  zDv…abc
        ▼
   ┌─────────────────────┐   logos.test network    ┌──────────────────────┐
   │  storage node (CLI)  │◀───  fetch zDv…abc  ────│ storage_module        │
   │  serves blocks while │────▶  blocks       ────▶│ (Filesharing app)     │
   │  ./seeder.sh serve   │                         └──────────────────────┘
   └─────────────────────┘
```

## What you can do

| Command | What it does |
|---------|--------------|
| `./seeder.sh serve`      | Bring the storage node up and **keep it seeding** (leave it running). |
| `./seeder.sh seed <file>`| Seed a file → prints its **CID**. |
| `./seeder.sh list`       | List every seeded file with its **CID** and size. |
| `./seeder.sh rm <cid>`   | Stop seeding / delete a file by CID. |
| `./seeder.sh info`       | This node's peer id / SPR / free space. |
| `./seeder.sh stop`       | Stop the daemon. |

Files are available **only while `serve` is running** — that's the whole point of
seeding: your node is the one serving the blocks.

## How it works

- It drives `storage_module` through the logoscore CLI's own commands
  (`load-module` / `call storage_module init|start|uploadUrl|manifests|remove`) —
  exactly the workflow the storage-module repo documents in
  `docs/logoscore-overview/`. No custom module, no GUI.
- **Seeding** = `uploadUrl(<file>)`: the node chunks the file, computes its CID,
  and stores the blocks in its local repo. The CID is read back from
  `manifests()` (which lists every stored file with `{cid, filename, size}`).
- **Availability** = the node joins the `logos.test` network (`network` in
  [seeder/config.json](seeder/config.json)); peers discover which node holds a CID
  and fetch the blocks directly. Stop the node and the content is gone (unless
  another peer also has it).
- **Deletion** = `remove(<cid>)` drops the blocks from the local repo.

See **[docs/BRIEF.md](docs/BRIEF.md)** for the design + storage API mapping and
**[docs/RUN.md](docs/RUN.md)** to build, run, and fetch from Basecamp.

## Layout

```
part12-seed-storage/
├── seeder/                # the CLI seeding tool
│   ├── config.json        # storage-node config (data-dir, ports, network)
│   ├── setup-modules.sh   # build/stage the dev-variant storage_module into ./modules
│   ├── seeder.sh          # serve / seed / list / rm / info / stop
│   └── modules/           # created by setup-modules.sh (git-ignored)
└── docs/                  # BRIEF.md (design)  ·  RUN.md (build + run + fetch)
```

## Quick start

```bash
cd seeder
./setup-modules.sh           # one-time: nix-builds the dev-variant storage_module
./seeder.sh serve            # terminal 1 — keep it running

# terminal 2:
./seeder.sh seed ~/report.pdf   # → CID zDv…
./seeder.sh list
```

Then on Basecamp (same `logos.test` network): open **Filesharing**, paste the CID,
download — it fetches from your seeder node. See [docs/RUN.md](docs/RUN.md).

## Relationship to part11

Same shape as [part11-core-ping-pong](../part11-core-ping-pong): a headless
logoscore-CLI peer talking to Basecamp over a Logos core module. Part 11 used
`delivery_module` (messaging); part 12 uses `storage_module` (content-addressed
files). Both need the module's **dev (`.#lgx`) variant** to load under the
standalone CLI runtime.
