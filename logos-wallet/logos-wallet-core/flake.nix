{
  description = "Logos Wallet core — unified Bedrock + LEZ wallet (manages the node binary, drives logos_execution_zone dynamically)";

  # No build dependency on the LEZ module: it is called dynamically at
  # runtime via getClient("logos_execution_zone")->invokeRemoteMethod(...),
  # not through generated LIDL bindings. Declaring it here would trigger
  # codegen against a name (lez_core) that differs from the runtime name.
  inputs = {
    logos-module-builder.url = "github:logos-co/logos-module-builder";
  };

  outputs = inputs@{ logos-module-builder, ... }:
    logos-module-builder.lib.mkLogosModule {
      src = ./.;
      configFile = ./metadata.json;
      flakeInputs = inputs;
    };
}
