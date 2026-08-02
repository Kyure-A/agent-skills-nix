# Checks for agent-skills
{ pkgs
, agentLib
, hmLib
, agentSkillsModule
, bundle
}:

{
  skills = pkgs.runCommand "agent-skills-checks" {} ''
    test -d ${bundle}
    mkdir -p "$out"
    touch "$out/ok"
  '';

  discover = import ./discover.nix {
    inherit pkgs agentLib;
  };

  transform-packages = import ./transform-packages.nix {
    inherit pkgs agentLib;
  };

  targets = import ./targets.nix {
    inherit pkgs agentLib;
  };

  local-install-script = import ./local-install-script.nix {
    inherit pkgs agentLib;
  };

  sync-shellcheck = pkgs.runCommand "agent-skills-sync-shellcheck" {
    nativeBuildInputs = [ pkgs.shellcheck ];
  } ''
    shellcheck ${../scripts/sync.sh}
    mkdir -p "$out"
  '';

  compatibility = import ./compatibility.nix {
    inherit pkgs agentLib bundle;
  };

  home-manager-warnings = import ./home-manager-warnings.nix {
    inherit pkgs hmLib agentSkillsModule;
  };

  home-manager-input-source = import ./home-manager-input-source.nix {
    inherit pkgs hmLib agentSkillsModule;
  };
}
