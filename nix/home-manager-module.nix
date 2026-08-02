{ inputs }:

import ../modules/home-manager/agent-skills.nix {
  inherit inputs;
  lib = inputs.nixpkgs.lib;
}
