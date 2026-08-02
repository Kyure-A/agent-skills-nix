{ manifestsDir, nixpkgsLib, sourceRegistryLib }:

let
  lib = import (builtins.toPath nixpkgsLib);
  sourceRegistry = import (builtins.toPath sourceRegistryLib) { inherit lib; };
in
sourceRegistry.loadSourceManifests (builtins.toPath manifestsDir)
