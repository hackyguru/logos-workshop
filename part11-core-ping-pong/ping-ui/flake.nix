{
  description = "ping_ui — fire-a-ping / watch-the-pong UI for the ping module (QML-only)";

  inputs = {
    logos-module-builder.url = "github:logos-co/logos-module-builder";
    # ping is auto-resolved from metadata.json `dependencies`; attr name must match.
    # Defaults to the sibling source; override at build time if needed:
    #   nix build --override-input ping path:../ping-core '.#lgx-portable'
    ping.url = "path:../ping-core";
  };

  outputs = inputs@{ logos-module-builder, ... }:
    logos-module-builder.lib.mkLogosQmlModule {
      src = ./.;
      configFile = ./metadata.json;
      flakeInputs = inputs;
    };
}
