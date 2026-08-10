{
  description = "Skills-only Agent Plugin export example";

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

      sources.example = {
        path = ./skills;
        idPrefix = "example";
        filter.maxDepth = 1;
      };
      catalog = agentLib.discoverCatalog sources;
      selection = agentLib.selectSkills {
        inherit catalog sources;
        allowlist = [ "example/pdf" ];
      };

      pluginFor = system: agentLib.mkAgentPlugin {
        pkgs = nixpkgs.legacyPackages.${system};
        manifest = {
          name = "document-tools";
          version = "0.1.0";
          description = "Portable document workflows";
        };
        skills = {
          pdf = selection."example/pdf";
        };
      };
    in
    {
      packages = forAllSystems (system: {
        default = pluginFor system;
        agent-plugin = pluginFor system;
      });
    };
}
