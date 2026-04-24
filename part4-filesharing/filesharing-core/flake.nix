{
  description = "File sharing — upload, download, and remove files over logos-storage";

  inputs = {
    logos-module-builder.url = "github:logos-co/logos-module-builder";
    storage_module.url = "github:logos-co/logos-storage-module";
  };

  outputs = inputs@{ logos-module-builder, ... }:
    logos-module-builder.lib.mkLogosModule {
      src = ./.;
      configFile = ./metadata.json;
      flakeInputs = inputs;
    };
}
