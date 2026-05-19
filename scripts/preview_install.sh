#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
TARGET_HOME="${TEST_HOME:-$HOME}"
LANGUAGE="zh"

# shellcheck source=scripts/config_sources.sh
. "$SCRIPT_DIR/config_sources.sh"
# shellcheck source=scripts/path_helpers.sh
. "$SCRIPT_DIR/path_helpers.sh"
# shellcheck source=scripts/common.sh
. "$SCRIPT_DIR/common.sh"

PATH="$TARGET_HOME/.local/bin:$TARGET_HOME/.cargo/bin:/snap/bin:/home/linuxbrew/.linuxbrew/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
export PATH

usage() {
  cat <<'EOF'
Usage: scripts/preview_install.sh [--lang zh|en]

Prints a concise, read-only install preview:
  - detected platform
  - tool installed/missing status
  - terminal font status
  - managed config link status
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --lang)
        [[ $# -ge 2 ]] || die "--lang requires zh or en"
        case "$2" in
          zh|en) LANGUAGE="$2" ;;
          *) die "unsupported language: $2" ;;
        esac
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

is_zh() {
  [[ "$LANGUAGE" == "zh" ]]
}

tool_state() {
  local label="$1"
  shift
  local cmd

  for cmd in "$@"; do
    if command -v "$cmd" >/dev/null 2>&1; then
      if is_zh; then
        printf '  [已安装] %s (%s)\n' "$label" "$cmd"
      else
        printf '  [installed] %s (%s)\n' "$label" "$cmd"
      fi
      return 0
    fi
  done

  if is_zh; then
    printf '  [待安装] %s\n' "$label"
  else
    printf '  [missing]   %s\n' "$label"
  fi
}

syntax_highlighting_state() {
  if find_zsh_syntax_highlighting >/dev/null 2>&1; then
    if is_zh; then
      printf '  [已安装] zsh-syntax-highlighting\n'
    else
      printf '  [installed] zsh-syntax-highlighting\n'
    fi
  else
    if is_zh; then
      printf '  [待安装] zsh-syntax-highlighting\n'
    else
      printf '  [missing]   zsh-syntax-highlighting\n'
    fi
  fi
}

font_state() {
  local os="$1"
  local match
  local dir
  local dirs=()

  if command -v fc-match >/dev/null 2>&1; then
    match="$(fc-match 'JetBrainsMono Nerd Font' 2>/dev/null || true)"
    if printf '%s\n' "$match" | grep -Eiq 'JetBrainsMono.*Nerd|JetBrains.*Nerd|Nerd.*JetBrains'; then
      if is_zh; then
        printf '  [已安装] JetBrainsMono Nerd Font (%s)\n' "$match"
      else
        printf '  [installed] JetBrainsMono Nerd Font (%s)\n' "$match"
      fi
      return 0
    fi
  fi

  if [[ "$os" == "macos" ]]; then
    dirs=(
      "$TARGET_HOME/Library/Fonts"
      "$TARGET_HOME/Library/Fonts/NerdFonts/JetBrainsMono"
      "/Library/Fonts"
      "/Library/Fonts/NerdFonts/JetBrainsMono"
    )
  else
    dirs=(
      "$TARGET_HOME/.local/share/fonts"
      "$TARGET_HOME/.local/share/fonts/NerdFonts/JetBrainsMono"
      "/usr/local/share/fonts"
      "/usr/share/fonts"
    )
  fi

  for dir in "${dirs[@]}"; do
    if [[ -d "$dir" ]] && find "$dir" -maxdepth 5 -type f \
      \( -iname '*JetBrainsMono*NerdFont*.ttf' -o -iname '*JetBrainsMono*NerdFont*.otf' \) \
      -print -quit 2>/dev/null | grep -q .; then
      if is_zh; then
        printf '  [已安装] JetBrainsMono Nerd Font (%s)\n' "$dir"
      else
        printf '  [installed] JetBrainsMono Nerd Font (%s)\n' "$dir"
      fi
      return 0
    fi
  done

  if is_zh; then
    printf '  [待安装] JetBrainsMono Nerd Font\n'
  else
    printf '  [missing]   JetBrainsMono Nerd Font\n'
  fi
}

