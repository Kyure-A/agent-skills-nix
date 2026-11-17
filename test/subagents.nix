{ pkgs, agentLib }:

let
  inherit (pkgs) lib;
  sources.fixture = { path = ./fixtures/subagents; subagentsSubdir = "."; };
  catalog = agentLib.discoverSubagents sources;
  select = args: agentLib.allowlistFor ({ inherit catalog sources; context = "subagents"; } // args);
  bundleFor = args: agentLib.mkSubagentBundle {
    inherit pkgs;
    subagents = lib.getAttrs (select args) catalog;
  };
  rejected = value: !(builtins.tryEval value).success;
  failures = {
    unknown-id = rejected (builtins.length (select { enable = [ "missing" ]; }));
    unknown-enable-all-source = rejected (builtins.length (select { enableAll = [ "missing" ]; }));
    duplicate-id = rejected (builtins.attrNames (agentLib.discoverSubagents (sources // {
      duplicate = { path = ./fixtures/subagents-dup; subagentsSubdir = "."; };
    })));
    missing-dir = rejected (builtins.attrNames (agentLib.discoverSubagents {
      fixture = { path = ./fixtures/subagents; subagentsSubdir = "missing"; };
    }));
  };
  failedChecks = builtins.attrNames (lib.filterAttrs (_: passed: !passed) failures);
  alphaOnly = bundleFor { enable = [ "alpha" ]; };
  fromSource = bundleFor { enableAll = [ "fixture" ]; };
in
assert lib.assertMsg (failedChecks == [ ]) "subagent selection accepted invalid cases: ${lib.concatStringsSep ", " failedChecks}";
assert lib.assertMsg (builtins.attrNames catalog == [ "alpha" "beta" ]) "discovery must return only top-level regular *.md files";
assert lib.assertMsg (agentLib.discoverSubagents { skills.path = ./fixtures/test-skill; } == { }) "sources without subagentsSubdir must contribute no subagents";
assert lib.assertMsg (agentLib.discoverSubagents { links = { path = ./fixtures/subagents-symlink; subagentsSubdir = "."; }; } == { }) "discovery must skip symlinked files";
pkgs.runCommand "agent-skills-subagents-test" { } ''
  set -euo pipefail
  fail() { echo "ERROR: $*" >&2; exit 1; }

  test "$(ls -A ${alphaOnly})" = alpha.md || fail "enable must bundle only the selected subagent"
  cmp ${alphaOnly}/alpha.md ${./fixtures/subagents/alpha.md}
  test "$(ls -A ${fromSource} | tr '\n' ' ')" = "alpha.md beta.md " || fail "enableAll must bundle every subagent of the source"
  cmp ${fromSource}/beta.md ${./fixtures/subagents/beta.md}

  mkdir -p "$out"
  touch "$out/ok"
''
