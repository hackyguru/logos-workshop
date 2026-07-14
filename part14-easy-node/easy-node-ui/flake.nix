{
  description = "Easy Node UI — QML frontend for the easy_node core module";

  inputs = {
    logos-module-builder.url = "github:logos-co/logos-module-builder";
    # Sibling core; override at build time if needed:
    #   nix build --override-input easy_node path:../easy-node-core '.#lgx-portable'
    easy_node.url = "path:../easy-node-core";
    # Bundled with Basecamp at runtime; input exists only for dependency-name
    # resolution (loaded before easy_node so its registry is up first).
    logos_execution_zone.url = "github:logos-blockchain/logos-execution-zone-module";
  };

  outputs = inputs@{ logos-module-builder, ... }:
    logos-module-builder.lib.mkLogosQmlModule {
      src = ./.;
      configFile = ./metadata.json;
      flakeInputs = inputs;
    };
}
