# Per-skill agent allowlists retain the full bundle and filter each target.
{ pkgs, agentLib }:

let
  inherit (pkgs) lib;
  sources.fixture.path = ./fixtures/test-skill;
  catalog = agentLib.discoverCatalog sources;
  skill = extra: { from = "fixture"; path = "."; } // extra;
  select = skills: agentLib.selectSkills {
    inherit catalog sources skills;
    allowlist = [ "fixture" ];
  };
  selection = select {
    shared = skill { };
    nullable = skill { agents = null; };
    hidden = skill { agents = [ ]; };
    claude-only = skill { agents = [ "claude" ]; };
    custom-only = skill { agents = [ "custom" ]; };
    both = skill { agents = [ "claude" "codex" "claude" ]; };
    transformed = skill {
      agents = [ "codex" ];
      transform = { original, dependencies }: original + "\nTarget-specific transform\n";
    };
    disabled = skill { enable = false; agents = [ "unknown-disabled-skill" ]; };
  };
  bundle = agentLib.mkBundle {
    inherit pkgs selection;
    name = "agent-skills-target-allowlist-bundle";
  };
  unrestrictedBundle = agentLib.mkBundle {
    inherit pkgs;
    selection = select { shared = skill { }; nullable = skill { agents = null; }; };
    name = "agent-skills-unrestricted-bundle";
  };
  hiddenBundle = agentLib.mkBundle {
    inherit pkgs;
    selection = agentLib.selectSkills {
      inherit catalog sources;
      skills.hidden = skill { agents = [ ]; };
    };
    name = "agent-skills-hidden-bundle";
  };
  prefixedSources.alpha = {
    path = ./fixtures/multi-skill-shared-root;
    idPrefix = "alpha";
  };
  prefixedCatalog = agentLib.discoverCatalog prefixedSources;
  prefixedBundle = agentLib.mkBundle {
    inherit pkgs;
    selection = agentLib.selectSkills {
      catalog = prefixedCatalog;
      sources = prefixedSources;
      allowlist = builtins.attrNames prefixedCatalog;
      skills."explicit/renamed" = {
        from = "alpha";
        path = "skill-a";
      };
    };
    name = "agent-skills-prefixed-bundle";
  };
  nestedSources.nested.path = ./fixtures/nested-skills;
  nestedCatalog = agentLib.discoverCatalog nestedSources;
  nestedBundle = agentLib.mkBundle {
    inherit pkgs;
    selection = agentLib.selectSkills {
      catalog = nestedCatalog;
      sources = nestedSources;
      allowlist = builtins.attrNames nestedCatalog;
      skills."custom/manual" = {
        from = "nested";
        path = "cat-a/skill-1";
      };
    };
    name = "agent-skills-nested-bundle";
  };
  collisionSources = {
    alpha = prefixedSources.alpha;
    beta = prefixedSources.alpha // { idPrefix = "beta"; };
  };
  collisionCatalog = agentLib.discoverCatalog collisionSources;
  collisionBundle = agentLib.mkBundle {
    inherit pkgs;
    selection = agentLib.selectSkills {
      catalog = collisionCatalog;
      sources = collisionSources;
      allowlist = builtins.attrNames collisionCatalog;
    };
    name = "agent-skills-prefixed-collision-bundle";
  };
  nestedCollisionBundle = agents: agentLib.mkBundle {
    inherit pkgs;
    selection = agentLib.selectSkills {
      catalog = nestedCatalog;
      sources = nestedSources;
      allowlist = [ "cat-a/skill-1" ];
      skills."different/skill-1" = {
        from = "nested";
        path = "cat-a/skill-2";
        inherit agents;
      };
    };
    name = "agent-skills-nested-collision-bundle";
  };
  unrestrictedCollision = nestedCollisionBundle null;
  filteredCollision = nestedCollisionBundle [ "codex" ];
  evaluationSucceeds = value: (builtins.tryEval (builtins.deepSeq value true)).success;
  rejectsAgents = agents: !evaluationSucceeds (select { invalid = skill { inherit agents; }; });
  programFor = agents: targets:
    (agentLib.mkSyncProgram {
      inherit pkgs targets;
      bundle = agentLib.mkBundle {
        inherit pkgs;
        selection = select { restricted = skill { inherit agents; }; };
      };
    }).drvPath;
  target = {
    dest = "$HOME/target-skills";
    structure = "symlink-tree";
    enable = true;
  };
  expect = condition: message:
    if condition then true else throw "agent-skills skill-targets test: ${message}";
  assertContents = path: expected:
    let
      all = builtins.attrNames selection;
    in
    lib.concatMapStringsSep "\n"
      (id:
        if builtins.elem id expected then ''
          test -f ${lib.escapeShellArg "${path}/${id}/SKILL.md"} || fail "missing ${id} from ${path}"
        '' else ''
          test ! -e ${lib.escapeShellArg "${path}/${id}"} || fail "unexpected ${id} in ${path}"
        ''
      )
      all;
