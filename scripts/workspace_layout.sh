#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPT_PATH="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"

WORK_DIR="${WORKSPACE_DIR:-$(pwd -P)}"
SESSION="${WORKSPACE_SESSION:-my-terminal-workspace}"
RESET=0
ATTACH=1
PANE_MODE=""
FIT_ONLY=0

usage() {
  cat <<'EOF'
Usage: scripts/workspace_layout.sh [--dir PATH] [--session NAME] [--reset] [--no-attach]

Create a daily tmux workspace:
  - window 1: dev
    - left top: nvim
    - left bottom: shell
    - right top: yazi
    - right bottom: lazygit
  - window 2: ai
    - left: agent-1 shell
    - right: agent-2 shell
  - window 3: ssh
    - 4 shells for remote sessions
  - window 4: logs
    - left: logs-1 shell
    - right: logs-2 shell
  - window 5: btop
    - system monitor

Options:
  --dir PATH      Use PATH as the workspace directory. Defaults to current directory.
  --session NAME  Use a custom tmux session name.
  --reset         Recreate the session if it already exists.
  --no-attach     Create the session and print its name without attaching.
  --fit-only      Refit an existing session without creating or attaching.
  --help, -h      Show this help.

Environment:
  WORKSPACE_COLS / WORKSPACE_LINES  Override the detected tmux size.
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

resolve_dir() {
  local path="$1"

  [[ -d "$path" ]] || die "not a directory: $path"
  (cd "$path" && pwd -P)
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dir)
        [[ $# -ge 2 ]] || die "--dir requires a path"
        WORK_DIR="$(resolve_dir "$2")"
        shift 2
        ;;
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
      --fit-only)
        FIT_ONLY=1
        ATTACH=0
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

  WORK_DIR="$(resolve_dir "$WORK_DIR")"
}

exec_shell() {
  local shell_path="${SHELL:-/bin/sh}"

  if [[ "${shell_path##*/}" == "zsh" ]]; then
    PROMPT_EOL_MARK="" exec "$shell_path"
  fi

  exec "$shell_path"
}

run_editor() {
  cd "$WORK_DIR"
  if command -v nvim >/dev/null 2>&1; then
    nvim . || true
    exec_shell
  fi

  clear 2>/dev/null || true
  printf 'nvim is not installed. Workspace: %s\n\n' "$WORK_DIR"
  ls -la
  exec_shell
}

run_files() {
  cd "$WORK_DIR"
  if command -v yazi >/dev/null 2>&1; then
    yazi . || true
    exec_shell
  fi

  clear 2>/dev/null || true
  printf 'yazi is not installed. Workspace: %s\n\n' "$WORK_DIR"
  if command -v eza >/dev/null 2>&1; then
    eza --tree --level=2 --icons=auto . 2>/dev/null || true
  else
    find . -maxdepth 2 -type f | sort | sed -n '1,80p' || true
  fi
  exec_shell
}

run_git() {
  cd "$WORK_DIR"
  if command -v lazygit >/dev/null 2>&1; then
    lazygit || true
    exec_shell
  fi

  clear 2>/dev/null || true
  printf 'lazygit is not installed. Workspace: %s\n\n' "$WORK_DIR"
  git status --short 2>/dev/null || true
  printf '\nRecent commits:\n'
  git log --oneline --decorate -n 8 2>/dev/null || true
  exec_shell
}

run_shell() {
  cd "$WORK_DIR"
  exec_shell
}

run_monitor() {
  cd "$WORK_DIR"
  if command -v btop >/dev/null 2>&1; then
    btop || true
    exec_shell
  fi

  clear 2>/dev/null || true
  printf 'btop is not installed. Workspace: %s\n\n' "$WORK_DIR"
  exec_shell
}

run_pane_mode() {
  case "$PANE_MODE" in
    editor) run_editor ;;
    files) run_files ;;
    git) run_git ;;
    monitor) run_monitor ;;
    shell) run_shell ;;
    *) die "unknown pane mode: $PANE_MODE" ;;
  esac
}

shell_quote() {
  printf '%q' "$1"
}

