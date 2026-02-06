{
  description = "Declarative Agent Skills management with flake-pinned sources and Home Manager integration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs@{ self, nixpkgs, home-manager, ... }:
    let
      lib = nixpkgs.lib;

      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      forAllSystems = lib.genAttrs systems;
      agentLib = import ./lib/agent-skills.nix { inherit lib inputs; };

      # Default global targets are defined in lib/agent-skills.nix; see README.md#default-target-paths.
      defaultTargets = agentLib.defaultTargets;

      # Default local targets are defined in lib/agent-skills.nix; see README.md#default-target-paths.
      defaultLocalTargets = agentLib.defaultLocalTargets;

      defaultConfig = {
        # Add sources and skills (enable/explicit) in your consumer flake; kept empty here to stay neutral.
        sources = {};
        skills = {
          enable = [];
          enableAll = false;
          explicit = {};
        };
        targets = defaultTargets;
        excludePatterns = agentLib.defaultExcludePatterns;
      };

      defaultCatalog = agentLib.discoverCatalog defaultConfig.sources;
      defaultAllowlist = agentLib.allowlistFor {
        catalog = defaultCatalog;
        sources = defaultConfig.sources;
        enableAll = defaultConfig.skills.enableAll;
        enable = defaultConfig.skills.enable;
      };
      defaultSelection = agentLib.selectSkills {
        catalog = defaultCatalog;
        allowlist = defaultAllowlist;
        skills = defaultConfig.skills.explicit;
        sources = defaultConfig.sources;
      };

      bundleFor = system:
        let pkgs = nixpkgs.legacyPackages.${system}; in
        agentLib.mkBundle { inherit pkgs; selection = defaultSelection; name = "agent-skills-bundle"; };
    in
    {
      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixpkgs-fmt);

      packages = forAllSystems (system: let
        bundle = bundleFor system;
      in {
        agent-skills-bundle = bundle;
        default = bundle;
      });

      apps = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          bundle = bundleFor system;
          listJson = pkgs.writeText "agent-skills-catalog.json" (builtins.toJSON (agentLib.catalogJson defaultCatalog));

          installScript = pkgs.writeShellApplication {
            name = "skills-install";
            runtimeInputs = [ pkgs.rsync pkgs.coreutils ];
            text = agentLib.mkSyncScript {
              inherit pkgs bundle;
              targets = defaultTargets;
              system = pkgs.system;
              allowOverrides = true;
            };
          };

          listScript = pkgs.writeShellApplication {
            name = "skills-list";
            runtimeInputs = [ pkgs.jq pkgs.coreutils ];
            text = ''
              cat ${listJson} | ${pkgs.jq}/bin/jq .
            '';
          };

          installLocalScript = agentLib.mkLocalInstallScript {
            inherit pkgs bundle;
            targets = defaultLocalTargets;
          };
        in {
          skills-install = {
            type = "app";
            program = "${installScript}/bin/skills-install";
          };
          skills-install-local = {
            type = "app";
            program = "${installLocalScript}/bin/skills-install-local";
          };
          skills-list = {
            type = "app";
            program = "${listScript}/bin/skills-list";
          };
        });

      checks = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          bundle = bundleFor system;
        in {
          skills = pkgs.runCommand "agent-skills-checks" {} ''
            test -d ${bundle}
            mkdir -p "$out"
            touch "$out/ok"
          '';
          transform-packages = import ./test/transform-packages.nix {
            inherit pkgs agentLib;
          };
          targets = import ./test/targets.nix {
            inherit pkgs agentLib;
          };
        });

      homeManagerModules.default =
        import ./modules/home-manager/agent-skills.nix { inherit inputs lib; };

      lib.agent-skills = agentLib // { defaultConfig = defaultConfig; };
      catalog = agentLib.catalogJson defaultCatalog;
    };
}
