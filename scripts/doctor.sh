#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
TARGET_HOME="${TEST_HOME:-$HOME}"

# shellcheck source=scripts/config_sources.sh
. "$SCRIPT_DIR/config_sources.sh"
# shellcheck source=scripts/path_helpers.sh
. "$SCRIPT_DIR/path_helpers.sh"
# shellcheck source=scripts/common.sh
. "$SCRIPT_DIR/common.sh"

PATH="$(command_search_path "$TARGET_HOME")"
export PATH

FAILURES=0
STRICT_LINKS=0
WARNINGS=0

usage() {
  cat <<'EOF'
Usage: scripts/doctor.sh [--strict]

Checks installed tools and repository-managed config links.
By default, config targets that are not linked to this repository are warnings.

Options:
  --strict    Treat unmanaged or mismatched config links as failures
  --help      Show help
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

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

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --strict)
        STRICT_LINKS=1
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

link_issue() {
  if [[ "$STRICT_LINKS" == "1" ]]; then
    fail "$*"
  else
    warn "$*"
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

# Debian-family packages rename bat and fd. The tools are installed, but the
# aliases, fzf previews, Yazi, and LazyVim look for the upstream name.
check_renamed_cmd() {
  local alt="$2"
  local name="$1"

  if command -v "$name" >/dev/null 2>&1; then
    ok "$name found"
  elif command -v "$alt" >/dev/null 2>&1; then
    ok "$name found as $alt"
    warn "$name is only available as $alt; run ./scripts/install_command_shims.sh --yes to link it as $name"
  else
    fail "$name not found"
  fi
}

check_tmux_version() {
  local major
  local minor
  local version

  command -v tmux >/dev/null 2>&1 || return 0
  version="$(tmux -V 2>/dev/null | sed -n 's/^tmux[^0-9]*\([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1 \2/p')"
  [[ -n "$version" ]] || return 0
  read -r major minor <<< "$version"

  if ((major > 3 || (major == 3 && minor >= 2))); then
    ok "tmux $major.$minor supports the workspace (3.2 or newer)"
  else
    warn "tmux $major.$minor is older than 3.2; the workspace needs 3.2 or newer"
  fi
}

# Runs git against the target HOME only, so a test HOME never reads the real
# user's configuration. --includes matters: the identity lives in the
# included ~/.gitconfig.local, which --global alone would not read.
target_git_config() {
  if [[ "$TARGET_HOME" == "${HOME:-}" ]]; then
    git config --global --includes --get "$1" 2>/dev/null || true
  else
    env -u XDG_CONFIG_HOME -u GIT_CONFIG_GLOBAL HOME="$TARGET_HOME" git config --global --includes --get "$1" 2>/dev/null || true
  fi
}

check_git_setup() {
  local editor
  local editor_cmd
  local email
  local name

  command -v git >/dev/null 2>&1 || return 0

  name="$(target_git_config user.name)"
  email="$(target_git_config user.email)"
  if [[ -z "$name" || -z "$email" ]]; then
    warn "git identity is not set; add user.name and user.email to $TARGET_HOME/.gitconfig.local"
  elif [[ "$name" == *"<YOUR_"* || "$email" == *"<YOUR_"* ]]; then
    warn "git identity is still a placeholder; set user.name and user.email in $TARGET_HOME/.gitconfig.local"
  else
    ok "git identity is set"
  fi

  editor="$(target_git_config core.editor)"
  [[ -n "$editor" ]] || return 0
  # The program may be quoted because its path contains spaces.
  case "$editor" in
    \'*)
      editor_cmd="${editor#\'}"
      editor_cmd="${editor_cmd%%\'*}"
      ;;
    \"*)
      editor_cmd="${editor#\"}"
      editor_cmd="${editor_cmd%%\"*}"
      ;;
    *)
      editor_cmd="${editor%%[[:space:]]*}"
      ;;
  esac
  if command -v "$editor_cmd" >/dev/null 2>&1; then
    ok "git editor $editor_cmd found"
  else
    warn "git core.editor is \"$editor\" but $editor_cmd is not installed; git commit cannot open an editor"
  fi
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
    if [[ -e "$target" ]]; then
      link_issue "$target is not managed by this repository; expected symlink to $rel_source"
    else
      link_issue "$target is not linked yet; expected symlink to $rel_source"
    fi
    return 0
  fi

  source_canon="$(canonical_existing_path "$source")"
  link_canon="$(resolve_link_target "$target" 2>/dev/null || true)"

  if [[ "$link_canon" == "$source_canon" ]]; then
    ok "$target points to $rel_source"
  else
    link_issue "$target points somewhere else; expected $rel_source"
  fi
}

main() {
  local os_name
  local ghostty_source

  parse_args "$@"

  os_name="$("$SCRIPT_DIR/detect_os.sh")"
  ghostty_source="$(select_ghostty_source "$REPO_ROOT" "$os_name")"

  printf 'Detected OS: %s\n' "$os_name"
  printf 'Current shell: %s\n' "${SHELL:-unknown}"
  printf 'Repository: %s\n' "$REPO_ROOT"
  printf 'Target HOME: %s\n\n' "$TARGET_HOME"
  if [[ "$STRICT_LINKS" == "1" ]]; then
    printf 'Config link mode: strict (repository symlinks required)\n\n'
  else
    printf 'Config link mode: default (unmanaged config targets are warnings)\n\n'
  fi

  check_cmd zsh
  check_zsh_syntax_highlighting
  check_cmd tmux
  check_tmux_version
  check_cmd starship
  check_cmd btop
  check_cmd fzf
  check_cmd zoxide
  check_cmd eza
  check_renamed_cmd bat batcat
  check_renamed_cmd fd fdfind
  check_cmd rg
  check_cmd lazygit
  check_cmd nvim
  check_cmd yazi
  check_cmd ya
  check_cmd ghostty 1
  printf 'note: Ghostty is an optional GUI terminal emulator.\n\n'

  check_git_setup
  printf '\n'

  check_link "configs/zsh/zshrc" ".zshrc"
  check_link "configs/zsh/zprofile" ".zprofile"
  check_link "configs/zsh/zshenv" ".zshenv"
  check_link "configs/tmux/tmux.conf" ".tmux.conf"
  check_link "configs/starship/starship.toml" ".config/starship.toml"
  check_link "$ghostty_source" ".config/ghostty/config"
  check_link "configs/yazi" ".config/yazi"
  check_link "configs/lazygit/config.yml" ".config/lazygit/config.yml"
  check_link "configs/nvim" ".config/nvim"
  check_link "configs/git/gitconfig" ".gitconfig"

  printf '\nDoctor summary: %s failure(s), %s warning(s)\n' "$FAILURES" "$WARNINGS"
  [[ "$FAILURES" -eq 0 ]]
}

main "$@"
