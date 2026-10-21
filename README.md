# agent-skills-nix

Manage Agent Skills (directories containing `SKILL.md`) declaratively with Nix.
Pin skill sources, select the skills you need, and install them through Home
Manager or project-local commands. You can also export selected skills as a
self-contained Agent Plugin.

Nothing is installed by default: choose both skills and targets explicitly.

## Quick start with Home Manager

For an existing flake-based Home Manager configuration, add these inputs to
your flake:

```nix
inputs = {
  agent-skills.url = "github:Kyure-A/agent-skills-nix";
  anthropic-skills = {
    url = "github:anthropics/skills";
    flake = false;
  };
};
```

Capture the flake inputs with `outputs = inputs@{ ... }: ...;`. Add
`inputs.agent-skills.homeManagerModules.default` to your existing Home Manager
`modules` list and pass `extraSpecialArgs = { inherit inputs; };` to
`home-manager.lib.homeManagerConfiguration`. This makes the named skill input
available to the module.

Then add the following to your Home Manager configuration:

```nix
programs.agent-skills = {
  enable = true;

  sources.anthropic = {
    input = "anthropic-skills";
    subdir = "skills";
  };

  skills.enable = [ "frontend-design" "skill-creator" ];
  targets.claude.enable = true;
};
```

Apply your Home Manager configuration as usual. The selected skills are synced
to `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills`. Enable other agents with
`targets.<name>.enable = true;`; see [default target paths](#default-target-paths).
For an existing non-empty skills directory, see
[destination ownership](./docs/installation.md#destination-ownership).

The [complete quickstart examples](./examples/quickstart/README.md) show both
ways to arrange the inputs:

- [Main flake](./examples/quickstart/main/flake.nix): keep agent-skills and skill
  sources alongside your Home Manager inputs.
- [Child flake](./examples/quickstart/child/flake.nix): keep the skill inputs in a
  separate catalog flake.

## How it works

1. **Sources** point to skill roots in flake inputs, local paths, or an optional
   [source registry](./docs/source-registry.md).
2. **Discovery** scans for `SKILL.md` files and builds a catalog. Nested skill
   IDs use `/`, such as `documents/pdf`; `idPrefix` adds a source namespace.
3. **Selection** chooses catalog entries with `skills.enable` or
   `skills.enableAll`, and custom declarations with `skills.explicit`.
4. **Bundling** builds the selection in the Nix store, including any content
   transforms and package dependencies.
5. **Targets** install the bundle for enabled agents. Explicit skills can limit
   installation to named targets with `agents`.

## Guides and examples

| Task | Guide | Example |
|------|-------|---------|
| Configure sources, select skills, and customise content | [Configuration](./docs/configuration.md) | [Transforms and dependencies](./examples/skill-customization/explicit-transform.nix) |
| Install skills in a project | [Installation](./docs/installation.md#project-local-installation) | [Local install flake](./examples/local-install/flake.nix) |
| Install automatically on shell entry | [Development shells](./docs/installation.md#development-shells) | [devShell flake](./examples/devshell/flake.nix) |
| Pin sources without a flake input per repository | [Source registry](./docs/source-registry.md) | [Registry flake](./examples/source-registry/README.md) |
| Export a portable skills-only plugin | [Agent Plugin export (experimental)](./docs/agent-plugin.md) | [Plugin flake](./examples/agent-plugin/README.md) |
| Build your own integration | [Library and flake reference](./docs/reference.md) | [Library snippet](./examples/library-functions/snippet.nix) |

The root flake has an empty catalog and no enabled targets. Installation
commands such as `nix run .#skills-install-local` must run against your own
configured flake. Home Manager installs skills when you activate your home
configuration; it does not add apps to your flake.

## Default target paths

All built-in targets are disabled by default. Global targets use
`symlink-tree`; local targets use `copy-tree`. See
[target configuration](./docs/installation.md#target-configuration) for custom
paths, structures, and system filters.

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

## Development

The root `flake.nix` depends only on nixpkgs. It wires the library, packages,
apps, checks, and Home Manager module through ordinary Nix imports:

| Directory | Contents |
|-----------|----------|
| `lib/` | Discovery, selection, bundling, targets, registry, and plugin export |
| `modules/` | Shared options and Home Manager integration |
| `nix/` | Package, app, and default configuration definitions |
| `scripts/` | Synchronization, source locking, and plugin validation runtimes |
| `test/` | Library and runtime checks, plus Home Manager integration tests |
| `examples/` | Consumer configurations |

Home Manager is a test-only dependency in `test/flake.nix`, which imports the
root flake through a relative path and follows its nixpkgs input. Consumers do
not inherit a Home Manager dependency.

Run both check suites from the repository root:

```console
nix flake check
nix flake check ./test
```

To update dependencies, update the root lock first, then the test lock:

```console
nix flake update
nix flake update --flake ./test
```

CI runs both suites and checks formatting with `nix fmt`. The dependency update
workflow updates both lock files.
