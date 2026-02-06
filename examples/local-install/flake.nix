{
  inputs = {
    agent-skills.url = "github:Kyure-A/agent-skills-nix";
    anthropic-skills.url = "github:anthropics/skills";
    anthropic-skills.flake = false;
  };

  outputs = { self, nixpkgs, agent-skills, anthropic-skills, ... }:
    let
      system = "x86_64-linux"; # or your system
      pkgs = nixpkgs.legacyPackages.${system};
      agentLib = agent-skills.lib.agent-skills;

      sources = {
        anthropic = {
          path = anthropic-skills;
          subdir = "skills";
        };
      };

      catalog = agentLib.discoverCatalog sources;
      allowlist = agentLib.allowlistFor {
        inherit catalog sources;
        enable = [ "frontend-design" "skill-creator" ];
      };
      selection = agentLib.selectSkills {
        inherit catalog allowlist sources;
        skills = {};
      };
      bundle = agentLib.mkBundle { inherit pkgs selection; };
    in
    {
      apps.${system}.skills-install-local = {
        type = "app";
        program = "${agentLib.mkLocalInstallScript { inherit pkgs bundle; }}/bin/skills-install-local";
      };
    };
}
