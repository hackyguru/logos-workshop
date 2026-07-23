{
  description = "Logos Wallet UI — Bedrock + LEZ, QML frontend for the logos_wallet core";

  inputs = {
    logos-module-builder.url = "github:logos-co/logos-module-builder";
    # Core module. Pinned to GitHub so this flake builds standalone (the
    # module-catalog release mirror at hackyguru/logos-wallet-ui needs no
    # sibling checkout). For local dev against the sibling dir:
    #   nix build --override-input logos_wallet path:../logos-wallet-core '.#lgx-portable'
    logos_wallet.url = "github:hackyguru/logos-wallet-core";
    # Bundled with Basecamp; declared as a DIRECT dep so the host spawns it
    # (dependencies are not resolved transitively). Listed first so its
    # registry is up before logos_wallet queries it.
    logos_execution_zone.url = "github:logos-blockchain/logos-execution-zone-module";
  };

  outputs = inputs@{ logos-module-builder, ... }:
    logos-module-builder.lib.mkLogosQmlModule {
      src = ./.;
      configFile = ./metadata.json;
      flakeInputs = inputs;
    };
}
