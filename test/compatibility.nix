# Verify that existing consumer flakes can keep using the original helper API.
{ pkgs, agentLib, bundle }:

let
  legacyLocalProgram = agentLib.mkLocalInstallScript {
    inherit pkgs bundle;
    targets = {};
  };

  currentLocalProgram = agentLib.mkLocalInstallProgram {
    inherit pkgs bundle;
    targets = {};
  };

  legacySyncText = agentLib.mkSyncScript {
    inherit pkgs bundle;
    targets = {};
  };

  legacyWrappedProgram = pkgs.writeShellApplication {
    name = "legacy-skills-install";
    text = legacySyncText;
  };

  _assertLocalDerivation =
    if pkgs.lib.isDerivation legacyLocalProgram then true
    else throw "agent-skills compatibility test failed: mkLocalInstallScript must return a derivation";

  _assertLocalAlias =
    if legacyLocalProgram.outPath == currentLocalProgram.outPath then true
    else throw "agent-skills compatibility test failed: legacy local helper must delegate to the current program";

  _assertSyncText =
    if builtins.isString legacySyncText && pkgs.lib.hasInfix "/bin/skills-install" legacySyncText then true
    else throw "agent-skills compatibility test failed: mkSyncScript must return runnable shell source";
in
assert _assertLocalDerivation;
assert _assertLocalAlias;
assert _assertSyncText;
pkgs.runCommand "agent-skills-consumer-api-compatibility-test" {} ''
  ${legacyLocalProgram}/bin/skills-install-local
  ${legacyWrappedProgram}/bin/legacy-skills-install
  mkdir -p "$out"
''