detect_tmux_size() {
  local cols="${WORKSPACE_COLS:-}"
  local detected_cols
  local detected_lines
  local detected_window_cols
  local detected_window_lines
  local lines="${WORKSPACE_LINES:-}"

  if [[ -z "$cols" || -z "$lines" ]]; then
    while read -r detected_cols detected_lines; do
      [[ "$detected_cols" =~ ^[0-9]+$ ]] && cols="${cols:-$detected_cols}"
      [[ "$detected_lines" =~ ^[0-9]+$ ]] && lines="${lines:-$detected_lines}"
      [[ -n "$cols" && -n "$lines" ]] && break
    done < <(tmux list-clients -t "$SESSION" -F '#{client_width} #{client_height}' 2>/dev/null || true)
  fi

  if [[ -z "$cols" || -z "$lines" ]] && [[ -n "${TMUX:-}" ]]; then
    if read -r detected_cols detected_lines < <(tmux display-message -p '#{client_width} #{client_height}' 2>/dev/null); then
      [[ "$detected_cols" =~ ^[0-9]+$ ]] && cols="${cols:-$detected_cols}"
      [[ "$detected_lines" =~ ^[0-9]+$ ]] && lines="${lines:-$detected_lines}"
    fi
  fi

  if [[ -z "$cols" || -z "$lines" ]] && [[ -t 1 ]]; then
    if read -r detected_lines detected_cols < <(stty size 2>/dev/null); then
      [[ "$detected_cols" =~ ^[0-9]+$ ]] && cols="${cols:-$detected_cols}"
      [[ "$detected_lines" =~ ^[0-9]+$ ]] && lines="${lines:-$detected_lines}"
    fi
  fi

  if [[ -z "$cols" || -z "$lines" ]] && [[ -t 1 ]]; then
    detected_cols="$(tput cols 2>/dev/null || true)"
    detected_lines="$(tput lines 2>/dev/null || true)"
    [[ "$detected_cols" =~ ^[0-9]+$ ]] && cols="${cols:-$detected_cols}"
    [[ "$detected_lines" =~ ^[0-9]+$ ]] && lines="${lines:-$detected_lines}"
  fi

  cols="${cols:-${COLUMNS:-}}"
  lines="${lines:-${LINES:-}}"

  if [[ -z "$cols" || -z "$lines" ]]; then
    if read -r detected_window_cols detected_window_lines < <(tmux display-message -p -t "$SESSION" '#{window_width} #{window_height}' 2>/dev/null); then
      [[ "$detected_window_cols" =~ ^[0-9]+$ ]] && cols="${cols:-$detected_window_cols}"
      [[ "$detected_window_lines" =~ ^[0-9]+$ ]] && lines="${lines:-$detected_window_lines}"
    fi
  fi

  [[ "$cols" =~ ^[0-9]+$ ]] || cols=80
  [[ "$lines" =~ ^[0-9]+$ ]] || lines=24
  printf '%s %s\n' "$cols" "$lines"
}

workspace_window_target() {
  window_id_by_name dev \
    || tmux display-message -p -t "$SESSION" '#{window_id}' 2>/dev/null \
    || true
}

window_id_by_name() {
  local target_name="$1"
  local window_id
  local window_name

  while read -r window_id window_name; do
    if [[ "$window_name" == "$target_name" ]]; then
      printf '%s\n' "$window_id"
      return 0
    fi
  done < <(tmux list-windows -t "$SESSION" -F '#{window_id} #{window_name}' 2>/dev/null)

  return 1
}

pane_id_by_title() {
  local pane_id
  local pane_title
  local title="$2"
  local window_id="$1"

  while read -r pane_id pane_title; do
    if [[ "$pane_title" == "$title" ]]; then
      printf '%s\n' "$pane_id"
      return 0
    fi
  done < <(tmux list-panes -t "$window_id" -F '#{pane_id} #{pane_title}' 2>/dev/null)

  return 1
}

fit_pane_layout() {
  local bottom_height
  local git_pane
  local pane_area_height
  local right_bottom_height
  local right_width
  local shell_pane
  local term_cols
  local term_lines
  local window_id="$1"
  local yazi_pane

  read -r term_cols term_lines < <(detect_tmux_size)

  yazi_pane="$(pane_id_by_title "$window_id" yazi || true)"
  shell_pane="$(pane_id_by_title "$window_id" shell || true)"
  git_pane="$(pane_id_by_title "$window_id" lazygit || true)"
  [[ -n "$yazi_pane" && -n "$shell_pane" && -n "$git_pane" ]] || return 0

  pane_area_height=$((term_lines > 1 ? term_lines - 1 : term_lines))
  right_width=$(((term_cols - 1) * 36 / 100))
  bottom_height=$((pane_area_height * 32 / 100))
  right_bottom_height=$(((pane_area_height - 1) / 2))

  ((right_width < 24)) && right_width=24
  ((bottom_height < 6)) && bottom_height=6
  ((right_bottom_height < 6)) && right_bottom_height=6

  tmux select-layout -E -t "$window_id" >/dev/null 2>&1 || true
  tmux resize-pane -t "$yazi_pane" -x "$right_width" >/dev/null 2>&1 || true
  tmux resize-pane -t "$shell_pane" -y "$bottom_height" >/dev/null 2>&1 || true
  tmux resize-pane -t "$git_pane" -y "$right_bottom_height" >/dev/null 2>&1 || true
}

