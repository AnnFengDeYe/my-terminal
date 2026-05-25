#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPT_PATH="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"

WORK_DIR="${WORKSPACE_DIR:-$(pwd -P)}"
SESSION="${WORKSPACE_SESSION:-my-terminal-workspace}"
RESET=0
REPAIR=0
SESSION_CREATED=0
ATTACH=1
PANE_MODE=""
FIT_ONLY=0
FIT_TARGET=""
LIST_WINDOWS=0
SELECT_ENTRY_ONLY=0
SCHEDULE_FIT=0

usage() {
  cat <<'EOF'
Usage: scripts/workspace_layout.sh [--dir PATH] [--session NAME] [--repair] [--reset] [--no-attach]

Create a daily tmux workspace:
  - window 1: dev
    - left top: nvim
    - left bottom: shell
    - right top: lazygit
    - right bottom: yazi
  - window 2: agent
    - configurable AI agent panes
    - default: Codex / Gemini, falling back to shell if the CLI is missing
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
  --repair        Repair managed windows, pane roles, hooks, and options without killing tasks.
  --reset         Recreate the session if it already exists.
  --no-attach     Create the session and print its name without attaching.
  --fit-only      Resize an existing session without creating or attaching.
  --target-window WINDOW_ID
                  With --fit-only, resize only one tmux window. Used by hooks.
  --schedule-fit  Schedule a debounced fit pass. Used by hooks.
  --list-windows  Print the workspace window registry and exit.
  --repair-layout Reset managed pane layouts during fit/repair.
  --help, -h      Show this help.

Environment:
  WORKSPACE_COLS / WORKSPACE_LINES  Override the detected tmux size.
  WORKSPACE_REFIT_LAYOUT=1          Reset managed pane layouts during fit/repair.
  WORKSPACE_AGENT_CONFIG=FILE       Read agent pane config from FILE.
  WORKSPACE_AGENT_LAYOUT=auto|horizontal|vertical|tiled
                                   Override the agent window layout.
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
      --repair)
        REPAIR=1
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
      --repair-layout)
        export WORKSPACE_REFIT_LAYOUT=1
        shift
        ;;
      --schedule-fit)
        SCHEDULE_FIT=1
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

trim_space() {
  local value="$1"

  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

default_workspace_agent_records() {
  printf '%s\n' \
    "agent-1|Codex|codex" \
    "agent-2|Gemini|gemini"
}

workspace_agent_config_file() {
  local candidate

  if [[ -n "${WORKSPACE_AGENT_CONFIG:-}" ]]; then
    [[ -f "$WORKSPACE_AGENT_CONFIG" ]] && printf '%s\n' "$WORKSPACE_AGENT_CONFIG"
    return 0
  fi

  for candidate in \
    "$WORK_DIR/.my-terminal/agents.tsv" \
    "${HOME:-}/.config/my-terminal/workspace_agents.tsv" \
    "$REPO_ROOT/configs/workspace/agents.tsv"; do
    [[ -n "$candidate" && -f "$candidate" ]] || continue
    printf '%s\n' "$candidate"
    return 0
  done
}

parse_workspace_agent_config() {
  local command
  local config_file="$1"
  local _extra
  local line
  local role
  local title

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -n "$(trim_space "$line")" ]] || continue
    [[ "$line" == \#* ]] && continue

    IFS=$'\t' read -r role title command _extra <<< "$line"
    role="$(trim_space "${role:-}")"
    title="$(trim_space "${title:-}")"
    command="$(trim_space "${command:-}")"

    [[ "$role" == "role" && "$title" == "title" ]] && continue
    [[ -n "$role" ]] || continue
    [[ "$role" =~ ^[A-Za-z0-9_.-]+$ ]] || continue
    [[ -n "$title" ]] || title="$role"

    printf '%s|%s|%s\n' "$role" "$title" "$command"
  done < "$config_file"
}

workspace_agent_records() {
  local config_file
  local record
  local records=()

  config_file="$(workspace_agent_config_file || true)"
  if [[ -n "$config_file" ]]; then
    while IFS= read -r record; do
      [[ -n "$record" ]] || continue
      records+=("$record")
    done < <(parse_workspace_agent_config "$config_file")
  fi

  if [[ "${#records[@]}" -gt 0 ]]; then
    printf '%s\n' "${records[@]}"
  else
    default_workspace_agent_records
  fi
}

workspace_agent_record_by_role() {
  local command
  local role
  local target_role="$1"
  local title

  while IFS='|' read -r role title command; do
    if [[ "$role" == "$target_role" ]]; then
      printf '%s|%s|%s\n' "$role" "$title" "$command"
      return 0
    fi
  done < <(workspace_agent_records)

  return 1
}

first_workspace_agent_record() {
  local record

  while IFS= read -r record; do
    [[ -n "$record" ]] || continue
    printf '%s\n' "$record"
    return 0
  done < <(workspace_agent_records)

  return 1
}

agent_command_executable() {
  local command="$1"
  local token

  while :; do
    read -r token _ <<< "$command"
    [[ -n "${token:-}" ]] || return 1
    case "$token" in
      *=*)
        command="${command#"$token"}"
        command="$(trim_space "$command")"
        ;;
      command|exec)
        command="${command#"$token"}"
        command="$(trim_space "$command")"
        ;;
      env)
        command="${command#"$token"}"
        command="$(trim_space "$command")"
        ;;
      *)
        printf '%s\n' "$token"
        return 0
        ;;
    esac
  done
}

