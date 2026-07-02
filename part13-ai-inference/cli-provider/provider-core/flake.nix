{
  description = "inference_provider — headless AI inference provider for the logoscore CLI (runs ollama on prompts received over logos-delivery)";

  inputs = {
    logos-module-builder.url = "github:logos-co/logos-module-builder";
    nixpkgs.follows = "logos-module-builder/nixpkgs";
    nix-bundle-lgx.follows = "logos-module-builder/nix-bundle-lgx";
    # delivery_module is auto-resolved from metadata.json `dependencies`; attr name must match.
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
