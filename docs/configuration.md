# Configuration

[Back to README](../README.md) · [Installation](./installation.md) · [Library reference](./reference.md)

Home Manager settings live under `programs.agent-skills`. Library consumers
use the same source and explicit-skill declarations through
`agent-skills.lib.agent-skills`; see the [library reference](./reference.md).

## Sources and discovery

A source points to a skill root using a flake input name or a local path:

```nix
sources.anthropic = {
  input = "anthropic-skills";
  subdir = "skills";
  idPrefix = "anthropic";
};

sources.local = {
  path = ./skills;
};
```

Pass flake `inputs` through Home Manager's `extraSpecialArgs` when using named
input references. When using the public `inputs.agent-skills.lib.agent-skills`
library directly, use `path = inputs.anthropic-skills;` instead: that library
does not resolve input names from your consumer flake.

A source must provide `path` or `input`; `path` takes
precedence when both are set. The optional [source registry](./source-registry.md)
produces path-backed sources and can be mixed with direct declarations.

| Option | Default | Meaning |
|--------|---------|---------|
| `subdir` | `"."` | Relative skill root inside the input or path |
| `idPrefix` | `null` | Namespace prepended to discovered skill IDs |
| `filter.maxDepth` | `null` | Discovery depth: `0` scans only the root, `1` includes immediate children, `2` includes one further level |
| `filter.nameRegex` | `null` | Regex matched against the skill's relative path, such as `cat-a/skill-1` |

Discovery recursively finds directories containing `SKILL.md`. Nested IDs use
`/`, such as `cat-a/skill-1`. A `null` depth scans recursively up to an internal
limit of 100 levels to guard against symlink loops; negative depths are rejected.
Set `filter.maxDepth = 1;` for flat-only discovery, including configurations
that relied on the former default of `1`.

Use prefixes when sources expose the same relative skill path:

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

Direct sources, Home Manager sources, and registry manifests share validation
for `subdir`, `idPrefix`, and `filter`. Unknown source or filter fields, invalid
types, unsafe relative paths, and invalid prefixes fail before selection.
Prefixes cannot end in `/`. Duplicate discovered IDs fail after prefixing,
with both conflicting source paths in the error.

## Selecting skills

| Setting | Selection |
|---------|-----------|
| `skills.enable = [ "frontend-design" ];` | Named catalog entries |
| `skills.enableAll = true;` | All discovered skills |
| `skills.enableAll = [ "anthropic" ];` | All discovered skills from the named sources |
| `skills.explicit` | Explicit declarations with optional renaming, target restrictions, and customisation |

These selections are combined. By default, `skills.enable` is empty,
`skills.enableAll` is `false`, and `skills.explicit` is empty. Unknown skill IDs
or source names fail evaluation.

An explicit declaration uses `from` to name a source and `path` to locate the
skill relative to that source's `subdir`. The path defaults to the declaration
name; `rename` sets the final output ID:

```nix
skills.explicit.original = {
  from = "local";
  path = "pdf";
  rename = "documents/pdf";
};
```

This installs to `documents/pdf/`. An omitted or `null` rename uses the
declaration name. Selection keys and entry IDs match, and collisions are
checked after renaming against both discovered selections and other explicit
skills. Do not select the same output ID through both `enable` and `explicit`.

Enabled declarations are validated before selection returns: the skill must
contain `SKILL.md`, `transform` must be a function if set, and `packages` must
contain derivations. Skill IDs cannot be absolute or contain `..` path
traversal; source `subdir` and explicit `path` values also reject traversal.

## Restricting skills to agents

Set `agents` on an explicit skill to choose which named targets receive it:

```nix
programs.agent-skills = {
  targets.claude.enable = true;
  targets.codex.enable = true;
  targets.pi.enable = true;

  skills.explicit = {
    writing = {
      from = "my-source";
      agents = [ "claude" "codex" ];
    };
    pi-tools = {
      from = "my-source";
      agents = [ "pi" ];
    };
    shared = {
      from = "my-source";
    };
  };
};
```

Here `writing` goes to Claude and Codex, `pi-tools` goes to Pi, and `shared`
goes to all three. Omitted `agents` or `agents = null;` allows every enabled
target on the current system. `agents = [];` installs the skill nowhere while
keeping it in the full bundle. Skills selected through `skills.enable` or
`skills.enableAll` go to every enabled target.

Names match `targets` attribute keys, including custom targets, regardless of
their destination paths. Listing a target does not enable it or override its
`systems` filter. Unknown names fail evaluation when constructing install
programs; known but disabled targets, or targets for another system, are allowed.

Restrictions apply to Home Manager links and activation, global and local
install programs, and development-shell hooks. If any selected skill has a
non-null `agents` list, `AGENT_SKILLS_DESTS` and `AGENT_SKILLS_LOCAL_DESTS`
overrides are rejected because those paths do not identify a target. Configure
`targets.<name>.dest` instead. [Plugin exports](./agent-plugin.md) use their
explicit export map rather than these restrictions.

## Transforming content and bundling dependencies

Explicit skills support `transform` and `packages` to customise `SKILL.md` and
make package binaries available beside it. See the
[complete customisation example](../examples/skill-customization/explicit-transform.nix).

The resulting directory has this shape:

```text
my-skill/
├── SKILL.md
├── jq -> /nix/store/xxx-jq/bin/jq
└── curl/ -> /nix/store/xxx-curl/bin/  (for packages with multiple binaries)
```

Package binaries are referenced with local paths (`./jq` or `./pkg/` for
packages with multiple binaries). With packages present, `rewriteCommands`
defaults to `true` and rewrites command references before the transform runs.
Set `rewriteCommands = false;` to keep bare command names.

A transform receives:

| Argument | Value |
|----------|-------|
| `original` | The `SKILL.md` content, after any command rewriting |
| `dependencies` | A Markdown table of package dependencies with local paths |

With packages but no transform, the dependency table is appended after the
content (including any command rewriting). With neither, the original
`SKILL.md` is used as-is.

## Symlinks inside skills

Symlinks are kept when their textual target stays inside the declared source
root, such as `../shared` to a sibling at that root. Links that escape the root
are dropped, along with links left dangling by that removal.

- The entire source root is imported into the store, not only each skill
  directory. Scope sources with `path = ./skills` or `subdir` to avoid unrelated
  heavy trees such as `.git` or build artefacts.
- `--safe-links` checks the textual target, not the resolved path. Keep symlinks
  source-root-relative.
- Sources resolving to the same physical directory share one store path and
  one safe-tree derivation.
