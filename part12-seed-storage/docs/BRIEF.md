# Part 12 — Brief: Seed Storage

## Goal

Use the **logoscore CLI** to run a Logos Storage node that **seeds (pins) files**:
the operator adds files and gets CIDs back, can list and delete them, and — while
the node runs — any peer on the same network (e.g. a Basecamp user) can fetch
those files by CID directly from this node.

This is the storage analogue of part11: a headless CLI peer that a Basecamp user
talks to over a Logos core module — `storage_module` here instead of
`delivery_module`.

## Architecture

```
        CLI seeder (this)                          Basecamp (fetcher)
 ┌────────────────────────┐                    ┌────────────────────────┐
 │ seeder.sh serve         │                    │ Filesharing app (QML)  │
 │   logoscore -D          │                    │   downloadToUrl(cid)   │
 │   load-module storage   │                    │        │               │
 │   call ... init/start   │                    │        ▼               │
 │ seeder.sh seed <file>   │                    │   storage_module       │
 │   call ... uploadUrl ───┼── chunk + CID      │   (Basecamp build)     │
 │ seeder.sh list          │   stored locally   └──────────┬─────────────┘
 │   call ... manifests    │                               │
 └───────────┬────────────┘                               │
             │  storage node serves blocks                 │
             ▼                                              ▼
   ╔══════════════════════════════════════════════════════════════════╗
   ║   logos.test storage network  —  CID → which node has the blocks  ║
   ╚══════════════════════════════════════════════════════════════════╝
```

## Storage API → feature mapping

`storage_module` wraps `libstorage` (Codex). The methods we use (all called via
`logoscore call storage_module <method> [args]`):

| Feature | storage_module call | Notes |
|---------|---------------------|-------|
| bring node up | `init @config.json` then `start` | `init` is a **synchronous** call that returns `true`; once per process. |
| **seed a file** | `uploadUrl <abs-path>` | Chunks the file, computes the CID, stores blocks. Returns a sessionId; the CID lands via a `storageUploadDone` event. |
| **get the CID** | `manifests` | Returns `[{cid, filename, datasetSize, blockSize, treeCid, mimetype}]`. We read the new file's CID from here (diff before/after, or match by filename). |
| **list seeded** | `manifests` | Same call — the full list with CIDs + sizes. |
| **delete** | `remove <cid>` | Drops the blocks from the local repo. |
| node identity | `peerId`, `spr`, `space` | Share `spr`/`peerId` so peers can reach this node. |
| (fetch side) | `downloadToUrl <cid> <url>`, `exists <cid>` | Used by the *consumer* (Basecamp Filesharing), not the seeder. |

**Why read the CID from `manifests` instead of the upload result?** `uploadUrl`'s
CID is delivered asynchronously via the `storageUploadDone` event, and the
logoscore CLI's event stream (`watch`) doesn't forward module events in the
current build (discovered in part11). `manifests` returns the CID as a normal
value, so the seeder polls it after an upload — no events needed.

## Message/­config details

`seeder/config.json` (passed to `init` via the CLI's `@file` syntax):

```json
{
  "log-level": "INFO",
  "data-dir": "./storage-data",
  "storage-quota": 21474836480,
  "listen-port": 0,
  "disc-port": 8091,
  "nat": "any",
  "network": "logos.test"
}
```

- `network: logos.test` — joins the same default network Basecamp's storage uses,
  so a Basecamp user can discover and fetch our CIDs. (Override with
  `bootstrap-node` for a private network.)
- `data-dir: ./storage-data` — the node's local repo (seeded blocks live here).
  **Distinct from Basecamp's** `~/Library/Application Support/Storage` so the two
  nodes can run on one machine without a LevelDB lock clash.
- `disc-port: 8091` — Basecamp's storage uses the default `8090`; the seeder uses
  `8091` to avoid a same-machine UDP clash. `listen-port: 0` = random TCP, no clash.

## Key constraints (shared with part11)

- **Dev variant required.** The standalone logoscore CLI loads modules via a *dev*
  `logos_host` and looks up `manifest.main["darwin-arm64-dev"]`. A storage_module
  copied from Basecamp is the portable `darwin-arm64` variant and won't come up
  under the CLI. `setup-modules.sh` builds the `.#lgx` (dev) package.
- **Two cores coexist** on one machine (Qt sockets are instance-scoped), so the
  seeder daemon and Basecamp run together — just give the storage nodes different
  `data-dir` + `disc-port` (done in config.json).
- **Availability is liveness-bound.** Seeded content is served by *this* node.
  Stop `serve` and the content is gone unless another peer also holds it. That's
  inherent to seeding/pinning, not a limitation of the tool.

## Files of interest

- `seeder/seeder.sh` — the serve/seed/list/rm/info pipeline over the CLI.
- `seeder/setup-modules.sh` — builds + stages the dev-variant storage_module.
- `seeder/config.json` — the storage-node config.
