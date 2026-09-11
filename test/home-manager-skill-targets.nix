# Home Manager routes each layout through the same per-target selection.
{ pkgs, hmLib, agentSkillsModule }:

let
  inherit (pkgs) lib;
  skill = extra: { from = "fixture"; path = "."; } // extra;
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
            sources.fixture.path = ./fixtures/test-skill;
          };
        }
        extraModule
      ];
    };
  evaluated = mkConfig {
    programs.agent-skills = {
      skills.explicit = {
        shared = skill { };
        nullable = skill { agents = null; };
        claude-only = skill { agents = [ "claude" ]; };
        codex-only = skill { agents = [ "codex" ]; };
        custom-only = skill { agents = [ "custom" ]; };
        inactive-only = skill { agents = [ "inactive" ]; };
        elsewhere-only = skill { agents = [ "elsewhere" ]; };
        hidden = skill { agents = [ ]; };
        disabled = skill { enable = false; agents = [ "unknown-disabled-skill" ]; };
      };
      targets = {
        claude = { enable = true; dest = ".claude/skills"; structure = "link"; };
        codex = { enable = true; dest = "$HOME/.codex/skills"; structure = "copy-tree"; };
        custom = { enable = true; dest = "$HOME/.custom/skills"; structure = "symlink-tree"; };
        inactive = { enable = false; dest = "$HOME/.inactive/skills"; };
        elsewhere = { enable = true; dest = "$HOME/.elsewhere/skills"; systems = [ "another-system" ]; };
      };
    };
  };
  config = evaluated.config;
  cfg = config.programs.agent-skills;
  paths = cfg.targetBundlePaths;
  linkedSource = config.home.file.".claude/skills".source;
  activation = config.home.activation.agent-skills.data;
  noTargets = (mkConfig {
    programs.agent-skills.skills.explicit.shared = skill { };
  }).config.programs.agent-skills;
  invalidConfig = (mkConfig {
    programs.agent-skills = {
      skills.explicit.invalid = skill { agents = "claude"; };
      targets.claude.enable = true;
    };
  }).config.programs.agent-skills.skills.explicit.invalid.agents;
  unknownTargetSource = (mkConfig {
    programs.agent-skills = {
      skills.explicit.invalid = skill { agents = [ "cluade" ]; };
      targets.claude = { enable = true; dest = ".claude/skills"; structure = "link"; };
    };
  }).config.home.file.".claude/skills".source;
  evaluationSucceeds = value: (builtins.tryEval (builtins.deepSeq value true)).success;
  expect = condition: message:
    if condition then true else throw "agent-skills Home Manager skill-targets test: ${message}";
  expectedFor = {
    claude = [ "claude-only" "nullable" "shared" ];
    codex = [ "codex-only" "nullable" "shared" ];
    custom = [ "custom-only" "nullable" "shared" ];
  };
  allNames = [ "claude-only" "codex-only" "custom-only" "elsewhere-only" "hidden" "inactive-only" "nullable" "shared" ];
  assertContents = path: expected:
    lib.concatMapStringsSep "\n"
      (id:
        if builtins.elem id expected then ''
          test -f "${path}/${id}/SKILL.md" || fail "missing ${id} in ${path}"
        '' else ''
          test ! -e "${path}/${id}" || fail "unexpected ${id} in ${path}"
        ''
      )
      (allNames ++ [ "disabled" ]);
in
assert expect (builtins.attrNames paths == [ "claude" "codex" "custom" ]) "targetBundlePaths must contain only enabled targets for this system";
assert expect (toString linkedSource == toString paths.claude) "link layout must use the target bundle";
assert expect (cfg.skills.explicit.shared.agents == null) "agents must default to null";
assert expect (noTargets.targetBundlePaths == { }) "disabled targets must not create output paths";
assert expect (!evaluationSucceeds invalidConfig) "the module must reject a non-list agents value";
assert expect (!evaluationSucceeds (toString unknownTargetSource)) "link-only configurations must reject unknown target names";
assert expect (lib.hasInfix "/bin/skills-install" activation) "mixed layouts must retain sync activation";
pkgs.runCommand "agent-skills-home-manager-skill-targets-test" { } ''
  set -euo pipefail
  fail() { echo "ERROR: $*" >&2; exit 1; }

  ${assertContents cfg.bundlePath allNames}
  ${lib.concatMapStringsSep "\n" (name: assertContents paths.${name} expectedFor.${name}) (builtins.attrNames expectedFor)}
  ${assertContents linkedSource expectedFor.claude}

  # Exercise the module-generated activation for both synchronization layouts.
  export HOME="$PWD/home"
  mkdir -p "$HOME"
  ${activation}
  ${assertContents "$HOME/.codex/skills" expectedFor.codex}
  ${assertContents "$HOME/.custom/skills" expectedFor.custom}
  test ! -L "$HOME/.codex/skills/codex-only"
  test -L "$HOME/.custom/skills/custom-only"
  test ! -e "$HOME/.inactive/skills"
  test ! -e "$HOME/.elsewhere/skills"

  mkdir -p "$out"
  touch "$out/ok"
''
