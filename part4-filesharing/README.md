# Part 4 — File sharing (work in progress)

> 🚧 **Status: not yet in a working state.** The code here is structurally complete and follows the right integration patterns for `storage_module`, but end-to-end upload/download doesn't currently work in this Basecamp build. Ship-worthy fix is pending upstream.

## What's here

- **`filesharing-core/`** — C++ plugin that wraps `storage_module`'s typed `StorageModule` client, exposes `startStorage`/`uploadFile`/`downloadFile`/`removeFile`/`listFiles` as `Q_INVOKABLE` methods, and subscribes to `storageStart` / `storageUploadDone` / `storageDownloadDone` events.
- **`filesharing-ui/`** — QML sidebar tab with a start button, paste-a-path / drag-a-file upload area, download form, and a "My files" list.

The code is intentionally readable as a reference implementation — comments at the top of [`filesharing_plugin.cpp`](filesharing-core/src/filesharing_plugin.cpp) walk through the integration rules (vendor/typed-wrapper vs raw IPC, `QTimer::singleShot(0, ...)` main-thread dispatch, yolo-pattern ready flip, re-entrancy guards on polls). The [`flake.nix`](filesharing-core/flake.nix) comment block documents what's actually blocking the code from working today.

## Building

Same pattern as the other parts (see the top-level [README](../README.md#build--install)):

```bash
cd filesharing-core
nix build '.#lgx-portable' --out-link result-portable

cd ../filesharing-ui
nix build --override-input filesharing path:../filesharing-core '.#lgx-portable' --out-link result-portable
```

`storage_module` is NOT pre-installed on Basecamp — install it separately:

```bash
nix build github:logos-co/logos-storage-module --out-link /tmp/storage
cp /tmp/storage/lib/* "$HOME/Library/Application Support/Logos/LogosBasecamp/modules/"
# Linux: "$HOME/.local/share/Logos/LogosBasecamp/modules/"
```

Then import both filesharing `.lgx` files via Basecamp's **Modules → Install LGX Package**.