fit_ai_layout() {
  local agent_1_pane
  local agent_2_pane
  local window_id="$1"

  agent_1_pane="$(pane_id_by_title "$window_id" agent-1 || true)"
  agent_2_pane="$(pane_id_by_title "$window_id" agent-2 || true)"
  [[ -n "$agent_1_pane" && -n "$agent_2_pane" ]] || return 0

  tmux select-layout -t "$window_id" even-horizontal >/dev/null 2>&1 || true
}

fit_logs_layout() {
  local logs_1_pane
  local logs_2_pane
  local window_id="$1"

  logs_1_pane="$(pane_id_by_title "$window_id" logs-1 || true)"
  logs_2_pane="$(pane_id_by_title "$window_id" logs-2 || true)"
  [[ -n "$logs_1_pane" && -n "$logs_2_pane" ]] || return 0

  tmux select-layout -t "$window_id" even-horizontal >/dev/null 2>&1 || true
}

fit_ssh_layout() {
  local pane
  local window_id="$1"

  for pane in ssh-1 ssh-2 ssh-3 ssh-4; do
    pane_id_by_title "$window_id" "$pane" >/dev/null || return 0
  done

  tmux select-layout -t "$window_id" tiled >/dev/null 2>&1 || true
}

fit_workspace_to_terminal() {
  local ai_window
  local btop_window
  local logs_window
  local ssh_window
  local target_window="${1:-}"
  local term_cols
  local term_lines

  target_window="${target_window:-$(workspace_window_target)}"
  [[ -n "$target_window" ]] || return 0

  read -r term_cols term_lines < <(detect_tmux_size)
  set_window_pane_options "$target_window"
  tmux set-option -t "$SESSION" window-size latest >/dev/null 2>&1 || true
  tmux resize-window -t "$target_window" -x "$term_cols" -y "$term_lines" >/dev/null 2>&1 || true
  tmux set-option -t "$SESSION" window-size latest >/dev/null 2>&1 || true
  fit_pane_layout "$target_window"

  ai_window="$(window_id_by_name ai || true)"
  ssh_window="$(window_id_by_name ssh || true)"
  logs_window="$(window_id_by_name logs || true)"
  btop_window="$(window_id_by_name btop || true)"

  if [[ -n "$ai_window" ]]; then
    set_window_pane_options "$ai_window"
    tmux resize-window -t "$ai_window" -x "$term_cols" -y "$term_lines" >/dev/null 2>&1 || true
    fit_ai_layout "$ai_window"
  fi

  if [[ -n "$ssh_window" ]]; then
    set_window_pane_options "$ssh_window"
    tmux resize-window -t "$ssh_window" -x "$term_cols" -y "$term_lines" >/dev/null 2>&1 || true
    fit_ssh_layout "$ssh_window"
  fi

  if [[ -n "$logs_window" ]]; then
    set_window_pane_options "$logs_window"
    tmux resize-window -t "$logs_window" -x "$term_cols" -y "$term_lines" >/dev/null 2>&1 || true
    fit_logs_layout "$logs_window"
  fi

  if [[ -n "$btop_window" ]]; then
    set_window_pane_options "$btop_window"
    tmux resize-window -t "$btop_window" -x "$term_cols" -y "$term_lines" >/dev/null 2>&1 || true
  fi

  tmux set-option -t "$SESSION" window-size latest >/dev/null 2>&1 || true
}

