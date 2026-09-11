# Selection validation must run on shallow evaluation, before bundle creation.
{ pkgs, agentLib }:

let
  inherit (pkgs) lib;
  sources.fixture.path = ./fixtures/test-skill;
  catalog = agentLib.discoverCatalog sources;
  baseSkill = { from = "fixture"; path = "."; };
  select = args: agentLib.selectSkills ({ inherit sources catalog; } // args);
  allowlist = args: agentLib.allowlistFor ({ inherit sources catalog; } // args);
  rejected = value: !(builtins.tryEval value).success;
  selectionRejected = args: rejected (builtins.attrNames (select args));
  skillRejected = cfg: selectionRejected { skills.example = baseSkill // cfg; };

  # These intentionally do not use deepSeq: attrNames/length must be enough to
  # reject invalid declarations even if no selected record has been inspected.
  failures = {
    unknown-enable-all-source = rejected (builtins.length (allowlist { enableAll = [ "missing" ]; }));
    invalid-enable-all = rejected (allowlist { enableAll = "fixture"; });
    invalid-enable-all-entry = rejected (allowlist { enableAll = [ 1 ]; });
    invalid-enable-type = rejected (allowlist { enable = "fixture"; });
    invalid-enable-id = rejected (allowlist { enable = [ "../fixture" ]; });
    invalid-enable-entry = rejected (allowlist { enable = [ null ]; });
    unknown-enable-id = rejected (builtins.length (allowlist { enable = [ "missing" ]; }));
    unknown-allowlist-id = selectionRejected { allowlist = [ "missing" ]; };
    invalid-allowlist-type = selectionRejected { allowlist = "fixture"; };
    invalid-allowlist-id = selectionRejected { allowlist = [ "" ]; };
    invalid-allowlist-entry = selectionRejected { allowlist = [ 1 ]; };
    invalid-sources = selectionRejected { sources = [ ]; };
    invalid-source-config = selectionRejected { sources = { fixture = { }; }; };
    invalid-catalog = selectionRejected { catalog = [ ]; };
    invalid-skills = selectionRejected { skills = [ ]; };
    invalid-skill-config = selectionRejected { skills.example = true; };
    unknown-skill-field = skillRejected { typo = true; };
    invalid-skill-enable = skillRejected { enable = "yes"; };
    missing-from = selectionRejected { skills.example.path = "."; };
    invalid-from = skillRejected { from = 1; };
    unknown-explicit-source = skillRejected { from = "missing"; };
    missing-explicit-path = skillRejected { path = "missing"; };
    missing-skill-file = selectionRejected {
      sources.fixture.path = ./fixtures/nested-skills;
      skills.example = baseSkill;
    };
    invalid-explicit-path = skillRejected { path = 1; };
    unsafe-explicit-path = skillRejected { path = "../escape"; };
    empty-explicit-path = skillRejected { path = ""; };
    invalid-rename-type = skillRejected { rename = 1; };
    empty-rename = skillRejected { rename = ""; };
    unsafe-rename = skillRejected { rename = "../escape"; };
    invalid-meta = skillRejected { meta = [ ]; };
    invalid-transform = skillRejected { transform = "not a function"; };
    invalid-rewrite-commands = skillRejected { rewriteCommands = "yes"; };
    invalid-packages-type = skillRejected { packages = pkgs.hello; };
    invalid-package = skillRejected { packages = [ "hello" ]; };
    invalid-outpath-package = skillRejected { packages = [{ outPath = ./fixtures/test-skill; }]; };
    invalid-agents-type = skillRejected { agents = "claude"; };
    invalid-agents-entry = skillRejected { agents = [ null ]; };
    empty-agents-entry = skillRejected { agents = [ "" ]; };
    invalid-package-info = rejected (builtins.attrNames (agentLib.getPkgBinInfo { outPath = ./fixtures/test-skill; }));
  };
  failedChecks = builtins.attrNames (lib.filterAttrs (_: passed: !passed) failures);

  selection = select {
    allowlist = [ "fixture" "fixture" ];
    skills = {
      example = baseSkill;
      disabled.enable = false;
    };
  };
  ids = builtins.attrNames selection;
  lazyPackageSelection = select {
    skills.lazy = baseSkill // {
      packages = [ (pkgs.hello // { unused = throw "package internals must stay lazy"; }) ];
      meta.unused = throw "metadata internals must stay lazy";
      transform = _: throw "selection must not execute transforms";
    };
  };
  subdirSelection = agentLib.selectSkills {
    sources.fixture = { path = ./fixtures/nested-skills; subdir = "cat-a"; };
    catalog = { };
    skills.example = { from = "fixture"; path = "skill-1"; };
  };
  bundle = agentLib.mkBundle {
    inherit pkgs selection;
    name = "agent-skills-selection-bundle";
  };
in
assert lib.assertMsg (failedChecks == [ ])
  "Selection accepted invalid inputs: ${lib.concatStringsSep ", " failedChecks}";
assert allowlist { enableAll = true; enable = [ "fixture" ]; } == [ "fixture" ];
assert allowlist { enableAll = [ "fixture" ]; } == [ "fixture" ];
assert allowlist { } == [ ];
assert ids == [ "example" "fixture" ];
assert lib.all (id: selection.${id}.id == id) ids;
assert builtins.attrNames lazyPackageSelection == [ "lazy" ];
assert subdirSelection.example.sourceRelPath == "skill-1";
assert toString subdirSelection.example.sourceRoot == toString (./fixtures/nested-skills + "/cat-a");
pkgs.runCommand "agent-skills-selection-test" { } ''
  cmp ${./fixtures/test-skill/SKILL.md} ${bundle}/fixture/SKILL.md
  cmp ${./fixtures/test-skill/SKILL.md} ${bundle}/example/SKILL.md
  test ! -e ${bundle}/disabled
  mkdir -p "$out"
  touch "$out/ok"
''
