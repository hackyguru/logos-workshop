{
  description = "Lotion UI — a local-first, Notion-style writing workspace. Talks to storage_module directly (via the QML/JS bridge) for publish/read; uses lotion-core for the local workspace and crypto.";

  inputs = {
    logos-module-builder.url = "github:logos-co/logos-module-builder";
    # storage_module is declared so logos-module-builder can resolve the
    # dependency listed in metadata.json. At runtime, the QML calls
    # logos.callModule("storage_module", ...) directly via the JS bridge —
    # the same pattern as part 4's filesharing-ui.
    storage_module.url = "github:logos-co/logos-storage-module";
    # Override with the sibling source at build time:
    #   nix build --override-input lotion path:../lotion-core '.#lgx-portable'
    lotion.url = "github:logos-co/logos-module-builder";
  };

  outputs = inputs@{ logos-module-builder, ... }:
    logos-module-builder.lib.mkLogosQmlModule {
      src = ./.;
      configFile = ./metadata.json;
      flakeInputs = inputs;
    };
}