run_agent() {
  local agent_command
  local executable
  local record
  local role
  local shell_path="${SHELL:-/bin/sh}"
  local target_role="${1:-}"
  local title

  cd "$WORK_DIR"

  if [[ -n "$target_role" ]]; then
    record="$(workspace_agent_record_by_role "$target_role" || true)"
  else
    record="$(first_workspace_agent_record || true)"
  fi

  if [[ -z "$record" ]]; then
    clear 2>/dev/null || true
    printf 'workspace agent is not configured'
    [[ -n "$target_role" ]] && printf ': %s' "$target_role"
    printf '\n\n'
    exec_shell
  fi

  IFS='|' read -r role title agent_command <<< "$record"
  if [[ -z "$agent_command" ]]; then
    exec_shell
  fi

  executable="$(agent_command_executable "$agent_command" || true)"
  if [[ -z "$executable" ]] || ! command -v "$executable" >/dev/null 2>&1; then
    clear 2>/dev/null || true
    printf 'workspace agent configured: %s\n' "$title"
    printf 'command not found in PATH: %s\n' "${executable:-$agent_command}"
    printf 'Install it yourself, edit the agent config, or continue in this shell.\n\n'
    exec_shell
  fi

  "$shell_path" -lc "$agent_command" || true
  exec_shell
}

run_pane_mode() {
  case "$PANE_MODE" in
    agent) run_agent ;;
    agent:*) run_agent "${PANE_MODE#agent:}" ;;
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
  "agent|secondary||agent|configure_agent_window|fit_agent_layout"
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

tmux_workspace_windows() {
  tmux list-windows -t "$SESSION" -F '#{window_id}|#{@workspace_managed}|#{@workspace_window_name}|#{window_name}' 2>/dev/null
}

set_workspace_window_metadata() {
  local window_id="$1"
  local window_name="$2"

  tmux set-window-option -t "$window_id" @workspace_managed 1 >/dev/null 2>&1 || true
  tmux set-window-option -t "$window_id" @workspace_window_name "$window_name" >/dev/null 2>&1 || true
}

window_id_by_workspace_metadata() {
  local managed
  local managed_name
  local target_name="$1"
  local window_id
  local window_name

  while IFS='|' read -r window_id managed managed_name window_name; do
    if [[ "$managed" == "1" && "$managed_name" == "$target_name" ]]; then
      printf '%s\n' "$window_id"
      return 0
    fi
  done < <(tmux_workspace_windows)

  return 1
}

window_id_by_exact_window_name() {
  local managed
  local managed_name
  local target_name="$1"
  local window_id
  local window_name

  while IFS='|' read -r window_id managed managed_name window_name; do
    if [[ "$window_name" == "$target_name" ]]; then
      printf '%s\n' "$window_id"
      return 0
    fi
  done < <(tmux_workspace_windows)

  return 1
}

window_id_by_name() {
  local target_name="$1"

  window_id_by_workspace_metadata "$target_name" || window_id_by_exact_window_name "$target_name"
}

