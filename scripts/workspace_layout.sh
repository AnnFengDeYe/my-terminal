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
FIT_TARGET=""
LIST_WINDOWS=0
SELECT_ENTRY_ONLY=0

usage() {
  cat <<'EOF'
Usage: scripts/workspace_layout.sh [--dir PATH] [--session NAME] [--reset] [--no-attach]

Create a daily tmux workspace:
  - window 1: dev
    - left top: nvim
    - left bottom: shell
    - right top: lazygit
    - right bottom: yazi
  - window 2: agent
    - left: agent-1 shell
    - right: agent-2 shell
  - window 3: ssh
    - 4 shells for remote sessions
  - window 4: logs
    - left: logs-1 shell
    - right: logs-2 shell
  - window 5: btop
    - system monitor
  - window 6: manual
    - alias and function manual

Options:
  --dir PATH      Use PATH as the workspace directory. Defaults to current directory.
  --session NAME  Use a custom tmux session name.
  --reset         Recreate the session if it already exists.
  --no-attach     Create the session and print its name without attaching.
  --fit-only      Refit an existing session without creating or attaching.
  --target-window WINDOW_ID
                  With --fit-only, refit only one tmux window. Used by hooks.
  --list-windows  Print the workspace window registry and exit.
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
      --target-window)
        [[ $# -ge 2 ]] || die "--target-window requires a tmux window id"
        FIT_TARGET="$2"
        shift 2
        ;;
      --list-windows)
        LIST_WINDOWS=1
        ATTACH=0
        shift
        ;;
      --select-entry-only)
        SELECT_ENTRY_ONLY=1
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

run_manual() {
  cd "$WORK_DIR"
  clear 2>/dev/null || true
  WORKPLACE_MANUAL_FULL_HEIGHT=1 "$SCRIPT_DIR/workplace_manual.sh" --interactive || true
  exec_shell
}

run_pane_mode() {
  case "$PANE_MODE" in
    editor) run_editor ;;
    files) run_files ;;
    git) run_git ;;
    manual) run_manual ;;
    monitor) run_monitor ;;
    shell) run_shell ;;
    *) die "unknown pane mode: $PANE_MODE" ;;
  esac
}

shell_quote() {
  printf '%q' "$1"
}

WORKSPACE_WINDOWS=(
  "dev|primary|shell|editor|configure_dev_window|fit_dev_layout"
  "agent|secondary||shell|configure_agent_window|fit_agent_layout"
  "ssh|secondary||shell|configure_ssh_window|fit_ssh_layout"
  "logs|secondary||shell|configure_logs_window|fit_logs_layout"
  "btop|secondary||monitor|configure_btop_window|fit_noop_layout"
  "manual|secondary||manual|configure_manual_window|fit_noop_layout"
)

workspace_window_records() {
  printf '%s\n' "${WORKSPACE_WINDOWS[@]}"
}

workspace_window_record() {
  local candidate="$1"
  local configure_fn
  local entry_pane
  local fit_fn
  local initial_pane_mode
  local role
  local window_name

  while IFS='|' read -r window_name role entry_pane initial_pane_mode configure_fn fit_fn; do
    if [[ "$window_name" == "$candidate" ]]; then
      printf '%s|%s|%s|%s|%s|%s\n' "$window_name" "$role" "$entry_pane" "$initial_pane_mode" "$configure_fn" "$fit_fn"
      return 0
    fi
  done < <(workspace_window_records)

  return 1
}

workspace_window_field() {
  local configure_fn
  local entry_pane
  local field_name="$2"
  local fit_fn
  local initial_pane_mode
  local role
  local window_name

  if ! IFS='|' read -r window_name role entry_pane initial_pane_mode configure_fn fit_fn < <(workspace_window_record "$1"); then
    return 1
  fi

  case "$field_name" in
    name) printf '%s\n' "$window_name" ;;
    role) printf '%s\n' "$role" ;;
    entry_pane) printf '%s\n' "$entry_pane" ;;
    initial_pane_mode) printf '%s\n' "$initial_pane_mode" ;;
    configure_fn) printf '%s\n' "$configure_fn" ;;
    fit_fn) printf '%s\n' "$fit_fn" ;;
    *) return 1 ;;
  esac
}

