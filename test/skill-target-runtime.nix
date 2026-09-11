# Per-skill routing reaches every synchronization structure and mode.
{ pkgs, agentLib }:

let
  inherit (pkgs) lib;
  sources = { fixture.path = ./fixtures/test-skill; };
  catalog = agentLib.discoverCatalog sources;
  skills = {
    common = { };
    codex-only.agents = [ "codex" ];
    claude-only.agents = [ "claude" ];
    custom-only.agents = [ "custom" ];
    shared.agents = [ "codex" "custom" ];
    nowhere.agents = [ ];
    inactive.agents = [ "disabled" "other-system" "cursor" ];
  };
  mkBundle = overrides: agentLib.mkBundle {
    inherit pkgs;
    name = "agent-skills-routing-test-bundle";
    selection = agentLib.selectSkills {
      inherit catalog sources;
      allowlist = [ ];
      skills = lib.mapAttrs (_: skill: { from = "fixture"; path = "."; } // skill)
        (skills // overrides);
    };
  };
  initialBundle = mkBundle { };
  matchingBundle = mkBundle {
    codex-only.agents = [ "claude" "codex" ];
    claude-only.agents = [ "claude" "codex" ];
    shared.agents = [ "custom" ];
  };
  changedBundle = mkBundle {
    codex-only.agents = [ "claude" ];
    claude-only.agents = [ ];
    custom-only.agents = [ ];
    shared.agents = [ ];
  };
  targetsForMode = mode: lib.mapAttrs
    (name: target: target // { dest = if mode == "local" then name else "$HOME/${name}"; })
    {
      claude.structure = "link";
      codex.structure = "symlink-tree";
      custom.structure = "copy-tree";
      disabled.enable = false;
      other-system.systems = [ "unsupported-system" ];
    };
  mkProgram = mode: bundle: agentLib.mkSyncProgram {
    inherit pkgs mode bundle;
    targets = targetsForMode mode;
    allowOverrides = true;
    programName = "skills-routing-test";
  };
  sharedDestinationProgram = mode: bundle: agentLib.mkSyncProgram {
    inherit pkgs mode bundle;
    targets = targetsForMode mode // {
      before = {
        dest = if mode == "local" then "before" else "$HOME/before";
        structure = "copy-tree";
      };
    } // lib.genAttrs [ "claude" "codex" ] (_: {
      dest = if mode == "local" then "shared" else "$HOME/shared";
      structure = "copy-tree";
    });
    programName = "skills-routing-shared-test";
  };
  invalidProgram = agentLib.mkSyncProgram {
    inherit pkgs;
    bundle = initialBundle // { skillTargetNames = [ "cluade" ]; };
    targets = { };
  };
  unknownTarget = builtins.tryEval invalidProgram.drvPath;
  # A plain derivation remains usable by the public synchronization API.
  plainBundle = pkgs.runCommand "agent-skills-plain-routing-bundle" { } ''
    mkdir -p "$out/plain"
    cp ${./fixtures/test-skill/SKILL.md} "$out/plain/SKILL.md"
  '';
  plainProgram = agentLib.mkLocalInstallProgram {
    inherit pkgs;
    bundle = plainBundle;
    targets.plain = { dest = "plain"; structure = "copy-tree"; };
  };
