{ flake, pkgs, ... }:

let
  agentLib = flake.lib.agent-skills;
  config = agentLib.defaultConfig;
  catalog = agentLib.discoverCatalog config.sources;
  allowlist = agentLib.allowlistFor {
    inherit catalog;
    sources = config.sources;
    enableAll = config.skills.enableAll;
    enable = config.skills.enable;
  };
  selection = agentLib.selectSkills {
    inherit catalog allowlist;
    skills = config.skills.explicit;
    sources = config.sources;
  };
in
agentLib.mkBundle {
  inherit pkgs selection;
  name = "agent-skills-bundle";
}
