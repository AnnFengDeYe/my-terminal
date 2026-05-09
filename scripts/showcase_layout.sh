#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
SCRIPT_PATH="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"

SESSION="${SHOWCASE_SESSION:-my-terminal-showcase}"
RESET=0
ATTACH=1
PANE_MODE=""

usage() {
  cat <<'EOF'
Usage: scripts/showcase_layout.sh [--session NAME] [--reset] [--no-attach]

Create a tmux session arranged for README screenshots:
  - left: nvim / LazyVim
  - top right: yazi
  - bottom right: lazygit
  - bottom: starship prompt plus install preview / doctor output
  - windows: 1:dev  2:ai  3:ssh  4:logs

Options:
  --session NAME  Use a custom tmux session name.
  --reset         Recreate the session if it already exists.
  --no-attach     Create the session and print its name without attaching.
  --help, -h      Show this help.

Environment:
  SHOWCASE_COLS / SHOWCASE_LINES  Override the initial tmux size.
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --session)
        [[ $# -ge 2 ]] || die "--session requires a name"
        SESSION="$2"
        shift 2
        ;;
      --reset)
        RESET=1
        shift
        ;;
      --no-attach)
        ATTACH=0
        shift
        ;;
      --pane)
        [[ $# -ge 2 ]] || die "--pane requires a mode"
        PANE_MODE="$2"
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

exec_shell() {
  exec "${SHELL:-/bin/sh}"
}

run_editor() {
  cd "$REPO_ROOT"
  if command -v nvim >/dev/null 2>&1; then
    nvim README.md +"vsplit install.sh" +"wincmd h" || true
    exec_shell
  fi

  clear 2>/dev/null || true
  printf 'nvim / LazyVim fallback preview\n\n'
  sed -n '1,70p' README.md || true
  exec_shell
}

run_files() {
  cd "$REPO_ROOT"
  if command -v yazi >/dev/null 2>&1; then
    yazi . || true
    exec_shell
  fi

  clear 2>/dev/null || true
  printf 'yazi fallback file tree\n\n'
  if command -v eza >/dev/null 2>&1; then
    eza --tree --level=2 --icons=auto configs scripts packages 2>/dev/null || true
  else
    find configs scripts packages -maxdepth 2 -type f | sort | sed -n '1,80p' || true
  fi
  exec_shell
}

run_git() {
  cd "$REPO_ROOT"
  if command -v lazygit >/dev/null 2>&1; then
    lazygit || true
    exec_shell
  fi

  clear 2>/dev/null || true
  printf 'lazygit fallback git state\n\n'
  git status --short 2>/dev/null || true
  printf '\nRecent commits:\n'
  git log --oneline --decorate -n 8 2>/dev/null || true
  exec_shell
}

print_command() {
  printf '\n$ %s\n' "$*"
}

run_prompt() {
  local doctor_line
  local preview_line

  cd "$REPO_ROOT"
  clear 2>/dev/null || true

  preview_line="$(
    ./scripts/preview_install.sh --lang zh | awk '
    /^系统:/ { os=$2 }
    /^包管理器:/ { pm=$2 }
    /\[已安装\] (tmux|starship|lazygit|neovim|yazi|ghostty)/ {
      tool = $2
      if (tool == "neovim") tool = "nvim"
      tools = tools (tools ? " " : "") tool
    }
    END {
      printf "$ preview: %s/%s | %s", os, pm, tools
    }
  ' || true
  )"

  doctor_line="$(
    ./scripts/doctor.sh 2>/dev/null | awk '
    /^ok: (tmux|starship|lazygit|nvim|yazi|ghostty) found/ {
      tools = tools (tools ? " " : "") $2
    }
    END {
      printf "$ doctor: ok %s", tools
    }
  ' || true
  )"

  printf '%s\n' "$preview_line"
  printf '%s\n\n' "$doctor_line"
  exec_shell
}

run_pane_mode() {
  case "$PANE_MODE" in
    editor) run_editor ;;
    files) run_files ;;
    git) run_git ;;
    prompt) run_prompt ;;
    *) die "unknown pane mode: $PANE_MODE" ;;
  esac
}

shell_quote() {
  printf '%q' "$1"
}

detect_tmux_size() {
  local cols="${SHOWCASE_COLS:-${COLUMNS:-}}"
  local lines="${SHOWCASE_LINES:-${LINES:-}}"

  if [[ -t 1 ]]; then
    cols="${cols:-$(tput cols 2>/dev/null || true)}"
    lines="${lines:-$(tput lines 2>/dev/null || true)}"
  fi

  [[ "$cols" =~ ^[0-9]+$ ]] || cols=80
  [[ "$lines" =~ ^[0-9]+$ ]] || lines=24
  printf '%s %s\n' "$cols" "$lines"
}

