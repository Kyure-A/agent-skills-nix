# Installation

[Back to README](../README.md) · [Configuration](./configuration.md) · [Library reference](./reference.md)

Choose Home Manager for home-level installation, or expose an install program
in your own flake. The root agent-skills flake has an empty catalog and no
enabled targets; its install apps do not use your Home Manager configuration.

## Home Manager

Follow the [quick start](../README.md#quick-start-with-home-manager), then
activate your Home Manager configuration as usual. The module installs the
selected skills to enabled targets:

- `link` uses recursive `home.file` symlinks.
- `symlink-tree` and `copy-tree` run through `home.activation`.

Home Manager exposes the full bundle as `programs.agent-skills.bundlePath` and
the filtered bundles for enabled targets on the current system as
`programs.agent-skills.targetBundlePaths`.

## Project-local installation

Use [`mkLocalInstallProgram`](../examples/local-install/flake.nix) to expose an
app in your project flake, select skills, and enable local targets. Run it from
your project root:

```console
nix run .#skills-install-local
```

Local destinations are relative to the current working directory, or
`AGENT_SKILLS_ROOT` if set. They must remain beneath that root; paths that escape
it are rejected. Local paths are literal, without shell-variable expansion.
The built-in local targets use `copy-tree`.

## Development shells

Use `mkShellHook` to install local skills when entering a development shell.
The [devShell example](../examples/devshell/flake.nix) wires the selection,
bundle, and enabled local targets together. Then run:

```console
nix develop
```

The hook prints one line per installed target. Under direnv it is re-evaluated
on every shell entry; pass `quiet = true;` to `mkShellHook` to suppress those
lines. `AGENT_SKILLS_QUIET=1` does the same for any synchronization program at
runtime. Warnings and failures still go to stderr.

## Global install apps

Use `mkSyncProgram` to expose a `skills-install` app in a consumer flake when
you want to sync globally without Home Manager activation. Pass your bundle
and enabled global targets, then run:

```console
nix run .#skills-install
```

`mkSyncProgram` disables destination overrides by default. Set
`allowOverrides = true;` if you want to allow `AGENT_SKILLS_DESTS` for an
unrestricted bundle. See the [library reference](./reference.md) for the
program helpers and bundle filtering.

## Default target paths

The `agents` target provides a shared installation directory. Product-specific
targets provide separate destinations when you want to distribute different
skill sets or use features that require a dedicated path.

The following table lists this library's built-in defaults. All targets are
disabled by default; global targets use `symlink-tree` and local targets use
`copy-tree`.

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

Per-skill `agents` lists select installation targets; they do not control which
applications can discover the installed files.

## Target configuration

Each target supports `enable`, `dest`, `structure`, and `systems`; an empty
`systems` list allows every system. Built-in targets must be enabled explicitly.
Custom targets require a destination.

| Structure | Behavior |
|-----------|----------|
| `link` | Links to the store bundle; Home Manager manages recursive `home.file` links |
| `symlink-tree` | Synchronizes with `rsync -a --delete`, preserving symlinks |
| `copy-tree` | Synchronizes with `rsync -aL --delete`, dereferencing symlinks |

Global runtime destinations support `$HOME`, `~`, and fallback forms such as
`${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills`. These are parsed as data, without
general shell evaluation. Shell metacharacters and command-substitution syntax
are not executed. Home Manager's `link` structure requires a static path and
uses the fallback path for supported fallback expressions.

All install methods respect per-skill [`agents` restrictions](./configuration.md#restricting-skills-to-agents).
Pass the bundle derivation directly to the library helpers so they retain the
metadata needed for filtering.

## Destination overrides

Overrides are available only for bundles without `agents` restrictions, and
only when the program enables them. `mkLocalInstallProgram` enables them by
default; `mkSyncProgram` requires `allowOverrides = true;`.

| Variable | Effect |
|----------|--------|
| `AGENT_SKILLS_ROOT` | Sets the root for local installation |
| `AGENT_SKILLS_DESTS` | Replaces the entire global target list |
| `AGENT_SKILLS_LOCAL_DESTS` | Replaces local destinations in target-name order |
| `AGENT_SKILLS_QUIET=1` | Suppresses per-target progress lines |
| `AGENT_SKILLS_FORCE=1` | Allows intentional takeover of an existing destination |

Destination overrides are separated by spaces, tabs, or newlines. For example,
an unrestricted global program with overrides enabled accepts
`AGENT_SKILLS_DESTS="~/tmp/skills1 ~/tmp/skills2"`.

Local overrides retain each matched target's structure; remaining targets keep
their configured destinations. Additional overrides use `overrideStructure`
(`copy-tree` for `mkLocalInstallProgram`). Use configured targets for paths
containing whitespace or for bundles with `agents` restrictions.

## Destination ownership

The synchronizer refuses to replace a non-empty, unmarked directory. A
successful tree sync records ownership in `.agent-skills-managed.json` before
future synchronization can replace its contents with `rsync --delete`.

For an existing destination, including one created by an older release,
inspect its contents before setting `AGENT_SKILLS_FORCE=1` for a one-time
takeover. Use this only when you intend agent-skills to manage that destination.

Synchronization builds and validates the complete execution plan before
changing any destination. Targets with the same resolved destination,
structure, and bundle synchronize once. The first target's name is used for the
ownership marker and progress message.

Different structures or bundles at one destination, or destinations nested
inside each other, are rejected before synchronization starts.