workspace_window_name_for_id() {
  local current_name
  local managed_name
  local window_id="$1"

  managed_name="$(tmux display-message -p -t "$window_id" '#{@workspace_window_name}' 2>/dev/null || true)"
  if [[ -n "$managed_name" ]] && workspace_window_is_configured "$managed_name"; then
    printf '%s\n' "$managed_name"
    return 0
  fi

  current_name="$(tmux display-message -p -t "$window_id" '#{window_name}' 2>/dev/null || true)"
  [[ -n "$current_name" ]] || return 1
  printf '%s\n' "$current_name"
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
  local _agent_command
  local layout="${WORKSPACE_AGENT_LAYOUT:-auto}"
  local pane_count=0
  local pane_id
  local role
  local title
  local window_id="$1"

  while IFS='|' read -r role title _agent_command; do
    pane_id="$(pane_id_by_role_or_title "$window_id" "$role" "$title" || true)"
    [[ -n "$pane_id" ]] || return 0
    pane_count=$((pane_count + 1))
  done < <(workspace_agent_records)

  case "$layout" in
    horizontal)
      ((pane_count > 1)) && tmux select-layout -t "$window_id" even-horizontal >/dev/null 2>&1 || true
      ;;
    vertical)
      ((pane_count > 1)) && tmux select-layout -t "$window_id" even-vertical >/dev/null 2>&1 || true
      ;;
    tiled)
      ((pane_count > 1)) && tmux select-layout -t "$window_id" tiled >/dev/null 2>&1 || true
      ;;
    auto|"")
      if ((pane_count == 2)); then
        tmux select-layout -t "$window_id" even-horizontal >/dev/null 2>&1 || true
      elif ((pane_count > 2)); then
        tmux select-layout -t "$window_id" tiled >/dev/null 2>&1 || true
      fi
      ;;
    *)
      if ((pane_count == 2)); then
        tmux select-layout -t "$window_id" even-horizontal >/dev/null 2>&1 || true
      elif ((pane_count > 2)); then
        tmux select-layout -t "$window_id" tiled >/dev/null 2>&1 || true
      fi
      ;;
  esac
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

resize_window_to_terminal() {
  local current_cols
  local current_lines
  local term_cols="$2"
  local term_lines="$3"
  local window_id="$1"

  read -r current_cols current_lines < <(
    tmux display-message -p -t "$window_id" '#{window_width} #{window_height}' 2>/dev/null ||
      printf '0 0\n'
  )

  [[ "$current_cols" == "$term_cols" && "$current_lines" == "$term_lines" ]] && return 0
  tmux resize-window -t "$window_id" -x "$term_cols" -y "$term_lines" >/dev/null 2>&1 || true
}

should_refit_pane_layout() {
  [[ "${WORKSPACE_REFIT_LAYOUT:-0}" == "1" ]]
}

window_is_zoomed() {
  local window_id="$1"
  local zoomed

  zoomed="$(tmux display-message -p -t "$window_id" '#{window_zoomed_flag}' 2>/dev/null || printf '0')"
  [[ "$zoomed" == "1" ]]
}

fit_window_to_terminal() {
  local fit_fn="$2"
  local term_cols="$3"
  local term_lines="$4"
  local window_id="$1"

  [[ -n "$window_id" ]] || return 0
  tmux display-message -p -t "$window_id" '#{window_id}' >/dev/null 2>&1 || return 0

  resize_window_to_terminal "$window_id" "$term_cols" "$term_lines"
  should_refit_pane_layout || return 0
  window_is_zoomed "$window_id" && return 0
  fit_window_layout "$window_id" "$fit_fn"
}

