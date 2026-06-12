{
  description = "Lotion core — local-first SQLite workspace + AES-256-GCM envelope crypto for the Lotion UI";

  # No storage_module dependency: every C++→storage_module call hangs on
  # macOS (logos_host dispatches plugin methods on a worker thread with no
  # visible QCoreApplication, so the storage_module's internal
  # QEventLoop::waitForSignal never pumps). The Lotion UI talks to
  # storage_module directly via the QML/JS bridge instead.
  inputs = {
    logos-module-builder.url = "github:logos-co/logos-module-builder";
  };

  outputs = inputs@{ logos-module-builder, ... }:
    logos-module-builder.lib.mkLogosModule {
      src = ./.;
      configFile = ./metadata.json;
      flakeInputs = inputs;
    };
}
