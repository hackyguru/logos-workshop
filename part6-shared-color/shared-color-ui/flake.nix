{
  description = "Shared color UI — QML frontend for the shared_color core module";

  inputs = {
    logos-module-builder.url = "github:logos-co/logos-module-builder";
    # Placeholder — override with the sibling source at build time:
    #   nix build --override-input shared_color path:../shared-color-core '.#lgx-portable'
    shared_color.url = "github:logos-co/logos-module-builder";
  };

  outputs = inputs@{ logos-module-builder, ... }:
    logos-module-builder.lib.mkLogosQmlModule {
      src = ./.;
      configFile = ./metadata.json;
      flakeInputs = inputs;
    };
}
