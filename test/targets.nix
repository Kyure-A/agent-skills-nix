# Test targets default merging behaviour
{ pkgs, agentLib }:

pkgs.runCommand "agent-skills-targets-test" {} ''
  set -e

  echo "=== Testing targetsFor with default targets ==="

  # Test that default targets include agents, codex, claude, copilot, antigravity, gemini, cursor, and windsurf
  ${pkgs.lib.concatMapStringsSep "\n" (name: ''
    echo "Checking default target: ${name}"
    test "${agentLib.defaultTargets.${name}.dest}" != "" || { echo "Missing dest for ${name}"; exit 1; }
    test "${agentLib.defaultTargets.${name}.structure}" = "symlink-tree" || { echo "Wrong structure for ${name}"; exit 1; }
    test "${if agentLib.defaultTargets.${name}.enable then "true" else "false"}" = "false" || { echo "Expected ${name}.enable=false by default"; exit 1; }
  '') ["agents" "codex" "claude" "copilot" "antigravity" "gemini" "cursor" "windsurf"]}

  echo ""
  echo "=== Testing default local targets ==="

  ${pkgs.lib.concatMapStringsSep "\n" (name: ''
    echo "Checking default local target: ${name}"
    test "${agentLib.defaultLocalTargets.${name}.dest}" != "" || { echo "Missing local dest for ${name}"; exit 1; }
    test "${agentLib.defaultLocalTargets.${name}.structure}" = "copy-tree" || { echo "Wrong local structure for ${name}"; exit 1; }
    test "${if agentLib.defaultLocalTargets.${name}.enable then "true" else "false"}" = "false" || { echo "Expected local ${name}.enable=false by default"; exit 1; }
  '') ["agents" "codex" "claude" "copilot" "antigravity" "gemini" "cursor" "windsurf"]}

  echo ""
  echo "=== Testing targetsFor filtering ==="

  # Test that targetsFor filters correctly
  # All targets are disabled by default
  ${let
    activeTargets = agentLib.targetsFor { targets = agentLib.defaultTargets; system = pkgs.stdenv.hostPlatform.system; };
  in ''
    test "${toString (builtins.length (builtins.attrNames activeTargets))}" = "0" || { echo "Expected 0 active targets"; exit 1; }
  ''}

  # Enabling a single target should pick current default destination/structure
  ${let
    enabledClaudeTargets = agentLib.targetsFor {
      targets = agentLib.defaultTargets // {
        claude = agentLib.defaultTargets.claude // { enable = true; };
      };
      system = pkgs.stdenv.hostPlatform.system;
    };
  in ''
    test "${toString (builtins.length (builtins.attrNames enabledClaudeTargets))}" = "1" || { echo "Expected 1 active target when only claude is enabled"; exit 1; }
    test "${enabledClaudeTargets.claude.dest}" = "${agentLib.defaultTargets.claude.dest}" || { echo "Unexpected default claude.dest when enabled"; exit 1; }
    test "${enabledClaudeTargets.claude.structure}" = "symlink-tree" || { echo "Unexpected default claude.structure when enabled"; exit 1; }
  ''}

  echo ""
  echo "All targets tests passed!"
  mkdir -p "$out"
  touch "$out/ok"
''