set_workspace_hooks() {
  local hook_cmd

  hook_cmd="WORKSPACE_COLS=#{client_width} WORKSPACE_LINES=#{client_height} $(shell_quote "$SCRIPT_PATH") --dir $(shell_quote "$WORK_DIR") --session $(shell_quote "$SESSION") --fit-only"

  tmux set-hook -t "$SESSION" client-resized "run-shell -b '$hook_cmd'" >/dev/null 2>&1 || true
  tmux set-hook -t "$SESSION" client-attached "run-shell -b '$hook_cmd'" >/dev/null 2>&1 || true
  tmux set-hook -t "$SESSION" client-session-changed "run-shell -b '$hook_cmd'" >/dev/null 2>&1 || true
  tmux set-hook -t "$SESSION" session-window-changed "run-shell -b '$hook_cmd'" >/dev/null 2>&1 || true
  tmux set-hook -t "$SESSION" after-select-window "run-shell -b '$hook_cmd'" >/dev/null 2>&1 || true
}

attach_or_switch() {
  set_workspace_hooks
  fit_workspace_to_terminal

  if [[ "$ATTACH" != "1" ]]; then
    printf 'Created tmux session: %s\n' "$SESSION"
    printf 'Workspace: %s\n' "$WORK_DIR"
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
  tmux set-option -t "$SESSION" window-status-format " #I:#W " >/dev/null
  tmux set-option -t "$SESSION" window-status-current-format " #I:#W " >/dev/null
  tmux set-option -t "$SESSION" status-left " workspace " >/dev/null
  tmux set-option -t "$SESSION" status-right " %Y-%m-%d %H:%M " >/dev/null
  tmux set-option -t "$SESSION" window-size latest >/dev/null 2>&1 || true
  tmux set-window-option -t "$window_id" aggressive-resize on >/dev/null 2>&1 || true
  tmux bind-key -n M-1 select-window -t :=1 >/dev/null
  tmux bind-key -n M-2 select-window -t :=2 >/dev/null
  tmux bind-key -n M-3 select-window -t :=3 >/dev/null
  tmux bind-key -n M-4 select-window -t :=4 >/dev/null
  tmux bind-key -n M-5 select-window -t :=5 >/dev/null
  set_workspace_hooks
}

set_window_pane_options() {
  local window_id="$1"

  tmux set-window-option -t "$window_id" pane-border-status top >/dev/null
  tmux set-window-option -t "$window_id" pane-border-format " #{pane_title} " >/dev/null
  tmux set-window-option -t "$window_id" aggressive-resize on >/dev/null 2>&1 || true
  tmux set-window-option -t "$window_id" pane-base-index 1 >/dev/null
}

create_ai_window() {
  local agent_1_pane
  local agent_2_pane
  local script_cmd="$1"
  local window_id

  window_id="$(tmux new-window -d -P -F '#{window_id}' -t "$SESSION" -n ai -c "$WORK_DIR" "$script_cmd --dir $(shell_quote "$WORK_DIR") --pane shell")"
  set_window_pane_options "$window_id"

  agent_1_pane="$(tmux display-message -p -t "$window_id" '#{pane_id}')"
  agent_2_pane="$(tmux split-window -h -P -F '#{pane_id}' -t "$agent_1_pane" -c "$WORK_DIR" "$script_cmd --dir $(shell_quote "$WORK_DIR") --pane shell")"

  tmux select-pane -t "$agent_1_pane" -T "agent-1"
  tmux select-pane -t "$agent_2_pane" -T "agent-2"
  fit_ai_layout "$window_id"
}

create_ssh_window() {
  local script_cmd="$1"
  local ssh_1_pane
  local ssh_2_pane
  local ssh_3_pane
  local ssh_4_pane
  local window_id

  window_id="$(tmux new-window -d -P -F '#{window_id}' -t "$SESSION" -n ssh -c "$WORK_DIR" "$script_cmd --dir $(shell_quote "$WORK_DIR") --pane shell")"
  set_window_pane_options "$window_id"

  ssh_1_pane="$(tmux display-message -p -t "$window_id" '#{pane_id}')"
  ssh_2_pane="$(tmux split-window -h -P -F '#{pane_id}' -t "$ssh_1_pane" -c "$WORK_DIR" "$script_cmd --dir $(shell_quote "$WORK_DIR") --pane shell")"
  ssh_3_pane="$(tmux split-window -v -P -F '#{pane_id}' -t "$ssh_1_pane" -c "$WORK_DIR" "$script_cmd --dir $(shell_quote "$WORK_DIR") --pane shell")"
  ssh_4_pane="$(tmux split-window -v -P -F '#{pane_id}' -t "$ssh_2_pane" -c "$WORK_DIR" "$script_cmd --dir $(shell_quote "$WORK_DIR") --pane shell")"

  tmux select-pane -t "$ssh_1_pane" -T "ssh-1"
  tmux select-pane -t "$ssh_2_pane" -T "ssh-2"
  tmux select-pane -t "$ssh_3_pane" -T "ssh-3"
  tmux select-pane -t "$ssh_4_pane" -T "ssh-4"
  fit_ssh_layout "$window_id"
  tmux select-pane -t "$ssh_1_pane"
}

