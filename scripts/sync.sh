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

# Progress lines are printed on every synchronization, so a devShell hook run
# from direnv repeats them at every shell entry. Quiet mode drops those lines
# only; warnings and failures keep their stderr output.
quiet() {
  case "${AGENT_SKILLS_QUIET:-}" in
    1 | true | yes) return 0 ;;
    *) return 1 ;;
  esac
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
  parent="$(dirname -- "$lexical")" || return 1
  leaf="$(basename -- "$lexical")" || return 1
  resolved_parent="$(realpath -m -- "$parent")" || return 1
  realpath -m -s -- "$resolved_parent/$leaf"
}

assert_safe_common_destination() {
  local path="$1"
  local home_path="" home_resolved="" source_bundle

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

  for source_bundle in "${resolved_bundle_paths[@]}"; do
    case "$source_bundle/" in
      "$path/"*) die "destination contains the bundle: $path" ;;
    esac
    case "$path/" in
      "$source_bundle/"*) die "destination is inside the bundle: $path" ;;
    esac
  done
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

  parent="$(dirname -- "$lexical")" || return 1
  leaf="$(basename -- "$lexical")" || return 1
  resolved_parent="$(realpath -m -- "$parent")" || die "could not resolve local destination parent: $raw"
  resolved="$(realpath -m -s -- "$resolved_parent/$leaf")" || die "could not resolve local destination: $raw"
  [ "$resolved" != "$local_root" ] || die "local destination must not be the project root: $raw"
  case "$resolved/" in
    "$local_root/"*) ;;
    *) die "local destination escapes the project root through a symlink: $raw" ;;
  esac

  assert_safe_common_destination "$resolved" || return 1
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
      result="$(expand_home_path "$raw")" || return 1
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
        result="$(expand_home_path "$fallback")" || return 1
        result="$result$suffix"
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
  local bundle_path="$4"
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

# Command substitutions and conditional callers can disable errexit. Path
# resolution must propagate failures explicitly before returning a destination.
prepare_destination() {
  local raw_destination="$1"
  local structure="$2"
  local target_name="$3"
  local destination

  is_structure "$structure" || die "unknown structure '$structure' for target '$target_name'"
  if [ "$mode" = "local" ]; then
    destination="$(resolve_local_destination "$raw_destination")" || return 1
  else
    destination="$(expand_global_destination "$raw_destination")" || return 1
    assert_safe_common_destination "$destination" || return 1
  fi

  check_overwrite_permission "$destination" || return 1
  printf '%s\n' "$destination"
}

sync_destination() {
  local destination="$1"
  local structure="$2"
  local target_name="$3"
  local bundle_path="$4"
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
      write_marker "$destination" "$target_name" "$structure" "$bundle_path"
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

  quiet || printf '%s: installed %s to %s\n' "$PROGRAM_NAME" "$target_name" "$destination"
}

