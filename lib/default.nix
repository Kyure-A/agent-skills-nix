{ lib, inputs }:

let
  sources = import ./sources.nix { inherit lib inputs; };
  selection = import ./selection.nix { inherit lib sources; };
  bundle = import ./bundle.nix { inherit lib sources; };
  targets = import ./targets.nix { inherit lib; };
  sourceRegistry = import ./source-registry.nix { inherit lib; };
in
{
  inherit (sourceRegistry)
    loadSourceManifests
    mkSourceLockProgram
    sourcesFromLock
    ;
  inherit (sources)
    catalogJson
    discoverCatalog
    ;
  inherit (selection)
    allowlistFor
    selectSkills
    ;
  inherit (bundle)
    getPkgBinInfo
    mkBundle
    mkPackagesTable
    rewriteCommandPaths
    ;
  inherit (targets)
    defaultExcludePatterns
    defaultLocalTargets
    defaultTargets
    mkLocalInstallProgram
    mkLocalInstallScript
    mkShellHook
    mkSyncProgram
    mkSyncScript
    targetsFor
    ;
}
