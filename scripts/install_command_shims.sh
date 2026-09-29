#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
TARGET_HOME="${TEST_HOME:-$HOME}"

# shellcheck source=scripts/common.sh
. "$SCRIPT_DIR/common.sh"

DRY_RUN=0
YES=0
SHIM_DIR="$TARGET_HOME/.local/bin"

# Debian, Ubuntu, and Raspberry Pi OS install these tools under another name.
# The zsh aliases, fzf previews, Yazi, and LazyVim all call the upstream name.
SHIMS=(
  "bat:batcat"
  "fd:fdfind"
)

usage() {
  cat <<'EOF'
Usage: scripts/install_command_shims.sh [--dry-run] [--yes]

Links renamed distribution binaries to the names the tools expect:
  ~/.local/bin/bat -> batcat
  ~/.local/bin/fd  -> fdfind

A link is only created when the upstream name is missing and the renamed
binary exists. Existing files are never replaced. Without --yes, no changes
are made.
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '%s\n' "$*"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      --yes)
        YES=1
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        die "unknown option: $1"
        ;;
    esac
  done
}

link_shim() {
  local alt="$2"
  local alt_path
  local name="$1"
  local target="$SHIM_DIR/$name"

  if command -v "$name" >/dev/null 2>&1; then
    log "ok: $name found at $(command -v "$name")"
    return 0
  fi

  if ! command -v "$alt" >/dev/null 2>&1; then
    log "skip: neither $name nor $alt is installed"
    return 0
  fi
  alt_path="$(command -v "$alt")"

  if [[ -e "$target" || -L "$target" ]]; then
    log "skip: $target exists but does not run; leaving it alone"
    return 0
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    log "shim: would link $target -> $alt_path"
    return 0
  fi

  [[ "$YES" == "1" ]] || die "refusing to link $target without --yes"
  mkdir -p "$SHIM_DIR"
  ln -s "$alt_path" "$target"
  log "shim: linked $target -> $alt_path"
}

main() {
  local alt
  local name
  local shim

  parse_args "$@"
  ensure_safe_home "$TARGET_HOME"

  if [[ "$DRY_RUN" != "1" && "$YES" != "1" ]]; then
    die "no changes made; pass --dry-run to preview or --yes to link"
  fi

  PATH="$(command_search_path "$TARGET_HOME")"
  export PATH

  log "Shim directory: $SHIM_DIR"
  [[ "$DRY_RUN" == "1" ]] && log "Mode: dry-run"

  for shim in "${SHIMS[@]}"; do
    name="${shim%%:*}"
    alt="${shim#*:}"
    link_shim "$name" "$alt"
  done
}

main "$@"
