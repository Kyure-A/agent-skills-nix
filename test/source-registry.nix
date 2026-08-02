{ pkgs, agentLib }:

let
  fixtureRoot = ./fixtures/source-registry;
  sourceRegistryLib = import ../lib/source-registry.nix { lib = pkgs.lib; };
  manifests = agentLib.loadSourceManifests (fixtureRoot + "/manifests");
  fixturePaths = {
    alpha = ./fixtures/nested-skills;
    release = ./fixtures/rewrite-skill;
    zeta = ./fixtures/test-skill;
  };
  sources = agentLib.sourcesFromLock {
    manifestsDir = fixtureRoot + "/manifests";
    lockFile = fixtureRoot + "/lock.json";
    fetchPin = name: _pin: fixturePaths.${name};
  };
  catalog = agentLib.discoverCatalog sources;

  mismatchedLock = builtins.toFile "agent-skills-mismatched-sources-lock.json" (builtins.toJSON {
    schemaVersion = 1;
    manifests.alpha = manifests.alpha;
    npins = {
      version = 8;
      pins.alpha = { };
    };
  });
  wrongVersionLock = builtins.toFile "agent-skills-wrong-version-sources-lock.json" (builtins.toJSON {
    schemaVersion = 1;
    inherit manifests;
    npins = {
      version = 7;
      pins = { };
    };
  });
  staleManifestLock = builtins.toFile "agent-skills-stale-manifest-sources-lock.json" (builtins.toJSON {
    schemaVersion = 1;
    manifests = manifests // {
      alpha = manifests.alpha // {
        pin = manifests.alpha.pin // { branch = "stale"; };
      };
    };
    npins = (builtins.fromJSON (builtins.readFile (fixtureRoot + "/lock.json"))).npins;
  });

  invalidManifest = builtins.tryEval (builtins.deepSeq (agentLib.loadSourceManifests (fixtureRoot + "/invalid-manifests")) true);
  mismatched = builtins.tryEval (builtins.deepSeq
    (agentLib.sourcesFromLock {
      manifestsDir = fixtureRoot + "/manifests";
      lockFile = mismatchedLock;
      fetchPin = _: _: fixtureRoot;
    })
    true);
  wrongVersion = builtins.tryEval (builtins.deepSeq
    (agentLib.sourcesFromLock {
      manifestsDir = fixtureRoot + "/manifests";
      lockFile = wrongVersionLock;
      fetchPin = _: _: fixtureRoot;
    })
    true);
  staleManifest = builtins.tryEval (builtins.deepSeq
    (agentLib.sourcesFromLock {
      manifestsDir = fixtureRoot + "/manifests";
      lockFile = staleManifestLock;
      fetchPin = _: _: fixtureRoot;
    })
    true);

  gitTarballPlan = sourceRegistryLib.__internal.npinsPinFetchPlan "git-tarball" {
    type = "Git";
    hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
    revision = "0000000000000000000000000000000000000000";
    submodules = false;
    url = "https://example.invalid/source.tar.gz";
  };
  releaseGitPlan = sourceRegistryLib.__internal.npinsPinFetchPlan "release-git" {
    type = "GitRelease";
    hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
    revision = "0000000000000000000000000000000000000000";
    submodules = false;
    url = null;
    repository = {
      type = "Git";
      url = "https://example.invalid/source.git";
    };
  };
  urlTarballPlan = sourceRegistryLib.__internal.npinsPinFetchPlan "url-tarball" {
    type = "Url";
    hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
    unpack = true;
    url = "https://example.invalid/source.tar.gz";
  };

  _manifestAssertions =
    assert builtins.attrNames manifests == [ "alpha" "release" "zeta" ];
    assert manifests.alpha.pin.type == "git";
    assert manifests.alpha.pin.branch == "main; touch PWNED";
    assert manifests.alpha.filter.maxDepth == 3;
    assert sources.alpha.path == fixturePaths.alpha;
    assert sources.zeta.idPrefix == "second";
    assert catalog ? "fixture/cat-a/skill-1";
    assert catalog ? "fixture/cat-a/skill-2";
    assert catalog ? "release/release";
    assert catalog ? "second/zeta";
    assert !invalidManifest.success;
    assert !mismatched.success;
    assert !wrongVersion.success;
    assert !staleManifest.success;
    assert gitTarballPlan.fetcher == "tarball";
    assert releaseGitPlan.fetcher == "git";
    assert releaseGitPlan.args.url == "https://example.invalid/source.git";
    assert urlTarballPlan.fetcher == "tarball";
    true;

  fakeNpins = pkgs.writeShellApplication {
    name = "npins";
    runtimeInputs = [ pkgs.coreutils pkgs.jq ];
    text = builtins.readFile (fixtureRoot + "/fake-npins.sh");
  };
  lockProgram = agentLib.mkSourceLockProgram {
    inherit pkgs;
    npins = fakeNpins;
  };
in
assert _manifestAssertions;
pkgs.runCommand "agent-skills-source-registry-test"
{
  nativeBuildInputs = [ pkgs.coreutils pkgs.jq ];
} ''
  work="$TMPDIR/source registry"
  mkdir -p "$work/registry"
  cp -R ${fixtureRoot + "/manifests"} "$work/registry/sources"
  chmod -R u+w "$work"
  cd "$work"

  ${lockProgram}/bin/skills-sources-lock
  test -f registry/sources.lock.json
  test "$(jq -r .schemaVersion registry/sources.lock.json)" = 1
  test "$(jq -r .npins.version registry/sources.lock.json)" = 8
  test "$(jq -r '.npins.pins | keys | join(",")' registry/sources.lock.json)" = alpha,release,zeta
  test "$(jq -r .npins.pins.alpha.branch registry/sources.lock.json)" = 'main; touch PWNED'
  test "$(jq -r .npins.pins.release.type registry/sources.lock.json)" = GitRelease
  test "$(jq -r .manifests.alpha.pin.branch registry/sources.lock.json)" = 'main; touch PWNED'
  test ! -e PWNED

  cp registry/sources.lock.json first-lock.json
  ${lockProgram}/bin/skills-sources-lock
  cmp first-lock.json registry/sources.lock.json

  mkdir registry/lock-directory
  if ${lockProgram}/bin/skills-sources-lock --lock-file registry/lock-directory; then
    echo "expected directory lock path to fail" >&2
    exit 1
  fi
  test ! -e registry/lock-directory/sources.canonical.json

  if ${lockProgram}/bin/skills-sources-lock \
    --manifest-dir ${fixtureRoot + "/invalid-value-manifests"}; then
    echo "expected Nix manifest type validation to fail" >&2
    exit 1
  fi
  cmp first-lock.json registry/sources.lock.json

  if ${lockProgram}/bin/skills-sources-lock \
    --manifest-dir ${fixtureRoot + "/failing-manifests"}; then
    echo "expected failing source resolution to fail" >&2
    exit 1
  fi
  cmp first-lock.json registry/sources.lock.json

  mkdir -p "$out"
  cp registry/sources.lock.json "$out/lock.json"
''
