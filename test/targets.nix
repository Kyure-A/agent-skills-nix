# Test targets default merging behaviour
{ pkgs, agentLib }:

pkgs.runCommand "agent-skills-targets-test" {} ''
  set -e

  echo "=== Testing targetsFor with default targets ==="

  # Test that default targets include agents, claude, and copilot
  ${pkgs.lib.concatMapStringsSep "\n" (name: ''
    echo "Checking default target: ${name}"
    test "${agentLib.defaultTargets.${name}.dest}" != "" || { echo "Missing dest for ${name}"; exit 1; }
    test "${agentLib.defaultTargets.${name}.structure}" = "symlink-tree" || { echo "Wrong structure for ${name}"; exit 1; }
  '') ["agents" "claude" "copilot"]}

  echo ""
  echo "=== Testing targetsFor filtering ==="

  # Test that targetsFor filters correctly
  # All targets enabled by default
  ${let
    activeTargets = agentLib.targetsFor { targets = agentLib.defaultTargets; system = pkgs.system; };
  in ''
    test "${toString (builtins.length (builtins.attrNames activeTargets))}" = "3" || { echo "Expected 3 active targets"; exit 1; }
  ''}

  echo ""
  echo "All targets tests passed!"
  mkdir -p "$out"
  touch "$out/ok"
''
