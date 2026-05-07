#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
TARGET_HOME="${TEST_HOME:-$HOME}"
OS_NAME="${TEST_OS:-$("$SCRIPT_DIR/detect_os.sh")}"

# shellcheck source=scripts/backup.sh
. "$SCRIPT_DIR/backup.sh"

DRY_RUN=0
YES=0

PATH="$TARGET_HOME/.local/bin:$TARGET_HOME/.cargo/bin:/snap/bin:/home/linuxbrew/.linuxbrew/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
export PATH

usage() {
  cat <<'EOF'
Usage: scripts/install_desktop_entries.sh [--dry-run] [--yes]

Creates Linux desktop/menu launchers for optional GUI tools installed by this
starter kit. It currently manages Ghostty launchers only.

No files are modified unless --yes is supplied. macOS is skipped.
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

write_file_if_changed() {
  local target="$1"
  local content="$2"
  local parent

  ensure_under_home "$target"
  parent="$(dirname "$target")"

  if [[ -f "$target" ]] && printf '%s\n' "$content" | cmp -s - "$target"; then
    log "skip: $target is already up to date"
    return 0
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    [[ -e "$target" || -L "$target" ]] && log "backup: would move $target -> $target.backup.TIMESTAMP"
    log "desktop-entry: would write $target"
    return 0
  fi

  [[ "$YES" == "1" ]] || die "refusing to write $target without --yes"
  mkdir -p "$parent"
  if [[ -e "$target" || -L "$target" ]]; then
    backup_path "$target" 0 "$TARGET_HOME"
  fi
  printf '%s\n' "$content" > "$target"
  chmod 0644 "$target"
  log "desktop-entry: wrote $target"
}

desktop_dir() {
  local dir=""

  if command -v xdg-user-dir >/dev/null 2>&1; then
    dir="$(HOME="$TARGET_HOME" xdg-user-dir DESKTOP 2>/dev/null || true)"
  fi

  [[ -n "$dir" && "$dir" == "$TARGET_HOME"/* ]] || dir="$TARGET_HOME/Desktop"
  printf '%s\n' "$dir"
}

ghostty_command() {
  command -v ghostty 2>/dev/null || true
}

install_ghostty_desktop_entry() {
  local ghostty_cmd
  local apps_dir="$TARGET_HOME/.local/share/applications"
  local menu_entry="$apps_dir/com.mitchellh.ghostty.desktop"
  local desktop_entry
  local content

  ghostty_cmd="$(ghostty_command)"
  if [[ -z "$ghostty_cmd" ]]; then
    if [[ "$DRY_RUN" == "1" ]]; then
      ghostty_cmd="/snap/bin/ghostty"
      log "dry-run: ghostty is not currently in PATH; using $ghostty_cmd for preview"
    else
      die "ghostty is not installed or not in PATH"
    fi
  fi

  content="[Desktop Entry]
Type=Application
Name=Ghostty
Comment=Fast, native terminal emulator
Exec=$ghostty_cmd
Icon=ghostty
Terminal=false
Categories=System;TerminalEmulator;
StartupNotify=true
StartupWMClass=com.mitchellh.ghostty"

  write_file_if_changed "$menu_entry" "$content"

  desktop_entry="$(desktop_dir)/Ghostty.desktop"
  if [[ "$DRY_RUN" == "1" ]]; then
    log "desktop-entry: would ensure desktop directory $(dirname "$desktop_entry")"
    write_file_if_changed "$desktop_entry" "$content"
    log "desktop-entry: would mark $desktop_entry executable"
    return 0
  fi

  [[ "$YES" == "1" ]] || die "refusing to write desktop launcher without --yes"
  mkdir -p "$(dirname "$desktop_entry")"
  write_file_if_changed "$desktop_entry" "$content"
  chmod 0755 "$desktop_entry"
  log "desktop-entry: marked $desktop_entry executable"

  if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$apps_dir" >/dev/null 2>&1 || true
  fi
}

main() {
  parse_args "$@"
  ensure_safe_home

  if [[ "$DRY_RUN" != "1" && "$YES" != "1" ]]; then
    die "no desktop entries installed; pass --dry-run to preview or --yes to write"
  fi

  case "$OS_NAME" in
    macos)
      log "desktop-entry: skipped on macOS"
      ;;
    *)
      log "desktop-entry: installing Linux Ghostty launchers"
      install_ghostty_desktop_entry
      ;;
  esac
}

main "$@"