fit_workspace_target_to_terminal() {
  local fit_fn
  local term_cols
  local term_lines
  local window_id="$1"
  local window_name

  [[ -n "$window_id" ]] || return 0
  window_name="$(workspace_window_name_for_id "$window_id" || true)"
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

schedule_workspace_fit() {
  local command
  local delay="${WORKSPACE_FIT_DELAY:-0.25}"
  local token="$$.$RANDOM"

  tmux set-option -q -t "$SESSION" @workspace_fit_token "$token" >/dev/null 2>&1 || true
  tmux set-option -q -t "$SESSION" @workspace_fit_cols "${WORKSPACE_COLS:-}" >/dev/null 2>&1 || true
  tmux set-option -q -t "$SESSION" @workspace_fit_lines "${WORKSPACE_LINES:-}" >/dev/null 2>&1 || true

  command="if [ \"\$(tmux show-options -qv -t $(shell_quote "$SESSION") @workspace_fit_token 2>/dev/null)\" = $(shell_quote "$token") ]; then "
  command+="WORKSPACE_COLS=\"\$(tmux show-options -qv -t $(shell_quote "$SESSION") @workspace_fit_cols 2>/dev/null)\" "
  command+="WORKSPACE_LINES=\"\$(tmux show-options -qv -t $(shell_quote "$SESSION") @workspace_fit_lines 2>/dev/null)\" "
  command+="$(shell_quote "$SCRIPT_PATH") --dir $(shell_quote "$WORK_DIR") --session $(shell_quote "$SESSION") --fit-only >/dev/null 2>&1 || true; "
  command+="fi"

  tmux run-shell -b -d "$delay" "$command" >/dev/null 2>&1 || true
}

set_workspace_hooks() {
  local schedule_fit_cmd

  schedule_fit_cmd="WORKSPACE_COLS=#{client_width} WORKSPACE_LINES=#{client_height} $(shell_quote "$SCRIPT_PATH") --dir $(shell_quote "$WORK_DIR") --session $(shell_quote "$SESSION") --schedule-fit >/dev/null 2>&1 || true"

  tmux set-hook -t "$SESSION" client-resized "run-shell -b '$schedule_fit_cmd'" >/dev/null 2>&1 || true
  tmux set-hook -t "$SESSION" client-attached "run-shell -b '$schedule_fit_cmd'" >/dev/null 2>&1 || true
  tmux set-hook -t "$SESSION" client-session-changed "run-shell -b '$schedule_fit_cmd'" >/dev/null 2>&1 || true
  tmux set-hook -u -t "$SESSION" session-window-changed >/dev/null 2>&1 || true
  tmux set-hook -u -t "$SESSION" after-select-window >/dev/null 2>&1 || true
}

attach_or_switch() {
  set_workspace_hooks
  if [[ "$ATTACH" == "1" ]]; then
    shield_workspace_entry_pane
  fi

  fit_workspace_to_terminal

  if [[ "$ATTACH" != "1" ]]; then
    select_workspace_entry_pane
    if [[ "$SESSION_CREATED" == "1" ]]; then
      printf 'Created tmux session: %s\n' "$SESSION"
    else
      printf 'Workspace session ready: %s\n' "$SESSION"
    fi
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
  local _agent_command
  local agent_pane
  local anchor_pane
  local index=0
  local pane_mode
  local role
  local script_cmd="$2"
  local title
  local window_id="$1"

  set_window_pane_options "$window_id"

  anchor_pane="$(tmux display-message -p -t "$window_id" '#{pane_id}')"
  while IFS='|' read -r role title _agent_command; do
    pane_mode="agent:$role"
    if [[ "$index" == "0" ]]; then
      agent_pane="$anchor_pane"
    else
      agent_pane="$(tmux split-window -h -P -F '#{pane_id}' -t "$anchor_pane" -c "$WORK_DIR" "$script_cmd --dir $(shell_quote "$WORK_DIR") --pane $(shell_quote "$pane_mode")")"
    fi

    set_workspace_pane_role "$agent_pane" "$role" "$title"
    index=$((index + 1))
  done < <(workspace_agent_records)

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
  set_workspace_window_metadata "$window_id" "$window_name"
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

workspace_pane_records() {
  case "$1" in
    dev)
      printf '%s\n' \
        "editor|nvim|editor" \
        "git|lazygit|git" \
        "files|yazi|files" \
        "shell|shell|shell"
      ;;
    agent)
      local _agent_command
      local role
      local title

      while IFS='|' read -r role title _agent_command; do
        [[ -n "$role" && -n "$title" ]] || continue
        printf '%s|%s|agent:%s\n' "$role" "$title" "$role"
      done < <(workspace_agent_records)
      ;;
    ssh)
      printf '%s\n' \
        "ssh-1|ssh-1|shell" \
        "ssh-2|ssh-2|shell" \
        "ssh-3|ssh-3|shell" \
        "ssh-4|ssh-4|shell"
      ;;
    logs)
      printf '%s\n' \
        "logs-1|logs-1|shell" \
        "logs-2|logs-2|shell"
      ;;
    btop)
      printf '%s\n' "monitor|btop|monitor"
      ;;
    manual)
      printf '%s\n' "manual|manual|manual"
      ;;
  esac
}

