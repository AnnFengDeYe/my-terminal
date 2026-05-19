#!/usr/bin/env bash

detect_default_pm() {
  local os="$1"

  case "$os" in
    macos) printf '%s\n' "brew" ;;
    debian|ubuntu|raspberrypi) printf '%s\n' "apt" ;;
    arch) printf '%s\n' "pacman" ;;
    fedora) printf '%s\n' "dnf" ;;
    *) printf '%s\n' "unknown" ;;
  esac
}

find_zsh_syntax_highlighting() {
  local brew_prefix=""
  local candidate
  local candidates=()

  if command -v brew >/dev/null 2>&1; then
    brew_prefix="$(brew --prefix 2>/dev/null || true)"
    if [[ -n "$brew_prefix" ]]; then
      candidates+=("$brew_prefix/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh")
    fi
  fi

  candidates+=(
    "/opt/homebrew/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh"
    "/usr/local/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh"
    "/usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh"
  )

  for candidate in "${candidates[@]}"; do
    if [[ -f "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  return 1
}

ensure_safe_home() {
  local target_home="${1:-${TARGET_HOME:-${TEST_HOME:-${HOME:-}}}}}"

  [[ -n "$target_home" ]] || {
    printf 'ERROR: target HOME is empty\n' >&2
    exit 1
  }
  [[ "$target_home" == /* ]] || {
    printf 'ERROR: target HOME must be absolute: %s\n' "$target_home" >&2
    exit 1
  }
  [[ "$target_home" != "/" ]] || {
    printf 'ERROR: refusing to use / as HOME\n' >&2
    exit 1
  }
  [[ "$target_home" != *$'\n'* ]] || {
    printf 'ERROR: refusing HOME with newline\n' >&2
    exit 1
  }
}
