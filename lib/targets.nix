{ lib }:

let
  inherit (builtins)
    elem
    ;

  inherit (lib)
    filterAttrs
    ;

  # Filter targets by enabled flag and system selector.
  targetsFor = { targets, system }:
    filterAttrs
      (_: t:
        let systems = t.systems or [ ];
        in (t.enable or true) && (systems == [ ] || elem system systems)
      )
      targets;

  # Default global targets for user-level installation.
  # Targets are opt-in by default; enable explicitly per target.
  # Canonical path docs live in README.md#default-target-paths.
  defaultTargets = {
    agents = {
      dest = "$HOME/.agents/skills";
      structure = "symlink-tree";
      enable = false;
      systems = [ ];
    };
    codex = {
      dest = "\${CODEX_HOME:-$HOME/.codex}/skills";
      structure = "symlink-tree";
      enable = false;
      systems = [ ];
    };
    opencode = {
      dest = "$HOME/.config/opencode/skills";
      structure = "symlink-tree";
      enable = false;
      systems = [ ];
    };
    claude = {
      dest = "\${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills";
      structure = "symlink-tree";
      enable = false;
      systems = [ ];
    };
    copilot = {
      dest = "$HOME/.copilot/skills";
      structure = "symlink-tree";
      enable = false;
      systems = [ ];
    };
    cursor = {
      dest = "$HOME/.cursor/skills";
      structure = "symlink-tree";
      enable = false;
      systems = [ ];
    };
    windsurf = {
      dest = "$HOME/.codeium/windsurf/skills";
      structure = "symlink-tree";
      enable = false;
      systems = [ ];
    };
    antigravity = {
      dest = "$HOME/.gemini/antigravity/skills";
      structure = "symlink-tree";
      enable = false;
      systems = [ ];
    };
    gemini = {
      dest = "$HOME/.gemini/skills";
      structure = "symlink-tree";
      enable = false;
      systems = [ ];
    };
    pi = {
      dest = "$HOME/.pi/agent/skills";
      structure = "symlink-tree";
      enable = false;
      systems = [ ];
    };
  };

  # Default local targets for project-local skill installation.
  # Targets are opt-in by default; enable explicitly per target.
  # Uses relative paths for project-local installation (not global env vars).
  defaultLocalTargets = {
    agents = { dest = ".agents/skills"; structure = "copy-tree"; enable = false; systems = [ ]; };
    codex = { dest = ".codex/skills"; structure = "copy-tree"; enable = false; systems = [ ]; };
    opencode = { dest = ".opencode/skills"; structure = "copy-tree"; enable = false; systems = [ ]; };
    claude = { dest = ".claude/skills"; structure = "copy-tree"; enable = false; systems = [ ]; };
    copilot = { dest = ".github/skills"; structure = "copy-tree"; enable = false; systems = [ ]; };
    cursor = { dest = ".cursor/skills"; structure = "copy-tree"; enable = false; systems = [ ]; };
    windsurf = { dest = ".windsurf/skills"; structure = "copy-tree"; enable = false; systems = [ ]; };
    antigravity = { dest = ".agents/skills"; structure = "copy-tree"; enable = false; systems = [ ]; };
    gemini = { dest = ".gemini/skills"; structure = "copy-tree"; enable = false; systems = [ ]; };
    pi = { dest = ".pi/skills"; structure = "copy-tree"; enable = false; systems = [ ]; };
  };

  # Default exclude patterns for rsync synchronization.
  # Excludes "/.system" (root-level only) to allow agents (Codex, etc.) to manage their own system skills.
  # The leading "/" ensures only the top-level .system is excluded, not .system dirs inside skills.
  defaultExcludePatterns = [ "/.system" ];

  # Build an executable that delegates synchronization to the shared runtime.
  # Nix is responsible only for filtering targets and serializing configuration;
  # destination expansion and filesystem safety checks happen at runtime.
  mkSyncProgram =
    { pkgs
    , bundle
    , targets
    , system ? pkgs.stdenv.hostPlatform.system
    , mode ? "global"
    , programName ? (if mode == "local" then "skills-install-local" else "skills-install")
    , allowOverrides ? false
    , overrideEnvVar ? (if mode == "local" then "AGENT_SKILLS_LOCAL_DESTS" else "AGENT_SKILLS_DESTS")
    , overrideStructure ? (if mode == "local" then "copy-tree" else "symlink-tree")
    , excludePatterns ? defaultExcludePatterns
    ,
    }:
    let
      activeTargets = targetsFor { inherit targets system; };
      config = {
        schemaVersion = 1;
        inherit mode excludePatterns;
        bundle = "${bundle}";
        targets = lib.mapAttrsToList
          (name: target: {
            inherit name;
            structure = target.structure or (if mode == "local" then "copy-tree" else "symlink-tree");
            dest = target.dest;
          })
          activeTargets;
        overrides = {
          enabled = allowOverrides;
          envVar = overrideEnvVar;
          structure = overrideStructure;
        };
      };
      configFile = pkgs.writeText "${programName}-config.json" (builtins.toJSON config);
    in
    pkgs.writeShellApplication {
      name = programName;
      runtimeInputs = [
        pkgs.coreutils
        pkgs.jq
        pkgs.rsync
      ];
      text = ''
        exec ${pkgs.bash}/bin/bash ${../scripts/sync.sh} ${configFile} "$@"
      '';
    };

  # Project-local synchronization uses the same runtime with local path guards
  # and the established local override environment variables.
  mkLocalInstallProgram =
    { pkgs
    , bundle
    , targets ? defaultLocalTargets
    , system ? pkgs.stdenv.hostPlatform.system
    , excludePatterns ? defaultExcludePatterns
    ,
    }:
    mkSyncProgram {
      inherit pkgs bundle targets system excludePatterns;
      mode = "local";
      programName = "skills-install-local";
      allowOverrides = true;
      overrideEnvVar = "AGENT_SKILLS_LOCAL_DESTS";
      overrideStructure = "copy-tree";
    };

  # Compatibility wrappers for consumer flakes using the original public API.
  # New code should use mkSyncProgram/mkLocalInstallProgram directly.
  mkSyncScript = args:
    let
      syncProgram = mkSyncProgram args;
    in
    ''
      ${syncProgram}/bin/skills-install
    '';

  mkLocalInstallScript = args: mkLocalInstallProgram args;

  # Create a shellHook string for use in devShells.
  # Automatically installs skills when entering the dev shell.
  # Set quiet when the shell is entered often, e.g. through direnv, where the
  # per-target progress lines would otherwise print at every shell entry;
  # warnings and failures still reach stderr.
  mkShellHook = { pkgs, bundle, targets ? defaultLocalTargets, excludePatterns ? defaultExcludePatterns, quiet ? false }:
    let
      installProgram = mkLocalInstallProgram { inherit pkgs bundle targets excludePatterns; };
    in
    ''
      ${lib.optionalString quiet "AGENT_SKILLS_QUIET=1 "}${installProgram}/bin/skills-install-local
    '';
in
{
  inherit
    defaultExcludePatterns
    defaultLocalTargets
    defaultTargets
    mkLocalInstallProgram
    mkLocalInstallScript
    mkShellHook
    mkSyncProgram
    mkSyncScript
    targetsFor
    ;
}
