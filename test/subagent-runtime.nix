{ pkgs, agentLib }:

let
  inherit (pkgs) lib;
  skillSources.fixture.path = ./fixtures/test-skill;
  skillBundle = agentLib.mkBundle {
    inherit pkgs;
    selection = agentLib.selectSkills {
      catalog = agentLib.discoverCatalog skillSources;
      sources = skillSources;
      allowlist = [ "fixture" ];
    };
  };
  catalog = agentLib.discoverSubagents {
    agents = { path = ./fixtures/subagents; subagentsSubdir = "."; };
  };
  claude = { claude = agentLib.defaultTargets.claude // { enable = true; }; };
  mkProgram = { ids, targets ? claude, excludePatterns ? agentLib.defaultExcludePatterns }:
    agentLib.mkSyncProgram {
      inherit pkgs targets excludePatterns;
      bundle = skillBundle;
      extraEntries = agentLib.subagentEntriesFor {
        inherit targets;
        bundle = agentLib.mkSubagentBundle { inherit pkgs; subagents = lib.getAttrs ids catalog; };
        system = pkgs.stdenv.hostPlatform.system;
      };
    };
  alphaProgram = mkProgram { ids = [ "alpha" ]; };
  betaProgram = mkProgram { ids = [ "beta" ]; };
  keepMineProgram = mkProgram { ids = [ "alpha" ]; excludePatterns = [ "/mine.md" ]; };
  overlapProgram = mkProgram {
    ids = [ "alpha" ];
    targets.custom = { dest = "$HOME/x"; subagentsDest = "$HOME/x/agents"; };
  };
in
pkgs.runCommand "agent-skills-subagent-runtime-test"
{ nativeBuildInputs = [ pkgs.jq ]; }
  ''
    set -euo pipefail
    fail() { echo "ERROR: $*" >&2; exit 1; }

    export HOME="$PWD/home"
    mkdir -p "$HOME"
    ${alphaProgram}/bin/skills-install
    test -f "$HOME/.claude/skills/fixture/SKILL.md" || fail "skills were not installed"
    cmp "$HOME/.claude/agents/alpha.md" ${./fixtures/subagents/alpha.md}
    test ! -e "$HOME/.claude/agents/beta.md" || fail "unselected subagent was installed"
    jq -e '.managedBy == "agent-skills-nix"' "$HOME/.claude/agents/.agent-skills-managed.json" >/dev/null

    ${betaProgram}/bin/skills-install
    test ! -e "$HOME/.claude/agents/alpha.md" || fail "deselected subagent was kept"
    test -f "$HOME/.claude/agents/beta.md" || fail "newly selected subagent was not installed"

    export HOME="$PWD/user"
    mkdir -p "$HOME/.claude/agents"
    echo mine > "$HOME/.claude/agents/mine.md"
    if ${alphaProgram}/bin/skills-install > refuse.log 2>&1; then
      fail "an unmarked agents directory was replaced"
    fi
    grep -F "$HOME/.claude/agents exists and is non-empty" refuse.log
    test "$(cat "$HOME/.claude/agents/mine.md")" = mine
    test ! -e "$HOME/.claude/agents/.agent-skills-managed.json"
    test ! -e "$HOME/.claude/skills" || fail "skills were installed after the agents directory was refused"

    AGENT_SKILLS_FORCE=1 ${keepMineProgram}/bin/skills-install
    test "$(cat "$HOME/.claude/agents/mine.md")" = mine || fail "excluded user agent was not kept"
    test -f "$HOME/.claude/agents/alpha.md"

    export HOME="$PWD/overlap"
    mkdir -p "$HOME"
    if ${overlapProgram}/bin/skills-install > overlap.log 2>&1; then
      fail "a subagents dest nested in a skills dest was accepted"
    fi
    grep -F 'destinations overlap' overlap.log
    test ! -e "$HOME/x"

    mkdir -p "$out"
    touch "$out/ok"
  ''
