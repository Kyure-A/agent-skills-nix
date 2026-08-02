#!/usr/bin/env bash

set -euo pipefail

output_dir=${1:?output directory is required}
source_evaluator=${2:?source evaluator path is required}
nixpkgs_lib=${3:?nixpkgs lib path is required}
source_registry_lib=${4:?source registry library path is required}
work="$TMPDIR/npins-local-integration"
repo="$work/upstream"
consumer="$work/consumer"
mkdir -p "$repo" "$consumer/registry/sources"

git -C "$repo" init -b main
git -C "$repo" config user.name "Agent Skills Test"
git -C "$repo" config user.email "agent-skills@example.invalid"
printf '%s\n' '# Local fixture' >"$repo/SKILL.md"
git -C "$repo" add SKILL.md
GIT_AUTHOR_DATE='2000-01-01T00:00:00Z' \
  GIT_COMMITTER_DATE='2000-01-01T00:00:00Z' \
  git -C "$repo" commit -m fixture

printf '%s\n' \
  '{' \
  '  pin = {' \
  '    type = "git";' \
  '    url = builtins.getEnv "AGENT_SKILLS_TEST_REPO_URL";' \
  '    branch = "main";' \
  '    forge = "none";' \
  '  };' \
  '}' >"$consumer/registry/sources/local.nix"

export AGENT_SKILLS_TEST_REPO_URL="file://$repo"
cd "$consumer"
skills-sources-lock

jq -e '
  .schemaVersion == 1
  and .npins.version == 8
  and (.npins.pins | keys == ["local"])
  and .npins.pins.local.type == "Git"
  and .npins.pins.local.repository.type == "Git"
  and .npins.pins.local.repository.url == $url
  and .manifests.local.pin.url == $url
' --arg url "$AGENT_SKILLS_TEST_REPO_URL" registry/sources.lock.json >/dev/null

source_path=$(nix-instantiate --eval --strict --json "$source_evaluator" \
  --argstr manifestsDir "$consumer/registry/sources" \
  --argstr lockFile "$consumer/registry/sources.lock.json" \
  --argstr nixpkgsLib "$nixpkgs_lib" \
  --argstr sourceRegistryLib "$source_registry_lib" | jq -r .)
test -f "$source_path/SKILL.md"

cp registry/sources.lock.json first-lock.json
skills-sources-lock
cmp first-lock.json registry/sources.lock.json

mkdir -p "$output_dir"
touch "$output_dir/ok"