workspace_window_names() {
  local configure_fn
  local entry_pane
  local fit_fn
  local initial_pane_mode
  local role
  local window_name

  while IFS='|' read -r window_name role entry_pane initial_pane_mode configure_fn fit_fn; do
    printf '%s\n' "$window_name"
  done < <(workspace_window_records)
}

workspace_window_fit_fn() {
  workspace_window_field "$1" fit_fn
}

workspace_window_configure_fn() {
  workspace_window_field "$1" configure_fn
}

workspace_window_initial_pane_mode() {
  workspace_window_field "$1" initial_pane_mode
}

workspace_window_is_primary() {
  local role

  role="$(workspace_window_field "$1" role || true)"
  [[ "$role" == "primary" ]]
}

workspace_entry_window_name() {
  local configure_fn
  local entry_pane
  local fit_fn
  local initial_pane_mode
  local role
  local window_name

  while IFS='|' read -r window_name role entry_pane initial_pane_mode configure_fn fit_fn; do
    if [[ "$role" == "primary" ]]; then
      printf '%s\n' "$window_name"
      return 0
    fi
  done < <(workspace_window_records)

  return 1
}

workspace_entry_pane_title() {
  local configure_fn
  local entry_pane
  local fit_fn
  local initial_pane_mode
  local role
  local window_name

  while IFS='|' read -r window_name role entry_pane initial_pane_mode configure_fn fit_fn; do
    if [[ "$role" == "primary" ]]; then
      [[ -n "$entry_pane" ]] || return 1
      printf '%s\n' "$entry_pane"
      return 0
    fi
  done < <(workspace_window_records)

  return 1
}

workspace_window_is_configured() {
  workspace_window_record "$1" >/dev/null
}

workspace_window_manifest() {
  local configure_fn
  local entry_pane
  local fit_fn
  local index=1
  local initial_pane_mode
  local role
  local window_name

  while IFS='|' read -r window_name role entry_pane initial_pane_mode configure_fn fit_fn; do
    printf '%s:%s:%s:%s:%s:%s:%s\n' "$index" "$window_name" "$role" "$entry_pane" "$initial_pane_mode" "$configure_fn" "$fit_fn"
    index=$((index + 1))
  done < <(workspace_window_records)
}

bind_workspace_keys() {
  local index=1
  local window_name

  while read -r window_name; do
    [[ -n "$window_name" ]] || continue
    tmux bind-key -n "M-$index" select-window -t ":=$index" >/dev/null
    index=$((index + 1))
  done < <(workspace_window_names)
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

set_workspace_pane_role() {
  local pane_id="$1"
  local role="$2"
  local title="$3"

  tmux select-pane -t "$pane_id" -T "$title"
  tmux set-option -p -t "$pane_id" @workspace_pane_role "$role" >/dev/null 2>&1 || true
}

pane_id_by_role() {
  local pane_id
  local pane_role
  local role="$2"
  local window_id="$1"

  while read -r pane_id pane_role; do
    if [[ "$pane_role" == "$role" ]]; then
      printf '%s\n' "$pane_id"
      return 0
    fi
  done < <(tmux list-panes -t "$window_id" -F '#{pane_id} #{@workspace_pane_role}' 2>/dev/null)

  return 1
}

pane_id_by_role_or_title() {
  local role="$2"
  local title="$3"
  local window_id="$1"

  pane_id_by_role "$window_id" "$role" || pane_id_by_title "$window_id" "$title"
}

pane_is_plain_shell() {
  local current_command
  local in_mode
  local pane_id="$1"
  local uses_alternate_screen

  read -r current_command in_mode uses_alternate_screen < <(
    tmux display-message -p -t "$pane_id" '#{pane_current_command} #{pane_in_mode} #{alternate_on}' 2>/dev/null ||
      printf 'unknown 1 1\n'
  )

  [[ "$in_mode" == "0" && "$uses_alternate_screen" == "0" ]] || return 1
  case "$current_command" in
    bash|zsh|fish|sh) return 0 ;;
  esac

  return 1
}

