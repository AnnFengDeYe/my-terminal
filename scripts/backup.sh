#!/usr/bin/env bash
set -euo pipefail

timestamp() {
  date +%Y%m%d-%H%M%S
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: scripts/backup.sh [--dry-run] ABSOLUTE_PATH

Safely moves a target under HOME to an adjacent .backup.TIMESTAMP path.
EOF
}

is_under_home() {
  local path="$1"
  local home_root="${2:-${TEST_HOME:-$HOME}}"

  [[ -n "$home_root" ]] || return 1
  [[ "$path" == "$home_root"/* ]]
}

validate_backup_target() {
  local target="$1"
  local home_root="${2:-${TEST_HOME:-$HOME}}"

  [[ -n "$target" ]] || die "backup target is empty"
  [[ "$target" == /* ]] || die "backup target must be absolute: $target"
  [[ "$target" != "/" ]] || die "refusing to backup /"
  [[ "$target" != "$home_root" ]] || die "refusing to backup HOME itself"
  [[ "$target" != *$'\n'* ]] || die "refusing path with newline"
  is_under_home "$target" "$home_root" || die "backup target is outside target HOME: $target"
}

next_backup_path() {
  local target="$1"
  local backup
  local i=1

  backup="${target}.backup.$(timestamp)"

  while [[ -e "$backup" || -L "$backup" ]]; do
    backup="${target}.backup.$(timestamp).$i"
    i=$((i + 1))
  done

  printf '%s\n' "$backup"
}

backup_path() {
  local target="$1"
  local dry_run="${2:-0}"
  local home_root="${3:-${TEST_HOME:-$HOME}}"
  local backup

  validate_backup_target "$target" "$home_root"

  if [[ ! -e "$target" && ! -L "$target" ]]; then
    printf 'backup: skipped missing %s\n' "$target"
    return 0
  fi

  backup="$(next_backup_path "$target")"

  if [[ "$dry_run" == "1" ]]; then
    printf 'backup: would move %s -> %s\n' "$target" "$backup"
    return 0
  fi

  mv "$target" "$backup"
  printf 'backup: moved %s -> %s\n' "$target" "$backup"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  dry_run=0
  target=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        dry_run=1
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      --)
        shift
        break
        ;;
      -*)
        die "unknown option: $1"
        ;;
      *)
        target="$1"
        shift
        ;;
    esac
  done

  [[ -n "$target" ]] || die "usage: $0 [--dry-run] ABSOLUTE_PATH"
  backup_path "$target" "$dry_run" "${TEST_HOME:-$HOME}"
fi
