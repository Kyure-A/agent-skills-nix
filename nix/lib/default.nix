{ inputs, ... }:

let
  agentLib = import ../../lib {
    lib = inputs.nixpkgs.lib;
    inherit inputs;
  };
  defaultConfig = import ../default-config.nix { inherit agentLib; };
in
{
  agent-skills = agentLib // { inherit defaultConfig; };
}