clear_shell_prompt_input() {
  local pane_id="$1"

  pane_is_plain_shell "$pane_id" || return 0
  tmux send-keys -t "$pane_id" C-u >/dev/null 2>&1 || true
}

cancel_pane_mode() {
  local in_mode
  local pane_id="$1"

  in_mode="$(tmux display-message -p -t "$pane_id" '#{pane_in_mode}' 2>/dev/null || printf '0')"
  [[ "$in_mode" == "1" ]] || return 0
  tmux copy-mode -q -t "$pane_id" >/dev/null 2>&1 || true
}

shield_workspace_entry_pane() {
  local pane_id
  local pane_title
  local window_id
  local window_name

  window_name="$(workspace_entry_window_name)"
  pane_title="$(workspace_entry_pane_title)"
  window_id="$(window_id_by_name "$window_name" || true)"
  [[ -n "$window_id" ]] || return 0

  pane_id="$(pane_id_by_role_or_title "$window_id" "$pane_title" "$pane_title" || true)"
  [[ -n "$pane_id" ]] || return 0

  tmux select-window -t "$window_id" >/dev/null 2>&1 || return 0
  tmux select-pane -t "$pane_id" >/dev/null 2>&1 || return 0
  pane_is_plain_shell "$pane_id" || return 0
  tmux copy-mode -H -t "$pane_id" >/dev/null 2>&1 || true
}

fit_dev_layout() {
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

  yazi_pane="$(pane_id_by_role_or_title "$window_id" files yazi || true)"
  shell_pane="$(pane_id_by_role_or_title "$window_id" shell shell || true)"
  git_pane="$(pane_id_by_role_or_title "$window_id" git lazygit || true)"
  [[ -n "$yazi_pane" && -n "$shell_pane" && -n "$git_pane" ]] || return 0

  pane_area_height=$((term_lines > 1 ? term_lines - 1 : term_lines))
  right_width=$(((term_cols - 1) * 36 / 100))
  bottom_height=$((pane_area_height * 32 / 100))
  right_bottom_height=$(((pane_area_height - 1) / 2))

  ((right_width < 24)) && right_width=24
  ((bottom_height < 6)) && bottom_height=6
  ((right_bottom_height < 6)) && right_bottom_height=6

  tmux select-layout -E -t "$window_id" >/dev/null 2>&1 || true
  tmux resize-pane -t "$git_pane" -x "$right_width" >/dev/null 2>&1 || true
  tmux resize-pane -t "$shell_pane" -y "$bottom_height" >/dev/null 2>&1 || true
  tmux resize-pane -t "$yazi_pane" -y "$right_bottom_height" >/dev/null 2>&1 || true
}

fit_agent_layout() {
  local agent_1_pane
  local agent_2_pane
  local window_id="$1"

  agent_1_pane="$(pane_id_by_role_or_title "$window_id" agent-1 agent-1 || true)"
  agent_2_pane="$(pane_id_by_role_or_title "$window_id" agent-2 agent-2 || true)"
  [[ -n "$agent_1_pane" && -n "$agent_2_pane" ]] || return 0

  tmux select-layout -t "$window_id" even-horizontal >/dev/null 2>&1 || true
}

fit_logs_layout() {
  local logs_1_pane
  local logs_2_pane
  local window_id="$1"

  logs_1_pane="$(pane_id_by_role_or_title "$window_id" logs-1 logs-1 || true)"
  logs_2_pane="$(pane_id_by_role_or_title "$window_id" logs-2 logs-2 || true)"
  [[ -n "$logs_1_pane" && -n "$logs_2_pane" ]] || return 0

  tmux select-layout -t "$window_id" even-horizontal >/dev/null 2>&1 || true
}

fit_ssh_layout() {
  local pane
  local window_id="$1"

  for pane in ssh-1 ssh-2 ssh-3 ssh-4; do
    pane_id_by_role_or_title "$window_id" "$pane" "$pane" >/dev/null || return 0
  done

  tmux select-layout -t "$window_id" tiled >/dev/null 2>&1 || true
}

