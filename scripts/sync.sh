#!/usr/bin/env bash

set -euo pipefail

readonly PROGRAM_NAME="agent-skills"
readonly MARKER_NAME=".agent-skills-managed.json"

die() {
  printf '%s: %s\n' "$PROGRAM_NAME" "$*" >&2
  exit 1
}

warn() {
  printf '%s: %s\n' "$PROGRAM_NAME" "$*" >&2
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

is_structure() {
  case "$1" in
    link | symlink-tree | copy-tree) return 0 ;;
    *) return 1 ;;
  esac
}

directory_is_empty() (
  local path="$1"
  local entries

  shopt -s nullglob dotglob
  entries=("$path"/*)
  [ "${#entries[@]}" -eq 0 ]
)

is_nix_store_symlink() {
  local path="$1"
  local resolved

  [ -L "$path" ] || return 1
  resolved="$(realpath -- "$path" 2>/dev/null)" || return 1
  case "$resolved" in
    /nix/store/*) return 0 ;;
    *) return 1 ;;
  esac
}

has_valid_marker() {
  local path="$1"
  local marker="$path/$MARKER_NAME"

  [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
  jq -e '
    type == "object" and
    ((keys - ["bundle", "managedBy", "mode", "schemaVersion", "structure", "target"]) | length == 0) and
    .schemaVersion == 1 and
    .managedBy == "agent-skills-nix" and
    (.mode == "local" or .mode == "global") and
    (.bundle | type == "string" and length > 0) and
    (.target | type == "string" and length > 0) and
    (.structure == "symlink-tree" or .structure == "copy-tree")
  ' "$marker" >/dev/null 2>&1
}

is_managed_destination() {
  local path="$1"

  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    return 0
  fi
  if is_nix_store_symlink "$path"; then
    return 0
  fi
  if [ -L "$path" ]; then
    return 1
  fi
  if [ -d "$path" ] && directory_is_empty "$path"; then
    return 0
  fi
  if [ -d "$path" ] && has_valid_marker "$path"; then
    return 0
  fi
  return 1
}

ensure_writable_tree() {
  local path="$1"

  [ -d "$path" ] || return 0
  chmod -R u+w -- "$path" 2>/dev/null || true
}

# Canonicalize the parent but deliberately do not dereference the final path.
# A final symlink into /nix/store is a safe, replaceable managed destination.
canonical_destination() {
  local path="$1"
  local lexical parent leaf resolved_parent

  lexical="$(realpath -m -s -- "$path")" || return 1
  if [ "$lexical" = "/" ]; then
    printf '/\n'
    return 0
  fi
  parent="$(dirname -- "$lexical")"
  leaf="$(basename -- "$lexical")"
  resolved_parent="$(realpath -m -- "$parent")" || return 1
  realpath -m -s -- "$resolved_parent/$leaf"
}

assert_safe_common_destination() {
  local path="$1"
  local home_path="" home_resolved=""

  [ "$path" != "/" ] || die "refusing to synchronize to /"
  if [ -n "${HOME:-}" ]; then
    home_path="$(canonical_destination "$HOME")" || die "could not normalize HOME"
    home_resolved="$(realpath -m -- "$HOME")" || die "could not resolve HOME"
    if [ "$path" = "$home_path" ] || [ "$path" = "$home_resolved" ]; then
      die "refusing to synchronize to HOME itself: $path"
    fi
  fi

  case "$path" in
    /nix/store | /nix/store/*) die "refusing to synchronize inside /nix/store: $path" ;;
  esac

  case "$bundle_path/" in
    "$path/"*) die "destination contains the bundle: $path" ;;
  esac
  case "$path/" in
    "$bundle_path/"*) die "destination is inside the bundle: $path" ;;
  esac
}

resolve_local_destination() {
  local raw="$1"
  local lexical parent leaf resolved_parent resolved

  [ -n "$raw" ] || die "local destination must not be empty"
  case "$raw" in
    /*) die "local destination must be relative: $raw" ;;
  esac

  lexical="$(realpath -m -s -- "$local_root/$raw")" || die "could not normalize local destination: $raw"
  [ "$lexical" != "$local_root" ] || die "local destination must not be the project root: $raw"
  case "$lexical/" in
    "$local_root/"*) ;;
    *) die "local destination escapes the project root: $raw" ;;
  esac

  parent="$(dirname -- "$lexical")"
  leaf="$(basename -- "$lexical")"
  resolved_parent="$(realpath -m -- "$parent")" || die "could not resolve local destination parent: $raw"
  resolved="$(realpath -m -s -- "$resolved_parent/$leaf")" || die "could not resolve local destination: $raw"
  [ "$resolved" != "$local_root" ] || die "local destination must not be the project root: $raw"
  case "$resolved/" in
    "$local_root/"*) ;;
    *) die "local destination escapes the project root through a symlink: $raw" ;;
  esac

  assert_safe_common_destination "$resolved"
  printf '%s\n' "$resolved"
}

expand_home_path() {
  local raw="$1"

  [ -n "${HOME:-}" ] || die "HOME is required to expand destination: $raw"
  case "$raw" in
    \$HOME) printf '%s\n' "$HOME" ;;
    \$HOME/*) printf '%s%s\n' "$HOME" "${raw#\$HOME}" ;;
    *) die "unsupported HOME expression in destination: $raw" ;;
  esac
}

expand_global_destination() {
  local raw="$1"
  local result="" after_open inside suffix variable fallback variable_value

  [ -n "$raw" ] || die "global destination must not be empty"
  case "$raw" in
    \$HOME | \$HOME/*)
      result="$(expand_home_path "$raw")"
      ;;
    \$\{*)
      after_open="${raw:2}"
      case "$after_open" in
        *'}'*) ;;
        *) die "invalid destination expression: $raw" ;;
      esac
      inside="${after_open%%\}*}"
      suffix="${after_open#*\}}"
      case "$inside" in
        *':-'*) ;;
        *) die "invalid destination fallback expression: $raw" ;;
      esac
      variable="${inside%%:-*}"
      fallback="${inside#*:-}"
      [[ "$variable" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "invalid destination environment variable: $variable"
      case "$suffix" in
        '' | /*) ;;
        *) die "destination suffix must be empty or begin with '/': $raw" ;;
      esac
      if variable_value="$(printenv "$variable" 2>/dev/null)" && [ -n "$variable_value" ]; then
        result="$variable_value$suffix"
      else
        result="$(expand_home_path "$fallback")$suffix"
      fi
      ;;
    \~)
      [ -n "${HOME:-}" ] || die "HOME is required to expand destination: $raw"
      result="$HOME"
      ;;
    \~/*)
      [ -n "${HOME:-}" ] || die "HOME is required to expand destination: $raw"
      result="$HOME/${raw#\~/}"
      ;;
    *)
      case "$raw" in
        *'$'*) die "unsupported variable expression in destination: $raw" ;;
      esac
      result="$raw"
      ;;
  esac

  case "$result" in
    *'$'*) die "unexpanded '$' in destination: $raw" ;;
    /*) ;;
    *) die "global destination must resolve to an absolute path: $raw" ;;
  esac
  canonical_destination "$result" || die "could not resolve global destination: $raw"
}

write_marker() {
  local destination="$1"
  local target_name="$2"
  local structure="$3"
  local marker="$destination/$MARKER_NAME"
  local temporary="$destination/.${MARKER_NAME}.tmp.$$"

  chmod u+w -- "$destination" 2>/dev/null || true
  jq -n \
    --arg mode "$mode" \
    --arg bundle "$bundle_path" \
    --arg target "$target_name" \
    --arg structure "$structure" \
    '{schemaVersion: 1, managedBy: "agent-skills-nix", mode: $mode, bundle: $bundle, target: $target, structure: $structure}' \
    >"$temporary"
  mv -f -- "$temporary" "$marker"
}

check_overwrite_permission() {
  local destination="$1"

  if is_managed_destination "$destination"; then
    return 0
  fi
  if [ "${AGENT_SKILLS_FORCE:-}" = "1" ]; then
    warn "$destination is not managed; AGENT_SKILLS_FORCE=1 permits replacement"
    return 0
  fi
  die "$destination exists and is non-empty but has no $MARKER_NAME marker; set AGENT_SKILLS_FORCE=1 to replace it"
}

prepare_destination() {
  local raw_destination="$1"
  local structure="$2"
  local target_name="$3"
  local destination

  is_structure "$structure" || die "unknown structure '$structure' for target '$target_name'"
  if [ "$mode" = "local" ]; then
    destination="$(resolve_local_destination "$raw_destination")"
  else
    destination="$(expand_global_destination "$raw_destination")"
    assert_safe_common_destination "$destination"
  fi

  check_overwrite_permission "$destination"
  printf '%s\n' "$destination"
}

sync_destination() {
  local destination="$1"
  local structure="$2"
  local target_name="$3"
  local -a rsync_args

  case "$structure" in
    link)
      mkdir -p -- "$(dirname -- "$destination")"
      if [ -e "$destination" ] || [ -L "$destination" ]; then
        rm -rf -- "$destination"
      fi
      ln -s -- "$bundle_path" "$destination"
      ;;
    symlink-tree | copy-tree)
      if [ -L "$destination" ] || { [ -e "$destination" ] && [ ! -d "$destination" ]; }; then
        rm -rf -- "$destination"
      fi
      mkdir -p -- "$destination"
      ensure_writable_tree "$destination"
      # Claim ownership before rsync so an interrupted first synchronization
      # can be retried without requiring AGENT_SKILLS_FORCE.
      write_marker "$destination" "$target_name" "$structure"
      rsync_args=(-a --delete --filter "P /$MARKER_NAME" --exclude "/$MARKER_NAME")
      if [ "$structure" = "copy-tree" ]; then
        rsync_args+=(-L)
      fi
      while IFS= read -r exclude_pattern; do
        rsync_args+=(--exclude="$exclude_pattern")
      done < <(jq -r '.excludePatterns[]' "$config_path")
      rsync "${rsync_args[@]}" -- "$bundle_path/" "$destination/"
      chmod u+w -- "$destination"
      ;;
  esac

  printf '%s: installed %s to %s\n' "$PROGRAM_NAME" "$target_name" "$destination"
}

[ "$#" -eq 1 ] || die "usage: sync.sh CONFIG_JSON_PATH"
config_path="$1"
[ -f "$config_path" ] || die "configuration file not found: $config_path"

require_command jq
require_command rsync
require_command realpath
require_command dirname
require_command basename
require_command printenv

jq -e '
  def safe_text:
    type == "string" and (test("[\\x00-\\x1F\\x7F]") | not);
  def structure:
    . == "link" or . == "symlink-tree" or . == "copy-tree";
  type == "object" and
  ((keys - ["bundle", "excludePatterns", "mode", "overrides", "schemaVersion", "targets"]) | length == 0) and
  .schemaVersion == 1 and
  (.mode == "local" or .mode == "global") and
  (.bundle | safe_text and length > 0) and
  (.targets | type == "array") and
  (.targets | all(.[];
    type == "object" and
    ((keys - ["dest", "name", "structure"]) | length == 0) and
    (.name | safe_text and length > 0) and
    (.dest | safe_text and length > 0) and
    (.structure | type == "string" and structure)
  )) and
  ((.targets | map(.name) | unique | length) == (.targets | length)) and
  (.excludePatterns | type == "array" and all(.[]; safe_text)) and
  (.overrides | type == "object") and
  (.overrides | ((keys - ["enabled", "envVar", "structure"]) | length == 0)) and
  (.overrides.enabled | type == "boolean") and
  (.overrides.envVar | safe_text and test("^[A-Za-z_][A-Za-z0-9_]*$")) and
  (.overrides.structure | type == "string" and structure)
' "$config_path" >/dev/null || die "invalid configuration in $config_path"

mode="$(jq -r '.mode' "$config_path")"
bundle="$(jq -r '.bundle' "$config_path")"
[ -d "$bundle" ] || die "bundle directory not found: $bundle"
bundle_path="$(realpath -- "$bundle")" || die "could not resolve bundle: $bundle"

local_root=""
if [ "$mode" = "local" ]; then
  root_input="${AGENT_SKILLS_ROOT:-$PWD}"
  [ -d "$root_input" ] || die "local root is not a directory: $root_input"
  local_root="$(realpath -- "$root_input")" || die "could not resolve local root: $root_input"
  [ "$local_root" != "/" ] || die "local root must not be /"
fi

override_enabled="$(jq -r '.overrides.enabled' "$config_path")"
override_env_var="$(jq -r '.overrides.envVar' "$config_path")"
override_structure="$(jq -r '.overrides.structure' "$config_path")"
override_raw=""
overrides=()
if [ "$override_enabled" = "true" ]; then
  override_raw="$(printenv "$override_env_var" 2>/dev/null || true)"
  if [ -n "$override_raw" ]; then
    IFS=$' \t\n' read -r -a overrides <<<"$override_raw"
  fi
fi

target_names=()
target_structures=()
target_destinations=()

if [ "$mode" = "global" ] && [ "${#overrides[@]}" -gt 0 ]; then
  index=0
  for destination in "${overrides[@]}"; do
    target_names+=("override-$index")
    target_structures+=("$override_structure")
    target_destinations+=("$destination")
    index=$((index + 1))
  done
else
  target_count="$(jq '.targets | length' "$config_path")"
  index=0
  while [ "$index" -lt "$target_count" ]; do
    target_name="$(jq -r --argjson index "$index" '.targets[$index].name' "$config_path")"
    target_structure="$(jq -r --argjson index "$index" '.targets[$index].structure' "$config_path")"
    target_destination="$(jq -r --argjson index "$index" '.targets[$index].dest' "$config_path")"
    if [ "$mode" = "local" ] && [ "$index" -lt "${#overrides[@]}" ]; then
      target_destination="${overrides[$index]}"
    fi
    target_names+=("$target_name")
    target_structures+=("$target_structure")
    target_destinations+=("$target_destination")
    index=$((index + 1))
  done

  if [ "$mode" = "local" ] && [ "${#overrides[@]}" -gt "$target_count" ]; then
    index="$target_count"
    while [ "$index" -lt "${#overrides[@]}" ]; do
      target_names+=("override-$index")
      target_structures+=("copy-tree")
      target_destinations+=("${overrides[$index]}")
      index=$((index + 1))
    done
  fi
fi

# Resolve and authorize every target before changing any destination. Also
# reject equal or nested destinations, whose --delete operations would race.
resolved_destinations=()
index=0
while [ "$index" -lt "${#target_names[@]}" ]; do
  destination="$(prepare_destination \
    "${target_destinations[$index]}" \
    "${target_structures[$index]}" \
    "${target_names[$index]}")"
  for existing_destination in "${resolved_destinations[@]}"; do
    case "$destination/" in
      "$existing_destination/"*)
        die "destinations overlap: $existing_destination and $destination"
        ;;
    esac
    case "$existing_destination/" in
      "$destination/"*)
        die "destinations overlap: $destination and $existing_destination"
        ;;
    esac
  done
  resolved_destinations+=("$destination")
  index=$((index + 1))
done

index=0
while [ "$index" -lt "${#target_names[@]}" ]; do
  sync_destination \
    "${resolved_destinations[$index]}" \
    "${target_structures[$index]}" \
    "${target_names[$index]}"
  index=$((index + 1))
done
