{ pkgs, agentLib }:

let
  fixture = ./fixtures/test-skill;
  sourceConfig = import ../lib/source-config.nix { lib = pkgs.lib; };
  inputLib = import ../lib {
    lib = pkgs.lib;
    inputs.fixture.outPath = fixture;
  };
  invalidConfigs = {
    unknown-field = { typo = true; };
    invalid-path = { path = 1; };
    relative-root = { path = "relative/path"; };
    invalid-input = { input = [ "fixture" ]; };
    unsafe-subdir = { subdir = "../outside"; };
    invalid-subdir-type = { subdir = null; };
    empty-prefix = { idPrefix = ""; };
    trailing-prefix = { idPrefix = "fixture/"; };
    dot-prefix = { idPrefix = "fixture/./name"; };
    invalid-filter-type = { filter = null; };
    unknown-filter-field = { filter.depth = 1; };
    negative-depth = { filter.maxDepth = -1; };
    invalid-depth-type = { filter.maxDepth = "1"; };
    invalid-regex-type = { filter.nameRegex = [ ]; };
  };
  # Even asking only for the catalog's keys must validate all source fields.
  rejected = pkgs.lib.mapAttrs
    (_: extra: !(builtins.tryEval (builtins.attrNames (agentLib.discoverCatalog {
      fixture = { path = fixture; } // extra;
    }))).success)
    invalidConfigs;
  normalized = sourceConfig.normalizeSources {
    direct.path = fixture;
    input.path.outPath = fixture;
    string.path = toString fixture;
  };
  manifests = agentLib.loadSourceManifests ./fixtures/source-registry/manifests;
  registrySettings = builtins.removeAttrs manifests.alpha [ "pin" ];
  directSettings = builtins.removeAttrs
    (sourceConfig.normalizeSourceConfig "alpha"
      (registrySettings // { path = fixture; })) [ "input" "path" ];
  depthZero = agentLib.discoverCatalog {
    fixture = { path = fixture; filter.maxDepth = 0; };
    nested = { path = ./fixtures/nested-skills; filter.maxDepth = 0; };
  };
  registryRejected = manifestsDir:
    !(builtins.tryEval (builtins.attrNames (agentLib.loadSourceManifests manifestsDir))).success;
in
assert pkgs.lib.assertMsg (builtins.all (value: value) (builtins.attrValues rejected))
  "source config accepted invalid cases: ${pkgs.lib.concatStringsSep ", " (builtins.attrNames (pkgs.lib.filterAttrs (_: value: !value) rejected))}";
assert normalized.direct == normalized.input;
assert toString normalized.direct.path == normalized.string.path;
assert directSettings == registrySettings;
assert builtins.attrNames depthZero == [ "fixture" ];
assert builtins.attrNames (inputLib.discoverCatalog { fixture.input = "fixture"; }) == [ "fixture" ];
assert !(builtins.tryEval (builtins.attrNames (agentLib.discoverCatalog { missing = { }; }))).success;
assert !(builtins.tryEval (builtins.attrNames (agentLib.discoverCatalog { missing.input = "missing"; }))).success;
assert registryRejected ./fixtures/source-registry/invalid-manifests;
assert registryRejected ./fixtures/source-registry/invalid-value-manifests;
assert registryRejected ./fixtures/source-registry/invalid-prefix-manifests;
pkgs.runCommand "agent-skills-source-config-test" { } ''
  mkdir -p "$out"
''
