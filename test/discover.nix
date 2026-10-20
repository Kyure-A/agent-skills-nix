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

  sourceRootSymlinkSources = {
    source-root-symlinks = {
      path = ./fixtures/source-root-symlinks;
      filter.maxDepth = 1;
    };
  };

  multiSkillSharedRootSources = {
    multi-skill-shared = {
      path = ./fixtures/multi-skill-shared-root;
      filter.maxDepth = 1;
    };
  };

  escapingSkillSymlinkSources = {
    escaping-skill-symlink = {
      path = ./fixtures/escaping-skill-source;
      filter.maxDepth = 1;
    };
  };

  nestedCatalog = agentLib.discoverCatalog nestedSources;
  flatCatalog = agentLib.discoverCatalog flatSources;
  restrictedCatalog = agentLib.discoverCatalog restrictedSources;
  sourceRootSymlinkCatalog = agentLib.discoverCatalog sourceRootSymlinkSources;
  multiSkillSharedRootCatalog = agentLib.discoverCatalog multiSkillSharedRootSources;
  escapingSkillSymlinkCatalog = agentLib.discoverCatalog escapingSkillSymlinkSources;

  # Unsafe traversal in explicit skill `path` must be rejected at selection time.
  unsafePathSelection = builtins.tryEval (builtins.deepSeq
    (agentLib.selectSkills {
      catalog = {};
      allowlist = [];
      sources = flatSources;
      skills = {
        evil = { from = "flat"; path = "../escape"; };
      };
    })
    true);

  # Unsafe traversal in source `subdir` must be rejected at discovery time.
  unsafeSubdirDiscovery = builtins.tryEval (builtins.deepSeq
    (agentLib.discoverCatalog {
      bad = {
        path = ./fixtures/nested-skills;
        subdir = "../outside-shared";
      };
    })
    true);

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

  prefixedSources = {
    source-a = {
      path = ./fixtures/nested-skills;
      idPrefix = "alpha";
    };
    source-b = {
      path = ./fixtures/nested-skills;
      idPrefix = "beta";
    };
  };
  prefixedCatalog = agentLib.discoverCatalog prefixedSources;
  prefixedIds = builtins.attrNames prefixedCatalog;

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

  sourceRootSymlinkAllowlist = agentLib.allowlistFor {
    catalog = sourceRootSymlinkCatalog;
    sources = sourceRootSymlinkSources;
    enableAll = [ "source-root-symlinks" ];
  };
  sourceRootSymlinkSelection = agentLib.selectSkills {
    catalog = sourceRootSymlinkCatalog;
    allowlist = sourceRootSymlinkAllowlist;
    skills = {};
    sources = sourceRootSymlinkSources;
  };
  sourceRootSymlinkBundle = agentLib.mkBundle {
    inherit pkgs;
    selection = sourceRootSymlinkSelection;
    name = "agent-skills-test-source-root-symlinks-bundle";
  };

  multiSkillSharedRootAllowlist = agentLib.allowlistFor {
    catalog = multiSkillSharedRootCatalog;
    sources = multiSkillSharedRootSources;
    enableAll = [ "multi-skill-shared" ];
  };
  multiSkillSharedRootSelection = agentLib.selectSkills {
    catalog = multiSkillSharedRootCatalog;
    allowlist = multiSkillSharedRootAllowlist;
    skills = {};
    sources = multiSkillSharedRootSources;
  };
  multiSkillSharedRootBundle = agentLib.mkBundle {
    inherit pkgs;
    selection = multiSkillSharedRootSelection;
    name = "agent-skills-test-multi-skill-shared-root-bundle";
  };
  escapingSkillSymlinkAllowlist = agentLib.allowlistFor {
    catalog = escapingSkillSymlinkCatalog;
    sources = escapingSkillSymlinkSources;
    enableAll = [ "escaping-skill-symlink" ];
  };
  escapingSkillSymlinkSelection = agentLib.selectSkills {
    catalog = escapingSkillSymlinkCatalog;
    allowlist = escapingSkillSymlinkAllowlist;
    skills = {};
    sources = escapingSkillSymlinkSources;
  };
  escapingSkillSymlinkBundle = agentLib.mkBundle {
    inherit pkgs;
    selection = escapingSkillSymlinkSelection;
    name = "agent-skills-test-escaping-skill-symlink-bundle";
  };
  escapingSkillSymlinkFailure = pkgs.testers.testBuildFailure escapingSkillSymlinkBundle;

  nestedIds = builtins.attrNames nestedCatalog;
  flatIds = builtins.attrNames flatCatalog;
  restrictedIds = builtins.attrNames restrictedCatalog;
  sourceRootSymlinkIds = builtins.attrNames sourceRootSymlinkCatalog;
  multiSkillSharedRootIds = builtins.attrNames multiSkillSharedRootCatalog;
  escapingSkillSymlinkIds = builtins.attrNames escapingSkillSymlinkCatalog;
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
  echo "=== Test 4: idPrefix namespaces duplicate discovered IDs ==="
  prefixed_count=${toString (builtins.length prefixedIds)}
  test "$prefixed_count" -eq "4" || {
    echo "Expected 4 prefixed skills, got $prefixed_count"
    exit 1
  }
  ${if prefixedCatalog ? "alpha/cat-a/skill-1" then ''
    echo "ID alpha/cat-a/skill-1 found"
  '' else ''
    echo "ERROR: ID alpha/cat-a/skill-1 not found"
    exit 1
  ''}
  ${if prefixedCatalog ? "beta/cat-a/skill-1" then ''
    echo "ID beta/cat-a/skill-1 found"
  '' else ''
    echo "ERROR: ID beta/cat-a/skill-1 not found"
    exit 1
  ''}
  echo "Test 4 passed!"

  echo ""
  echo "=== Test 5: Explicit maxDepth=1 restricts discovery ==="
  restricted_count=${toString (builtins.length restrictedIds)}
  # maxDepth=1 starting from nested-skills root: depth 0 scans root (no SKILL.md),
  # depth 1 scans cat-a (no SKILL.md), but does NOT recurse into skill-1/skill-2.
  # So we expect 0 skills found with maxDepth=1.
  test "$restricted_count" -eq "0" || {
    echo "Expected 0 skills with maxDepth=1, got $restricted_count"
    exit 1
  }
  echo "maxDepth=1 correctly restricted discovery to 0 skills"
  echo "Test 5 passed!"

  echo ""
  echo "=== Test 6: Default (null) discovers at arbitrary depth ==="
  # This is the same as Test 1 but confirms that default behavior (no filter.maxDepth set)
  # finds skills at depth > 1
  test "$actual_count" -ge "2" || {
    echo "Default maxDepth should find nested skills, got $actual_count"
    exit 1
  }
  echo "Default maxDepth=null correctly discovered $actual_count nested skills"
  echo "Test 6 passed!"

  echo ""
  echo "=== Test 7: Bundle with nested IDs creates correct directory structure ==="
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
  echo "Test 7 passed!"

  echo ""
  echo "=== Test 8: Path-traversal rejection in subdir and explicit path ==="
  ${if unsafePathSelection.success then ''
    echo "ERROR: explicit skill path '../escape' should have been rejected"
    exit 1
  '' else ''
    echo "Correctly rejected unsafe explicit skill path"
  ''}
  ${if unsafeSubdirDiscovery.success then ''
    echo "ERROR: source subdir '../outside-shared' should have been rejected"
    exit 1
  '' else ''
    echo "Correctly rejected unsafe source subdir"
  ''}
  echo "Test 8 passed!"

  echo ""
  echo "=== Test 9: Bundle preserves source-root symlink context ==="
  source_root_count=${toString (builtins.length sourceRootSymlinkIds)}
  test "$source_root_count" -eq "1" || {
    echo "Expected 1 source-root symlink skill, got $source_root_count"
    exit 1
  }
  ${if sourceRootSymlinkCatalog ? "skill-a" then ''
    echo "ID skill-a found"
  '' else ''
    echo "ERROR: ID skill-a not found"
    exit 1
  ''}
  test -f "${sourceRootSymlinkBundle}/skill-a/shared/data.txt" || {
    echo "ERROR: internal source-root symlink is not readable"
    exit 1
  }
  grep -q "shared fixture data" "${sourceRootSymlinkBundle}/skill-a/shared/data.txt" || {
    echo "ERROR: internal source-root symlink content is not readable"
    exit 1
  }
  ! test -L "${sourceRootSymlinkBundle}/skill-a/outside" || {
    echo "ERROR: escaping symlink should not be included"
    exit 1
  }
  ! test -e "${sourceRootSymlinkBundle}/skill-a/outside/secret.txt" || {
    echo "ERROR: escaping symlink target should not be readable"
    exit 1
  }
  # `chain` is a symlink to `outside` (whose target text escapes). rsync drops
  # `outside`, then the dangling-symlink post-pass must drop `chain` too so it
  # is neither present nor dangling.
  ! test -L "${sourceRootSymlinkBundle}/skill-a/chain" || {
    echo "ERROR: chained-escape symlink should not be included"
    exit 1
  }
  ! test -e "${sourceRootSymlinkBundle}/skill-a/chain" || {
    echo "ERROR: chained-escape symlink target should not be reachable"
    exit 1
  }
  echo "Source-root symlink context is preserved and escaping/chained symlinks are excluded"
  echo "Test 9 passed!"

  echo ""
  echo "=== Test 10: Two skills sharing one source root are deduped ==="
  multi_count=${toString (builtins.length multiSkillSharedRootIds)}
  test "$multi_count" -eq "2" || {
    echo "Expected 2 skills in shared-root fixture, got $multi_count"
    exit 1
  }
  test -f "${multiSkillSharedRootBundle}/skill-a/SKILL.md" || {
    echo "ERROR: skill-a/SKILL.md missing"
    exit 1
  }
  test -f "${multiSkillSharedRootBundle}/skill-b/SKILL.md" || {
    echo "ERROR: skill-b/SKILL.md missing"
    exit 1
  }
  test -f "${multiSkillSharedRootBundle}/skill-a/shared/data.txt" || {
    echo "ERROR: skill-a cannot reach shared/data.txt"
    exit 1
  }
  test -f "${multiSkillSharedRootBundle}/skill-b/shared/data.txt" || {
    echo "ERROR: skill-b cannot reach shared/data.txt"
    exit 1
  }
  # Dedup proof: both skills' `shared/data.txt` files must resolve to the
  # *same* safe-tree store path (one rsync derivation for the whole root, not
  # one per skill).
  a_path="$(readlink -f "${multiSkillSharedRootBundle}/skill-a/shared/data.txt")"
  b_path="$(readlink -f "${multiSkillSharedRootBundle}/skill-b/shared/data.txt")"
  test "$a_path" = "$b_path" || {
    echo "ERROR: skills sharing a source root should resolve to the same safe-tree path"
    echo "  skill-a: $a_path"
    echo "  skill-b: $b_path"
    exit 1
  }
  echo "Shared source root produced a single safe-tree derivation"
  echo "Test 10 passed!"

  echo ""
  echo "=== Test 11: Escaping symlink skill directory fails clearly ==="
  escaping_count=${toString (builtins.length escapingSkillSymlinkIds)}
  test "$escaping_count" -eq "1" || {
    echo "Expected 1 escaping symlink skill, got $escaping_count"
    exit 1
  }
  ${if escapingSkillSymlinkCatalog ? "escaping-skill" then ''
    echo "ID escaping-skill found"
  '' else ''
    echo "ERROR: ID escaping-skill not found"
    exit 1
  ''}
  grep -F "agent-skills: selected skill escaping-skill is missing SKILL.md in the safe source tree" "${escapingSkillSymlinkFailure}/testBuildFailure.log" || {
    echo "ERROR: escaping symlink skill failure message not found"
    echo "---- testBuildFailure.log ----"
    cat "${escapingSkillSymlinkFailure}/testBuildFailure.log"
    echo "------------------------------"
    exit 1
  }
  echo "Escaping symlink skill directory fails during bundle build"
  echo "Test 11 passed!"

  echo ""
  echo "All discover tests passed!"
  mkdir -p "$out"
  touch "$out/ok"
''
