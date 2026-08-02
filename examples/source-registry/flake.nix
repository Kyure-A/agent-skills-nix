{
  description = "agent-skills source registry example";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    agent-skills.url = "github:Kyure-A/agent-skills-nix";
  };

  outputs = { nixpkgs, agent-skills, ... }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      agentLib = agent-skills.lib.agent-skills;

      sources = agentLib.sourcesFromLock {
        manifestsDir = ./registry/sources;
        lockFile = ./registry/sources.lock.json;
      };
      catalog = agentLib.discoverCatalog sources;
      selection = agentLib.selectSkills {
        inherit catalog sources;
        allowlist = [ "anthropic/pdf" ];
      };
      bundleFor = system: agentLib.mkBundle {
        pkgs = nixpkgs.legacyPackages.${system};
        inherit selection;
        name = "example-agent-skills-bundle";
      };
    in
    {
      packages = forAllSystems (system: {
        default = bundleFor system;
      });

      apps = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          sourceLockProgram = agentLib.mkSourceLockProgram { inherit pkgs; };
        in
        {
          skills-sources-lock = {
            type = "app";
            program = "${sourceLockProgram}/bin/skills-sources-lock";
          };
        });
    };
}
