{ pkgs, hmLib, agentSkillsModule }:

let
  inherit (pkgs) lib;
  mkConfig = extraModule:
    (hmLib.homeManagerConfiguration {
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
            skills.enable = [ "fixture" ];
          };
        }
        extraModule
      ];
    }).config;
  withAgents = extra: mkConfig {
    imports = [ extra ];
    programs.agent-skills.sources.agents = { path = ./fixtures/subagents; subagentsSubdir = "."; };
  };
  activationOf = config: config.home.activation.agent-skills.data;
  fileNames = config: builtins.attrNames config.home.file;

  unchangedFor = structure:
    let
      targets.claude = { enable = true; inherit structure; };
      before = mkConfig { programs.agent-skills.targets = targets; };
      after = withAgents { programs.agent-skills.targets = targets; };
    in
    after.programs.agent-skills.subagentsBundlePath == null
    && fileNames after == fileNames before
    && (structure == "link" || activationOf after == activationOf before);

  selected = withAgents {
    programs.agent-skills = {
      subagents.enable = [ "alpha" ];
      targets = {
        claude.enable = true;
        cursor.enable = true;
        codex.enable = true;
      };
    };
  };
  withoutClaudeAgents = withAgents {
    programs.agent-skills = {
      subagents.enableAll = [ "agents" ];
      targets.claude = { enable = true; subagentsDest = null; };
    };
  };
  linked = withAgents {
    programs.agent-skills = {
      subagents.enable = [ "alpha" ];
      targets.claude = { enable = true; structure = "link"; };
    };
  };
  linkedAgents = linked.home.file.".claude/agents";
  expect = condition: message:
    if condition then true else throw "agent-skills Home Manager subagents test: ${message}";
in
assert expect (unchangedFor "symlink-tree") "an unselected subagents source changed the sync activation";
assert expect (unchangedFor "link") "an unselected subagents source changed home.file";
assert expect (!(builtins.elem ".claude/agents" (fileNames selected))) "sync layouts must not add home.file entries";
assert expect linkedAgents.recursive "link layout must link each subagent file";
assert expect (!linkedAgents.force) "link layout must not replace user-written agents";
pkgs.runCommand "agent-skills-home-manager-subagents-test" { } ''
  set -euo pipefail
  fail() { echo "ERROR: $*" >&2; exit 1; }

  test "$(ls -A ${linkedAgents.source})" = alpha.md || fail "link source must contain only the selected subagent"

  export HOME="$PWD/selected"
  mkdir -p "$HOME"
  ${activationOf selected}
  cmp "$HOME/.claude/agents/alpha.md" ${./fixtures/subagents/alpha.md}
  cmp "$HOME/.cursor/agents/alpha.md" ${./fixtures/subagents/alpha.md}
  test ! -e "$HOME/.claude/agents/beta.md" || fail "unselected subagent was installed"
  test "$(ls -A "$HOME/.codex")" = skills || fail "codex has no subagents default but received one"

  export HOME="$PWD/without-claude-agents"
  mkdir -p "$HOME"
  ${activationOf withoutClaudeAgents}
  test -f "$HOME/.claude/skills/fixture/SKILL.md"
  test ! -e "$HOME/.claude/agents" || fail "subagentsDest = null still installed subagents"

  mkdir -p "$out"
  touch "$out/ok"
''