in
assert !unknownTarget.success;
pkgs.runCommand "agent-skills-target-runtime-test"
{ nativeBuildInputs = [ pkgs.coreutils pkgs.jq pkgs.rsync ]; }
  ''
    set -euo pipefail
    fail() { echo "ERROR: $*" >&2; exit 1; }

    ${lib.concatMapStringsSep "\n" (mode: let
      initialProgram = mkProgram mode initialBundle;
      changedProgram = mkProgram mode changedBundle;
      conflictingProgram = sharedDestinationProgram mode initialBundle;
      matchingProgram = sharedDestinationProgram mode matchingBundle;
      overrideVar = if mode == "local" then "AGENT_SKILLS_LOCAL_DESTS" else "AGENT_SKILLS_DESTS";
    in ''
      root="$PWD/${mode}"
      mkdir -p "$root"
      HOME="$root" AGENT_SKILLS_ROOT="$root" \
        ${initialProgram}/bin/skills-routing-test
      for target in claude codex custom; do
        test -f "$root/$target/common/SKILL.md" || fail "${mode}: missing common skill for $target"
        test ! -e "$root/$target/nowhere" || fail "${mode}: empty agents installed a skill"
        test ! -e "$root/$target/inactive" || fail "${mode}: inactive skill leaked to $target"
      done
      test -L "$root/claude" || fail "${mode}: link structure was lost"
      test -L "$root/codex/codex-only" || fail "${mode}: symlink-tree structure was lost"
      test ! -L "$root/custom/custom-only" || fail "${mode}: copy-tree retained a symlink"
      test -f "$root/claude/claude-only/SKILL.md"
      test -f "$root/codex/codex-only/SKILL.md"
      test -f "$root/custom/custom-only/SKILL.md"
      test -f "$root/codex/shared/SKILL.md"
      test -f "$root/custom/shared/SKILL.md"
      test ! -e "$root/codex/claude-only"
      test ! -e "$root/claude/codex-only"
      test ! -e "$root/custom/codex-only"
      test ! -e "$root/disabled"
      test ! -e "$root/other-system"
      jq -e --arg bundle '${initialBundle.forTarget "codex"}' \
        '.bundle == $bundle and .target == "codex"' \
        "$root/codex/.agent-skills-managed.json" >/dev/null
      jq -e --arg bundle '${initialBundle.forTarget "custom"}' \
        '.bundle == $bundle and .target == "custom"' \
        "$root/custom/.agent-skills-managed.json" >/dev/null

      HOME="$root" AGENT_SKILLS_ROOT="$root" \
        ${changedProgram}/bin/skills-routing-test
      test -f "$root/claude/codex-only/SKILL.md"
      test ! -e "$root/claude/claude-only" || fail "${mode}: link retained a removed skill"
      test ! -e "$root/codex/codex-only" || fail "${mode}: symlink-tree retained a removed skill"
      test ! -e "$root/custom/custom-only" || fail "${mode}: copy-tree retained a removed skill"
      test ! -e "$root/codex/shared"
      test ! -e "$root/custom/shared"

      # Anonymous overrides must fail even with FORCE, before creating or
      # changing either the requested destinations or the named targets.
      reject_root="$PWD/${mode}-override"
      mkdir -p "$reject_root/anonymous"
      echo keep > "$reject_root/anonymous/SENTINEL"
      if HOME="$reject_root" AGENT_SKILLS_ROOT="$reject_root" AGENT_SKILLS_FORCE=1 \
        ${overrideVar}="${if mode == "local" then "anonymous" else "$reject_root/anonymous"}" \
        ${initialProgram}/bin/skills-routing-test > override.log 2>&1; then
        fail "${mode}: anonymous override accepted a restricted bundle"
      fi
      grep -F '${overrideVar} cannot be used with per-skill agents restrictions' override.log
      grep -F 'targets.<name>.dest' override.log
      test "$(cat "$reject_root/anonymous/SENTINEL")" = keep
      test ! -e "$reject_root/anonymous/.agent-skills-managed.json"
      test ! -e "$reject_root/claude"
      test ! -e "$reject_root/codex"
      test ! -e "$reject_root/custom"

      # Named targets can share a destination only when their filtered bundles
      # agree. Reject a later conflict before changing any earlier target.
      conflict_root="$PWD/${mode}-conflicting-bundles"
      mkdir -p "$conflict_root/shared"
      echo keep > "$conflict_root/shared/SENTINEL"
      if HOME="$conflict_root" AGENT_SKILLS_ROOT="$conflict_root" AGENT_SKILLS_FORCE=1 \
        ${conflictingProgram}/bin/skills-routing-shared-test > conflict.log 2>&1; then
        fail "${mode}: shared destination accepted distinct restricted bundles"
      fi
      grep -F 'conflicting bundles for destination' conflict.log
      test "$(cat "$conflict_root/shared/SENTINEL")" = keep
      test ! -e "$conflict_root/shared/.agent-skills-managed.json"
      test ! -e "$conflict_root/before"
      test ! -e "$conflict_root/custom"

      # Identical filtered bundles still merge and retain the first name in
      # the marker, including when the existing destination is synchronized.
      matching_root="$PWD/${mode}-matching-bundles"
      mkdir -p "$matching_root"
      for run in initial repeated; do
        HOME="$matching_root" AGENT_SKILLS_ROOT="$matching_root" \
          ${matchingProgram}/bin/skills-routing-shared-test > matching.log 2>&1
        test "$(grep -c "installed .* to $matching_root/shared$" matching.log)" = 1 \
          || fail "${mode}: identical restricted bundles did not synchronize once"
      done
      test -f "$matching_root/shared/common/SKILL.md"
      test -f "$matching_root/shared/claude-only/SKILL.md"
      test -f "$matching_root/shared/codex-only/SKILL.md"
      test ! -e "$matching_root/shared/custom-only"
      test ! -e "$matching_root/shared/shared"
      jq -e --arg bundle '${matchingBundle.forTarget "claude"}' \
        '.bundle == $bundle and .target == "claude"' \
        "$matching_root/shared/.agent-skills-managed.json" >/dev/null
    '') [ "local" "global" ]}

    # The complete set of source paths is checked before the first target
    # can be installed. Destinations cannot consume another target's source.
    preflight_root="$PWD/preflight"
    mkdir -p "$preflight_root/source-one" "$preflight_root/source-two"
    echo keep > "$preflight_root/source-two/SENTINEL"
    make_config() {
      jq -n --arg root "$preflight_root" --arg second "$1" --arg dest "$2" '{
        schemaVersion: 2,
        mode: "local",
        bundle: ($root + "/source-one"),
        excludePatterns: [],
        overrides: {enabled: false, envVar: "UNUSED", structure: "copy-tree", hasTargetRestrictions: false},
        targets: [
          {name: "first", bundle: ($root + "/source-one"), dest: $dest, structure: "copy-tree"},
          {name: "second", bundle: $second, dest: "second", structure: "copy-tree"}
        ]
      }' > "$preflight_root/config.json"
    }
    make_config "$preflight_root/missing" first
    if AGENT_SKILLS_ROOT="$preflight_root" ${pkgs.bash}/bin/bash \
      ${../scripts/sync.sh} "$preflight_root/config.json" > preflight.log 2>&1; then
      fail "runtime accepted a missing target bundle"
    fi
    grep -F 'bundle directory not found' preflight.log
    test ! -e "$preflight_root/first"
    make_config "$preflight_root/source-two" source-two
    if AGENT_SKILLS_ROOT="$preflight_root" AGENT_SKILLS_FORCE=1 ${pkgs.bash}/bin/bash \
      ${../scripts/sync.sh} "$preflight_root/config.json" > preflight.log 2>&1; then
      fail "runtime accepted a destination containing another target bundle"
    fi
    grep -F 'destination contains the bundle' preflight.log
    test "$(cat "$preflight_root/source-two/SENTINEL")" = keep
    test ! -e "$preflight_root/second"

    # Canonical source aliases compare equal and the marker records the
    # resolved source, so spelling differences cannot cause false conflicts.
    ln -s "$preflight_root/source-one" "$preflight_root/source-alias"
    echo content > "$preflight_root/source-one/CONTENT"
    make_config "$preflight_root/source-alias" shared
    jq '.targets[1].dest = "shared"' "$preflight_root/config.json" > "$preflight_root/aliases.json"
    AGENT_SKILLS_ROOT="$preflight_root" ${pkgs.bash}/bin/bash \
      ${../scripts/sync.sh} "$preflight_root/aliases.json" > aliases.log 2>&1
    test "$(grep -c 'installed .* to ' aliases.log)" = 1
    test "$(cat "$preflight_root/shared/CONTENT")" = content
    jq -e --arg bundle "$preflight_root/source-one" \
      '.bundle == $bundle and .target == "first"' \
      "$preflight_root/shared/.agent-skills-managed.json" >/dev/null

    plain_root="$PWD/plain-root"
    mkdir -p "$plain_root"
    AGENT_SKILLS_ROOT="$plain_root" AGENT_SKILLS_LOCAL_DESTS="override extra" \
      ${plainProgram}/bin/skills-install-local
    test -f "$plain_root/override/plain/SKILL.md"
    test -f "$plain_root/extra/plain/SKILL.md"
    test ! -e "$plain_root/plain"

    mkdir -p "$out"
    touch "$out/ok"
  ''
