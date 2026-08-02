#!/usr/bin/env bash

set -euo pipefail

[[ ${1-} == --lock-file && -n ${2-} ]] || {
  echo "fake-npins: expected --lock-file FILE" >&2
  exit 2
}
lock_file=$2
shift 2

case "${1-}" in
  init)
    [[ ${2-} == --bare ]] || exit 2
    jq -n '{pins: {}, version: 8}' >"$lock_file"
    ;;
  add)
    shift
    [[ ${1-} == --name && -n ${2-} ]] || exit 2
    name=$2
    shift 2
    [[ "$name" != fail ]] || {
      echo "fake-npins: intentional failure" >&2
      exit 1
    }

    pin_type=${1-}
    shift
    branch=null
    case "$pin_type" in
      git)
        url=${1-}
        shift
        repository=$(jq -cn --arg url "$url" '{type: "Git", $url}')
        ;;
      github)
        owner=${1-}
        repo=${2-}
        shift 2
        repository=$(jq -cn --arg owner "$owner" --arg repo "$repo" '{type: "GitHub", $owner, $repo}')
        ;;
      tarball)
        url=${1-}
        shift
        pin=$(jq -cn --arg url "$url" '{type: "Url", $url, hash: "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=", unpack: true}')
        ;;
      *) exit 2 ;;
    esac

    while (($# > 0)); do
      case "$1" in
        --branch)
          branch=$(jq -cn --arg value "$2" '$value')
          shift 2
          ;;
        --at | --forge | --upper-bound | --release-prefix)
          shift 2
          ;;
        --pre-releases | --submodules | --mutable)
          shift
          ;;
        *) exit 2 ;;
      esac
    done

    if [[ "$pin_type" != tarball ]]; then
      lock_type=Git
      [[ "$branch" != null ]] || lock_type=GitRelease
      pin=$(jq -cn \
        --argjson branch "$branch" \
        --argjson repository "$repository" \
        --arg lockType "$lock_type" \
        '{
          type: $lockType,
          $repository,
          $branch,
          submodules: false,
          revision: "0000000000000000000000000000000000000000",
          url: null,
          hash: "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
        }')
    fi

    next_lock="${lock_file}.next"
    jq --arg name "$name" --argjson pin "$pin" '.pins[$name] = $pin' "$lock_file" >"$next_lock"
    mv -f -- "$next_lock" "$lock_file"
    ;;
  *) exit 2 ;;
esac
