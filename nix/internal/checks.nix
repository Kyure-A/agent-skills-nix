{ flake
, inputs
, perSystem
, pkgs
, ...
}:

import ../../test {
  inherit pkgs;
  agentLib = flake.lib.agent-skills;
  hmLib = inputs.home-manager.lib;
  agentSkillsModule = flake.homeManagerModules.default;
  bundle = perSystem.self.agent-skills-bundle;
}
