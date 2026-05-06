{
  description = "File sharing UI — QML-only plugin that talks to storage_module directly via the Logos JS bridge";

  # No sibling C++ core to depend on. We declare storage_module as a flake
  # input only so logos-module-builder can resolve the dependency name listed
  # in metadata.json.dependencies — at runtime, storage_module is loaded by
  # Basecamp from the user's modules dir, not bundled with this .lgx.
  inputs = {
    logos-module-builder.url = "github:logos-co/logos-module-builder";
    storage_module.url       = "github:logos-co/logos-storage-module";
  };

  outputs = inputs@{ logos-module-builder, ... }:
    logos-module-builder.lib.mkLogosQmlModule {
      src = ./.;
      configFile = ./metadata.json;
      flakeInputs = inputs;
    };
}
