# Library and flake reference

[Back to README](../README.md) · [Configuration](./configuration.md) · [Installation](./installation.md)

## Flake outputs

The root flake's default configuration has no sources, selected skills, or
enabled targets. Build your own selection and programs in a consumer flake.
Enabling the Home Manager module configures home activation, not these apps.

| Output | Purpose |
|--------|---------|
| `packages.<system>.agent-skills-bundle` | Store bundle of the default selection (empty) |
| `packages.<system>.default` | Alias for `agent-skills-bundle` |
| `apps.<system>.skills-install` | Syncs the default bundle to enabled global targets; permits overrides for unrestricted bundles |
| `apps.<system>.skills-install-local` | Syncs the default bundle to enabled local targets |
| `apps.<system>.skills-list` | Prints the default catalog as JSON |
| `apps.<system>.skills-sources-lock` | Resolves `registry/sources/*.nix` and atomically updates `registry/sources.lock.json` |
| `checks.<system>.skills` | Checks that the default bundle builds; other checks cover library and runtime behavior |
| `homeManagerModules.default` | Home Manager module for `programs.agent-skills` |
| `lib.agent-skills` | Public library and `defaultConfig` |
| `catalog` | JSON-ready view of the default catalog |
| `formatter.<system>` | `nixpkgs-fmt` |

Run `nix run .#skills-list` against a flake exposing that app to inspect its
catalog. The root flake returns an empty catalog.

## Discovery, selection, and bundles

Access the library with `agentLib = inputs.agent-skills.lib.agent-skills;`.
The [library snippet](../examples/library-functions/snippet.nix) shows the
discovery → selection → bundle pipeline with caller-provided `inputs`,
`nixpkgs`, `sources`, and `system`.

| Helper | Purpose |
|--------|---------|
| `discoverCatalog sources` | Discovers `SKILL.md` directories with nested and optionally prefixed IDs |
| `allowlistFor { catalog; sources; enable; enableAll; }` | Resolves selected IDs, including enable-all source lists |
| `selectSkills { catalog; sources; allowlist; skills; }` | Combines catalog entries with explicit skill declarations |
| `mkBundle { pkgs; selection; }` | Builds the full selection in the Nix store |
| `catalogJson catalog` | Produces a JSON-ready catalog view |

Home Manager maps `skills.enable` and `skills.enableAll` through `allowlistFor`,
then passes the result as `allowlist` and `skills.explicit` as `skills` to
`selectSkills`. See [configuration](./configuration.md) for discovery filters,
selection validation, renaming, and customisation.

`mkBundle` exposes `bundle.forTarget { name = "claude"; }` to filter the selection
by each skill's `agents` list. Its argument is an attribute set; the former
target-name string argument is no longer supported.

Use `bundle.forTarget { name = "agents"; flatten = true; }` to install the
allowed skills under the basenames of their final IDs. `flatten` defaults to
`false`, independently of the target name. Basename collisions are rejected
after filtering. The full bundle always retains the original nested IDs, and
target views share its materialized skill contents.

Pass the bundle derivation directly to the install helpers to retain this
metadata. A plain store path or derivation without `forTarget` remains usable
when flattening is disabled, but cannot be used with `flatten = true`.

## Targets and install programs

| Helper or value | Purpose |
|-----------------|---------|
| `defaultTargets` / `defaultLocalTargets` | Built-in global and local targets, all disabled by default |
| `defaultExcludePatterns` | Synchronization exclusions; defaults to `[ "/.system" ]` |
| `targetsFor { targets; system; }` | Filters targets by `enable` and `systems` |
| `bundlesForTargets { bundle; targets; system; }` | Validates skill target names and returns filtered bundles for enabled targets |
| `mkSyncProgram { pkgs; bundle; targets; ... }` | Builds a `skills-install` executable for global synchronization |
| `mkLocalInstallProgram { pkgs; bundle; targets; ... }` | Builds a `skills-install-local` executable for project-local synchronization |
| `mkShellHook { pkgs; bundle; targets; ... }` | Runs the local install program on shell entry; accepts `quiet = true;` |

The program helpers serialize a versioned JSON configuration and invoke the
shared synchronization runtime. They return executable derivations, not inline
shell source. `mkSyncScript` is a wrapper returning shell text that invokes the
global program; `mkLocalInstallScript` returns the local program derivation.

See [installation](./installation.md) for structures, runtime path expansion,
destination overrides, and ownership checks.

## Source registry and plugin export

| Helper | Purpose |
|--------|---------|
| `loadSourceManifests` | Loads, validates, and normalizes per-source Nix manifests |
| `sourcesFromLock` | Verifies manifests against a schema-v1 lock containing an npins version-8 pin set and returns path-backed sources |
| `mkSourceLockProgram` | Builds the `skills-sources-lock` updater |
| `mkAgentPlugin` | Exports an explicit skill map as a portable, skills-only plugin |

See the [source registry guide](./source-registry.md) and
[Agent Plugin guide](./agent-plugin.md) for usage and validation rules.

Additional bundle utilities (`getPkgBinInfo`, `mkPackagesTable`, and
`rewriteCommandPaths`) are exported from [the library](../lib/default.nix).
