#!/usr/bin/env bash
set -euo pipefail

DRY_RUN=0
YES=0
TARGET_USER="${SUDO_USER:-${USER:-}}"
SHELL_PATH=""

usage() {
  cat <<'EOF'
Usage: scripts/set_default_shell.sh [--dry-run] [--yes] [--shell PATH] [--user USER]

Switches the target user's login shell to zsh. Without --yes, no changes are made.
If zsh is not listed in /etc/shells, the script adds it before running chsh.
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
      --shell)
        [[ $# -ge 2 ]] || die "--shell requires a path"
        SHELL_PATH="$2"
        shift 2
        ;;
      --user)
        [[ $# -ge 2 ]] || die "--user requires a username"
        TARGET_USER="$2"
        shift 2
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

validate_shell_path() {
  local path="$1"

  [[ -n "$path" ]] || die "zsh was not found; install zsh first"
  [[ "$path" == /* ]] || die "shell path must be absolute: $path"
  [[ "$path" != *$'\n'* ]] || die "shell path contains newline"
  if [[ "$DRY_RUN" != "1" ]]; then
    [[ -x "$path" ]] || die "shell path is not executable: $path"
  fi
  [[ "$(basename "$path")" == "zsh" ]] || die "refusing to set non-zsh shell: $path"
}

current_login_shell() {
  local user="$1"

  if command -v getent >/dev/null 2>&1; then
    getent passwd "$user" | awk -F: '{print $7}'
    return 0
  fi

  awk -F: -v user="$user" '$1 == user {print $7}' /etc/passwd 2>/dev/null || true
}

run_privileged() {
  if [[ "$(id -u)" == "0" ]]; then
    "$@"
  else
    command -v sudo >/dev/null 2>&1 || die "sudo is required to update /etc/shells or run chsh"
    sudo "$@"
  fi
}

ensure_shell_listed() {
  local shell_path="$1"

  if [[ -r /etc/shells ]] && grep -Fxq "$shell_path" /etc/shells; then
    log "shell: $shell_path already listed in /etc/shells"
    return 0
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    log "dry-run: would add $shell_path to /etc/shells"
    return 0
  fi

  [[ "$YES" == "1" ]] || die "refusing to update /etc/shells without --yes"
  run_privileged sh -c 'printf "%s\n" "$1" >> /etc/shells' sh "$shell_path"
  log "shell: added $shell_path to /etc/shells"
}

set_login_shell() {
  local user="$1"
  local shell_path="$2"
  local current_shell

  current_shell="$(current_login_shell "$user")"
  if [[ "$current_shell" == "$shell_path" ]]; then
    log "shell: $user already uses $shell_path"
    return 0
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    log "dry-run: would run chsh -s $shell_path $user"
    return 0
  fi

  [[ "$YES" == "1" ]] || die "refusing to change login shell without --yes"
  run_privileged chsh -s "$shell_path" "$user"
  log "shell: changed $user login shell from ${current_shell:-unknown} to $shell_path"
}

main() {
  parse_args "$@"

  [[ -n "$TARGET_USER" ]] || die "target user is unknown; pass --user"
  if [[ -z "$SHELL_PATH" ]]; then
    SHELL_PATH="$(command -v zsh || true)"
    if [[ -z "$SHELL_PATH" && "$DRY_RUN" == "1" ]]; then
      case "$(uname -s 2>/dev/null || true)" in
        Darwin) SHELL_PATH="/bin/zsh" ;;
        *) SHELL_PATH="/usr/bin/zsh" ;;
      esac
    fi
  fi

  validate_shell_path "$SHELL_PATH"

  log "Target user: $TARGET_USER"
  log "Target shell: $SHELL_PATH"
  [[ "$DRY_RUN" == "1" ]] && log "Mode: dry-run"

  if [[ "$DRY_RUN" != "1" && "$YES" != "1" ]]; then
    die "no changes made; pass --dry-run to preview or --yes to change the login shell"
  fi

  ensure_shell_listed "$SHELL_PATH"
  set_login_shell "$TARGET_USER" "$SHELL_PATH"
}

main "$@"
