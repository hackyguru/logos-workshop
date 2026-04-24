{
  description = "On-chain counter core — Basecamp plugin that reads/increments a SPEL counter program via the `spel` + `wallet` CLIs";

  # No blockchain module is declared as a Basecamp dependency — this plugin
  # doesn't talk to a sibling logos_host module. It shells out to the `spel`
  # + `wallet` binaries on the host, which the user installs separately (see
  # the Part 5 README). The chain itself lives in a separate process (local
  # docker-compose or a hosted sequencer), not inside Basecamp.
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
