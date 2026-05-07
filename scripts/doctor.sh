#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
TARGET_HOME="${TEST_HOME:-$HOME}"

PATH="$TARGET_HOME/.local/bin:$TARGET_HOME/.cargo/bin:/snap/bin:/home/linuxbrew/.linuxbrew/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
export PATH

FAILURES=0
WARNINGS=0

ok() {
  printf 'ok: %s\n' "$*"
}

warn() {
  WARNINGS=$((WARNINGS + 1))
  printf 'warning: %s\n' "$*"
}

fail() {
  FAILURES=$((FAILURES + 1))
  printf 'fail: %s\n' "$*"
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

check_cmd() {
  local cmd="$1"
  local optional="${2:-0}"

  if command -v "$cmd" >/dev/null 2>&1; then
    ok "$cmd found"
  elif [[ "$optional" == "1" ]]; then
    warn "$cmd not found; this is optional"
  else
    fail "$cmd not found"
  fi
}

check_any_cmd() {
  local label="$1"
  shift
  local cmd

  for cmd in "$@"; do
    if command -v "$cmd" >/dev/null 2>&1; then
      ok "$label found as $cmd"
      return 0
    fi
  done

  fail "$label not found"
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

check_zsh_syntax_highlighting() {
  local path

  path="$(find_zsh_syntax_highlighting 2>/dev/null || true)"
  if [[ -n "$path" ]]; then
    ok "zsh-syntax-highlighting found at $path"
  else
    fail "zsh-syntax-highlighting not found"
  fi
}

check_link() {
  local rel_source="$1"
  local rel_target="$2"
  local source="$REPO_ROOT/$rel_source"
  local target="$TARGET_HOME/$rel_target"
  local source_canon
  local link_canon

  if [[ ! -e "$source" && ! -L "$source" ]]; then
    warn "repository config missing: $rel_source"
    return 0
  fi

  if [[ ! -L "$target" ]]; then
    fail "$target is not a symlink to $rel_source"
    return 0
  fi

  source_canon="$(canonical_existing_path "$source")"
  link_canon="$(resolve_link_target "$target" 2>/dev/null || true)"

  if [[ "$link_canon" == "$source_canon" ]]; then
    ok "$target points to $rel_source"
  else
    fail "$target points somewhere else"
  fi
}

main() {
  printf 'Detected OS: %s\n' "$("$SCRIPT_DIR/detect_os.sh")"
  printf 'Current shell: %s\n' "${SHELL:-unknown}"
  printf 'Repository: %s\n' "$REPO_ROOT"
  printf 'Target HOME: %s\n\n' "$TARGET_HOME"

  check_cmd zsh
  check_zsh_syntax_highlighting
  check_cmd tmux
  check_cmd starship
  check_cmd fzf
  check_cmd zoxide
  check_cmd eza
  check_any_cmd "bat" bat batcat
  check_any_cmd "fd" fd fdfind
  check_cmd rg
  check_cmd lazygit
  check_cmd nvim
  check_cmd yazi
  check_cmd ya
  check_cmd ghostty 1
  printf 'note: Ghostty is an optional GUI terminal emulator.\n\n'

  check_link "configs/zsh/zshrc" ".zshrc"
  check_link "configs/zsh/zprofile" ".zprofile"
  check_link "configs/zsh/zshenv" ".zshenv"
  check_link "configs/tmux/tmux.conf" ".tmux.conf"
  check_link "configs/starship/starship.toml" ".config/starship.toml"
  check_link "configs/ghostty/config" ".config/ghostty/config"
  check_link "configs/yazi" ".config/yazi"
  check_link "configs/lazygit/config.yml" ".config/lazygit/config.yml"
  check_link "configs/nvim" ".config/nvim"
  check_link "configs/git/gitconfig" ".gitconfig"

  printf '\nDoctor summary: %s failure(s), %s warning(s)\n' "$FAILURES" "$WARNINGS"
  [[ "$FAILURES" -eq 0 ]]
}

main "$@"
