#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
TARGET_HOME="${TEST_HOME:-$HOME}"

# shellcheck source=scripts/config_sources.sh
. "$SCRIPT_DIR/config_sources.sh"

DRY_RUN=0
YES=0

usage() {
  cat <<'EOF'
Usage: scripts/restore_backups.sh [--dry-run] [--yes]

Restores the latest adjacent .backup.YYYYMMDD-HHMMSS copy for each managed
config target. It only unlinks targets that are symlinks pointing to this
repository. Without --yes, no filesystem changes are made.
EOF
}

log() {
  printf '%s\n' "$*"
}

die() {
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

ensure_safe_home() {
  [[ -n "$TARGET_HOME" ]] || die "target HOME is empty"
  [[ "$TARGET_HOME" == /* ]] || die "target HOME must be absolute: $TARGET_HOME"
  [[ "$TARGET_HOME" != "/" ]] || die "refusing to use / as HOME"
  [[ "$TARGET_HOME" != *$'\n'* ]] || die "refusing HOME with newline"
}

ensure_under_home() {
  local path="$1"
  [[ "$path" == "$TARGET_HOME"/* ]] || die "path is outside target HOME: $path"
}

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

latest_backup_for() {
  local target="$1"
  local backups=()
  local backup

  shopt -s nullglob
  backups=("$target".backup.*)
  shopt -u nullglob

  [[ "${#backups[@]}" -gt 0 ]] || return 1

  backup="$(printf '%s\n' "${backups[@]}" | sort | tail -n 1)"
  printf '%s\n' "$backup"
}

restore_one() {
  local rel_source="$1"
  local rel_target="$2"
  local source="$REPO_ROOT/$rel_source"
  local target="$TARGET_HOME/$rel_target"
  local source_canon
  local link_canon
  local backup=""
  local has_backup=0
  local managed_link=0

  ensure_under_home "$target"

  if [[ -e "$source" || -L "$source" ]]; then
    source_canon="$(canonical_existing_path "$source")"
  else
    source_canon=""
  fi

  if backup="$(latest_backup_for "$target" 2>/dev/null)"; then
    has_backup=1
    ensure_under_home "$backup"
  fi

  if [[ -L "$target" && -n "$source_canon" ]]; then
    link_canon="$(resolve_link_target "$target" 2>/dev/null || true)"
    [[ "$link_canon" == "$source_canon" ]] && managed_link=1
  fi

  log "check: $target"

  if [[ "$managed_link" == "1" ]]; then
    if [[ "$DRY_RUN" == "1" ]]; then
      log "restore: would unlink repository symlink $target"
      if [[ "$has_backup" == "1" ]]; then
        log "restore: would move $backup -> $target"
      else
        log "restore: no backup found; target would be left absent"
      fi
      return 0
    fi

    [[ "$YES" == "1" ]] || die "refusing to restore $target without --yes"
    unlink "$target"
    log "restore: unlinked $target"

    if [[ "$has_backup" == "1" ]]; then
      mv "$backup" "$target"
      log "restore: moved $backup -> $target"
    else
      log "restore: no backup found for $target"
    fi
    return 0
  fi

  if [[ ! -e "$target" && ! -L "$target" && "$has_backup" == "1" ]]; then
    if [[ "$DRY_RUN" == "1" ]]; then
      log "restore: would move $backup -> $target"
      return 0
    fi

    [[ "$YES" == "1" ]] || die "refusing to restore $target without --yes"
    mv "$backup" "$target"
    log "restore: moved $backup -> $target"
    return 0
  fi

  if [[ -e "$target" || -L "$target" ]]; then
    log "skip: $target is not a symlink managed by this repository"
    return 0
  fi

  log "skip: no target or backup for $target"
}

restore_one_any() {
  local rel_target="$1"
  shift
  local rel_source
  local target="$TARGET_HOME/$rel_target"
  local source
  local source_canon
  local link_canon
  local backup=""
  local has_backup=0
  local managed_link=0

  ensure_under_home "$target"

  if backup="$(latest_backup_for "$target" 2>/dev/null)"; then
    has_backup=1
    ensure_under_home "$backup"
  fi

  if [[ -L "$target" ]]; then
    for rel_source in "$@"; do
      source="$REPO_ROOT/$rel_source"
      if [[ -e "$source" || -L "$source" ]]; then
        source_canon="$(canonical_existing_path "$source")"
        link_canon="$(resolve_link_target "$target" 2>/dev/null || true)"
        if [[ "$link_canon" == "$source_canon" ]]; then
          managed_link=1
          break
        fi
      fi
    done
  fi

  log "check: $target"

  if [[ "$managed_link" == "1" ]]; then
    if [[ "$DRY_RUN" == "1" ]]; then
      log "restore: would unlink repository symlink $target"
      if [[ "$has_backup" == "1" ]]; then
        log "restore: would move $backup -> $target"
      else
        log "restore: no backup found; target would be left absent"
      fi
      return 0
    fi

    [[ "$YES" == "1" ]] || die "refusing to restore $target without --yes"
    unlink "$target"
    log "restore: unlinked $target"

    if [[ "$has_backup" == "1" ]]; then
      mv "$backup" "$target"
      log "restore: moved $backup -> $target"
    else
      log "restore: no backup found for $target"
    fi
    return 0
  fi

  if [[ ! -e "$target" && ! -L "$target" && "$has_backup" == "1" ]]; then
    if [[ "$DRY_RUN" == "1" ]]; then
      log "restore: would move $backup -> $target"
      return 0
    fi

    [[ "$YES" == "1" ]] || die "refusing to restore $target without --yes"
    mv "$backup" "$target"
    log "restore: moved $backup -> $target"
    return 0
  fi

  if [[ -e "$target" || -L "$target" ]]; then
    log "skip: $target is not a symlink managed by this repository"
    return 0
  fi

  log "skip: no target or backup for $target"
}

main() {
  parse_args "$@"
  ensure_safe_home

  if [[ "$DRY_RUN" != "1" && "$YES" != "1" ]]; then
    die "no changes made; pass --dry-run to preview or --yes to restore"
  fi

  log "Repository: $REPO_ROOT"
  log "Target HOME: $TARGET_HOME"
  [[ "$DRY_RUN" == "1" ]] && log "Mode: dry-run"

  local os_name
  local ghostty_source
  os_name="$("$SCRIPT_DIR/detect_os.sh")"
  ghostty_source="$(select_ghostty_source "$REPO_ROOT" "$os_name")"

  restore_one "configs/zsh/zshrc" ".zshrc"
  restore_one "configs/zsh/zprofile" ".zprofile"
  restore_one "configs/zsh/zshenv" ".zshenv"
  restore_one "configs/tmux/tmux.conf" ".tmux.conf"
  restore_one "configs/starship/starship.toml" ".config/starship.toml"
  restore_one_any ".config/ghostty/config" "$ghostty_source" "configs/ghostty/config" "configs/ghostty/config.linux"
  restore_one "configs/yazi" ".config/yazi"
  restore_one "configs/lazygit/config.yml" ".config/lazygit/config.yml"
  restore_one "configs/nvim" ".config/nvim"
  restore_one "configs/git/gitconfig" ".gitconfig"
}

main "$@"