explicit_tmux_size() {
  [[ -n "${SHOWCASE_COLS:-}" || -n "${SHOWCASE_LINES:-}" ]]
}

should_set_tmux_size() {
  explicit_tmux_size || [[ "$ATTACH" != "1" ]] || [[ ! -t 1 ]]
}

attach_or_switch() {
  if [[ "$ATTACH" != "1" ]]; then
    printf 'Created tmux session: %s\n' "$SESSION"
    printf 'Attach with: tmux attach -t %s\n' "$SESSION"
    return 0
  fi

  if [[ -n "${TMUX:-}" ]]; then
    tmux switch-client -t "$SESSION"
  else
    tmux attach-session -t "$SESSION"
  fi
}

set_tmux_options() {
  local window_id="$1"

  tmux set-option -t "$SESSION" mouse on >/dev/null
  tmux set-option -t "$SESSION" status on >/dev/null
  tmux set-option -t "$SESSION" status-position bottom >/dev/null
  tmux set-option -t "$SESSION" status-bg "#333333" >/dev/null
  tmux set-option -t "$SESSION" status-fg white >/dev/null
  tmux set-option -t "$SESSION" base-index 1 >/dev/null
  tmux set-window-option -t "$window_id" pane-base-index 1 >/dev/null
  tmux set-option -t "$SESSION" window-status-format " #I:#W " >/dev/null
  tmux set-option -t "$SESSION" window-status-current-format " #I:#W " >/dev/null
  tmux set-option -t "$SESSION" status-left " my-terminal " >/dev/null
  tmux set-option -t "$SESSION" status-right " %Y-%m-%d %H:%M " >/dev/null
  tmux set-window-option -t "$window_id" pane-border-status top >/dev/null
  tmux set-window-option -t "$window_id" pane-border-format " #{pane_title} " >/dev/null
  tmux bind-key -n M-1 select-window -t :=1 >/dev/null
  tmux bind-key -n M-2 select-window -t :=2 >/dev/null
  tmux bind-key -n M-3 select-window -t :=3 >/dev/null
  tmux bind-key -n M-4 select-window -t :=4 >/dev/null
}

create_session() {
  local window_id
  local top_left
  local bottom
  local right_top
  local right_bottom
  local script_cmd
  local term_cols
  local term_lines

  command -v tmux >/dev/null 2>&1 || die "tmux is required"
  script_cmd="$(shell_quote "$SCRIPT_PATH")"
  if should_set_tmux_size; then
    read -r term_cols term_lines < <(detect_tmux_size)
  fi

  if tmux has-session -t "$SESSION" 2>/dev/null; then
    if [[ "$RESET" == "1" ]]; then
      tmux kill-session -t "$SESSION"
    else
      attach_or_switch
      return 0
    fi
  fi

  if should_set_tmux_size; then
    tmux new-session -d -x "$term_cols" -y "$term_lines" -s "$SESSION" -n dev -c "$REPO_ROOT" "$script_cmd --pane editor"
  else
    tmux new-session -d -s "$SESSION" -n dev -c "$REPO_ROOT" "$script_cmd --pane editor"
  fi
  window_id="$(tmux display-message -p -t "$SESSION" '#{window_id}')"
  tmux rename-window -t "$window_id" dev
  set_tmux_options "$window_id"

  top_left="$(tmux display-message -p -t "$window_id" '#{pane_id}')"
  bottom="$(tmux split-window -v -l 32% -P -F '#{pane_id}' -t "$top_left" -c "$REPO_ROOT" "$script_cmd --pane prompt")"
  right_top="$(tmux split-window -h -l 36% -P -F '#{pane_id}' -t "$top_left" -c "$REPO_ROOT" "$script_cmd --pane files")"
  right_bottom="$(tmux split-window -v -l 50% -P -F '#{pane_id}' -t "$right_top" -c "$REPO_ROOT" "$script_cmd --pane git")"

  tmux select-pane -t "$top_left" -T "nvim / LazyVim"
  tmux select-pane -t "$right_top" -T "yazi files"
  tmux select-pane -t "$right_bottom" -T "lazygit"
  tmux select-pane -t "$bottom" -T "preview + doctor"

  tmux new-window -d -t "$SESSION" -n ai -c "$REPO_ROOT"
  tmux new-window -d -t "$SESSION" -n ssh -c "$REPO_ROOT"
  tmux new-window -d -t "$SESSION" -n logs -c "$REPO_ROOT"
  tmux move-window -r -t "$SESSION"
  tmux select-window -t "$window_id"
  tmux select-pane -t "$top_left"

  attach_or_switch
}

main() {
  parse_args "$@"

  if [[ -n "$PANE_MODE" ]]; then
    run_pane_mode
  fi

  create_session
}

main "$@"
