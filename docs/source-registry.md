# Source registry

[Back to README](../README.md) · [Runnable example](../examples/source-registry/README.md)

The optional source registry lets you pin skill repositories without declaring
each one as a flake input. It uses [npins](https://github.com/andir/npins) for
revision resolution and hashing. You can mix registry sources with direct
`sources.<name>.input` and `sources.<name>.path` declarations.

## Define source manifests

Keep one human-edited Nix manifest per source and commit the generated JSON
lock alongside them:

```text
registry/
├── sources/
│   ├── anthropic.nix
│   └── internal.nix
└── sources.lock.json
```

For a GitHub source that follows a branch:

```nix
# registry/sources/anthropic.nix
{
  pin = {
    type = "github";
    owner = "anthropics";
    repo = "skills";
    branch = "main";
  };

  subdir = "skills";
  idPrefix = "anthropic";
  filter.maxDepth = 2;
}
```

`pin.type` supports these source kinds:

| Type | Required fields | Optional fields |
|------|-----------------|-----------------|
| `github` | `owner`, `repo` | `branch`, `at`, `submodules`, `preReleases`, `versionUpperBound`, `releasePrefix` |
| `git` | `url` | The same Git options, plus `forge` |
| `tarball` | `url` | `mutable` |

If `branch` is omitted, npins follows releases and writes a `GitRelease` pin.
The remaining manifest fields (`subdir`, `idPrefix`, and `filter`) use the same
discovery settings as direct sources.

## Load the lock

`sourcesFromLock` returns ordinary path-backed sources that you can pass to
`discoverCatalog`, `selectSkills`, or Home Manager:

```nix
sources = agentLib.sourcesFromLock {
  manifestsDir = ./registry/sources;
  lockFile = ./registry/sources.lock.json;
};

catalog = agentLib.discoverCatalog sources;
```

## Update source pins

Expose the updater in your consumer flake:

```nix
sourceLockProgram = agentLib.mkSourceLockProgram { inherit pkgs; };

apps.${system}.skills-sources-lock = {
  type = "app";
  program = "${sourceLockProgram}/bin/skills-sources-lock";
};
```

From that flake's directory, update all sources together:

```console
nix run .#skills-sources-lock
```

Review and commit both the manifests and `registry/sources.lock.json`.
The [complete example flake](../examples/source-registry/flake.nix) wires the
registry, selection, bundle, and updater together.

## Validation and lock guarantees

The updater validates and normalizes every manifest through the same Nix
loader used by consumers. Unknown fields, unsafe manifest names and source
paths, and invalid discovery settings fail validation. It passes npins
arguments without shell evaluation and resolves all pins in a temporary
sibling directory.

The generated lock has an agent-skills schema-v1 wrapper containing the
normalized manifests and an npins version-8 lock. `sourcesFromLock` rejects
unsupported lock versions and requires the current normalized manifests to
match that snapshot exactly. Changing a repository, branch, or discovery
option without updating the lock therefore fails evaluation.

The updater sorts JSON keys and atomically renames the completed lock into
place. A failed manifest or fetch leaves the old lock byte-for-byte unchanged;
rerunning with unchanged upstream revisions produces the same lock bytes.