# Global overrides replace the configured targets. Local overrides replace
# destinations by target position, retaining each target's structure; extra
# destinations use the configured override structure in either mode.
build_target_plan() {
  local override_raw="" override_env_var

  if jq -e '.overrides.enabled' "$config_path" >/dev/null; then
    override_env_var="$(jq -r '.overrides.envVar' "$config_path")"
    override_raw="$(printenv "$override_env_var" 2>/dev/null || true)"
    if [ -n "$override_raw" ] && jq -e '.overrides.hasTargetRestrictions' "$config_path" >/dev/null; then
      die "$override_env_var cannot be used with per-skill agents restrictions; configure named targets.<name>.dest instead"
    fi
  fi

  jq -c --arg overrideRaw "$override_raw" '
    . as $config |
    [$overrideRaw | scan("[^ \t\n]+")] as $overrides |
    [.targets[] | {name, structure, destination: .dest, bundle}] as $targets |
    def added_override($index): {
      name: "override-\($index)",
      structure: $config.overrides.structure,
      destination: $overrides[$index],
      bundle: $config.bundle
    };
    if .mode == "global" and ($overrides | length) > 0 then
      [range(0; $overrides | length) | added_override(.)]
    elif .mode == "local" then
      [$targets | to_entries[] |
        .key as $index | .value |
        .destination = ($overrides[$index] // .destination)
      ] + [range($targets | length; $overrides | length) | added_override(.)]
    else
      $targets
    end
  ' "$config_path"
}

resolve_bundle_path() {
  local source_bundle="$1"

  [ -d "$source_bundle" ] || die "bundle directory not found: $source_bundle"
  realpath -- "$source_bundle" || die "could not resolve bundle: $source_bundle"
}

# Resolve every source before inspecting destinations, so overlap guards also
# protect the sources used by other targets.
resolve_bundle_plan() {
  local plan="$1"
  local target resolved_bundle

  while IFS= read -r target; do
    resolved_bundle="$(resolve_bundle_path "$(jq -r '.bundle' <<<"$target")")" || return 1
    jq -c --arg bundle "$resolved_bundle" '.bundle = $bundle' <<<"$target" || return 1
  done < <(jq -c '.[]' <<<"$plan")
}

# Resolve and authorize every destination before any synchronization starts.
# Emit one JSON record per target, preserving literal path characters.
resolve_target_plan() {
  local plan="$1"
  local target destination

  while IFS= read -r target; do
    destination="$(prepare_destination \
      "$(jq -r '.destination' <<<"$target")" \
      "$(jq -r '.structure' <<<"$target")" \
      "$(jq -r '.name' <<<"$target")")" || return 1
    jq -c --arg destination "$destination" '.destination = $destination' <<<"$target" || return 1
  done < <(jq -c '.[]' <<<"$plan")
}

# Targets sharing a canonical destination can synchronize once when their
# structures and bundles match. Keep the first target's name for a stable marker.
# Different bundles or structures and nested destinations cannot synchronize together.
merge_target_plan() {
  jq -c '
    reduce .[] as $target ([];
      if any(.[];
        .destination == $target.destination and .structure != $target.structure
      ) then
        error("conflicting structures for destination: \($target.destination)")
      elif any(.[];
        .destination == $target.destination and .bundle != $target.bundle
      ) then
        error("conflicting bundles for destination: \($target.destination)")
      elif any(.[];
        (.destination | startswith($target.destination + "/")) or
        (.destination as $existing | $target.destination | startswith($existing + "/"))
      ) then
        error("destinations overlap: \($target.destination)")
      elif any(.[]; .destination == $target.destination) then
        .
      else
        . + [$target]
      end
    )
  ' <<<"$1"
}

execute_target_plan() {
  local plan="$1"
  local target

  while IFS= read -r target; do
    sync_destination \
      "$(jq -r '.destination' <<<"$target")" \
      "$(jq -r '.structure' <<<"$target")" \
      "$(jq -r '.name' <<<"$target")" \
      "$(jq -r '.bundle' <<<"$target")"
  done < <(jq -c '.[]' <<<"$plan")
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
  .schemaVersion == 2 and
  (.mode == "local" or .mode == "global") and
  (.bundle | safe_text and length > 0) and
  (.targets | type == "array") and
  (.targets | all(.[];
    type == "object" and
    ((keys - ["bundle", "dest", "name", "structure"]) | length == 0) and
    (.bundle | safe_text and length > 0) and
    (.name | safe_text and length > 0) and
    (.dest | safe_text and length > 0) and
    (.structure | type == "string" and structure)
  )) and
  ((.targets | map(.name) | unique | length) == (.targets | length)) and
  (.excludePatterns | type == "array" and all(.[]; safe_text)) and
  (.overrides | type == "object") and
  (.overrides | ((keys - ["enabled", "envVar", "hasTargetRestrictions", "structure"]) | length == 0)) and
  (.overrides.enabled | type == "boolean") and
  (.overrides.hasTargetRestrictions | type == "boolean") and
  (.overrides.envVar | safe_text and test("^[A-Za-z_][A-Za-z0-9_]*$")) and
  (.overrides.structure | type == "string" and structure)
' "$config_path" >/dev/null || die "invalid configuration in $config_path"

mode="$(jq -r '.mode' "$config_path")"
bundle="$(jq -r '.bundle' "$config_path")"

local_root=""
if [ "$mode" = "local" ]; then
  root_input="${AGENT_SKILLS_ROOT:-$PWD}"
  [ -d "$root_input" ] || die "local root is not a directory: $root_input"
  local_root="$(realpath -- "$root_input")" || die "could not resolve local root: $root_input"
  [ "$local_root" != "/" ] || die "local root must not be /"
fi

plan="$(build_target_plan)"
bundle_path="$(resolve_bundle_path "$bundle")"
plan="$(resolve_bundle_plan "$plan" | jq -sc '.')"
resolved_bundle_paths=("$bundle_path")
while IFS= read -r resolved_bundle; do
  resolved_bundle_paths+=("$resolved_bundle")
done < <(jq -r '.[].bundle' <<<"$plan")
plan="$(resolve_target_plan "$plan" | jq -sc '.')"
plan="$(merge_target_plan "$plan")"
execute_target_plan "$plan"
