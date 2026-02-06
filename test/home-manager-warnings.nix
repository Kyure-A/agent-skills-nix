# Test Home Manager warnings for opt-in target behaviour
{ pkgs, hmLib, agentSkillsModule }:

let
  warningPrefix = "agent-skills: programs.agent-skills.enable is true, but no install targets are enabled.";

  mkConfig = extraModule:
    hmLib.homeManagerConfiguration {
      inherit pkgs;
      modules = [
        agentSkillsModule
        {
          home.username = "example";
          home.homeDirectory = "/home/example";
          home.stateVersion = "24.05";
          programs.agent-skills = {
            enable = true;
            sources = {};
            skills = {
              enable = [];
              enableAll = false;
              explicit = {};
            };
          };
        }
        extraModule
      ];
    };

  noTargetsWarnings = (mkConfig {}).config.warnings;
  claudeEnabledWarnings = (mkConfig {
    programs.agent-skills.targets.claude.enable = true;
  }).config.warnings;

  hasOptInWarning = warnings:
    pkgs.lib.any (msg: pkgs.lib.hasPrefix warningPrefix msg) warnings;

  _assertNoTargets =
    if hasOptInWarning noTargetsWarnings then true
    else throw "agent-skills warning test failed: expected warning when no install targets are enabled";

  _assertWithTarget =
    if hasOptInWarning claudeEnabledWarnings then
      throw "agent-skills warning test failed: warning should not be shown when an install target is enabled"
    else true;
in
assert _assertNoTargets;
assert _assertWithTarget;
pkgs.runCommand "agent-skills-home-manager-warnings-test" {} ''
  mkdir -p "$out"
  touch "$out/ok"
''
