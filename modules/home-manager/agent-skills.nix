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
  agentLib = agentLibFor (args.inputs or { });

  activeTargets = agentLib.targetsFor { targets = cfg.targets; system = pkgs.stdenv.hostPlatform.system; };
  anyTargetEnabled = lib.any (t: t.enable or false) (builtins.attrValues cfg.targets);

  linkTargets = lib.filterAttrs (_: t: t.structure == "link") activeTargets;
  syncTargets = lib.filterAttrs (_: t: t.structure != "link") activeTargets;

  syncProgram = bundle: agentLib.mkSyncProgram {
    inherit pkgs bundle;
    # Keep disabled and link target names available for allowlist validation.
    targets = lib.mapAttrs
      (_: t: t // {
        enable = t.enable && t.structure != "link";
      })
      cfg.targets;
    system = pkgs.stdenv.hostPlatform.system;
    excludePatterns = cfg.excludePatterns;
  };

  # home.file does not shell-expand its paths.
  staticDestFor = dest:
    if lib.strings.hasPrefix "\${" dest || lib.strings.hasPrefix "$" dest then
      let
        homeRelativeFallback = builtins.match ".*:-\\$HOME/([^}]+)[}](.*)" dest;
      in
      if homeRelativeFallback != null then
        builtins.trace "agent-skills: 'link' structure does not support shell variables, using fallback path"
          (builtins.elemAt homeRelativeFallback 0) + (builtins.elemAt homeRelativeFallback 1)
      else
        throw "agent-skills: 'link' structure requires a static path, got '${dest}'. Use 'symlink-tree' or 'copy-tree' for dynamic paths."
    else
      dest;
in
{
  imports = [ (import ../common.nix { inherit inputs lib; }) ];

  config = lib.mkIf cfg.enable (
    let
      bundle = cfg.bundlePath;
    in
    {
      warnings = lib.optionals (!anyTargetEnabled) [
        "agent-skills: programs.agent-skills.enable is true, but no install targets are enabled. Set targets.<name>.enable = true (for example, targets.claude.enable = true)."
      ];

      home.activation.agent-skills =
        lib.mkIf (syncTargets != { }) (lib.hm.dag.entryAfter [ "writeBoundary" ] ''
          ${syncProgram bundle}/bin/skills-install
        '');

      home.file = lib.mkMerge (lib.mapAttrsToList
        (name: t: {
          ${staticDestFor t.dest} = {
            source = cfg.targetBundlePaths.${name};
            recursive = true;
            force = true;
          };
        })
        linkTargets);
    }
  );
}
