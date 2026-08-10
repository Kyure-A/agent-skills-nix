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

  agent-plugin = import ./agent-plugin.nix {
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

  source-lock-shellcheck = pkgs.runCommand "agent-skills-source-lock-shellcheck" {
    nativeBuildInputs = [ pkgs.shellcheck ];
  } ''
    shellcheck \
      ${../scripts/source-lock.sh} \
      ${./fixtures/source-registry/fake-npins.sh} \
      ${./fixtures/source-registry/local-npins-test.sh}
    mkdir -p "$out"
  '';

  source-registry = import ./source-registry.nix {
    inherit pkgs agentLib;
  };

  source-registry-npins-local = import ./source-registry-npins-local.nix {
    inherit pkgs agentLib;
  };

  home-manager-warnings = import ./home-manager-warnings.nix {
    inherit pkgs hmLib agentSkillsModule;
  };

  home-manager-input-source = import ./home-manager-input-source.nix {
    inherit pkgs hmLib agentSkillsModule;
  };
}
