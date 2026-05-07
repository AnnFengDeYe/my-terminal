#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$SCRIPT_DIR"
CONFIG_FILE="$REPO_ROOT/setup.conf"
TARGET_HOME="${TEST_HOME:-$HOME}"
LANGUAGE=""

read_config_language() {
  local value=""

  if [[ -f "$CONFIG_FILE" ]]; then
    value="$(
      awk -F= '
        /^[[:space:]]*DEFAULT_LANGUAGE[[:space:]]*=/ {
          value=$2
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
          gsub(/^"|"$/, "", value)
          gsub(/^'\''|'\''$/, "", value)
          print value
        }
      ' "$CONFIG_FILE" | tail -n 1
    )"
  fi

  case "$value" in
    zh|en)
      printf '%s\n' "$value"
      ;;
    *)
      printf '%s\n' "zh"
      ;;
  esac
}

set_language() {
  local value="$1"

  case "$value" in
    zh|en)
      LANGUAGE="$value"
      ;;
    *)
      printf 'ERROR: unsupported language: %s\n' "$value" >&2
      exit 1
      ;;
  esac
}

is_zh() {
  [[ "$LANGUAGE" == "zh" ]]
}

usage() {
  if is_zh; then
    cat <<'EOF'
用法: ./setup.sh [--lang zh|en]

启动适合新手使用的交互式安装菜单。

安全规则:
  - 预览不会写入文件
  - 真实修改前必须输入 YES
  - 已存在的配置会先备份再链接

默认语言可在 setup.conf 中修改:
  DEFAULT_LANGUAGE=zh
EOF
  else
    cat <<'EOF'
Usage: ./setup.sh [--lang zh|en]

Starts a beginner-friendly interactive setup menu.

Safety rules:
  - previews do not write files
  - real changes require typing YES
  - existing configs are backed up before linking

The default language can be changed in setup.conf:
  DEFAULT_LANGUAGE=en
EOF
  fi
}

parse_args() {
  LANGUAGE="${SETUP_LANG:-$(read_config_language)}"
  set_language "$LANGUAGE"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --lang)
        [[ $# -ge 2 ]] || {
          printf 'ERROR: --lang requires zh or en\n' >&2
          exit 1
        }
        set_language "$2"
        shift 2
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        printf 'ERROR: unknown option: %s\n' "$1" >&2
        usage >&2
        exit 1
        ;;
    esac
  done
}

is_tty() {
  [[ -t 0 ]]
}

pause_if_tty() {
  is_tty || return 0

  if is_zh; then
    printf '\n按回车返回菜单...'
  else
    printf '\nPress Enter to return to the menu...'
  fi

  read -r _ || true
}

language_name() {
  if is_zh; then
    printf '%s\n' "中文"
  else
    printf '%s\n' "English"
  fi
}

print_header() {
  if is_tty; then
    clear 2>/dev/null || true
  fi

  if is_zh; then
    cat <<EOF
终端配置安装器
仓库路径:   $REPO_ROOT
目标 HOME: $TARGET_HOME
语言:       $(language_name)

请选择操作。第一次使用建议先选择 1 预览安装。
EOF
  else
    cat <<EOF
Terminal Starter Kit Setup
Repository:  $REPO_ROOT
Target HOME: $TARGET_HOME
Language:    $(language_name)

Choose an option. Select 1 first if this is your first run.
EOF
  fi
}

confirm_real_action() {
  local title="$1"

  if is_zh; then
    cat <<EOF

此操作可能修改目标 HOME:
  $TARGET_HOME

操作:
  $title

已存在的配置目标会先在原位置旁边备份，然后再创建仓库软链接。

如确认继续，请输入大写 YES:
EOF
  else
    cat <<EOF

This action can modify the target HOME:
  $TARGET_HOME

Action:
  $title

Existing managed config targets will be backed up next to the original path
before repository symlinks are created.

Type YES to continue:
EOF
  fi

  local answer
  read -r answer || return 1
  [[ "$answer" == "YES" ]]
}

canceled() {
  if is_zh; then
    printf '已取消。没有修改系统。\n'
  else
    printf 'Canceled. No changes made.\n'
  fi
}

run_preview() {
  "$REPO_ROOT/install.sh" --dry-run --install-packages --install-fonts --set-default-shell --backup
}

run_recommended_install() {
  local title
  if is_zh; then
    title="安装 CLI 工具、安装 Nerd Font、链接配置，并把默认 shell 切换为 zsh"
  else
    title="install CLI tools, install Nerd Font, link configs, and set zsh as the login shell"
  fi

  if confirm_real_action "$title"; then
    "$REPO_ROOT/install.sh" --install-packages --install-fonts --set-default-shell --backup --yes
  else
    canceled
  fi
}

run_link_only() {
  local title
  if is_zh; then
    title="只链接仓库配置，并备份已有配置"
  else
    title="link repository configs only, with backups"
  fi

  if confirm_real_action "$title"; then
    "$REPO_ROOT/install.sh" --link-only --backup --yes
  else
    canceled
  fi
}

run_gui_install() {
  local title
  if is_zh; then
    title="安装 CLI 工具、可选 GUI 应用、Nerd Font、链接配置，并切换默认 shell"
  else
    title="install CLI tools, optional GUI apps, Nerd Font, link configs, and set zsh as the login shell"
  fi

  if confirm_real_action "$title"; then
    "$REPO_ROOT/install.sh" --install-packages --install-gui-apps --install-fonts --set-default-shell --backup --yes
  else
    canceled
  fi
}

