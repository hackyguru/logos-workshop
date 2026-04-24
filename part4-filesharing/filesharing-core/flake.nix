{
  description = "File sharing — upload, download, and remove files over logos-storage";

  # logos-module-builder auto-generates the typed `StorageModule` client
  # wrapper (into logos_sdk.{h,cpp}) from metadata.json's dependencies. That
  # requires storage_module's flake available at build time so its interface
  # headers can be introspected — so we list it here, and include
  # `logos_sdk.h` from filesharing_plugin.h at compile time to use the
  # wrapper. The storage_module `.lgx` binary itself is installed into
  # Basecamp separately (see Part 4 README) — we only need it for the
  # client-side wrapper generation here.
  #
  # KNOWN ISSUE (macOS, 2026-04-24)
  # -------------------------------
  # Part 4 cannot complete an end-to-end upload/download on macOS Basecamp
  # due to upstream bugs in the storage_module ↔ logos_host boundary:
  #
  #   1. storage_module.init() uses QEventLoop::waitForSignal with a 1 s
  #      timeout. On macOS, logos_host dispatches plugin methods on a worker
  #      thread that has no QCoreApplication visible, so the event loop
  #      can't pump. waitForSignal always times out and init() returns
  #      false. Worse, libstorage's discovery thread then enters an
  #      infinite retry loop at 100% CPU, rendering the node unresponsive
  #      to any further IPC.
  #
  #   2. Qt Remote Objects serialisation of `LogosResult` across processes
  #      arrives as an empty `QVariant()` — methods that return LogosResult
  #      (uploadUrl, downloadToUrl, manifests, etc.) report success=false,
  #      error="" to callers on every call, even when the server-side
  #      succeeded. Workaround pattern (per vpavlin/logos-yolo's
  #      docs/inter-module-comm.md) is to wrap these in `std::string`
  #      JSON returns, but that requires modifying storage_module itself.
  #
  #   3. `storage_module.on("storageUploadDone", ...)` callbacks don't
  #      reliably fire cross-process on macOS, so we can't fall back to
  #      event-driven completion detection.
  #
  # All three are upstream bugs (logos-basecamp / logos-storage-module),
  # not workshop code. On Linux Basecamp builds, the same code is reported
  # to work end-to-end (see xAlisher/stash-basecamp and
  # vpavlin/logos-yolo — both were tested on Linux).
  #
  # Integration tests on this Mac: `nix run github:logos-co/logos-storage-module#unit-tests`
  # pass in ~1 s because they run with a proper QCoreApplication. So
  # libstorage itself is fine — it's the logos_host boundary on macOS
  # that breaks.
  inputs = {
    logos-module-builder.url = "github:logos-co/logos-module-builder";
    storage_module.url = "github:logos-co/logos-storage-module";
  };

  outputs = inputs@{ logos-module-builder, ... }:
    logos-module-builder.lib.mkLogosModule {
      src = ./.;
      configFile = ./metadata.json;
      flakeInputs = inputs;
    };
}

