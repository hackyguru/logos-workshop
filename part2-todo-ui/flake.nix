{
  description = "Todo UI — QML frontend for the todo core module";

  inputs = {
    logos-module-builder.url = "github:logos-co/logos-module-builder";
    # Placeholder — override with the sibling source at build time:
    #   nix build --override-input todo path:../part2-todo '.#lgx-portable'
    # Once you publish the core module, replace this URL with the github
    # repo + dir syntax, e.g.:
    #   todo.url = "github:<org>/<repo>?dir=part2-todo";
    todo.url = "github:logos-co/logos-module-builder";
  };

  outputs = inputs@{ logos-module-builder, ... }:
    logos-module-builder.lib.mkLogosQmlModule {
      src = ./.;
      configFile = ./metadata.json;
      flakeInputs = inputs;
    };
}
