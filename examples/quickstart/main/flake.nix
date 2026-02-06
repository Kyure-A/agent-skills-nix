{
  description = "agent-skills-nix quickstart (main: tightly coupled)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    agent-skills.url = "github:Kyure-A/agent-skills-nix";
    anthropic-skills = {
      url = "github:anthropics/skills";
      flake = false;
    };
  };

  outputs = inputs@{ nixpkgs, home-manager, agent-skills, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in
    {
      homeConfigurations.example = home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        modules = [
          agent-skills.homeManagerModules.default
          ./home.nix
        ];
        extraSpecialArgs = { inherit inputs; };
      };
    };
}
