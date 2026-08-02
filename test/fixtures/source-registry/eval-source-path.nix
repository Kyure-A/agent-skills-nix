{ lockFile, manifestsDir, nixpkgsLib, sourceRegistryLib }:

let
  lib = import (builtins.toPath nixpkgsLib);
  sourceRegistry = import (builtins.toPath sourceRegistryLib) { inherit lib; };
  sources = sourceRegistry.sourcesFromLock {
    manifestsDir = builtins.toPath manifestsDir;
    lockFile = builtins.toPath lockFile;
  };
in
toString sources.local.path
