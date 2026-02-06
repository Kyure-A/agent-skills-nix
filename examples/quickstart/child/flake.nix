{
  description = "agent-skills-nix quickstart (child: separated skills catalog)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    skills-catalog.url = "path:./skills";
  };

  outputs = inputs@{ nixpkgs, home-manager, skills-catalog, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in
    {
      homeConfigurations.example = home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        modules = [
          skills-catalog.homeManagerModules.default
          ./home.nix
        ];
        extraSpecialArgs = { inherit inputs; };
      };
    };
}
