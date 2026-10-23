# Agent Plugin export (experimental)

[Back to README](../README.md) · [Runnable example](../examples/agent-plugin/README.md)

`mkAgentPlugin` turns an explicit map of selected skills into a self-contained,
skills-only plugin for ChatGPT and Codex. The exporter uses the layout described
in OpenAI's [plugin packaging guide](https://developers.openai.com/plugins/build/plugins):

```text
result/
├── .codex-plugin/
│   └── plugin.json
└── skills/
    └── pdf/
        └── SKILL.md
```

## Export selected skills

Pass entries returned by `selectSkills` under their intended export names:

```nix
plugin = agentLib.mkAgentPlugin {
  inherit pkgs;

  manifest = {
    name = "document-tools";
    version = "0.1.0";
    description = "Portable document workflows";
  };

  skills = {
    pdf = selection."openai/pdf";
  };
};
```

The attribute names in `skills` become the exported skill directory names.
This explicit mapping flattens catalog IDs such as `openai/pdf` into portable
names such as `pdf`; the matching `SKILL.md` frontmatter must use that same
name. The exporter adds `"skills": "./skills/"` to the manifest. Per-skill
`agents` restrictions do not filter plugin exports; the explicit export map
determines their contents.

The [example flake](../examples/agent-plugin/flake.nix) discovers a local skill,
selects it, and exposes an `agent-plugin` package. Build it from the example
directory:

```console
nix build --no-write-lock-file .#agent-plugin
```

## Portability and validation

The initial exporter supports skills only. A selected skill with a nonempty
`packages` list or a non-null `transform` is rejected because those bundle
features can create output that is not portable outside the Nix store.

Each accepted skill is copied with its payload into the result, and internal
links are materialized. Dangling links, cyclic links, and links that escape the
declared source root are rejected. The completed plugin contains no symlinks.

The exporter validates both the source trees and the completed plugin:

- The export map must contain at least one skill.
- Plugin and skill names must contain 1–64 lowercase letters, numbers, and
  single hyphens, with no leading or trailing hyphen.
- `manifest.version` must use strict semantic versioning, and
  `manifest.description` must be nonempty.
- Each `SKILL.md` must have valid YAML frontmatter whose `name` matches its
  export directory and whose nonempty `description` is at most 1,024 characters.
  Skills cannot set `disable-model-invocation` to `true`.

## Supported manifest scope

The exporter owns the manifest's `skills` field and rejects `apps`,
`mcpServers`, and `hooks`. Plugin-level asset fields such as `composerIcon`,
`logo`, `logoDark`, and `screenshots` are also outside this initial API; keep
visual assets inside individual skills instead.

If present, `manifest.interface.defaultPrompt` supports at most three entries
of 128 characters each.
