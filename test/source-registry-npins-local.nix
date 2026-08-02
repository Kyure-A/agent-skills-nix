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
  export XDG_CACHE_HOME="$TMPDIR/cache"
  mkdir -p "$XDG_CACHE_HOME"
  ${pkgs.bash}/bin/bash ${./fixtures/source-registry/local-npins-test.sh} \
    "$out" \
    ${./fixtures/source-registry/eval-source-path.nix} \
    ${pkgs.path + "/lib"} \
    ${../lib/source-registry.nix}
''
