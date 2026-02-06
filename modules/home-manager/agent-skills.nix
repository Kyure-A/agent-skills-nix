{ inputs, lib, ... }:

let
  agentLibFor = inputsFromArgs:
    import ../../lib {
      inherit lib;
      inputs = inputs // inputsFromArgs;
    };
in
{ config, pkgs, lib, ... }@args:
let
  cfg = config.programs.agent-skills;
  agentLib = agentLibFor (args.inputs or {});

  activeTargets = agentLib.targetsFor { targets = cfg.targets; system = pkgs.system; };

  linkTargets = lib.filterAttrs (_: t: t.structure == "link") activeTargets;
  syncTargets = lib.filterAttrs (_: t: t.structure != "link") activeTargets;

  syncScript = bundle: agentLib.mkSyncScript {
    inherit pkgs bundle;
    targets = syncTargets;
    system = pkgs.system;
    excludePatterns = cfg.excludePatterns;
  };
in
{
  imports = [ (import ../common.nix { inherit inputs lib; }) ];

  config = lib.mkIf cfg.enable (let
    bundle = cfg.bundlePath;
  in {
    home.activation.agent-skills =
      lib.mkIf (syncTargets != {}) (lib.hm.dag.entryAfter [ "writeBoundary" ] (syncScript bundle));

    # Note: 'link' structure type uses home.file which requires a static path relative to $HOME.
    # Shell variable expansion in dest is not supported for 'link' type.
    # Use 'symlink-tree' or 'copy-tree' structure for dynamic paths with environment variables.
    home.file = lib.mkMerge (lib.mapAttrsToList (_: t:
      let
        # For link type, we need a static path relative to $HOME.
        # If dest contains shell variables, warn and extract the fallback path.
        staticDest =
          let
            dest = t.dest;
          in
            if lib.strings.hasPrefix "\${" dest || lib.strings.hasPrefix "$" dest then
              # dest contains shell variables, try to extract fallback path
              # e.g., "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills" -> ".claude/skills"
              let
                # Extract the fallback part after :- and before }
                fallbackMatch = builtins.match ".*:-\\$HOME/([^}]+)\\}(.*)" dest;
              in
                if fallbackMatch != null then
                  builtins.trace "agent-skills: 'link' structure does not support shell variables, using fallback path"
                  (builtins.elemAt fallbackMatch 0) + (builtins.elemAt fallbackMatch 1)
                else
                  throw "agent-skills: 'link' structure requires a static path, got '${dest}'. Use 'symlink-tree' or 'copy-tree' for dynamic paths."
            else
              dest;
      in {
        ${staticDest} = {
          source = bundle;
          recursive = true;
          force = true;
        };
      }
    ) linkTargets);
  });
}
