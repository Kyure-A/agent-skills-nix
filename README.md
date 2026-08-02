# agent-skills-nix

Declarative management of Agent Skills (directories containing `SKILL.md`) with flake-pinned sources, discovery, selection, bundling, and Home Manager integration.

## Concepts

- **sources**: Named inputs or paths pointing at a skills root (`subdir`). They can be written directly as before, or generated from the optional source registry. Optional `idPrefix` namespaces discovered skill IDs to avoid collisions across sources.
- **discover**: Recursively scans sources for directories that contain `SKILL.md`, producing a catalog. Skills can be nested (e.g. `ecosystem/c-ecosystem/`) and their IDs use `/` as separator.
- **skills.enable / skills.enableAll / skills.explicit**: Declaratively pick discovered skills, enable-all (global or by source list), and explicitly specified ones; no accidental auto-install unless you opt in.
- **targets**: Agent-specific destinations synced from a store bundle (structure: `link`, `symlink-tree`, `copy-tree`). Targets are opt-in (`enable = false` by default). Runtime destinations support `$HOME`, `~`, and `${VAR:-$HOME/...}` fallback forms without general shell evaluation. See **Default target paths** below.

## Source filters

Each source supports optional filters to control discovery:

- **`idPrefix`** (`null | string`, default: `null`): Prefix prepended to discovered skill IDs. Useful when multiple sources expose the same relative path, e.g. `idPrefix = "openai";` turns `pdf` into `openai/pdf`.
- **`filter.maxDepth`** (`null | int`, default: `null`): Maximum recursion depth for SKILL.md discovery. `null` = unlimited (capped internally at 100 to guard against symlink loops), `1` = immediate children only, `2` = one level of nesting. Set to `1` to restore pre-recursive (flat-only) behavior.
- **`filter.nameRegex`** (`null | string`, default: `null`): Regex matched against the skill's relative path (e.g. `cat-a/skill-1`) to restrict discovery.

If two sources both expose `pdf`, prefix them explicitly to keep IDs unique:

```nix
sources.openai = {
  input = "openai-skills";
  subdir = "skills";
  idPrefix = "openai";
};

sources.anthropic = {
  input = "anthropic-skills";
  subdir = "skills";
  idPrefix = "anthropic";
};

skills.enable = [ "openai/pdf" "anthropic/pdf" ];
```

## Source registry (optional)

