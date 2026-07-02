{
  description = "inference_ui — prompt/response UI for the inference module (QML-only)";

  inputs = {
    logos-module-builder.url = "github:logos-co/logos-module-builder";
    # inference is auto-resolved from metadata.json `dependencies`; attr name must match.
    # Defaults to the sibling source; override at build time if needed:
    #   nix build --override-input inference path:../inference-core '.#lgx-portable'
    inference.url = "path:../inference-core";
  };

  outputs = inputs@{ logos-module-builder, ... }:
    logos-module-builder.lib.mkLogosQmlModule {
      src = ./.;
      configFile = ./metadata.json;
      flakeInputs = inputs;
    };
}
