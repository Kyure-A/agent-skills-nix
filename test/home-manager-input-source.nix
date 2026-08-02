# Test Home Manager source resolution from flake inputs
{ pkgs, hmLib, agentSkillsModule }:

let
  fixtureInputs = {
    fixture = {
      outPath = ./fixtures/test-skill;
    };
  };

  config = hmLib.homeManagerConfiguration {
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
    ];
    extraSpecialArgs = { inputs = fixtureInputs; };
  };

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
    if pkgs.lib.hasInfix "bundle=/nix/store/" activation then true
    else throw "agent-skills input-source test failed: activation script did not capture the bundle path";
in
assert _assertBundle;
assert _assertCatalog;
assert _assertActivation;
pkgs.runCommand "agent-skills-home-manager-input-source-test" {} ''
  mkdir -p "$out"
  touch "$out/ok"
''