fit_noop_layout() {
  return 0
}

fit_window_layout() {
  local fit_fn="$2"
  local window_id="$1"

  declare -F "$fit_fn" >/dev/null || return 0
  "$fit_fn" "$window_id"
}

fit_window_to_terminal() {
  local fit_fn="$2"
  local term_cols="$3"
  local term_lines="$4"
  local window_id="$1"

  [[ -n "$window_id" ]] || return 0
  tmux display-message -p -t "$window_id" '#{window_id}' >/dev/null 2>&1 || return 0

  set_window_pane_options "$window_id"
  tmux resize-window -t "$window_id" -x "$term_cols" -y "$term_lines" >/dev/null 2>&1 || true
  fit_window_layout "$window_id" "$fit_fn"
}

fit_workspace_target_to_terminal() {
  local fit_fn
  local term_cols
  local term_lines
  local window_id="$1"
  local window_name

  [[ -n "$window_id" ]] || return 0
  window_name="$(tmux display-message -p -t "$window_id" '#{window_name}' 2>/dev/null || true)"
  [[ -n "$window_name" ]] || return 0
  workspace_window_is_configured "$window_name" || return 0

  fit_fn="$(workspace_window_fit_fn "$window_name" || printf 'fit_noop_layout')"
  read -r term_cols term_lines < <(detect_tmux_size)
  tmux set-option -t "$SESSION" window-size latest >/dev/null 2>&1 || true
  fit_window_to_terminal "$window_id" "$fit_fn" "$term_cols" "$term_lines"
  tmux set-option -t "$SESSION" window-size latest >/dev/null 2>&1 || true
}

fit_workspace_to_terminal() {
  local fit_fn
  local term_cols
  local term_lines
  local window_id
  local window_name

  read -r term_cols term_lines < <(detect_tmux_size)
  tmux set-option -t "$SESSION" window-size latest >/dev/null 2>&1 || true

  while read -r window_name; do
    window_id="$(window_id_by_name "$window_name" || true)"
    [[ -n "$window_id" ]] || continue

    fit_fn="$(workspace_window_fit_fn "$window_name" || printf 'fit_noop_layout')"
    fit_window_to_terminal "$window_id" "$fit_fn" "$term_cols" "$term_lines"
  done < <(workspace_window_names)

  tmux set-option -t "$SESSION" window-size latest >/dev/null 2>&1 || true
}

select_workspace_entry_pane() {
  local pane_id
  local pane_title
  local restore_mode="${1:-}"
  local window_id
  local window_name

  window_name="$(workspace_entry_window_name)"
  pane_title="$(workspace_entry_pane_title)"
  window_id="$(window_id_by_name "$window_name" || true)"
  [[ -n "$window_id" ]] || return 0

  tmux select-window -t "$window_id" >/dev/null 2>&1 || return 0
  pane_id="$(pane_id_by_role_or_title "$window_id" "$pane_title" "$pane_title" || true)"
  [[ -n "$pane_id" ]] || return 0
  [[ "$restore_mode" == "restore" ]] && cancel_pane_mode "$pane_id"
  clear_shell_prompt_input "$pane_id"
  tmux select-pane -t "$pane_id" >/dev/null 2>&1 || true
}

schedule_workspace_entry_pane() {
  local command
  local delay="${WORKSPACE_ENTRY_DELAY:-2.5}"

  # Some terminal feature probes can arrive after attach; shield the shell prompt
  # briefly, then restore the intended entry pane once the client settles.
  command="$(shell_quote "$SCRIPT_PATH") --dir $(shell_quote "$WORK_DIR") --session $(shell_quote "$SESSION") --select-entry-only >/dev/null 2>&1 || true"

  tmux run-shell -b -d "$delay" "$command" >/dev/null 2>&1 || true
}

