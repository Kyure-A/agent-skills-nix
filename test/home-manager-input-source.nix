# Test Home Manager source resolution from flake inputs
{ pkgs, hmLib, agentSkillsModule }:

let
  fixtureInputs = {
    fixture = {
      outPath = ./fixtures/test-skill;
    };
  };

  mkConfig = extra: hmLib.homeManagerConfiguration {
    inherit pkgs;
    modules = [
      agentSkillsModule
      {
        home.username = "example";
        home.homeDirectory = "/home/example";
        home.stateVersion = "24.05";
        programs.agent-skills = {
          enable = true;
          sources.fixture = {
            input = "fixture";
            subdir = ".";
          };
          skills.enable = [ "fixture" ];
          targets.claude.enable = true;
        };
      }
      extra
    ];
    extraSpecialArgs = { inputs = fixtureInputs; };
  };

  config = mkConfig {
    programs.agent-skills = {
      sources.fixture.filter.maxDepth = 0;
    };
  };
  invalidConfig = extra: !(builtins.tryEval
    (builtins.attrNames (mkConfig extra).config.programs.agent-skills.catalog)).success;

  bundle = config.config.programs.agent-skills.bundlePath;
  activation = config.config.home.activation.agent-skills.data;
  catalog = config.config.programs.agent-skills.catalog;

  _assertBundle =
    if bundle != null then true
    else throw "agent-skills input-source test failed: bundlePath should not be null";

  _assertCatalog =
    if catalog ? fixture then true
    else throw "agent-skills input-source test failed: expected skill catalog entry from input source";

  _assertActivation =
    if pkgs.lib.hasInfix "/bin/skills-install" activation then true
    else throw "agent-skills input-source test failed: activation script did not invoke the sync program";
in
assert _assertBundle;
assert _assertCatalog;
assert _assertActivation;
assert invalidConfig { programs.agent-skills.sources.fixture.idPrefix = "invalid/"; };
pkgs.runCommand "agent-skills-home-manager-input-source-test" { } ''
  mkdir -p "$out"
  touch "$out/ok"
''
