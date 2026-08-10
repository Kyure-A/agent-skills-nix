{ blueprint, inputs }:

let
  inherit (inputs.nixpkgs) lib;
  systems = import ./systems.nix;
  checkNames = [
    "agent-plugin"
    "compatibility"
    "discover"
    "home-manager-input-source"
    "home-manager-warnings"
    "local-install-script"
    "skills"
    "source-lock-shellcheck"
    "source-registry"
    "source-registry-npins-local"
    "sync-shellcheck"
    "targets"
    "transform-packages"
  ];
  packageNames = [
    "agent-skills-bundle"
    "default"
  ];

  agentLib = blueprint.lib.agent-skills;
  defaultCatalog = agentLib.discoverCatalog agentLib.defaultConfig.sources;
in
{
  formatter = lib.genAttrs systems (
    system: inputs.nixpkgs.legacyPackages.${system}.nixpkgs-fmt
  );

  packages = lib.genAttrs systems (
    system: lib.getAttrs packageNames blueprint.packages.${system}
  );

  apps = import ./apps.nix { inherit blueprint inputs systems; };

  checks = lib.genAttrs systems (
    system: lib.getAttrs checkNames blueprint.checks.${system}
  );

  homeManagerModules.default = import ./home-manager-module.nix { inherit inputs; };

  inherit (blueprint) lib;
  catalog = agentLib.catalogJson defaultCatalog;
}
