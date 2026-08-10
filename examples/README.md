# Examples

Use-case-oriented examples for `agent-skills-nix`.

- `quickstart/`: two patterns (`main` tightly coupled, `child` separated skills catalog)
- `library-functions/`: direct use of library helpers
- `agent-plugin/`: export selected skills as a self-contained, skills-only Agent Plugin
- `skill-customization/`: `transform` and `packages` customization
- `local-install/`: project-local install app with `mkLocalInstallProgram`
- `devshell/`: auto-install with `mkShellHook`
- `source-registry/`: per-source manifests plus an npins JSON lock, without one flake input per skill repository
