# Source registry example

This flake keeps skill repositories out of `flake.nix`. Human-edited source
metadata lives in `registry/sources/*.nix`; the generated
`registry/sources.lock.json` snapshots the normalized manifests and pins
revisions and hashes.

Update every source from this directory:

```console
nix run .#skills-sources-lock
```

Then review and commit both the manifests and lock file. The resulting
`sources` value has the same shape as the existing `sources` DSL and can be
passed directly to `discoverCatalog`, `selectSkills`, and Home Manager.