repair_workspace_pane_roles() {
  local expected_count=0
  local found_count=0
  local pane_mode
  local pane_id
  local role
  local title
  local window_id="$1"
  local window_name="$2"

  while IFS='|' read -r role title pane_mode; do
    [[ -n "$role" && -n "$title" && -n "$pane_mode" ]] || continue
    expected_count=$((expected_count + 1))
    pane_id="$(pane_id_by_role_or_title "$window_id" "$role" "$title" || true)"
    [[ -n "$pane_id" ]] || continue
    set_workspace_pane_role "$pane_id" "$role" "$title"
    found_count=$((found_count + 1))
  done < <(workspace_pane_records "$window_name")

  if [[ "$expected_count" != "0" && "$found_count" != "$expected_count" ]]; then
    repair_workspace_pane_roles_by_index "$window_id" "$window_name"
  fi
}

repair_workspace_pane_roles_by_index() {
  local expected_roles=()
  local expected_titles=()
  local index
  local pane_mode
  local pane_id
  local pane_ids=()
  local role
  local title
  local window_id="$1"
  local window_name="$2"

  while IFS='|' read -r role title pane_mode; do
    [[ -n "$role" && -n "$title" && -n "$pane_mode" ]] || continue
    expected_roles+=("$role")
    expected_titles+=("$title")
  done < <(workspace_pane_records "$window_name")

  [[ "${#expected_roles[@]}" != "0" ]] || return 0

  while read -r pane_id; do
    [[ -n "$pane_id" ]] || continue
    pane_ids+=("$pane_id")
  done < <(tmux list-panes -t "$window_id" -F '#{pane_id}' 2>/dev/null)

  [[ "${#pane_ids[@]}" == "${#expected_roles[@]}" ]] || return 0

  for ((index = 0; index < ${#expected_roles[@]}; index++)); do
    set_workspace_pane_role "${pane_ids[$index]}" "${expected_roles[$index]}" "${expected_titles[$index]}"
  done
}

first_pane_id_in_window() {
  local window_id="$1"

  tmux list-panes -t "$window_id" -F '#{pane_id}' 2>/dev/null | sed -n '1p'
}

workspace_pane_split_direction() {
  local anchor_role="$3"
  local role="$2"
  local window_name="$1"

  case "$window_name:$role:$anchor_role" in
    dev:shell:*) printf 'v\n' ;;
    dev:files:git|dev:git:files) printf 'v\n' ;;
    dev:editor:shell) printf 'v\n' ;;
    *) printf 'h\n' ;;
  esac
}

create_missing_workspace_pane() {
  local anchor_pane="$4"
  local before="$5"
  local direction="$6"
  local pane_mode="$3"
  local role="$1"
  local script_cmd="$7"
  local split_args=()
  local title="$2"
  local new_pane

  if [[ "$direction" == "v" ]]; then
    split_args+=("-v")
  else
    split_args+=("-h")
  fi

  [[ "$before" == "1" ]] && split_args+=("-b")

  new_pane="$(
    tmux split-window "${split_args[@]}" -P -F '#{pane_id}' -t "$anchor_pane" -c "$WORK_DIR" \
      "$script_cmd --dir $(shell_quote "$WORK_DIR") --pane $(shell_quote "$pane_mode")"
  )"
  [[ -n "$new_pane" ]] || return 1
  set_workspace_pane_role "$new_pane" "$role" "$title"
}

