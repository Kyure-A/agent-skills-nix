# Integration tests for safe local and global synchronization programs.
{ pkgs, agentLib }:

let
  markerName = ".agent-skills-managed.json";
  specialDest = "special dir/quote'\"/$(touch PWNED)/skills";
  invalidGlobalFallback = "\${AGENT_SKILLS_TEST_UNSET:-unsupported}";

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
    name = "agent-skills-test-sync-bundle";
  };

  copyProgram = agentLib.mkLocalInstallProgram {
    inherit pkgs;
    bundle = testBundle;
    excludePatterns = [ "/.system" "/keep-me" ];
    targets = {
      codex = {
        dest = ".codex/skills";
        structure = "copy-tree";
        enable = true;
        systems = [ ];
      };
    };
  };

  specialDestProgram = agentLib.mkLocalInstallProgram {
    inherit pkgs;
    bundle = testBundle;
    targets = {
      special = {
        dest = specialDest;
        structure = "copy-tree";
        enable = true;
        systems = [ ];
      };
    };
  };

  preflightProgram = agentLib.mkLocalInstallProgram {
    inherit pkgs;
    bundle = testBundle;
    targets = {
      first = {
        dest = "first/skills";
        structure = "copy-tree";
        enable = true;
        systems = [ ];
      };
      second = {
        dest = "second/skills";
        structure = "copy-tree";
        enable = true;
        systems = [ ];
      };
    };
  };

  sharedDestinationProgram = agentLib.mkLocalInstallProgram {
    inherit pkgs;
    bundle = testBundle;
    targets = {
      agents = agentLib.defaultLocalTargets.agents // { enable = true; };
      antigravity = agentLib.defaultLocalTargets.antigravity // { enable = true; };
    };
  };

  localOverrideProgram = agentLib.mkSyncProgram {
    inherit pkgs;
    bundle = testBundle;
    mode = "local";
    allowOverrides = true;
    overrideStructure = "link";
    targets = {
      first = { dest = "first/skills"; structure = "copy-tree"; };
      second = { dest = "second/skills"; structure = "symlink-tree"; };
    };
  };

  linkProgram = agentLib.mkLocalInstallProgram {
    inherit pkgs;
    bundle = testBundle;
    targets = {
      bundle = {
        dest = "linked-bundle";
        structure = "link";
        enable = true;
        systems = [ ];
      };
    };
  };

  symlinkProgram = agentLib.mkSyncProgram {
    inherit pkgs;
    bundle = testBundle;
    programName = "skills-sync-test";
    allowOverrides = true;
    excludePatterns = [ "/.system" "/keep-me" ];
    targets = {
      codex = {
        dest = "\${AGENT_SKILLS_TEST_HOME:-$HOME/sync}/skills";
        structure = "symlink-tree";
        enable = true;
        systems = [ ];
      };
    };
  };
