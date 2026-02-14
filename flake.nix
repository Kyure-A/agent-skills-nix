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
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      forAllSystems = nixpkgs.lib.genAttrs systems;
      lib = import ./lib {
        lib = nixpkgs.lib;
        inherit inputs;
      };

      # Default global targets are defined in lib/default.nix; see README.md#default-target-paths.
      defaultTargets = lib.defaultTargets;

      # Default local targets are defined in lib/default.nix; see README.md#default-target-paths.
      defaultLocalTargets = lib.defaultLocalTargets;

      defaultConfig = {
        # Add sources and skills (enable/explicit) in your consumer flake; kept empty here to stay neutral.
        sources = {};
        skills = {
          enable = [];
          enableAll = false;
          explicit = {};
        };
        targets = defaultTargets;
        excludePatterns = lib.defaultExcludePatterns;
      };

      defaultCatalog = lib.discoverCatalog defaultConfig.sources;
      defaultAllowlist = lib.allowlistFor {
        catalog = defaultCatalog;
        sources = defaultConfig.sources;
        enableAll = defaultConfig.skills.enableAll;
        enable = defaultConfig.skills.enable;
      };
      defaultSelection = lib.selectSkills {
        catalog = defaultCatalog;
        allowlist = defaultAllowlist;
        skills = defaultConfig.skills.explicit;
        sources = defaultConfig.sources;
      };

      bundleFor = system:
        let pkgs = nixpkgs.legacyPackages.${system}; in
        lib.mkBundle { inherit pkgs; selection = defaultSelection; name = "agent-skills-bundle"; };
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
          listJson = pkgs.writeText "agent-skills-catalog.json" (builtins.toJSON (lib.catalogJson defaultCatalog));

          installScript = pkgs.writeShellApplication {
            name = "skills-install";
            runtimeInputs = [ pkgs.rsync pkgs.coreutils ];
            text = lib.mkSyncScript {
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

          installLocalScript = lib.mkLocalInstallScript {
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
          discover = import ./test/discover.nix {
            inherit pkgs;
            agentLib = lib;
          };
          transform-packages = import ./test/transform-packages.nix {
            inherit pkgs;
            agentLib = lib;
          };
          targets = import ./test/targets.nix {
            inherit pkgs;
            agentLib = lib;
          };
          home-manager-warnings = import ./test/home-manager-warnings.nix {
            inherit pkgs;
            hmLib = home-manager.lib;
            agentSkillsModule = import ./modules/home-manager/agent-skills.nix {
              inherit inputs;
              lib = nixpkgs.lib;
            };
          };
        });

      homeManagerModules.default =
        import ./modules/home-manager/agent-skills.nix {
          inherit inputs;
          lib = nixpkgs.lib;
        };

      lib.agent-skills = lib // { defaultConfig = defaultConfig; };
      catalog = lib.catalogJson defaultCatalog;
    };
}
