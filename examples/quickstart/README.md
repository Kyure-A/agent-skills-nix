# Quickstart examples

This directory contains two patterns.

## `main` (tightly coupled)

`main/flake.nix` lists both `agent-skills` and skill sources directly in the
project-level flake inputs.

- Flake: [`main/flake.nix`](./main/flake.nix)
- Home module: [`main/home.nix`](./main/home.nix)

## `child` (separated skills catalog)

`child/flake.nix` only depends on `skills-catalog = path:./skills`.
The nested `child/skills/flake.nix` owns `agent-skills` and skill source inputs.

- Project flake: [`child/flake.nix`](./child/flake.nix)
- Project home module: [`child/home.nix`](./child/home.nix)
- Skills catalog flake: [`child/skills/flake.nix`](./child/skills/flake.nix)
- Skills catalog module: [`child/skills/home-manager.nix`](./child/skills/home-manager.nix)

Useful commands:

```bash
# main pattern
nix flake show ./examples/quickstart/main
nix build ./examples/quickstart/main#homeConfigurations.example.activationPackage

# child pattern
nix flake show ./examples/quickstart/child
nix build ./examples/quickstart/child#homeConfigurations.example.activationPackage
```