set_workspace_hooks() {
  local fit_all_cmd
  local fit_window_cmd

  fit_all_cmd="WORKSPACE_COLS=#{client_width} WORKSPACE_LINES=#{client_height} $(shell_quote "$SCRIPT_PATH") --dir $(shell_quote "$WORK_DIR") --session $(shell_quote "$SESSION") --fit-only >/dev/null 2>&1 || true"
  fit_window_cmd="WORKSPACE_COLS=#{client_width} WORKSPACE_LINES=#{client_height} $(shell_quote "$SCRIPT_PATH") --dir $(shell_quote "$WORK_DIR") --session $(shell_quote "$SESSION") --fit-only --target-window #{window_id} >/dev/null 2>&1 || true"

  tmux set-hook -t "$SESSION" client-resized "run-shell -b '$fit_all_cmd'" >/dev/null 2>&1 || true
  tmux set-hook -t "$SESSION" client-attached "run-shell -b '$fit_all_cmd'" >/dev/null 2>&1 || true
  tmux set-hook -t "$SESSION" client-session-changed "run-shell -b '$fit_all_cmd'" >/dev/null 2>&1 || true
  tmux set-hook -t "$SESSION" session-window-changed "run-shell -b '$fit_window_cmd'" >/dev/null 2>&1 || true
  tmux set-hook -t "$SESSION" after-select-window "run-shell -b '$fit_window_cmd'" >/dev/null 2>&1 || true
}

attach_or_switch() {
  set_workspace_hooks
  if [[ "$ATTACH" == "1" ]]; then
    shield_workspace_entry_pane
  fi

  fit_workspace_to_terminal

  if [[ "$ATTACH" != "1" ]]; then
    select_workspace_entry_pane
    printf 'Created tmux session: %s\n' "$SESSION"
    printf 'Workspace: %s\n' "$WORK_DIR"
    printf 'Attach with: tmux attach -t %s\n' "$SESSION"
    return 0
  fi

  shield_workspace_entry_pane
  schedule_workspace_entry_pane

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
  bind_workspace_keys
  set_workspace_hooks
}

set_window_pane_options() {
  local window_id="$1"

  tmux display-message -p -t "$window_id" '#{window_id}' >/dev/null 2>&1 || return 0
  tmux set-window-option -t "$window_id" pane-border-status top >/dev/null 2>&1 || true
  tmux set-window-option -t "$window_id" pane-border-format " #{pane_title} " >/dev/null 2>&1 || true
  tmux set-window-option -t "$window_id" aggressive-resize on >/dev/null 2>&1 || true
  tmux set-window-option -t "$window_id" pane-base-index 1 >/dev/null 2>&1 || true
}

configure_dev_window() {
  local bottom
  local right_bottom
  local right_top
  local script_cmd="$2"
  local top_left
  local window_id="$1"

  set_window_pane_options "$window_id"

  top_left="$(tmux display-message -p -t "$window_id" '#{pane_id}')"
  right_top="$(tmux split-window -h -l 36% -P -F '#{pane_id}' -t "$top_left" -c "$WORK_DIR" "$script_cmd --dir $(shell_quote "$WORK_DIR") --pane git")"
  bottom="$(tmux split-window -v -l 32% -P -F '#{pane_id}' -t "$top_left" -c "$WORK_DIR" "$script_cmd --dir $(shell_quote "$WORK_DIR") --pane shell")"
  right_bottom="$(tmux split-window -v -l 50% -P -F '#{pane_id}' -t "$right_top" -c "$WORK_DIR" "$script_cmd --dir $(shell_quote "$WORK_DIR") --pane files")"

  set_workspace_pane_role "$top_left" editor "nvim"
  set_workspace_pane_role "$right_top" git "lazygit"
  set_workspace_pane_role "$right_bottom" files "yazi"
  set_workspace_pane_role "$bottom" shell "shell"
  fit_dev_layout "$window_id"
}

configure_agent_window() {
  local agent_1_pane
  local agent_2_pane
  local script_cmd="$2"
  local window_id="$1"

  set_window_pane_options "$window_id"

  agent_1_pane="$(tmux display-message -p -t "$window_id" '#{pane_id}')"
  agent_2_pane="$(tmux split-window -h -P -F '#{pane_id}' -t "$agent_1_pane" -c "$WORK_DIR" "$script_cmd --dir $(shell_quote "$WORK_DIR") --pane shell")"

  set_workspace_pane_role "$agent_1_pane" agent-1 "agent-1"
  set_workspace_pane_role "$agent_2_pane" agent-2 "agent-2"
  fit_agent_layout "$window_id"
}