in
assert expect (selection.shared.agents == null) "omitted agents must be unrestricted";
assert expect (selection.nullable.agents == null) "explicit null must be unrestricted";
assert expect (selection.hidden.agents == [ ]) "empty allowlists must be retained";
assert expect (selection.both.agents == [ "claude" "codex" ]) "selection must retain unique agent names";
assert expect (!(selection ? disabled)) "disabled explicit skills must be excluded";
assert expect bundle.hasTargetRestrictions "restricted bundle metadata is missing";
assert expect (!unrestrictedBundle.hasTargetRestrictions) "null/omitted lists must not restrict targets";
assert expect hiddenBundle.hasTargetRestrictions "an empty allowlist is still a restriction";
assert expect (lib.sort builtins.lessThan bundle.skillTargetNames == [ "claude" "codex" "custom" ]) "target names must be unique";
assert expect (lib.all rejectsAgents [ "claude" 1 true { claude = true; } [ null ] [ 1 ] [ "" ] ]) "invalid agents values were accepted";
assert expect (!evaluationSucceeds (programFor [ "cluade" ] { })) "unknown target names must fail evaluation";
assert expect (evaluationSucceeds (programFor [ "claude" ] { })) "disabled built-in targets must remain valid";
assert expect (evaluationSucceeds (programFor [ "custom" ] { custom = target; })) "custom target keys must be accepted";
assert expect (evaluationSucceeds (programFor [ "custom" ] { custom = target // { enable = false; }; })) "disabled custom targets must remain valid";
assert expect (evaluationSucceeds (programFor [ "custom" ] { custom = target // { systems = [ "another-system" ]; }; })) "system-filtered targets must remain valid";
assert expect (!evaluationSucceeds ((collisionBundle.forTarget { name = "agents"; flatten = true; }).drvPath)) "flattened paths must reject collisions";
assert expect (evaluationSucceeds ((collisionBundle.forTarget { name = "codex"; }).drvPath)) "other targets must retain separate prefixed paths";
assert expect (!evaluationSucceeds ((unrestrictedCollision.forTarget { name = "agents"; flatten = true; }).drvPath)) "nested and explicit IDs with the same basename must collide";
assert expect (evaluationSucceeds ((unrestrictedCollision.forTarget { name = "codex"; }).drvPath)) "other targets must preserve the distinct nested paths";
assert expect (evaluationSucceeds ((filteredCollision.forTarget { name = "agents"; flatten = true; }).drvPath)) "skills routed away from the target must not collide";
pkgs.runCommand "agent-skills-skill-targets-test" { } ''
  set -euo pipefail
  fail() { echo "ERROR: $*" >&2; exit 1; }

  ${assertContents bundle (builtins.attrNames selection)}
  ${assertContents (bundle.forTarget { name = "claude"; }) [ "fixture" "shared" "nullable" "claude-only" "both" ]}
  ${assertContents (bundle.forTarget { name = "codex"; }) [ "fixture" "shared" "nullable" "both" "transformed" ]}
  ${assertContents (bundle.forTarget { name = "custom"; }) [ "fixture" "shared" "nullable" "custom-only" ]}
  ${assertContents (bundle.forTarget { name = "gemini"; }) [ "fixture" "shared" "nullable" ]}

  # Filtering must retain materialized transformations and the source content.
  grep -q 'Target-specific transform' ${bundle.forTarget { name = "codex"; }}/transformed/SKILL.md
  grep -q '# Test Skill' ${bundle.forTarget { name = "codex"; }}/transformed/SKILL.md
  cmp ${bundle}/transformed/SKILL.md ${bundle.forTarget { name = "codex"; }}/transformed/SKILL.md
  test ! -e ${bundle}/disabled
  test -f ${hiddenBundle}/hidden/SKILL.md
  test -z "$(find ${hiddenBundle.forTarget { name = "claude"; }} -mindepth 1 -maxdepth 1 -print -quit)"

  test -f ${prefixedBundle.forTarget { name = "agents"; flatten = true; }}/skill-a/SKILL.md
  test -f ${prefixedBundle.forTarget { name = "agents"; flatten = true; }}/skill-b/SKILL.md
  test ! -e ${prefixedBundle.forTarget { name = "agents"; flatten = true; }}/alpha
  test -f ${prefixedBundle.forTarget { name = "agents"; flatten = true; }}/renamed/SKILL.md
  test ! -e ${prefixedBundle.forTarget { name = "agents"; flatten = true; }}/explicit
  test -f ${prefixedBundle.forTarget { name = "codex"; }}/explicit/renamed/SKILL.md
  test -f ${prefixedBundle.forTarget { name = "codex"; }}/alpha/skill-a/SKILL.md
  test ! -e ${prefixedBundle.forTarget { name = "codex"; }}/skill-a

  test -f ${nestedBundle.forTarget { name = "agents"; flatten = true; }}/skill-1/SKILL.md
  test -f ${nestedBundle.forTarget { name = "agents"; flatten = true; }}/skill-2/SKILL.md
  test -f ${nestedBundle.forTarget { name = "agents"; flatten = true; }}/manual/SKILL.md
  test ! -e ${nestedBundle.forTarget { name = "agents"; flatten = true; }}/cat-a
  test ! -e ${nestedBundle.forTarget { name = "agents"; flatten = true; }}/custom
  test -f ${nestedBundle.forTarget { name = "codex"; }}/cat-a/skill-1/SKILL.md
  test -f ${nestedBundle.forTarget { name = "codex"; }}/custom/manual/SKILL.md

  mkdir -p "$out"
  touch "$out/ok"
''
