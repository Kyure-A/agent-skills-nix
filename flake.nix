{
  description = "Declarative Agent Skills management with flake-pinned sources and Home Manager integration";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = inputs@{ nixpkgs, ... }:
    let
      inherit (nixpkgs) lib;
      forAllSystems = lib.genAttrs (import ./nix/systems.nix);
      baseLib = import ./lib { inherit lib inputs; };
      agentLib = baseLib // {
        defaultConfig = import ./nix/default-config.nix { agentLib = baseLib; };
      };
      defaultCatalog = agentLib.discoverCatalog agentLib.defaultConfig.sources;

      packages = forAllSystems (system:
        let
          bundle = import ./nix/bundle.nix {
            inherit agentLib;
            pkgs = nixpkgs.legacyPackages.${system};
          };
        in
        {
          agent-skills-bundle = bundle;
          default = bundle;
        });
    in
    {
      inherit packages;

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixpkgs-fmt);

      apps = forAllSystems (system: import ./nix/apps.nix {
        inherit agentLib;
        pkgs = nixpkgs.legacyPackages.${system};
        bundle = packages.${system}.agent-skills-bundle;
      });

      checks = forAllSystems (system: import ./test {
        inherit agentLib;
        pkgs = nixpkgs.legacyPackages.${system};
        bundle = packages.${system}.agent-skills-bundle;
      });

      homeManagerModules.default = import ./modules/home-manager/agent-skills.nix {
        inherit inputs lib;
      };

      lib.agent-skills = agentLib;
      catalog = agentLib.catalogJson defaultCatalog;
    };
}
