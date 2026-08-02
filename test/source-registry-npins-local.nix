{ pkgs, agentLib }:

let
  lockProgram = agentLib.mkSourceLockProgram { inherit pkgs; };
in
pkgs.runCommand "agent-skills-source-registry-npins-local-test"
{
  nativeBuildInputs = [
    pkgs.git
    pkgs.jq
    pkgs.nix
    lockProgram
  ];
} ''
  # Nested Nix and npins cannot use the outer daemon from a Linux build sandbox.
  export NIX_REMOTE=local
  export NIX_STATE_DIR="$TMPDIR/nix-state"
  export NIX_DATA_DIR="$TMPDIR/nix-data"
  export NIX_LOG_DIR="$TMPDIR/nix-log"
  export NIX_STORE_DIR="$TMPDIR/nix-store"
  mkdir -p "$NIX_STATE_DIR" "$NIX_DATA_DIR" "$NIX_LOG_DIR" "$NIX_STORE_DIR"

  export XDG_CACHE_HOME="$TMPDIR/cache"
  mkdir -p "$XDG_CACHE_HOME"

  # A private store cannot import the outer store paths, so copy evaluator inputs.
  nix_runtime="$TMPDIR/nix-runtime"
  mkdir -p "$nix_runtime"
  cp ${./fixtures/source-registry/eval-source-path.nix} "$nix_runtime/eval-source-path.nix"
  cp ${../lib/eval-source-manifests.nix} "$nix_runtime/eval-source-manifests.nix"
  cp ${../lib/source-registry.nix} "$nix_runtime/source-registry.nix"
  cp -R ${pkgs.path + "/lib"} "$nix_runtime/nixpkgs-lib"
  export AGENT_SKILLS_SOURCE_NORMALIZER="$nix_runtime/eval-source-manifests.nix"
  export AGENT_SKILLS_NIXPKGS_LIB="$nix_runtime/nixpkgs-lib"
  export AGENT_SKILLS_SOURCE_REGISTRY_LIB="$nix_runtime/source-registry.nix"

  ${pkgs.bash}/bin/bash ${./fixtures/source-registry/local-npins-test.sh} \
    "$out" \
    "$nix_runtime/eval-source-path.nix" \
    "$nix_runtime/nixpkgs-lib" \
    "$nix_runtime/source-registry.nix"
''
