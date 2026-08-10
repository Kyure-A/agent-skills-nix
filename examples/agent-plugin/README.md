# Agent Plugin export example

This flake discovers one local skill, selects its namespaced catalog ID
`example/pdf`, and exports it under the portable name `pdf`.

Build the plugin from this directory:

```console
nix build --no-write-lock-file .#agent-plugin
```

When testing changes from a local checkout of `agent-skills-nix`, point the
example at that checkout instead of the GitHub input:

```console
nix build --no-write-lock-file --override-input agent-skills path:../.. .#agent-plugin
```

The result has the structure required by OpenAI's
[plugin packaging guide](https://developers.openai.com/plugins/build/plugins):

```text
result/
├── .codex-plugin/
│   └── plugin.json
└── skills/
    └── pdf/
        └── SKILL.md
```
