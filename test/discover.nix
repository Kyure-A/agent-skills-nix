# Tests for recursive skill discovery and ID generation
{ pkgs, agentLib }:

let
  # Source pointing at the nested fixture (root contains no SKILL.md, but nested dirs do)
  nestedSources = {
    nested = {
      path = ./fixtures/nested-skills;
    };
  };

  # Source pointing at the flat fixture (single skill at root)
  flatSources = {
    flat = {
      path = ./fixtures/test-skill;
    };
  };

  # Source with explicit maxDepth = 1 to restrict discovery
  restrictedSources = {
    restricted = {
      path = ./fixtures/nested-skills;
      filter.maxDepth = 1;
    };
  };

  nestedCatalog = agentLib.discoverCatalog nestedSources;
  flatCatalog = agentLib.discoverCatalog flatSources;
  restrictedCatalog = agentLib.discoverCatalog restrictedSources;

  # Test duplicate detection: two sources with same subdir structure
  duplicateSources = {
    source-a = {
      path = ./fixtures/nested-skills;
    };
    source-b = {
      path = ./fixtures/nested-skills;
    };
  };
  testDuplicate = builtins.tryEval (builtins.deepSeq (agentLib.discoverCatalog duplicateSources) true);

  # Build a bundle with nested skills to verify directory structure
  nestedAllowlist = agentLib.allowlistFor {
    catalog = nestedCatalog;
    sources = nestedSources;
    enableAll = true;
  };
  nestedSelection = agentLib.selectSkills {
    catalog = nestedCatalog;
    allowlist = nestedAllowlist;
    skills = {};
    sources = nestedSources;
  };
  nestedBundle = agentLib.mkBundle {
    inherit pkgs;
    selection = nestedSelection;
    name = "agent-skills-test-nested-bundle";
  };

  nestedIds = builtins.attrNames nestedCatalog;
  flatIds = builtins.attrNames flatCatalog;
  restrictedIds = builtins.attrNames restrictedCatalog;
in
pkgs.runCommand "agent-skills-discover-test" {} ''
  set -e

  echo "=== Test 1: Recursive discovery finds nested skills ==="
  # nestedCatalog should have 2 skills: cat-a/skill-1 and cat-a/skill-2
  expected_count=2
  actual_count=${toString (builtins.length nestedIds)}
  test "$actual_count" -eq "$expected_count" || {
    echo "Expected $expected_count nested skills, got $actual_count"
    exit 1
  }
  echo "Found $actual_count nested skills as expected"

  # Check specific IDs
  ${if nestedCatalog ? "cat-a/skill-1" then ''
    echo "ID cat-a/skill-1 found"
  '' else ''
    echo "ERROR: ID cat-a/skill-1 not found"
    exit 1
  ''}
  ${if nestedCatalog ? "cat-a/skill-2" then ''
    echo "ID cat-a/skill-2 found"
  '' else ''
    echo "ERROR: ID cat-a/skill-2 not found"
    exit 1
  ''}
  echo "Test 1 passed!"

  echo ""
  echo "=== Test 2: Flat structure still works (backward compat) ==="
  flat_count=${toString (builtins.length flatIds)}
  test "$flat_count" -eq "1" || {
    echo "Expected 1 flat skill, got $flat_count"
    exit 1
  }
  ${if flatCatalog ? "flat" then ''
    echo "Flat skill ID 'flat' found as expected"
  '' else ''
    echo "ERROR: Flat skill ID 'flat' not found"
    exit 1
  ''}
  echo "Test 2 passed!"

  echo ""
  echo "=== Test 3: Duplicate ID detection ==="
  ${if testDuplicate.success then ''
    echo "ERROR: Duplicate detection should have failed but succeeded"
    exit 1
  '' else ''
    echo "Correctly rejected duplicate skill IDs"
  ''}
  echo "Test 3 passed!"

  echo ""
  echo "=== Test 4: Explicit maxDepth=1 restricts discovery ==="
  restricted_count=${toString (builtins.length restrictedIds)}
  # maxDepth=1 starting from nested-skills root: depth 0 scans root (no SKILL.md),
  # depth 1 scans cat-a (no SKILL.md), but does NOT recurse into skill-1/skill-2.
  # So we expect 0 skills found with maxDepth=1.
  test "$restricted_count" -eq "0" || {
    echo "Expected 0 skills with maxDepth=1, got $restricted_count"
    exit 1
  }
  echo "maxDepth=1 correctly restricted discovery to 0 skills"
  echo "Test 4 passed!"

  echo ""
  echo "=== Test 5: Default (null) discovers at arbitrary depth ==="
  # This is the same as Test 1 but confirms that default behavior (no filter.maxDepth set)
  # finds skills at depth > 1
  test "$actual_count" -ge "2" || {
    echo "Default maxDepth should find nested skills, got $actual_count"
    exit 1
  }
  echo "Default maxDepth=null correctly discovered $actual_count nested skills"
  echo "Test 5 passed!"

  echo ""
  echo "=== Test 6: Bundle with nested IDs creates correct directory structure ==="
  # Check that the bundle has the correct nested directory structure
  test -d "${nestedBundle}/cat-a" || {
    echo "ERROR: cat-a directory not found in bundle"
    exit 1
  }
  # The skills should be symlinks within the nested directory
  test -e "${nestedBundle}/cat-a/skill-1/SKILL.md" || {
    echo "ERROR: cat-a/skill-1/SKILL.md not found in bundle"
    exit 1
  }
  test -e "${nestedBundle}/cat-a/skill-2/SKILL.md" || {
    echo "ERROR: cat-a/skill-2/SKILL.md not found in bundle"
    exit 1
  }
  grep -q "# Skill 1" "${nestedBundle}/cat-a/skill-1/SKILL.md" || {
    echo "ERROR: Skill 1 content not correct"
    exit 1
  }
  grep -q "# Skill 2" "${nestedBundle}/cat-a/skill-2/SKILL.md" || {
    echo "ERROR: Skill 2 content not correct"
    exit 1
  }
  echo "Bundle nested directory structure is correct"
  echo "Test 6 passed!"

  echo ""
  echo "All discover tests passed!"
  mkdir -p "$out"
  touch "$out/ok"
''
