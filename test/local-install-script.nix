# Test mkLocalInstallScript behavior around copy-tree overwrite safety.
{ pkgs, agentLib }:

let
  testSources = {
    test-skill = {
      path = ./fixtures/test-skill;
    };
  };

  testCatalog = agentLib.discoverCatalog testSources;
  testAllowlist = agentLib.allowlistFor {
    catalog = testCatalog;
    sources = testSources;
    enableAll = true;
  };
  testSelection = agentLib.selectSkills {
    catalog = testCatalog;
    allowlist = testAllowlist;
    skills = { };
    sources = testSources;
  };
  testBundle = agentLib.mkBundle {
    inherit pkgs;
    selection = testSelection;
    name = "agent-skills-test-local-install-bundle";
  };
  installScript = agentLib.mkLocalInstallScript {
    inherit pkgs;
    bundle = testBundle;
    targets = {
      codex = {
        dest = ".codex/skills";
        structure = "copy-tree";
        enable = true;
        systems = [ ];
      };
    };
  };
  syncScript = pkgs.writeShellApplication {
    name = "skills-sync-test";
    runtimeInputs = [
      pkgs.rsync
      pkgs.coreutils
    ];
    text = agentLib.mkSyncScript {
      inherit pkgs;
      bundle = testBundle;
      targets = {
        codex = {
          dest = "$PWD/sync/skills";
          structure = "symlink-tree";
          enable = true;
          systems = [ ];
        };
      };
      system = pkgs.stdenv.hostPlatform.system;
    };
  };
in
pkgs.runCommand "agent-skills-local-install-script-test" { } ''
  set -euo pipefail

  # should install copy-tree into a pre-existing destination directory
  project="$PWD/project"
  mkdir -p "$project/.codex/skills"
  echo "sentinel" > "$project/.codex/skills/EXISTING.txt"

  (
    cd "$project"
    "${installScript}/bin/skills-install-local"
  ) > "$PWD/install.log" 2>&1

  test -f "$project/.codex/skills/test-skill/SKILL.md" || {
    echo "ERROR: copy-tree should install into an existing directory target"
    echo "---- install.log ----"
    cat "$PWD/install.log"
    echo "---------------------"
    exit 1
  }

  # should reinstall copy-tree over a read-only previously-installed tree
  chmod -R a-w "$project/.codex/skills/test-skill"
  (
    cd "$project"
    "${installScript}/bin/skills-install-local"
  ) > "$PWD/reinstall-readonly-copy-tree.log" 2>&1

  test -f "$project/.codex/skills/test-skill/SKILL.md" || {
    echo "ERROR: copy-tree should reinstall over read-only copied skill directories"
    echo "---- reinstall-readonly-copy-tree.log ----"
    cat "$PWD/reinstall-readonly-copy-tree.log"
    echo "------------------------------------------"
    exit 1
  }

  # should sync symlink-tree over a read-only previously-copied tree
  mkdir -p "$PWD/sync/skills/test-skill"
  echo "# Old copied skill" > "$PWD/sync/skills/test-skill/SKILL.md"
  mkdir -p "$PWD/sync/skills/test-skill/nested"
  echo "old" > "$PWD/sync/skills/test-skill/nested/old.txt"
  chmod -R a-w "$PWD/sync/skills/test-skill"

  "${syncScript}/bin/skills-sync-test" > "$PWD/sync-readonly-symlink-tree.log" 2>&1

  test -L "$PWD/sync/skills/test-skill" || {
    echo "ERROR: symlink-tree should replace read-only copied skill directory with bundle symlink"
    echo "---- sync-readonly-symlink-tree.log ----"
    cat "$PWD/sync-readonly-symlink-tree.log"
    echo "----------------------------------------"
    exit 1
  }
  test -f "$PWD/sync/skills/test-skill/SKILL.md" || {
    echo "ERROR: symlink-tree replacement should expose SKILL.md"
    echo "---- sync-readonly-symlink-tree.log ----"
    cat "$PWD/sync-readonly-symlink-tree.log"
    echo "----------------------------------------"
    exit 1
  }

  echo "copy-tree installed successfully into pre-existing directory"
  echo "read-only destination trees are made writable before sync"
  mkdir -p "$out"
  touch "$out/ok"
''
