{ blueprint
, inputs
, systems
,
}:

let
  agentLib = blueprint.lib.agent-skills;
  config = agentLib.defaultConfig;
  catalog = agentLib.discoverCatalog config.sources;
in
inputs.nixpkgs.lib.genAttrs systems (
  system:
  let
    pkgs = inputs.nixpkgs.legacyPackages.${system};
    bundle = blueprint.packages.${system}.agent-skills-bundle;
    listJson = pkgs.writeText "agent-skills-catalog.json" (
      builtins.toJSON (agentLib.catalogJson catalog)
    );

    installProgram = agentLib.mkSyncProgram {
      inherit pkgs bundle;
      targets = config.targets;
      system = pkgs.stdenv.hostPlatform.system;
      allowOverrides = true;
    };

    installLocalProgram = agentLib.mkLocalInstallProgram {
      inherit pkgs bundle;
      targets = agentLib.defaultLocalTargets;
    };

    sourceLockProgram = agentLib.mkSourceLockProgram { inherit pkgs; };

    listScript = pkgs.writeShellApplication {
      name = "skills-list";
      runtimeInputs = [
        pkgs.jq
        pkgs.coreutils
      ];
      text = ''
        cat ${listJson} | ${pkgs.jq}/bin/jq .
      '';
    };
  in
  {
    skills-install = {
      type = "app";
      program = "${installProgram}/bin/skills-install";
    };
    skills-install-local = {
      type = "app";
      program = "${installLocalProgram}/bin/skills-install-local";
    };
    skills-list = {
      type = "app";
      program = "${listScript}/bin/skills-list";
    };
    skills-sources-lock = {
      type = "app";
      program = "${sourceLockProgram}/bin/skills-sources-lock";
    };
  }
)
