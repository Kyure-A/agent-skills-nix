# Test targets default merging behaviour
{ pkgs, agentLib }:

pkgs.runCommand "agent-skills-targets-test" {} ''
  set -e

  echo "=== Testing targetsFor with default targets ==="

  # Test that default targets include standard, claude, copilot, antigravity, gemini, cursor, and windsurf
  ${pkgs.lib.concatMapStringsSep "\n" (name: ''
    echo "Checking default target: ${name}"
    test "${agentLib.defaultTargets.${name}.dest}" != "" || { echo "Missing dest for ${name}"; exit 1; }
    test "${agentLib.defaultTargets.${name}.structure}" = "symlink-tree" || { echo "Wrong structure for ${name}"; exit 1; }
  '') ["agents" "claude" "copilot" "antigravity" "gemini" "cursor" "windsurf"]}

  echo ""
  echo "=== Testing default local targets ==="

  ${pkgs.lib.concatMapStringsSep "\n" (name: ''
    echo "Checking default local target: ${name}"
    test "${agentLib.defaultLocalTargets.${name}.dest}" != "" || { echo "Missing local dest for ${name}"; exit 1; }
    test "${agentLib.defaultLocalTargets.${name}.structure}" = "copy-tree" || { echo "Wrong local structure for ${name}"; exit 1; }
  '') ["agents" "claude" "copilot" "antigravity" "gemini" "cursor" "windsurf"]}

  echo ""
  echo "=== Testing targetsFor filtering ==="

  # Test that targetsFor filters correctly
  # All targets enabled by default
  ${let
    activeTargets = agentLib.targetsFor { targets = agentLib.defaultTargets; system = pkgs.system; };
  in ''
    test "${toString (builtins.length (builtins.attrNames activeTargets))}" = "7" || { echo "Expected 7 active targets"; exit 1; }
  ''}

  echo ""
  echo "All targets tests passed!"
  mkdir -p "$out"
  touch "$out/ok"
''