configure_ssh_window() {
  local script_cmd="$2"
  local ssh_1_pane
  local ssh_2_pane
  local ssh_3_pane
  local ssh_4_pane
  local window_id="$1"

  set_window_pane_options "$window_id"

  ssh_1_pane="$(tmux display-message -p -t "$window_id" '#{pane_id}')"
  ssh_2_pane="$(tmux split-window -h -P -F '#{pane_id}' -t "$ssh_1_pane" -c "$WORK_DIR" "$script_cmd --dir $(shell_quote "$WORK_DIR") --pane shell")"
  ssh_3_pane="$(tmux split-window -v -P -F '#{pane_id}' -t "$ssh_1_pane" -c "$WORK_DIR" "$script_cmd --dir $(shell_quote "$WORK_DIR") --pane shell")"
  ssh_4_pane="$(tmux split-window -v -P -F '#{pane_id}' -t "$ssh_2_pane" -c "$WORK_DIR" "$script_cmd --dir $(shell_quote "$WORK_DIR") --pane shell")"

  set_workspace_pane_role "$ssh_1_pane" ssh-1 "ssh-1"
  set_workspace_pane_role "$ssh_2_pane" ssh-2 "ssh-2"
  set_workspace_pane_role "$ssh_3_pane" ssh-3 "ssh-3"
  set_workspace_pane_role "$ssh_4_pane" ssh-4 "ssh-4"
  fit_ssh_layout "$window_id"
  tmux select-pane -t "$ssh_1_pane"
}

configure_logs_window() {
  local logs_1_pane
  local logs_2_pane
  local script_cmd="$2"
  local window_id="$1"

  set_window_pane_options "$window_id"

  logs_1_pane="$(tmux display-message -p -t "$window_id" '#{pane_id}')"
  logs_2_pane="$(tmux split-window -h -P -F '#{pane_id}' -t "$logs_1_pane" -c "$WORK_DIR" "$script_cmd --dir $(shell_quote "$WORK_DIR") --pane shell")"

  set_workspace_pane_role "$logs_1_pane" logs-1 "logs-1"
  set_workspace_pane_role "$logs_2_pane" logs-2 "logs-2"
  fit_logs_layout "$window_id"
  tmux select-pane -t "$logs_1_pane"
}

configure_btop_window() {
  local btop_pane
  local window_id="$1"

  set_window_pane_options "$window_id"

  btop_pane="$(tmux display-message -p -t "$window_id" '#{pane_id}')"
  set_workspace_pane_role "$btop_pane" monitor "btop"
}

configure_manual_window() {
  local manual_pane
  local window_id="$1"

  set_window_pane_options "$window_id"

  manual_pane="$(tmux display-message -p -t "$window_id" '#{pane_id}')"
  set_workspace_pane_role "$manual_pane" manual "manual"
}

create_workspace_window() {
  local configure_fn
  local initial_pane_mode
  local script_cmd="$2"
  local window_name="$1"
  local window_id

  configure_fn="$(workspace_window_configure_fn "$window_name" || true)"
  initial_pane_mode="$(workspace_window_initial_pane_mode "$window_name" || true)"
  [[ -n "$configure_fn" && -n "$initial_pane_mode" ]] || die "no registry entry for workspace window: $window_name"
  declare -F "$configure_fn" >/dev/null || die "missing configure function for workspace window: $window_name"

  window_id="$(tmux new-window -d -P -F '#{window_id}' -t "$SESSION" -n "$window_name" -c "$WORK_DIR" "$script_cmd --dir $(shell_quote "$WORK_DIR") --pane $(shell_quote "$initial_pane_mode")")"
  "$configure_fn" "$window_id" "$script_cmd"
}

create_remaining_workspace_windows() {
  local script_cmd="$1"
  local window_name

  while read -r window_name; do
    workspace_window_is_primary "$window_name" && continue
    create_workspace_window "$window_name" "$script_cmd"
  done < <(workspace_window_names)
}