The source registry removes the need to declare every skill repository as a
flake input. It uses [npins](https://github.com/andir/npins), the pin manager
recommended by the [nix.dev remote-source guide](https://nix.dev/guides/recipes/dependency-management.html),
for revision resolution and hashing. Existing `sources.<name>.input` and
`sources.<name>.path` declarations remain supported and can be mixed with this
approach.

Keep one human-edited Nix manifest per source and commit the generated JSON
lock:

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

`pin.type` can be `github`, `git`, or `tarball`. Git and GitHub pins accept
`branch`, `at`, `submodules`, `preReleases`, `versionUpperBound`, and
`releasePrefix`; generic Git pins additionally require `url` and accept
`forge`. If `branch` is omitted, npins follows releases and writes a
`GitRelease` pin. Tarball pins require `url` and optionally accept `mutable`.
The remaining fields (`subdir`, `idPrefix`, and `filter`) are the same source
discovery settings as the existing DSL.

Load the lock as an ordinary path-backed `sources` value:

```nix
sources = agentLib.sourcesFromLock {
  manifestsDir = ./registry/sources;
  lockFile = ./registry/sources.lock.json;
};

catalog = agentLib.discoverCatalog sources;
```

Expose the updater in a consumer flake:

```nix
sourceLockProgram = agentLib.mkSourceLockProgram { inherit pkgs; };

apps.${system}.skills-sources-lock = {
  type = "app";
  program = "${sourceLockProgram}/bin/skills-sources-lock";
};
```

Then update all sources together:

```console
nix run .#skills-sources-lock
```

The command validates and normalizes every manifest through the same Nix
loader used by consumers, passes every npins argument without shell evaluation,
and resolves all pins in a temporary sibling directory. The generated lock has
an agent-skills schema-v1 wrapper containing the normalized manifests and an
npins version-8 lock. `sourcesFromLock` requires the current normalized
manifests to match that snapshot exactly, so changing a repository, branch, or
discovery option without updating the lock fails evaluation. The updater sorts
JSON keys and only then atomically renames the completed lock into place. A
failed manifest or fetch leaves the old lock byte-for-byte unchanged; rerunning
with unchanged upstream revisions produces the same lock bytes. See the complete
[`examples/source-registry`](./examples/source-registry) flake.

## Default target paths

| Target | Global path | Local path |
|--------|-------------|------------|
| agents | `$HOME/.agents/skills` | `.agents/skills` |
| codex | `${CODEX_HOME:-$HOME/.codex}/skills` | `.codex/skills` |
| opencode | `$HOME/.config/opencode/skills` | `.opencode/skills` |
| claude | `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills` | `.claude/skills` |
| copilot | `$HOME/.copilot/skills` | `.github/skills` |
| cursor | `$HOME/.cursor/skills` | `.cursor/skills` |
| windsurf | `$HOME/.codeium/windsurf/skills` | `.windsurf/skills` |
| antigravity | `$HOME/.gemini/antigravity/skills` | `.agents/skills` |
| gemini | `$HOME/.gemini/skills` | `.gemini/skills` |
| pi | `$HOME/.pi/agent/skills` | `.pi/skills` |

## Quick start (child flake + Home Manager)

Put skills config in a small child flake so the only pinned inputs there are skill sources.

Use the quickstart example:

- Overview: [`examples/quickstart/README.md`](./examples/quickstart/README.md)
- Main (tightly coupled): [`examples/quickstart/main/flake.nix`](./examples/quickstart/main/flake.nix)
- Child (separated catalog): [`examples/quickstart/child/flake.nix`](./examples/quickstart/child/flake.nix)

Notes:

- In `main`, `agent-skills` and skill sources are listed directly in the top-level inputs.
- In `child`, top-level only depends on `skills-catalog = path:./skills`; skills inputs live under `./skills/flake.nix`.
- If you use source `input` references in your module config, pass flake `inputs` to Home Manager via `extraSpecialArgs`.
- To enable a default target, set `targets.<name>.enable = true;` (e.g. `targets.claude.enable = true;`).
- `structure = "link"` uses `home.file` symlinks; `symlink-tree` and `copy-tree` run in `home.activation`.
- `symlink-tree` uses `rsync -a --delete` (preserve symlinks); `copy-tree` uses `rsync -aL --delete` (dereference symlinks).
- Runtime `dest` values support `$HOME`, `~`, and `${VAR:-$HOME/...}` fallback forms (e.g. `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills`). Home Manager's `link` structure requires a static path and uses the fallback path.
- Symlinks inside skills are preserved when their target stays inside the source root; escaping or dangling ones are dropped. See [Symlinks inside skills](#symlinks-inside-skills).

## Flake outputs

- `packages.<system>.agent-skills-bundle`: Store bundle of selected skills (empty by default; configure in consumers).
- `apps.<system>.skills-install`: Sync bundle to enabled global targets (see **Default target paths**). Override destinations with `AGENT_SKILLS_DESTS`.
- `apps.<system>.skills-install-local`: Sync bundle to enabled local targets (see **Default target paths**) using `copy-tree`. Override root with `AGENT_SKILLS_ROOT`, destinations with `AGENT_SKILLS_LOCAL_DESTS`.
- `apps.<system>.skills-list`: JSON view of the default catalog.
- `apps.<system>.skills-sources-lock`: Resolve `registry/sources/*.nix` and atomically update `registry/sources.lock.json`.
- `checks.<system>.skills`: Sanity check that the bundle builds.
- `homeManagerModules.default`: Home Manager module implementing the DSL above.
- `lib.agent-skills`: Helper functions (`discoverCatalog`, `selectSkills`, `mkBundle`, `loadSourceManifests`, `sourcesFromLock`, `mkSourceLockProgram`, `mkSyncProgram`, `mkLocalInstallProgram`, compatibility wrappers `mkSyncScript` / `mkLocalInstallScript`, `mkShellHook`, `catalogJson`, `defaultConfig`).

## Development structure

The root `flake.nix` only declares inputs and invokes [Blueprint](https://github.com/numtide/blueprint). Blueprint discovers packages, checks, and the public library under `nix/`; `nix/flake-outputs.nix` projects those pieces onto the existing public output names and wires the apps and Home Manager module. Runtime and domain logic remain in `scripts/`, `lib/`, `modules/`, and `test/`.

## Library functions

See [`examples/library-functions/snippet.nix`](./examples/library-functions/snippet.nix).

`discoverCatalog` recursively discovers `SKILL.md` directories and generates `/`-separated IDs for nested skills (e.g. `cat-a/skill-1`). Set `idPrefix` on a source to namespace discovered IDs (for example, `openai/pdf`). It enforces `SKILL.md` presence and rejects duplicate IDs after prefixing (error messages include absolute paths for both conflicting sources). `selectSkills` errors on unknown allowlist entries or missing files, preventing accidental drift. (Home Manager maps `skills.enable` → `allowlist` and `skills.explicit` → `skills`.)

`loadSourceManifests` loads, validates, and normalizes a directory of per-source
Nix manifests. `sourcesFromLock` verifies them against an agent-skills
schema-v1 JSON lock (containing an npins version-8 pin set) and returns the same
path-backed source shape accepted by `discoverCatalog`. `mkSourceLockProgram`
builds the updater used by the `skills-sources-lock` app.

`mkSyncProgram` returns a `skills-install` executable after filtering enabled targets for the requested system. `mkLocalInstallProgram` is its project-local wrapper and returns `skills-install-local`. Both serialize a versioned JSON configuration and invoke the shared synchronization runtime; they do not return inline shell source. Existing consumer flakes can continue using `mkSyncScript` and `mkLocalInstallScript`; these compatibility wrappers preserve their original return types while delegating to the shared runtime. `mkShellHook` runs the local program from a development shell.

## Skill customisation

Explicit skills support `transform` and `packages` options to customise SKILL.md and bundle dependencies:

See [`examples/skill-customization/explicit-transform.nix`](./examples/skill-customization/explicit-transform.nix).

This generates:

```
my-skill/
├── SKILL.md
├── jq -> /nix/store/xxx-jq/bin/jq
└── curl/ -> /nix/store/xxx-curl/bin/  (for packages with multiple binaries)
```

With SKILL.md containing the transformed content.

**Transform function arguments:**
- `original`: The original SKILL.md content
- `dependencies`: A markdown table of package dependencies with local paths (e.g., `./jq`)

**Default behaviour (no transform):**
- If only `packages` is specified, the default is `dependencies + original`
- If neither is specified, the original SKILL.md is used as-is

Package binaries are referenced with local paths (`./jq` or `./pkg/` for multi-binary packages) to reduce context consumption when agents load the skill.

## Apps usage

### Global skills (Home Manager)

- List catalog: `nix run .#skills-list`
- Sync bundle to `$HOME`: `nix run .#skills-install` (override destinations via `AGENT_SKILLS_DESTS="~/tmp/skills1 ~/tmp/skills2"`)

### Local skills (project-local)

- Sync bundle to current directory: `nix run .#skills-install-local`

Local skills are installed to enabled local targets in **Default target paths** relative to the current working directory (or `AGENT_SKILLS_ROOT` if set). Override destinations via `AGENT_SKILLS_LOCAL_DESTS`.
Targets respect `enable`, `systems`, and `structure` (default `copy-tree`). To exclude a target, disable it or provide custom targets to `mkLocalInstallProgram`.
The synchronizer refuses to replace a non-empty, unmarked directory. A successful tree sync records ownership in `.agent-skills-managed.json`; set `AGENT_SKILLS_FORCE=1` only when you intentionally want agent-skills to take over an existing destination.

Both apps operate on the flake's default (empty) config; point at your own flake/module for real catalogs.

## Local skills in your project

To install skills locally in your project, use `mkLocalInstallProgram` in your flake:

See [`examples/local-install/flake.nix`](./examples/local-install/flake.nix).

Then run `nix run .#skills-install-local` from your project root to install skills to enabled local targets in **Default target paths**.

### Auto-install with devShell

Use `mkShellHook` to automatically install skills when entering a dev shell:

See [`examples/devshell/flake.nix`](./examples/devshell/flake.nix).

Now `nix develop` will automatically install skills to your project directory.

## Symlinks inside skills

Symlinks inside skill directories are kept when their textual target stays inside the declared source root (e.g. `../shared` to a sibling at the root). Symlinks whose target escapes the root are dropped, along with any links left dangling by that drop.

- The entire source root is imported into the store, not just each skill subdirectory. Scope the source via `path = ./skills` or `subdir` if the root contains unrelated heavy trees (`.git`, build artefacts).
- `--safe-links` checks the textual target, not the resolved path. Keep symlinks source-root-relative.
- Sources resolving to the same physical directory share one store path and one safe-tree derivation.

## Checks / safety

- Disallows skill IDs containing `/..` or leading `/`.
- Disallows source `idPrefix` values ending with `/`.
- Verifies `SKILL.md` for discovered and explicit skills.
- Fails on duplicate IDs across sources.
- Preserves symlinks that stay inside a declared source root and drops escaping or dangling symlinks when materializing bundles.
- Rejects `..` traversal in source `subdir` and explicit skill `path` values.
- Rejects unknown registry fields, unsafe manifest names and subdirectories, unsupported lock versions, and manifest/lock source drift.
- Caps recursion at 100 levels when maxDepth is null to guard against symlink loops.
- Passes destinations as JSON data; shell metacharacters and command-substitution syntax are not evaluated as shell code.
- Tree synchronization validates destination ownership before using `rsync --delete`; managed destinations carry a `.agent-skills-managed.json` marker.
- Local destinations are resolved beneath `AGENT_SKILLS_ROOT` (or the current directory) and paths that escape that root are rejected.

## Breaking changes

### Managed destination ownership

Tree synchronization now requires a valid `.agent-skills-managed.json` marker before replacing a non-empty destination. For an existing destination created by an older release, inspect it first and set `AGENT_SKILLS_FORCE=1` for the one-time takeover.

### filter.maxDepth default changed from 1 to null

Skill discovery now recurses into nested directories by default. If your source layout relies on flat-only discovery (one level of directories under the source root), add `filter.maxDepth = 1;` to your source configuration:

```nix
sources.my-skills = {
  path = ./skills;
  filter.maxDepth = 1;  # restore flat-only behavior
};
```