run_restore() {
  if is_zh; then
    printf '\n恢复预览:\n'
  else
    printf '\nRestore preview:\n'
  fi

  "$REPO_ROOT/scripts/restore_backups.sh" --dry-run

  local title
  if is_zh; then
    title="删除本仓库管理的软链接，并恢复最新的相邻备份"
  else
    title="remove repository-managed symlinks and restore the latest adjacent backups"
  fi

  if confirm_real_action "$title"; then
    "$REPO_ROOT/scripts/restore_backups.sh" --yes
  else
    canceled
  fi
}

run_import() {
  if is_zh; then
    printf '\n导入预览:\n'
  else
    printf '\nImport preview:\n'
  fi

  "$REPO_ROOT/scripts/import_existing_configs.sh" --dry-run

  if is_zh; then
    cat <<'EOF'

导入只会从当前 HOME 复制配置到本仓库。
它不会把仓库配置写回真实 HOME。
此菜单选项不会覆盖已经存在的仓库副本。
EOF
  else
    cat <<'EOF'

Import copies configs from the current HOME into this repository only.
It does not write back to source configs. Existing repository copies are not
overwritten by this menu option.
EOF
  fi

  local title
  if is_zh; then
    title="把当前 HOME 的配置导入仓库副本，并做脱敏处理"
  else
    title="import current HOME configs into repository copies with sanitization"
  fi

  if confirm_real_action "$title"; then
    "$REPO_ROOT/scripts/import_existing_configs.sh" --yes --sanitize
  else
    canceled
  fi
}

show_commands() {
  if is_zh; then
    cat <<'EOF'

常用命令:

  ./setup.sh
  ./setup.sh --lang en
  ./install.sh --dry-run
  ./install.sh --install-packages --install-fonts --set-default-shell --backup --yes
  ./install.sh --link-only --backup --yes
  ./install.sh --install-packages --install-gui-apps --install-fonts --set-default-shell --backup --yes
  ./scripts/doctor.sh
  ./scripts/restore_backups.sh --dry-run
  ./scripts/restore_backups.sh --yes
  ./scripts/import_existing_configs.sh --dry-run
  ./scripts/import_existing_configs.sh --yes --sanitize
  ./test_install.sh
EOF
  else
    cat <<'EOF'

Common commands:

  ./setup.sh
  ./setup.sh --lang zh
  ./install.sh --dry-run
  ./install.sh --install-packages --install-fonts --set-default-shell --backup --yes
  ./install.sh --link-only --backup --yes
  ./install.sh --install-packages --install-gui-apps --install-fonts --set-default-shell --backup --yes
  ./scripts/doctor.sh
  ./scripts/restore_backups.sh --dry-run
  ./scripts/restore_backups.sh --yes
  ./scripts/import_existing_configs.sh --dry-run
  ./scripts/import_existing_configs.sh --yes --sanitize
  ./test_install.sh
EOF
  fi
}

toggle_language() {
  if is_zh; then
    LANGUAGE="en"
  else
    LANGUAGE="zh"
  fi
}

advanced_menu() {
  local choice

  while true; do
    print_header
    if is_zh; then
      cat <<'EOF'

高级选项

1) 只链接配置
2) 安装时包含可选 GUI 应用
3) 导入当前本机配置
4) 显示命令参考
0) 返回主菜单

EOF
      printf '请选择 [0-4]: '
    else
      cat <<'EOF'

Advanced Options

1) Link configs only
2) Install with optional GUI apps
3) Import existing local configs
4) Show command reference
0) Back to main menu

EOF
      printf 'Select [0-4]: '
    fi

    if ! read -r choice; then
      printf '\n'
      exit 0
    fi

    case "$choice" in
      1)
        run_link_only
        pause_if_tty
        ;;
      2)
        run_gui_install
        pause_if_tty
        ;;
      3)
        run_import
        pause_if_tty
        ;;
      4)
        show_commands
        pause_if_tty
        ;;
      0|b|B)
        return 0
        ;;
      *)
        if is_zh; then
          printf '未知选项: %s\n' "$choice"
        else
          printf 'Unknown option: %s\n' "$choice"
        fi
        pause_if_tty
        ;;
    esac
  done
}

main_menu() {
  local choice

  while true; do
    print_header
    if is_zh; then
      cat <<'EOF'

1) 预览安装
2) 开始安装
3) 检查配置
4) 恢复备份
5) 高级选项
l) 切换语言
0) 退出

EOF
      printf '请选择 [0-5,l]: '
    else
      cat <<'EOF'

1) Preview install
2) Start install
3) Check configuration
4) Restore backups
5) Advanced options
l) Switch language
0) Exit

EOF
      printf 'Select [0-5,l]: '
    fi

    if ! read -r choice; then
      printf '\n'
      exit 0
    fi

    case "$choice" in
      1)
        run_preview
        pause_if_tty
        ;;
      2)
        run_recommended_install
        pause_if_tty
        ;;
      3)
        "$REPO_ROOT/scripts/doctor.sh"
        pause_if_tty
        ;;
      4)
        run_restore
        pause_if_tty
        ;;
      5)
        advanced_menu
        ;;
      l|L)
        toggle_language
        ;;
      0|q|Q)
        if is_zh; then
          printf '退出。\n'
        else
          printf 'Bye.\n'
        fi
        exit 0
        ;;
      *)
        if is_zh; then
          printf '未知选项: %s\n' "$choice"
        else
          printf 'Unknown option: %s\n' "$choice"
        fi
        pause_if_tty
        ;;
    esac
  done
}

main() {
  parse_args "$@"
  main_menu
}

main "$@"
