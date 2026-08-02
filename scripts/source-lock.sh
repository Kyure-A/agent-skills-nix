#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: skills-sources-lock [--manifest-dir DIR] [--lock-file FILE]

Resolve every <name>.nix manifest with npins and atomically replace the
versioned JSON lock file. Relative paths are resolved from the current working
directory.
EOF
}

manifest_dir="registry/sources"
lock_file="registry/sources.lock.json"

while (($# > 0)); do
  case "$1" in
    --manifest-dir)
      (($# >= 2)) || {
        echo "skills-sources-lock: --manifest-dir requires a value" >&2
        exit 2
      }
      manifest_dir=$2
      shift 2
      ;;
    --lock-file)
      (($# >= 2)) || {
        echo "skills-sources-lock: --lock-file requires a value" >&2
        exit 2
      }
      lock_file=$2
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "skills-sources-lock: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ ! -d "$manifest_dir" ]]; then
  echo "skills-sources-lock: manifest directory does not exist: $manifest_dir" >&2
  exit 1
fi

if [[ -L "$lock_file" ]]; then
  echo "skills-sources-lock: refusing to replace a symbolic-link lock file: $lock_file" >&2
  exit 1
fi
if [[ -e "$lock_file" && ! -f "$lock_file" ]]; then
  echo "skills-sources-lock: lock path exists and is not a regular file: $lock_file" >&2
  exit 1
fi

lock_dir=$(dirname -- "$lock_file")
mkdir -p -- "$lock_dir"
temp_dir=$(mktemp -d "${lock_dir}/.agent-skills-sources-lock.XXXXXX")
temp_lock="$temp_dir/sources.json"
canonical_lock="$temp_dir/sources.canonical.json"
normalized_manifests="$temp_dir/manifests.json"

cleanup() {
  rm -rf -- "$temp_dir"
}
trap cleanup EXIT HUP INT TERM

: "${AGENT_SKILLS_SOURCE_NORMALIZER:?source normalizer path is required}"
: "${AGENT_SKILLS_NIXPKGS_LIB:?nixpkgs lib path is required}"
: "${AGENT_SKILLS_SOURCE_REGISTRY_LIB:?source registry library path is required}"

manifest_dir_abs=$(realpath --canonicalize-existing -- "$manifest_dir")
if ! nix-instantiate --eval --strict --json "$AGENT_SKILLS_SOURCE_NORMALIZER" \
  --argstr manifestsDir "$manifest_dir_abs" \
  --argstr nixpkgsLib "$AGENT_SKILLS_NIXPKGS_LIB" \
  --argstr sourceRegistryLib "$AGENT_SKILLS_SOURCE_REGISTRY_LIB" \
  >"$normalized_manifests"; then
  echo "skills-sources-lock: source manifest validation failed" >&2
  exit 1
fi

npins --lock-file "$temp_lock" init --bare

names=()
while IFS= read -r -d '' name; do
  manifest_json=$(jq -cS --arg name "$name" '.[$name]' "$normalized_manifests")
  pin_type=$(jq -r '.pin.type' <<<"$manifest_json")

  command=(npins --lock-file "$temp_lock" add --name "$name")
  case "$pin_type" in
    git | github)
      command+=("$pin_type")
      if [[ "$pin_type" == "git" ]]; then
        url=$(jq -r '.pin.url' <<<"$manifest_json")
        forge=$(jq -r '.pin.forge' <<<"$manifest_json")
        command+=("$url" --forge "$forge")
      else
        owner=$(jq -r '.pin.owner' <<<"$manifest_json")
        repo=$(jq -r '.pin.repo' <<<"$manifest_json")
        command+=("$owner" "$repo")
      fi

      branch=$(jq -r '.pin.branch // empty' <<<"$manifest_json")
      at=$(jq -r '.pin.at // empty' <<<"$manifest_json")
      version_upper_bound=$(jq -r '.pin.versionUpperBound // empty' <<<"$manifest_json")
      release_prefix=$(jq -r '.pin.releasePrefix // empty' <<<"$manifest_json")
      [[ -z "$branch" ]] || command+=(--branch "$branch")
      [[ -z "$at" ]] || command+=(--at "$at")
      [[ -z "$version_upper_bound" ]] || command+=(--upper-bound "$version_upper_bound")
      [[ -z "$release_prefix" ]] || command+=(--release-prefix "$release_prefix")
      [[ $(jq -r '.pin.preReleases' <<<"$manifest_json") == false ]] || command+=(--pre-releases)
      [[ $(jq -r '.pin.submodules' <<<"$manifest_json") == false ]] || command+=(--submodules)
      ;;
    tarball)
      url=$(jq -r '.pin.url' <<<"$manifest_json")
      command+=(tarball "$url")
      [[ $(jq -r '.pin.mutable' <<<"$manifest_json") == false ]] || command+=(--mutable)
      ;;
    *)
      echo "skills-sources-lock: unsupported normalized pin.type '$pin_type' for $name" >&2
      exit 1
      ;;
  esac

  "${command[@]}"
  names+=("$name")
done < <(jq -j 'keys[] | ., "\u0000"' "$normalized_manifests")

if ! jq -e '.version == 8 and (.pins | type == "object")' >/dev/null "$temp_lock"; then
  echo "skills-sources-lock: npins produced an unsupported lock schema (expected version 8)" >&2
  exit 1
fi

pin_count=$(jq '.pins | length' "$temp_lock")
if ((pin_count != ${#names[@]})); then
  echo "skills-sources-lock: npins lock pin count does not match the manifests" >&2
  exit 1
fi
for name in "${names[@]}"; do
  if ! jq -e --arg name "$name" '.pins | has($name)' >/dev/null "$temp_lock"; then
    echo "skills-sources-lock: npins lock is missing pin: $name" >&2
    exit 1
  fi
done

jq -n --sort-keys \
  --slurpfile manifests "$normalized_manifests" \
  --slurpfile npins "$temp_lock" \
  '{schemaVersion: 1, manifests: $manifests[0], npins: $npins[0]}' \
  >"$canonical_lock"
chmod 0644 "$canonical_lock"

if [[ -f "$lock_file" ]] && cmp -s -- "$canonical_lock" "$lock_file"; then
  echo "skills-sources-lock: lock file is already up to date: $lock_file"
  exit 0
fi

mv -f -- "$canonical_lock" "$lock_file"
echo "skills-sources-lock: updated $lock_file"
