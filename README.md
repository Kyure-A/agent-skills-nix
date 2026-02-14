# agent-skills-nix

Declarative management of Agent Skills (directories containing `SKILL.md`) with flake-pinned sources, discovery, selection, bundling, and Home Manager integration.

## Concepts

- **sources**: Named inputs (flake or path) pointing at a skills root (`subdir`).
- **discover**: Recursively scans sources for directories that contain `SKILL.md`, producing a catalog. Skills can be nested (e.g. `ecosystem/c-ecosystem/`) and their IDs use `/` as separator.
- **skills.enable / skills.enableAll / skills.explicit**: Declaratively pick discovered skills, enable-all (global or by source list), and explicitly specified ones; no accidental auto-install unless you opt in.
- **targets**: Agent-specific destinations synced from a store bundle (structure: `link`, `symlink-tree`, `copy-tree`). Targets are opt-in (`enable = false` by default). The `dest` option supports shell variable expansion at runtime (e.g. `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills`). See **Default target paths** below.

## Source filters

Each source supports optional filters to control discovery:

- **`filter.maxDepth`** (`null | int`, default: `null`): Maximum recursion depth for SKILL.md discovery. `null` = unlimited (capped internally at 100 to guard against symlink loops), `1` = immediate children only, `2` = one level of nesting. Set to `1` to restore pre-recursive (flat-only) behavior.
- **`filter.nameRegex`** (`null | string`, default: `null`): Regex matched against the skill's relative path (e.g. `cat-a/skill-1`) to restrict discovery.

## Default target paths

| Target | Global path | Local path |
|--------|-------------|------------|
| agents | `$HOME/.agents/skills` | `.agents/skills` |
| codex | `${CODEX_HOME:-$HOME/.codex}/skills` | `.codex/skills` |
| claude | `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills` | `.claude/skills` |
| copilot | `$HOME/.copilot/skills` | `.github/skills` |
| cursor | `$HOME/.cursor/skills` | `.cursor/skills` |
| windsurf | `$HOME/.codeium/windsurf/skills` | `.windsurf/skills` |
| antigravity | `$HOME/.gemini/antigravity/skills` | `.agent/skills` |
| gemini | `$HOME/.gemini/skills` | `.gemini/skills` |

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
- `dest` supports shell variable expansion at runtime (e.g. `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills`). Note: `link` structure does not support shell variables and will use the fallback path.

## Flake outputs

- `packages.<system>.agent-skills-bundle`: Store bundle of selected skills (empty by default; configure in consumers).
- `apps.<system>.skills-install`: Sync bundle to enabled global targets (see **Default target paths**). Override destinations with `AGENT_SKILLS_DESTS`.
- `apps.<system>.skills-install-local`: Sync bundle to enabled local targets (see **Default target paths**) using `copy-tree`. Override root with `AGENT_SKILLS_ROOT`, destinations with `AGENT_SKILLS_LOCAL_DESTS`.
- `apps.<system>.skills-list`: JSON view of the default catalog.
- `checks.<system>.skills`: Sanity check that the bundle builds.
- `homeManagerModules.default`: Home Manager module implementing the DSL above.
- `lib.agent-skills`: Helper functions (`discoverCatalog`, `selectSkills`, `mkBundle`, `mkLocalInstallScript`, `mkShellHook`, `catalogJson`, `defaultConfig`).

## Library functions

See [`examples/library-functions/snippet.nix`](./examples/library-functions/snippet.nix).

`discoverCatalog` recursively discovers `SKILL.md` directories and generates `/`-separated IDs for nested skills (e.g. `cat-a/skill-1`). It enforces `SKILL.md` presence and rejects duplicate IDs (error messages include absolute paths for both conflicting sources). `selectSkills` errors on unknown allowlist entries or missing files, preventing accidental drift. (Home Manager maps `skills.enable` → `allowlist` and `skills.explicit` → `skills`.)

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
Targets respect `enable`, `systems`, and `structure` (default `copy-tree`). To exclude a target, disable it or provide custom targets to `mkLocalInstallScript`.
Local install skips non-Nix-managed existing paths to avoid clobbering user data; set `AGENT_SKILLS_FORCE=1` to overwrite.

Both apps operate on the flake's default (empty) config; point at your own flake/module for real catalogs.

## Local skills in your project

To install skills locally in your project, use `mkLocalInstallScript` in your flake:

See [`examples/local-install/flake.nix`](./examples/local-install/flake.nix).

Then run `nix run .#skills-install-local` from your project root to install skills to enabled local targets in **Default target paths**.

### Auto-install with devShell

Use `mkShellHook` to automatically install skills when entering a dev shell:

See [`examples/devshell/flake.nix`](./examples/devshell/flake.nix).

Now `nix develop` will automatically install skills to your project directory.

## Checks / safety

- Disallows skill IDs containing `/..` or leading `/`.
- Verifies `SKILL.md` for discovered and explicit skills.
- Fails on duplicate IDs across sources.
- Caps recursion at 100 levels when maxDepth is null to guard against symlink loops.
- Activation scripts always `mkdir -p` and use `rsync -a --delete` by default.

## Breaking changes

### filter.maxDepth default changed from 1 to null

Skill discovery now recurses into nested directories by default. If your source layout relies on flat-only discovery (one level of directories under the source root), add `filter.maxDepth = 1;` to your source configuration:

```nix
sources.my-skills = {
  path = ./skills;
  filter.maxDepth = 1;  # restore flat-only behavior
};
```
