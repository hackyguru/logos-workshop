{
  description = "Logos Wallet UI — Bedrock + LEZ, QML frontend for the logos_wallet core";

  inputs = {
    logos-module-builder.url = "github:logos-co/logos-module-builder";
    # Sibling core; override at build time:
    #   nix build --override-input logos_wallet path:../logos-wallet-core '.#lgx-portable'
    logos_wallet.url = "path:../logos-wallet-core";
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