create_logs_window() {
  local logs_1_pane
  local logs_2_pane
  local script_cmd="$1"
  local window_id

  window_id="$(tmux new-window -d -P -F '#{window_id}' -t "$SESSION" -n logs -c "$WORK_DIR" "$script_cmd --dir $(shell_quote "$WORK_DIR") --pane shell")"
  set_window_pane_options "$window_id"

  logs_1_pane="$(tmux display-message -p -t "$window_id" '#{pane_id}')"
  logs_2_pane="$(tmux split-window -h -P -F '#{pane_id}' -t "$logs_1_pane" -c "$WORK_DIR" "$script_cmd --dir $(shell_quote "$WORK_DIR") --pane shell")"

  tmux select-pane -t "$logs_1_pane" -T "logs-1"
  tmux select-pane -t "$logs_2_pane" -T "logs-2"
  fit_logs_layout "$window_id"
  tmux select-pane -t "$logs_1_pane"
}

create_btop_window() {
  local btop_pane
  local script_cmd="$1"
  local window_id

  window_id="$(tmux new-window -d -P -F '#{window_id}' -t "$SESSION" -n btop -c "$WORK_DIR" "$script_cmd --dir $(shell_quote "$WORK_DIR") --pane monitor")"
  set_window_pane_options "$window_id"

  btop_pane="$(tmux display-message -p -t "$window_id" '#{pane_id}')"
  tmux select-pane -t "$btop_pane" -T "btop"
}

ensure_btop_window() {
  local script_cmd="$1"

  if ! window_id_by_name btop >/dev/null; then
    create_btop_window "$script_cmd"
    tmux move-window -r -t "$SESSION"
  fi
}

create_session() {
  local bottom
  local right_bottom
  local right_top
  local script_cmd
  local term_cols
  local term_lines
  local top_left
  local window_id

  command -v tmux >/dev/null 2>&1 || die "tmux is required"
  script_cmd="$(shell_quote "$SCRIPT_PATH")"
  read -r term_cols term_lines < <(detect_tmux_size)

  if tmux has-session -t "$SESSION" 2>/dev/null; then
    if [[ "$RESET" == "1" ]]; then
      tmux kill-session -t "$SESSION"
    else
      ensure_btop_window "$script_cmd"
      attach_or_switch
      return 0
    fi
  fi

  tmux new-session -d -x "$term_cols" -y "$term_lines" -s "$SESSION" -n dev -c "$WORK_DIR" "$script_cmd --dir $(shell_quote "$WORK_DIR") --pane editor"
  window_id="$(tmux display-message -p -t "$SESSION" '#{window_id}')"
  tmux rename-window -t "$window_id" dev
  set_tmux_options "$window_id"
  set_window_pane_options "$window_id"
  fit_workspace_to_terminal "$window_id"

  top_left="$(tmux display-message -p -t "$window_id" '#{pane_id}')"
  right_top="$(tmux split-window -h -l 36% -P -F '#{pane_id}' -t "$top_left" -c "$WORK_DIR" "$script_cmd --dir $(shell_quote "$WORK_DIR") --pane files")"
  bottom="$(tmux split-window -v -l 32% -P -F '#{pane_id}' -t "$top_left" -c "$WORK_DIR" "$script_cmd --dir $(shell_quote "$WORK_DIR") --pane shell")"
  right_bottom="$(tmux split-window -v -l 50% -P -F '#{pane_id}' -t "$right_top" -c "$WORK_DIR" "$script_cmd --dir $(shell_quote "$WORK_DIR") --pane git")"

  tmux select-pane -t "$top_left" -T "nvim"
  tmux select-pane -t "$right_top" -T "yazi"
  tmux select-pane -t "$right_bottom" -T "lazygit"
  tmux select-pane -t "$bottom" -T "shell"

  create_ai_window "$script_cmd"
  create_ssh_window "$script_cmd"
  create_logs_window "$script_cmd"
  create_btop_window "$script_cmd"
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

  if [[ "$FIT_ONLY" == "1" ]]; then
    command -v tmux >/dev/null 2>&1 || die "tmux is required"
    fit_workspace_to_terminal
    exit 0
  fi

  create_session
}

main "$@"