ensure_missing_workspace_panes() {
  local anchor_pane
  local anchor_role
  local before
  local created=1
  local direction
  local index
  local look
  local modes=()
  local pane_id
  local pane_mode
  local roles=()
  local script_cmd="$3"
  local titles=()
  local window_id="$1"
  local window_name="$2"

  while IFS='|' read -r role title pane_mode; do
    [[ -n "$role" && -n "$title" && -n "$pane_mode" ]] || continue
    roles+=("$role")
    titles+=("$title")
    modes+=("$pane_mode")
  done < <(workspace_pane_records "$window_name")

  [[ "${#roles[@]}" != "0" ]] || return 1

  for ((index = 0; index < ${#roles[@]}; index++)); do
    pane_id="$(pane_id_by_role_or_title "$window_id" "${roles[$index]}" "${titles[$index]}" || true)"
    [[ -n "$pane_id" ]] && continue

    anchor_pane=""
    anchor_role=""
    before=0

    for ((look = index + 1; look < ${#roles[@]}; look++)); do
      anchor_pane="$(pane_id_by_role_or_title "$window_id" "${roles[$look]}" "${titles[$look]}" || true)"
      if [[ -n "$anchor_pane" ]]; then
        anchor_role="${roles[$look]}"
        before=1
        break
      fi
    done

    if [[ -z "$anchor_pane" ]]; then
      for ((look = index - 1; look >= 0; look--)); do
        anchor_pane="$(pane_id_by_role_or_title "$window_id" "${roles[$look]}" "${titles[$look]}" || true)"
        if [[ -n "$anchor_pane" ]]; then
          anchor_role="${roles[$look]}"
          before=0
          break
        fi
      done
    fi

    if [[ -z "$anchor_pane" ]]; then
      anchor_pane="$(first_pane_id_in_window "$window_id" || true)"
      before=0
    fi

    [[ -n "$anchor_pane" ]] || continue
    direction="$(workspace_pane_split_direction "$window_name" "${roles[$index]}" "$anchor_role")"
    create_missing_workspace_pane "${roles[$index]}" "${titles[$index]}" "${modes[$index]}" "$anchor_pane" "$before" "$direction" "$script_cmd" || continue
    created=0
  done

  return "$created"
}

repair_workspace_window() {
  local current_name
  local fit_fn
  local full_repair="$3"
  local pane_created=1
  local script_cmd="$4"
  local selected_pane
  local window_id="$1"
  local window_name="$2"

  [[ -n "$window_id" ]] || return 0
  set_workspace_window_metadata "$window_id" "$window_name"
  current_name="$(tmux display-message -p -t "$window_id" '#{window_name}' 2>/dev/null || true)"
  if [[ -n "$current_name" && "$current_name" != "$window_name" ]]; then
    tmux rename-window -t "$window_id" "$window_name" >/dev/null 2>&1 || true
  fi

  set_window_pane_options "$window_id"
  [[ "$full_repair" == "1" ]] || return 0
  selected_pane="$(tmux display-message -p -t "$window_id" '#{pane_id}' 2>/dev/null || true)"
  repair_workspace_pane_roles "$window_id" "$window_name"
  ensure_missing_workspace_panes "$window_id" "$window_name" "$script_cmd" && pane_created=0
  repair_workspace_pane_roles "$window_id" "$window_name"
  if [[ "$pane_created" == "0" ]] && ! window_is_zoomed "$window_id"; then
    fit_fn="$(workspace_window_fit_fn "$window_name" || printf 'fit_noop_layout')"
    fit_window_layout "$window_id" "$fit_fn"
  fi
  if [[ -n "$selected_pane" ]]; then
    tmux select-pane -t "$selected_pane" >/dev/null 2>&1 || true
  fi
}

repair_workspace_session() {
  local entry_window_id
  local entry_window_name
  local full_repair="$2"
  local script_cmd="$1"
  local window_id
  local window_name

  ensure_workspace_windows "$script_cmd"

  while read -r window_name; do
    window_id="$(window_id_by_name "$window_name" || true)"
    [[ -n "$window_id" ]] || continue
    repair_workspace_window "$window_id" "$window_name" "$full_repair" "$script_cmd"
  done < <(workspace_window_names)

  entry_window_name="$(workspace_entry_window_name || true)"
  entry_window_id="$(window_id_by_name "$entry_window_name" || true)"
  if [[ -n "$entry_window_id" ]]; then
    set_tmux_options "$entry_window_id"
  else
    bind_workspace_keys
    set_workspace_hooks
  fi

  order_workspace_windows
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
  set_workspace_window_metadata "$window_id" "$window_name"
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
      repair_workspace_session "$script_cmd" "$REPAIR"
      attach_or_switch
      return 0
    fi
  fi

  window_id="$(create_primary_workspace_window "$script_cmd" "$term_cols" "$term_lines")"
  SESSION_CREATED=1
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

  if [[ "$SCHEDULE_FIT" == "1" ]]; then
    command -v tmux >/dev/null 2>&1 || die "tmux is required"
    schedule_workspace_fit
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
