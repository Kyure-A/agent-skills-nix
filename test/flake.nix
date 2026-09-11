{
  description = "Home Manager integration tests for agent-skills-nix";

  inputs = {
    agent-skills.url = "path:..";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "agent-skills/nixpkgs";
    };
  };

  outputs = { agent-skills, home-manager, ... }:
    let
      nixpkgs = agent-skills.inputs.nixpkgs;
      systems = builtins.attrNames agent-skills.checks;
    in
    {
      checks = nixpkgs.lib.genAttrs systems (system:
        let
          args = {
            pkgs = nixpkgs.legacyPackages.${system};
            hmLib = home-manager.lib;
            agentSkillsModule = agent-skills.homeManagerModules.default;
          };
        in
        {
          home-manager-warnings = import ./home-manager-warnings.nix args;
          home-manager-input-source = import ./home-manager-input-source.nix args;
        });
    };
}