ensure_workspace_windows() {
  local created=0
  local script_cmd="$1"
  local window_name

  while read -r window_name; do
    if ! window_id_by_name "$window_name" >/dev/null; then
      create_workspace_window "$window_name" "$script_cmd"
      created=1
    fi
  done < <(workspace_window_names)

  if [[ "$created" == "1" ]]; then
    order_workspace_windows
  fi
}

order_workspace_windows() {
  local current_index
  local index=1
  local window_id
  local window_name

  while read -r window_name; do
    window_id="$(window_id_by_name "$window_name" || true)"
    [[ -n "$window_id" ]] || continue

    current_index="$(tmux display-message -p -t "$window_id" '#I' 2>/dev/null || true)"
    if [[ "$current_index" != "$index" ]]; then
      tmux swap-window -d -s "$window_id" -t "$SESSION:=$index" >/dev/null 2>&1 ||
        tmux move-window -d -s "$window_id" -t "$SESSION:=$index" >/dev/null 2>&1 ||
        true
    fi
    index=$((index + 1))
  done < <(workspace_window_names)

  tmux move-window -r -t "$SESSION"
}

create_primary_workspace_window() {
  local configure_fn
  local initial_pane_mode
  local script_cmd="$1"
  local term_cols="$2"
  local term_lines="$3"
  local window_id
  local window_name

  window_name="$(workspace_entry_window_name)" || die "no primary workspace window configured"
  configure_fn="$(workspace_window_configure_fn "$window_name" || true)"
  initial_pane_mode="$(workspace_window_initial_pane_mode "$window_name" || true)"
  [[ -n "$configure_fn" && -n "$initial_pane_mode" ]] || die "no registry entry for primary workspace window: $window_name"
  declare -F "$configure_fn" >/dev/null || die "missing configure function for primary workspace window: $window_name"

  tmux new-session -d -x "$term_cols" -y "$term_lines" -s "$SESSION" -n "$window_name" -c "$WORK_DIR" "$script_cmd --dir $(shell_quote "$WORK_DIR") --pane $(shell_quote "$initial_pane_mode")"
  window_id="$(tmux display-message -p -t "$SESSION" '#{window_id}')"
  tmux rename-window -t "$window_id" "$window_name"
  set_tmux_options "$window_id"
  "$configure_fn" "$window_id" "$script_cmd"
  printf '%s\n' "$window_id"
}

create_session() {
  local script_cmd
  local term_cols
  local term_lines
  local window_id

  command -v tmux >/dev/null 2>&1 || die "tmux is required"
  script_cmd="$(shell_quote "$SCRIPT_PATH")"
  read -r term_cols term_lines < <(detect_tmux_size)

  if tmux has-session -t "$SESSION" 2>/dev/null; then
    if [[ "$RESET" == "1" ]]; then
      tmux kill-session -t "$SESSION"
    else
      ensure_workspace_windows "$script_cmd"
      attach_or_switch
      return 0
    fi
  fi

  window_id="$(create_primary_workspace_window "$script_cmd" "$term_cols" "$term_lines")"
  create_remaining_workspace_windows "$script_cmd"
  order_workspace_windows
  select_workspace_entry_pane

  attach_or_switch
}

main() {
  parse_args "$@"

  if [[ "$LIST_WINDOWS" == "1" ]]; then
    workspace_window_manifest
    exit 0
  fi

  if [[ "$SELECT_ENTRY_ONLY" == "1" ]]; then
    command -v tmux >/dev/null 2>&1 || die "tmux is required"
    select_workspace_entry_pane restore
    exit 0
  fi

  if [[ -n "$PANE_MODE" ]]; then
    run_pane_mode
  fi

  if [[ "$FIT_ONLY" == "1" ]]; then
    command -v tmux >/dev/null 2>&1 || die "tmux is required"
    if [[ -n "$FIT_TARGET" ]]; then
      fit_workspace_target_to_terminal "$FIT_TARGET"
    else
      fit_workspace_to_terminal
    fi
    exit 0
  fi

  create_session
}

main "$@"
