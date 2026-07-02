{
  description = "inference — send prompts into a logos-delivery content topic and receive model responses from a remote provider (core module)";

  inputs = {
    logos-module-builder.url = "github:logos-co/logos-module-builder";
    # Pin nixpkgs/bundler to the builder's so delivery_module's RLN/zerokit (Rust)
    # toolchain resolves from the shared binary cache instead of building from source.
    nixpkgs.follows = "logos-module-builder/nixpkgs";
    nix-bundle-lgx.follows = "logos-module-builder/nix-bundle-lgx";
    # delivery_module is auto-resolved from metadata.json `dependencies`; attr name must match.
    # Pinned to v0.1.1 (proven in part6-shared-color / part8-videocall / part11-core-ping-pong).
    delivery_module.url = "github:logos-co/logos-delivery-module/v0.1.1";
    delivery_module.inputs.logos-module-builder.follows = "logos-module-builder";
  };

  outputs = inputs@{ logos-module-builder, ... }:
    logos-module-builder.lib.mkLogosModule {
      src = ./.;
      configFile = ./metadata.json;
      flakeInputs = inputs;
    };
}
