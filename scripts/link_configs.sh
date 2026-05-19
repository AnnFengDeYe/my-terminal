#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
TARGET_HOME="${TEST_HOME:-$HOME}"

# shellcheck source=scripts/backup.sh
. "$SCRIPT_DIR/backup.sh"
# shellcheck source=scripts/config_sources.sh
. "$SCRIPT_DIR/config_sources.sh"
# shellcheck source=scripts/path_helpers.sh
. "$SCRIPT_DIR/path_helpers.sh"
# shellcheck source=scripts/common.sh
. "$SCRIPT_DIR/common.sh"

DRY_RUN=0
YES=0
DO_BACKUP=0

usage() {
  cat <<'EOF'
Usage: scripts/link_configs.sh [--dry-run] [--yes] [--backup]

Safely links repository config copies into the target HOME.
Without --yes, no filesystem changes are made.
EOF
}

log() {
  printf '%s\n' "$*"
}

die_link() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
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
      --backup)
        DO_BACKUP=1
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        die_link "unknown option: $1"
        ;;
    esac
  done
}

ensure_target_under_home() {
  local target="$1"
  [[ "$target" == "$TARGET_HOME"/* ]] || die_link "target is outside HOME: $target"
}

ensure_parent_dir() {
  local target="$1"
  local parent
  parent="$(dirname "$target")"
  ensure_target_under_home "$target"

  if [[ -d "$parent" ]]; then
    return 0
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    log "mkdir: would create $parent"
    return 0
  fi

  [[ "$YES" == "1" ]] || die_link "refusing to create $parent without --yes"
  mkdir -p "$parent"
  log "mkdir: created $parent"
}

create_link() {
  local source="$1"
  local target="$2"

  ensure_parent_dir "$target"

  if [[ "$DRY_RUN" == "1" ]]; then
    log "link: would create $target -> $source"
    return 0
  fi

  [[ "$YES" == "1" ]] || die_link "refusing to link $target without --yes"
  ln -s "$source" "$target"
  log "link: created $target -> $source"
}

handle_existing_target() {
  local source="$1"
  local target="$2"

  if [[ "$DO_BACKUP" != "1" ]]; then
    if [[ "$DRY_RUN" == "1" ]]; then
      log "needs-backup: $target exists; real linking would require --backup --yes"
      return 0
    fi
    log "refuse: $target exists; re-run with --backup --yes to replace it safely"
    return 1
  fi

  backup_path "$target" "$DRY_RUN" "$TARGET_HOME"
  create_link "$source" "$target"
}

link_one() {
  local rel_source="$1"
  local rel_target="$2"
  local source="$REPO_ROOT/$rel_source"
  local target="$TARGET_HOME/$rel_target"
  local source_canon
  local link_canon

  ensure_target_under_home "$target"

  if [[ ! -e "$source" && ! -L "$source" ]]; then
    log "skip: missing repository config $rel_source"
    return 0
  fi

  source_canon="$(canonical_existing_path "$source")"

  log "check: $rel_source -> $target"

  if [[ ! -e "$target" && ! -L "$target" ]]; then
    create_link "$source_canon" "$target"
    return 0
  fi

  if [[ -L "$target" ]]; then
    link_canon="$(resolve_link_target "$target" 2>/dev/null || true)"
    if [[ "$link_canon" == "$source_canon" ]]; then
      log "skip: $target already points to this repository"
      return 0
    fi

    log "conflict: $target is a symlink to another location"
    handle_existing_target "$source_canon" "$target"
    return 0
  fi

  if [[ -f "$target" ]]; then
    log "conflict: $target is an existing file"
    handle_existing_target "$source_canon" "$target"
    return 0
  fi

  if [[ -d "$target" ]]; then
    log "conflict: $target is an existing directory"
    handle_existing_target "$source_canon" "$target"
    return 0
  fi

  log "conflict: $target exists with unsupported type"
  handle_existing_target "$source_canon" "$target"
}

main() {
  parse_args "$@"
  ensure_safe_home

  if [[ "$DRY_RUN" != "1" && "$YES" != "1" ]]; then
    die_link "no changes made; pass --dry-run to preview or --yes to write"
  fi

  log "Repository: $REPO_ROOT"
  log "Target HOME: $TARGET_HOME"
  [[ "$DRY_RUN" == "1" ]] && log "Mode: dry-run"

  local failures=0
  local os_name
  local ghostty_source

  os_name="$("$SCRIPT_DIR/detect_os.sh")"
  ghostty_source="$(select_ghostty_source "$REPO_ROOT" "$os_name")"

  link_one "configs/zsh/zshrc" ".zshrc" || failures=$((failures + 1))
  link_one "configs/zsh/zprofile" ".zprofile" || failures=$((failures + 1))
  link_one "configs/zsh/zshenv" ".zshenv" || failures=$((failures + 1))
  link_one "configs/tmux/tmux.conf" ".tmux.conf" || failures=$((failures + 1))
  link_one "configs/starship/starship.toml" ".config/starship.toml" || failures=$((failures + 1))
  link_one "$ghostty_source" ".config/ghostty/config" || failures=$((failures + 1))
  link_one "configs/yazi" ".config/yazi" || failures=$((failures + 1))
  link_one "configs/lazygit/config.yml" ".config/lazygit/config.yml" || failures=$((failures + 1))
  link_one "configs/nvim" ".config/nvim" || failures=$((failures + 1))
  link_one "configs/git/gitconfig" ".gitconfig" || failures=$((failures + 1))

  if [[ "$failures" -gt 0 ]]; then
    die_link "$failures link operation(s) need attention"
  fi
}

main "$@"
