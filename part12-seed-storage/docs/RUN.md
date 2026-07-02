# Part 12 — Run: Seed Storage

Run a Logos Storage node from the CLI, seed files, and fetch them from Basecamp.

---

## 1. Stage the storage module (one-time)

The standalone logoscore CLI needs the **dev variant** of `storage_module`
(a Basecamp copy won't load under it). `setup-modules.sh` builds and stages it:

```bash
cd part12-seed-storage/seeder
./setup-modules.sh
```

> The first build pulls the Nim/Codex toolchain and **can take tens of minutes**
> on a cold cache. It's cached afterwards. To skip the build, point it at a
> prebuilt package: `STORAGE_LGX=/path/to/storage.lgx ./setup-modules.sh`.

This produces `./modules/storage_module/` (git-ignored).

---

## 2. Serve (keep this running)

```bash
./seeder.sh serve
```

It starts the logoscore daemon, loads `storage_module`, runs `init @config.json`
+ `start`, and then stays up — **that's what keeps your files fetchable.** Expected:

```
[seeder] daemon is up
[seeder] loading storage_module...
[seeder] init (data-dir + network from config.json)...
[seeder] start (joining network, begin seeding)...
[seeder] seeding — storage node is up
[seeder] peer id: 16Uiu2HA...
[seeder] now seeding 0 file(s)
```

Leave this terminal open. `Ctrl+C` stops the node (and seeding).

> Runs fine alongside Basecamp: the seeder uses `data-dir ./storage-data` and
> `disc-port 8091`, distinct from Basecamp's storage. No need to close Basecamp.

---

## 3. Seed / list / delete (another terminal)

```bash
cd part12-seed-storage/seeder

./seeder.sh seed ~/Documents/report.pdf
#   [seeder] seeded report.pdf
#          CID: zDvZRwzm...              ← hand this CID to whoever should fetch it

./seeder.sh list
#   [seeder] seeding 1 file(s):
#     report.pdf   824133 bytes
#         CID: zDvZRwzm...

./seeder.sh rm zDvZRwzm...      # stop seeding that file
./seeder.sh info                # peer id / SPR / free space
```

---

## 4. Fetch from Basecamp

On a Basecamp that's on the same `logos.test` network (the default):

1. Open the **Filesharing** app (part4) — it drives `storage_module` from QML.
2. Make sure storage is **Started**.
3. Paste the **CID** from `./seeder.sh seed` into the download field, choose a
   save location, and **Download**.

Basecamp's storage node resolves the CID on the network, finds your seeder node,
and pulls the blocks from it. (If discovery is slow or the nodes are on different
networks, use `./seeder.sh info` to get this node's SPR and connect directly from
the consumer side.)

> The fetch side is just a storage consumer — any node with `storage_module` and
> the CID works. We reuse part4's Filesharing rather than ship a new UI.

---

## Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| `storage_module not staged` | Run `./setup-modules.sh` first. |
| `init returned 'false'` / won't start | Stale repo lock. Stop the daemon, delete `./storage-data`, try again. (Don't delete it while `serve` is running.) |
| `no storage daemon — run serve first` | `seed`/`list`/`rm` need `./seeder.sh serve` running in another terminal. |
| daemon won't come up; log shows capability_module crash | A stale daemon. `./seeder.sh stop`, then retry. (Unlike part11's early bug, Basecamp running is fine here.) |
| `logoscore binary not found` | Put `logoscore` on `PATH` or set `LOGOSCORE=/path/to/logoscore`. |
| Basecamp can't fetch the CID | (1) Both must be on the same `network`. (2) Give discovery a minute. (3) Keep `serve` running — the file is only served while your node is up. (4) Try connecting directly via the seeder's SPR (`./seeder.sh info`). |
| seeded a file but `seed` printed no CID | The upload is async; the CID shows up in `manifests` shortly. Run `./seeder.sh list`. |

## What was verified vs. needs a 2-node run

- **Verified locally**: the full CLI pipeline — `init`/`start`/`uploadUrl`/
  `manifests`/`remove` against the dev-variant storage_module — plus the
  seed→CID and list/delete flows of `seeder.sh`.
- **Needs a real consumer**: the cross-node fetch (Basecamp downloading a seeded
  CID over `logos.test`) — validated with a second node on the network.