config_state() {
  local rel_source="$1"
  local rel_target="$2"
  local source="$REPO_ROOT/$rel_source"
  local target="$TARGET_HOME/$rel_target"
  local source_canon=""
  local link_canon=""

  if [[ ! -e "$source" && ! -L "$source" ]]; then
    if is_zh; then
      printf '  [跳过] %s -> ~/%s 仓库配置不存在\n' "$rel_source" "$rel_target"
    else
      printf '  [skip]      %s -> ~/%s repository config missing\n' "$rel_source" "$rel_target"
    fi
    return 0
  fi

  source_canon="$(canonical_existing_path "$source")"

  if [[ -L "$target" ]]; then
    link_canon="$(resolve_link_target "$target" 2>/dev/null || true)"
    if [[ "$link_canon" == "$source_canon" ]]; then
      if is_zh; then
        printf '  [已链接] ~/%s\n' "$rel_target"
      else
        printf '  [linked]    ~/%s\n' "$rel_target"
      fi
    else
      if is_zh; then
        printf '  [需备份] ~/%s 当前是其他软链接\n' "$rel_target"
      else
        printf '  [backup]    ~/%s different symlink exists\n' "$rel_target"
      fi
    fi
    return 0
  fi

  if [[ -e "$target" ]]; then
    if is_zh; then
      printf '  [需备份] ~/%s 已存在\n' "$rel_target"
    else
      printf '  [backup]    ~/%s already exists\n' "$rel_target"
    fi
    return 0
  fi

  if is_zh; then
    printf '  [将链接] ~/%s\n' "$rel_target"
  else
    printf '  [will link] ~/%s\n' "$rel_target"
  fi
}

main() {
  parse_args "$@"

  local os
  local pm
  local ghostty_source
  os="$("$SCRIPT_DIR/detect_os.sh")"
  pm="$(detect_default_pm "$os")"
  ghostty_source="$(select_ghostty_source "$REPO_ROOT" "$os")"

  if is_zh; then
    printf '安装预览\n'
    printf '系统: %s\n' "$os"
    printf '包管理器: %s\n' "$pm"
    printf '目标 HOME: %s\n\n' "$TARGET_HOME"

    printf 'CLI 工具状态:\n'
  else
    printf 'Install Preview\n'
    printf 'OS: %s\n' "$os"
    printf 'Package manager: %s\n' "$pm"
    printf 'Target HOME: %s\n\n' "$TARGET_HOME"

    printf 'CLI tool status:\n'
  fi

  tool_state "zsh" zsh
  syntax_highlighting_state
  tool_state "tmux" tmux
  tool_state "starship" starship
  tool_state "btop" btop
  tool_state "fzf" fzf
  tool_state "zoxide" zoxide
  tool_state "eza" eza
  tool_state "bat" bat batcat
  tool_state "ripgrep" rg
  tool_state "fd" fd fdfind
  tool_state "lazygit" lazygit
  tool_state "neovim" nvim
  tool_state "yazi" yazi
  tool_state "ya" ya

  if is_zh; then
    printf '\n可选 GUI:\n'
  else
    printf '\nOptional GUI:\n'
  fi
  tool_state "ghostty" ghostty

  if is_zh; then
    printf '\n字体状态:\n'
  else
    printf '\nFont status:\n'
  fi
  font_state "$os"

  if is_zh; then
    printf '\n配置链接状态:\n'
  else
    printf '\nConfig link status:\n'
  fi
  config_state "configs/zsh/zshrc" ".zshrc"
  config_state "configs/zsh/zprofile" ".zprofile"
  config_state "configs/zsh/zshenv" ".zshenv"
  config_state "configs/tmux/tmux.conf" ".tmux.conf"
  config_state "configs/starship/starship.toml" ".config/starship.toml"
  config_state "$ghostty_source" ".config/ghostty/config"
  config_state "configs/yazi" ".config/yazi"
  config_state "configs/lazygit/config.yml" ".config/lazygit/config.yml"
  config_state "configs/nvim" ".config/nvim"
  config_state "configs/git/gitconfig" ".gitconfig"

  if is_zh; then
    cat <<'EOF'

下一步:
  选择“开始安装”会安装缺失工具、安装字体、备份已有配置、创建软链接，并切换默认 zsh。
  需要完整底层 dry-run 时，在高级选项查看命令参考后运行 ./install.sh --dry-run。
EOF
  else
    cat <<'EOF'

Next:
  Start install will install missing tools, install fonts, back up existing configs, create symlinks, and set zsh as the default shell.
  For the full low-level dry-run, use the command reference in Advanced options and run ./install.sh --dry-run.
EOF
  fi
}

main "$@"
