#!/usr/bin/env bash

canonical_existing_path() {
  local path="$1"
  local dir
  local base

  if [[ -d "$path" && ! -L "$path" ]]; then
    (cd "$path" && pwd -P)
    return 0
  fi

  dir="$(dirname "$path")"
  base="$(basename "$path")"
  (cd "$dir" && printf '%s/%s\n' "$(pwd -P)" "$base")
}

resolve_link_target() {
  local link_path="$1"
  local link_value
  local link_dir

  link_value="$(readlink "$link_path")"
  if [[ "$link_value" == /* ]]; then
    canonical_existing_path "$link_value"
  else
    link_dir="$(dirname "$link_path")"
    canonical_existing_path "$link_dir/$link_value"
  fi
}