in
pkgs.runCommand "agent-skills-sync-program-integration-test" { } ''
  set -euo pipefail

  fail() {
    echo "ERROR: $*" >&2
    exit 1
  }

  # The static runtime rejects unknown config schema versions before touching
  # any destination.
  invalid_config="$PWD/invalid-config.json"
  cat > "$invalid_config" <<'JSON'
  {
    "schemaVersion": 999,
    "mode": "local",
    "bundle": "${testBundle}",
    "targets": [],
    "excludePatterns": [],
    "overrides": {"enabled": false, "envVar": "UNUSED", "structure": "copy-tree", "hasTargetRestrictions": false}
  }
  JSON
  if PATH=${pkgs.lib.makeBinPath [ pkgs.coreutils pkgs.jq pkgs.rsync ]} \
    ${pkgs.bash}/bin/bash ${../scripts/sync.sh} "$invalid_config" \
    > "$PWD/invalid-config.log" 2>&1; then
    cat "$PWD/invalid-config.log" >&2
    fail "runtime should reject an unsupported config schema"
  fi

  # A new copy-tree destination is installed and marked as managed.
  fresh="$PWD/fresh"
  mkdir -p "$fresh"
  (
    cd "$fresh"
    AGENT_SKILLS_ROOT="$fresh" \
      "${copyProgram}/bin/skills-install-local"
  ) > "$PWD/fresh-install.log" 2>&1 || {
    cat "$PWD/fresh-install.log" >&2
    fail "copy-tree should install into a new destination"
  }

  fresh_dest="$fresh/.codex/skills"
  test -f "$fresh_dest/test-skill/SKILL.md" \
    || fail "new copy-tree destination is missing SKILL.md"
  test -f "$fresh_dest/${markerName}" \
    || fail "new copy-tree destination is missing its managed marker"
  "${pkgs.jq}/bin/jq" -e 'type == "object"' "$fresh_dest/${markerName}" >/dev/null \
    || fail "managed marker must contain valid JSON"

  grep -q "installed codex to $fresh_dest" "$PWD/fresh-install.log" \
    || fail "synchronization should report installed targets by default"

  # Quiet mode drops the progress lines but still synchronizes the tree.
  echo "stale" > "$fresh_dest/quiet-stale.txt"
  (
    cd "$fresh"
    AGENT_SKILLS_ROOT="$fresh" AGENT_SKILLS_QUIET=1 \
      "${copyProgram}/bin/skills-install-local"
  ) > "$PWD/quiet-install.log" 2>&1 || {
    cat "$PWD/quiet-install.log" >&2
    fail "quiet synchronization should succeed"
  }

  test ! -s "$PWD/quiet-install.log" \
    || fail "quiet synchronization should print nothing on success"
  test ! -e "$fresh_dest/quiet-stale.txt" \
    || fail "quiet synchronization did not synchronize the destination"

  # Excluded paths survive synchronization. A managed read-only tree can be
  # made writable, cleaned, and synchronized again.
  mkdir -p "$fresh_dest/.system" "$fresh_dest/keep-me"
  echo "system-owned" > "$fresh_dest/.system/sentinel"
  echo "user-owned" > "$fresh_dest/keep-me/sentinel"
  echo "stale" > "$fresh_dest/stale.txt"
  marker_hash_before="$("${pkgs.coreutils}/bin/sha256sum" "$fresh_dest/${markerName}" | cut -d' ' -f1)"
  chmod -R a-w "$fresh_dest"

  (
    cd "$fresh"
    AGENT_SKILLS_ROOT="$fresh" \
      "${copyProgram}/bin/skills-install-local"
  ) > "$PWD/read-only-resync.log" 2>&1 || {
    cat "$PWD/read-only-resync.log" >&2
    fail "managed read-only copy-tree should resynchronize"
  }

  test -f "$fresh_dest/test-skill/SKILL.md" \
    || fail "read-only resynchronization lost SKILL.md"
  test ! -e "$fresh_dest/stale.txt" \
    || fail "read-only resynchronization did not delete an unmanaged stale file"
  test "$(cat "$fresh_dest/.system/sentinel")" = "system-owned" \
    || fail "default .system exclusion was not preserved"
  test "$(cat "$fresh_dest/keep-me/sentinel")" = "user-owned" \
    || fail "custom exclusion was not preserved"
  test -f "$fresh_dest/${markerName}" \
    || fail "read-only resynchronization lost the managed marker"

  # Running the same synchronization again is idempotent.
  (
    cd "$fresh"
    AGENT_SKILLS_ROOT="$fresh" \
      "${copyProgram}/bin/skills-install-local"
  ) > "$PWD/idempotent-resync.log" 2>&1 || {
    cat "$PWD/idempotent-resync.log" >&2
    fail "repeated synchronization should succeed"
  }
  marker_hash_after="$("${pkgs.coreutils}/bin/sha256sum" "$fresh_dest/${markerName}" | cut -d' ' -f1)"
  test "$marker_hash_before" = "$marker_hash_after" \
    || fail "repeated synchronization changed the managed marker"
  test "$(cat "$fresh_dest/.system/sentinel")" = "system-owned" \
    || fail "repeated synchronization changed excluded content"

  # A non-empty destination without a marker is rejected without modifying it.
  unmanaged="$PWD/unmanaged"
  unmanaged_dest="$unmanaged/.codex/skills"
  mkdir -p "$unmanaged_dest"
  echo "do-not-delete" > "$unmanaged_dest/SENTINEL"
  if (
    cd "$unmanaged"
    AGENT_SKILLS_ROOT="$unmanaged" \
      "${copyProgram}/bin/skills-install-local"
  ) > "$PWD/unmanaged-reject.log" 2>&1; then
    cat "$PWD/unmanaged-reject.log" >&2
    fail "unmanaged non-empty destination should be rejected"
  fi
  test "$(cat "$unmanaged_dest/SENTINEL")" = "do-not-delete" \
    || fail "rejected synchronization modified the unmanaged sentinel"
  test ! -e "$unmanaged_dest/test-skill" \
    || fail "rejected synchronization partially installed the bundle"
  test ! -e "$unmanaged_dest/${markerName}" \
    || fail "rejected synchronization marked an unmanaged destination"

  # Merely creating a file with the marker name must not grant ownership.
  printf '{}\n' > "$unmanaged_dest/${markerName}"
  if (
    cd "$unmanaged"
    AGENT_SKILLS_ROOT="$unmanaged" \
      "${copyProgram}/bin/skills-install-local"
  ) > "$PWD/invalid-marker-reject.log" 2>&1; then
    cat "$PWD/invalid-marker-reject.log" >&2
    fail "destination with an invalid managed marker should be rejected"
  fi
  test "$(cat "$unmanaged_dest/SENTINEL")" = "do-not-delete" \
    || fail "invalid-marker rejection modified the unmanaged sentinel"

  # A symlink to a user-owned directory is not managed merely because its
  # target is empty; only whole-destination links into /nix/store are trusted.
  symlink_owned="$PWD/symlink-owned"
  symlink_target="$PWD/user-owned-target"
  mkdir -p "$symlink_owned/.codex" "$symlink_target"
  ln -s "$symlink_target" "$symlink_owned/.codex/skills"
  if (
    cd "$symlink_owned"
    AGENT_SKILLS_ROOT="$symlink_owned" \
      "${copyProgram}/bin/skills-install-local"
  ) > "$PWD/user-symlink-reject.log" 2>&1; then
    cat "$PWD/user-symlink-reject.log" >&2
    fail "symlink to a user-owned directory should be rejected"
  fi
  test -L "$symlink_owned/.codex/skills" \
    || fail "rejected synchronization replaced the user-owned symlink"
  test -z "$(find "$symlink_target" -mindepth 1 -maxdepth 1 -print -quit)" \
    || fail "rejected synchronization modified the user-owned symlink target"

  # All destinations are authorized before any target is changed.
  preflight_root="$PWD/preflight"
  mkdir -p "$preflight_root/second/skills"
  echo "do-not-delete" > "$preflight_root/second/skills/SENTINEL"
  if (
    cd "$preflight_root"
    AGENT_SKILLS_ROOT="$preflight_root" \
      "${preflightProgram}/bin/skills-install-local"
  ) > "$PWD/preflight-reject.log" 2>&1; then
    cat "$PWD/preflight-reject.log" >&2
    fail "multi-target synchronization should reject an unsafe destination"
  fi
  test ! -e "$preflight_root/first/skills" \
    || fail "preflight failure partially installed an earlier target"
  test "$(cat "$preflight_root/second/skills/SENTINEL")" = "do-not-delete" \
    || fail "preflight failure modified the unsafe destination"

  # A nested path-resolution failure must propagate through the complete plan.
  # Reject a later escaping local target before installing an earlier safe one.
  unsafe_local_root="$PWD/unsafe-local-plan/root"
  mkdir -p "$unsafe_local_root"
  if AGENT_SKILLS_ROOT="$unsafe_local_root" \
    AGENT_SKILLS_LOCAL_DESTS="safe/skills ../escaped" \
    "${preflightProgram}/bin/skills-install-local" \
    > "$PWD/unsafe-local-plan.log" 2>&1; then
    fail "a later unsafe local destination should reject the execution plan"
  fi
  grep -q 'escapes the project root' "$PWD/unsafe-local-plan.log" \
    || fail "later local destination did not report the path-resolution failure"
  test ! -e "$unsafe_local_root/safe" \
    && test ! -e "$unsafe_local_root/../escaped" \
    || fail "local path-resolution failure partially synchronized the plan"

  # A failed fallback cannot become a valid destination just because its suffix
  # is absolute. All potential destinations stay inside the build directory.
  invalid_global_root="$PWD/invalid-global-fallback"
  mkdir -p "$invalid_global_root"
  invalid_fallback=${pkgs.lib.escapeShellArg invalidGlobalFallback}"$invalid_global_root/fallback"
  unset AGENT_SKILLS_TEST_UNSET
  if HOME="$invalid_global_root" \
    AGENT_SKILLS_DESTS="$invalid_global_root/safe $invalid_fallback" \
    "${symlinkProgram}/bin/skills-sync-test" \
    > "$PWD/invalid-global-fallback.log" 2>&1; then
    fail "an invalid global fallback should reject the execution plan"
  fi
  grep -q 'unsupported HOME expression' "$PWD/invalid-global-fallback.log" \
    || fail "invalid fallback did not report the expansion failure"
  test ! -e "$invalid_global_root/safe" && test ! -e "$invalid_global_root/fallback" \
    || fail "global fallback failure partially synchronized the plan"

  # The default agents and antigravity targets share one layout and should
  # synchronize their common destination once, including on repeated runs.
  shared_root="$PWD/shared-destination"
  mkdir -p "$shared_root"
  for run in initial repeated; do
    AGENT_SKILLS_ROOT="$shared_root" \
      "${sharedDestinationProgram}/bin/skills-install-local" \
      > "$PWD/shared-$run.log" 2>&1 || {
      cat "$PWD/shared-$run.log" >&2
      fail "default agents and antigravity targets should synchronize together"
    }
    test "$(grep -c 'installed .* to ' "$PWD/shared-$run.log")" = 1 \
      || fail "shared destination should synchronize only once"
  done
  test -f "$shared_root/.agents/skills/test-skill/SKILL.md" \
    || fail "shared default destination is missing the skill"
  "${pkgs.jq}/bin/jq" -e '.target == "agents" and .structure == "copy-tree"' \
    "$shared_root/.agents/skills/${markerName}" >/dev/null \
    || fail "shared destination should retain the first target ownership marker"

  # Duplicate detection uses canonical destinations, including lexical aliases.
  AGENT_SKILLS_ROOT="$shared_root" \
    AGENT_SKILLS_LOCAL_DESTS=".agents/skills .agents/./skills" \
    "${sharedDestinationProgram}/bin/skills-install-local" \
    > "$PWD/shared-alias.log" 2>&1 || {
    cat "$PWD/shared-alias.log" >&2
    fail "equivalent destination spellings should merge"
  }
  test "$(grep -c 'installed .* to ' "$PWD/shared-alias.log")" = 1 \
    || fail "canonical destination aliases should synchronize only once"

  # Local overrides are positional: unmatched targets keep their defaults.
  partial_root="$PWD/partial-local-overrides"
  mkdir -p "$partial_root"
  AGENT_SKILLS_ROOT="$partial_root" AGENT_SKILLS_LOCAL_DESTS="changed/skills" \
    "${localOverrideProgram}/bin/skills-install-local"
  test -d "$partial_root/changed/skills/test-skill" \
    && test ! -L "$partial_root/changed/skills/test-skill" \
    || fail "local override should retain the first target copy-tree structure"
  test -L "$partial_root/second/skills/test-skill" \
    || fail "unmatched local target should retain its destination and structure"
  test ! -e "$partial_root/first" \
    || fail "local override should replace its positional destination"

  # Overrides accept all documented whitespace separators. Extra local
  # destinations use overrideStructure rather than a hard-coded copy-tree.
  extra_root="$PWD/extra-local-overrides"
  mkdir -p "$extra_root"
  AGENT_SKILLS_ROOT="$extra_root" \
    AGENT_SKILLS_LOCAL_DESTS=$'one/skills\ttwo/skills\nthree/skills' \
    "${localOverrideProgram}/bin/skills-install-local"
  test ! -L "$extra_root/one/skills/test-skill" \
    && test -f "$extra_root/one/skills/test-skill/SKILL.md" \
    || fail "first positional override lost copy-tree structure"
  test -L "$extra_root/two/skills/test-skill" \
    || fail "second positional override lost symlink-tree structure"
  test -L "$extra_root/three/skills" \
    && test "$(readlink "$extra_root/three/skills")" = "${testBundle}" \
    || fail "extra local override did not use the configured link structure"
  test ! -e "$extra_root/first" && test ! -e "$extra_root/second" \
    || fail "local overrides should replace all matched destinations"

  # Conflicting structures for an exact destination and nested destinations
  # must fail before an earlier, unrelated destination is installed.
  conflict_root="$PWD/conflicting-structures"
  mkdir -p "$conflict_root"
  if AGENT_SKILLS_ROOT="$conflict_root" \
    AGENT_SKILLS_LOCAL_DESTS="safe/skills shared/skills shared/./skills" \
    "${localOverrideProgram}/bin/skills-install-local" \
    > "$PWD/conflicting-structures.log" 2>&1; then
    fail "shared destination with conflicting structures should be rejected"
  fi
  grep -q 'conflicting structures' "$PWD/conflicting-structures.log" \
    || fail "conflicting destination was not rejected by structure validation"
  test ! -e "$conflict_root/safe" && test ! -e "$conflict_root/shared" \
    || fail "structure conflict partially synchronized the execution plan"

  for nested_overrides in \
    'safe/skills parent parent/child' \
    'safe/skills parent/child parent'; do
    nested_root="$PWD/nested-destinations"
    mkdir -p "$nested_root"
    if AGENT_SKILLS_ROOT="$nested_root" \
      AGENT_SKILLS_LOCAL_DESTS="$nested_overrides" \
      "${localOverrideProgram}/bin/skills-install-local" \
      > "$PWD/nested-destinations.log" 2>&1; then
      fail "nested destinations should be rejected in either target order"
    fi
    grep -q 'destinations overlap' "$PWD/nested-destinations.log" \
      || fail "nested destination was not rejected by overlap validation"
    test ! -e "$nested_root/safe" && test ! -e "$nested_root/parent" \
      || fail "nested destinations partially synchronized the execution plan"
  done

  # Force explicitly opts into replacing the unmanaged destination.
  (
    cd "$unmanaged"
    AGENT_SKILLS_ROOT="$unmanaged" AGENT_SKILLS_FORCE=1 \
      "${copyProgram}/bin/skills-install-local"
  ) > "$PWD/unmanaged-force.log" 2>&1 || {
    cat "$PWD/unmanaged-force.log" >&2
    fail "AGENT_SKILLS_FORCE=1 should replace an unmanaged destination"
  }
  test -f "$unmanaged_dest/test-skill/SKILL.md" \
    || fail "forced synchronization did not install SKILL.md"
  test -f "$unmanaged_dest/${markerName}" \
    || fail "forced synchronization did not create the managed marker"
  test ! -e "$unmanaged_dest/SENTINEL" \
    || fail "forced synchronization did not replace unmanaged content"

  # Local overrides must remain beneath AGENT_SKILLS_ROOT.
  traversal="$PWD/traversal"
  traversal_root="$traversal/root"
  mkdir -p "$traversal_root"
  if (
    cd "$traversal_root"
    AGENT_SKILLS_ROOT="$traversal_root" \
      AGENT_SKILLS_LOCAL_DESTS="../escaped" \
      "${copyProgram}/bin/skills-install-local"
  ) > "$PWD/traversal-reject.log" 2>&1; then
    cat "$PWD/traversal-reject.log" >&2
    fail "local ../ traversal should be rejected"
  fi
  test ! -e "$traversal/escaped" \
    || fail "local traversal wrote outside AGENT_SKILLS_ROOT"

  # Existing intermediate symlinks cannot redirect a local destination out of
  # AGENT_SKILLS_ROOT.
  symlink_escape_root="$PWD/symlink-escape/root"
  symlink_escape_target="$PWD/symlink-escape/outside"
  mkdir -p "$symlink_escape_root" "$symlink_escape_target"
  ln -s "$symlink_escape_target" "$symlink_escape_root/redirect"
  if (
    cd "$symlink_escape_root"
    AGENT_SKILLS_ROOT="$symlink_escape_root" \
      AGENT_SKILLS_LOCAL_DESTS="redirect/skills" \
      "${copyProgram}/bin/skills-install-local"
  ) > "$PWD/intermediate-symlink-reject.log" 2>&1; then
    cat "$PWD/intermediate-symlink-reject.log" >&2
    fail "local destination through an escaping symlink should be rejected"
  fi
  test ! -e "$symlink_escape_target/skills" \
    || fail "local destination escaped through an intermediate symlink"

  # Destination data containing whitespace, quotes, and command substitution
  # syntax is handled literally and never evaluated as shell code.
  special_root="$PWD/special-root"
  special_dest=${pkgs.lib.escapeShellArg specialDest}
  mkdir -p "$special_root"
  (
    cd "$special_root"
    AGENT_SKILLS_ROOT="$special_root" \
      "${specialDestProgram}/bin/skills-install-local"
  ) > "$PWD/special-dest.log" 2>&1 || {
    cat "$PWD/special-dest.log" >&2
    fail "destination containing shell metacharacters should install literally"
  }
  test ! -e "$special_root/PWNED" \
    || fail "destination command substitution was executed"
  test ! -e "$PWD/PWNED" \
    || fail "destination command substitution escaped into the build directory"
  test -f "$special_root/$special_dest/test-skill/SKILL.md" \
    || fail "literal special-character destination is missing SKILL.md"
  test -f "$special_root/$special_dest/${markerName}" \
    || fail "literal special-character destination is missing its marker"

  # link installs the whole bundle as a replaceable Nix-store symlink.
  link_root="$PWD/link-root"
  mkdir -p "$link_root"
  AGENT_SKILLS_ROOT="$link_root" "${linkProgram}/bin/skills-install-local"
  test -L "$link_root/linked-bundle" \
    || fail "link structure did not create a destination symlink"
  test -f "$link_root/linked-bundle/test-skill/SKILL.md" \
    || fail "link structure does not expose the bundle"
  AGENT_SKILLS_ROOT="$link_root" "${linkProgram}/bin/skills-install-local"
  test -L "$link_root/linked-bundle" \
    || fail "repeated link synchronization did not preserve the symlink"

  # symlink-tree preserves bundle symlinks, exclusions, marker state, and can
  # be run repeatedly.
  symlink_root="$PWD/symlink-root"
  mkdir -p "$symlink_root"
  (
    cd "$symlink_root"
    unset AGENT_SKILLS_DESTS AGENT_SKILLS_TEST_HOME
    HOME="$symlink_root" "${symlinkProgram}/bin/skills-sync-test"
  ) > "$PWD/symlink-install.log" 2>&1 || {
    cat "$PWD/symlink-install.log" >&2
    fail "symlink-tree should install into a new destination"
  }
  symlink_dest="$symlink_root/sync/skills"
  test -L "$symlink_dest/test-skill" \
    || fail "symlink-tree should preserve the bundle skill symlink"
  test -f "$symlink_dest/test-skill/SKILL.md" \
    || fail "symlink-tree target does not expose SKILL.md"
  test -f "$symlink_dest/${markerName}" \
    || fail "symlink-tree destination is missing its managed marker"

  mkdir -p "$symlink_dest/.system" "$symlink_dest/keep-me"
  echo "system-owned" > "$symlink_dest/.system/sentinel"
  echo "user-owned" > "$symlink_dest/keep-me/sentinel"
  (
    cd "$symlink_root"
    unset AGENT_SKILLS_DESTS AGENT_SKILLS_TEST_HOME
    HOME="$symlink_root" "${symlinkProgram}/bin/skills-sync-test"
  ) > "$PWD/symlink-resync.log" 2>&1 || {
    cat "$PWD/symlink-resync.log" >&2
    fail "repeated symlink-tree synchronization should succeed"
  }
  test -L "$symlink_dest/test-skill" \
    || fail "repeated symlink-tree synchronization replaced the skill link"
  test "$(cat "$symlink_dest/.system/sentinel")" = "system-owned" \
    || fail "symlink-tree did not preserve the default exclusion"
  test "$(cat "$symlink_dest/keep-me/sentinel")" = "user-owned" \
    || fail "symlink-tree did not preserve the custom exclusion"

  # A non-empty environment value wins over the $HOME fallback without eval.
  configured_root="$PWD/configured-root"
  mkdir -p "$configured_root"
  unset AGENT_SKILLS_DESTS
  AGENT_SKILLS_TEST_HOME="$configured_root" \
    HOME="$symlink_root" "${symlinkProgram}/bin/skills-sync-test"
  test -L "$configured_root/skills/test-skill" \
    || fail "global destination did not honor its configured environment root"

  override_root="$PWD/global-override"
  mkdir -p "$override_root"
  AGENT_SKILLS_DESTS="$override_root/skills" \
    HOME="$symlink_root" "${symlinkProgram}/bin/skills-sync-test"
  test -L "$override_root/skills/test-skill" \
    || fail "global destination override was not synchronized"

  # Global overrides replace the entire configured target set, and every
  # override uses the configured override structure.
  global_many_root="$PWD/global-many-overrides"
  global_many_home="$PWD/global-many-home"
  mkdir -p "$global_many_root" "$global_many_home"
  unset AGENT_SKILLS_TEST_HOME
  AGENT_SKILLS_DESTS="$global_many_root/first $global_many_root/second" \
    HOME="$global_many_home" "${symlinkProgram}/bin/skills-sync-test"
  test -L "$global_many_root/first/test-skill" \
    && test -L "$global_many_root/second/test-skill" \
    || fail "multiple global overrides did not synchronize every destination"
  test ! -e "$global_many_home/sync" \
    || fail "global overrides should replace all configured targets"

  mkdir -p "$out"
  touch "$out/ok"
''
