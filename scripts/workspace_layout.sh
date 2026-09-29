#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPT_PATH="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"

WORK_DIR="${WORKSPACE_DIR:-$(pwd -P)}"
DIR_EXPLICIT=0
[[ -n "${WORKSPACE_DIR:-}" ]] && DIR_EXPLICIT=1
SESSION="${WORKSPACE_SESSION:-}"
SESSION_EXPLICIT=0
[[ -n "$SESSION" ]] && SESSION_EXPLICIT=1
SESSION_TARGET=""
SESSION_KIND=""
# The name the workspace is known by. It differs from SESSION only while a
# replacement is being built under a temporary name.
SESSION_NAME=""
# Set when the command names its target: a session, a directory, or a mode.
TARGET_EXPLICIT=0
[[ "$DIR_EXPLICIT" == "1" || "$SESSION_EXPLICIT" == "1" ]] && TARGET_EXPLICIT=1
# Set when the target turns out to be the workspace the command runs in.
INSIDE_TARGET=0
PROJECT_MODE=0
[[ "${WORKSPACE_SESSION_MODE:-}" == "project" ]] && PROJECT_MODE=1
ACTION=""
APPLY=0
RESET=0
REPAIR=0
REPAIR_LAYOUT=0
SESSION_CREATED=0
ATTACH=1
PANE_MODE=""
FIT_ONLY=0
FIT_TARGET=""
LIST_WINDOWS=0
SELECT_ENTRY_ONLY=0
SCHEDULE_FIT=0
SEND_TEXT=""
SEND_FILTER=""
SEND_ENTER=1
PICK_PREVIEW_KIND=""
PICK_PREVIEW_VALUE=""
PICKED_KIND=""
PICKED_VALUE=""
HOOK_ACTION=""
HOOK_SESSION_ID=""
HOOK_ARGS=()

# Inputs that describe one command or one workspace. This process uses them,
# but nothing it starts may inherit them: the tmux server, a pane, or a shell
# inside a pane would otherwise apply them to some other workspace.
WORKSPACE_PRIVATE_INPUTS=(
  WORKSPACE_DIR
  WORKSPACE_SESSION
  WORKSPACE_COLS
  WORKSPACE_LINES
  WORKSPACE_RESET_HANDOFF
  WORKSPACE_AGENT_CONFIG
  WORKSPACE_AGENT_CWD
  WORKSPACE_WORKTREE_ROOT
  WORKSPACE_WORKTREE_BRANCH_PREFIX
  WORKSPACE_TRUST_PROJECT_CONFIG
)

for private_input in "${WORKSPACE_PRIVATE_INPUTS[@]}"; do
  export -n "${private_input?}"
done
unset private_input

# shellcheck source=scripts/workspace_sessions.sh
. "$SCRIPT_DIR/workspace_sessions.sh"
# shellcheck source=scripts/workspace_agents.sh
. "$SCRIPT_DIR/workspace_agents.sh"

usage() {
  cat <<'EOF'
Usage: scripts/workspace_layout.sh [--project] [--dir PATH] [--session NAME] [--repair] [--reset] [--no-attach]
       scripts/workspace_layout.sh --sessions | --pick
       scripts/workspace_layout.sh --send TEXT [--to ROLE[,ROLE]] [--no-enter]
       scripts/workspace_layout.sh --worktrees | --prune-worktrees [--yes] | --trust

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
  --project, -p   Use one workspace per project instead of the shared daily
                  workspace. The project is the git repository that contains
                  the directory, or the directory itself outside a repository.
  --global        Use the shared daily workspace even when
                  WORKSPACE_SESSION_MODE=project is set.
  --repair        Repair managed windows, pane roles, hooks, and options without killing tasks.
  --reset         Recreate the session if it already exists, with the
                  settings of this command rather than the ones it had.
  --no-attach     Create the session and print its name without attaching.
  --fit-only      Resize an existing session without creating or attaching.
  --target-window WINDOW_ID
                  With --fit-only, resize only one tmux window. Used by hooks.
  --schedule-fit  Schedule a debounced fit pass. Used by hooks.
  --list-windows  Print the workspace window registry and exit.
  --repair-layout Reset managed pane layouts during fit/repair.
  --help, -h      Show this help.

Workspaces:
  --sessions      List running workspace sessions and their directories.
  --pick          Choose a running workspace, or a project directory to open
                  as a new project workspace. Uses fzf when available.
  --pick-list     Print what --pick would offer, one tab-separated row each.

Agents:
  --send TEXT     Paste TEXT into every running agent pane and press Enter.
                  Use "-" to read TEXT from stdin. A pane only counts when
                  its agent is the program that holds the terminal; shell
                  prompts, ssh, and REPLs are skipped. Enter is only pressed
                  once the text shows up, so an agent that is asking a
                  question is left waiting for your answer.
  --to ROLES      With --send, only target these comma-separated roles or titles.
  --no-enter      With --send, paste without pressing Enter.
  --agent-worktrees
                  Start each agent in its own git worktree and branch, so
                  agents can edit in parallel without touching your checkout.
                  Kept with the workspace until it is reset.
  --worktrees     List this project's agent worktrees and their state.
  --prune-worktrees
                  Remove agent worktrees that have no uncommitted changes and
                  no unmerged commits. Prints the plan unless --yes is given.
  --yes           Apply --prune-worktrees.
  --trust         Trust this project's .my-terminal/agents.tsv so its commands
                  may start. Project configs are ignored until trusted.

Inside a workspace, --repair, --repair-layout, --reset, --send, --worktrees,
--prune-worktrees, and --trust act on the workspace you are in, unless the
command names another one with --session, --project, --global, or --dir.

Environment:
  WORKSPACE_COLS / WORKSPACE_LINES  Override the detected tmux size.
  WORKSPACE_REFIT_LAYOUT=1          Reset managed pane layouts during fit/repair.
  WORKSPACE_SESSION_MODE=project    Make --project the default.
  WORKSPACE_AGENT_CONFIG=FILE       Read agent pane config from FILE.
  WORKSPACE_AGENT_LAYOUT=auto|horizontal|vertical|tiled
                                   Override the agent window layout.
  WORKSPACE_AGENT_CWD=worktree|PATH Default working directory for agents
                                   whose agents.tsv row has no cwd column.

Settings are kept with the workspace they created. They are not passed on to
the shells inside it, so a command typed there starts from your own
environment, not from the settings of the workspace around it.
  WORKSPACE_AGENT_SILENCE=SECONDS   Flag the agent window in the status bar
                                   after this many quiet seconds.
  WORKSPACE_WORKTREE_ROOT=DIR       Where agent worktrees are created.
  WORKSPACE_PICK_DIRS=DIR[:DIR]     Extra parent directories offered by --pick.
  WORKSPACE_PICK_KEY=KEY            tmux key that opens --pick in a popup.
                                   Defaults to M-0; "none" disables it.
  WORKSPACE_TRUST_PROJECT_CONFIG=1  Skip the project config trust check.
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
        DIR_EXPLICIT=1
        TARGET_EXPLICIT=1
        shift 2
        ;;
      --session)
        [[ $# -ge 2 && -n "$2" ]] || die "--session requires a name"
        SESSION="$2"
        SESSION_EXPLICIT=1
        TARGET_EXPLICIT=1
        shift 2
        ;;
      --project|-p)
        PROJECT_MODE=1
        TARGET_EXPLICIT=1
        shift
        ;;
      --global)
        PROJECT_MODE=0
        TARGET_EXPLICIT=1
        shift
        ;;
      --sessions)
        ACTION="sessions"
        ATTACH=0
        shift
        ;;
      --pick)
        ACTION="pick"
        shift
        ;;
      --pick-list)
        ACTION="pick-list"
        ATTACH=0
        shift
        ;;
      --hook)
        [[ $# -ge 3 ]] || die "--hook requires an action and a session id"
        HOOK_ACTION="$2"
        HOOK_SESSION_ID="$3"
        shift 3
        HOOK_ARGS=("$@")
        shift $#
        ATTACH=0
        ;;
      --pick-preview)
        [[ $# -ge 3 ]] || die "--pick-preview requires a kind and a value"
        ACTION="pick-preview"
        PICK_PREVIEW_KIND="$2"
        PICK_PREVIEW_VALUE="$3"
        ATTACH=0
        shift 3
        ;;
      --send)
        [[ $# -ge 2 ]] || die "--send requires text, or - to read stdin"
        ACTION="send"
        SEND_TEXT="$2"
        ATTACH=0
        shift 2
        ;;
      --to)
        [[ $# -ge 2 && -n "$2" ]] || die "--to requires one or more roles"
        SEND_FILTER="$2"
        shift 2
        ;;
      --no-enter)
        SEND_ENTER=0
        shift
        ;;
      --agent-worktrees)
        WORKSPACE_AGENT_CWD="worktree"
        shift
        ;;
      --worktrees)
        ACTION="worktrees"
        ATTACH=0
        shift
        ;;
      --prune-worktrees)
        ACTION="prune-worktrees"
        ATTACH=0
        shift
        ;;
      --yes)
        APPLY=1
        shift
        ;;
      --trust)
        ACTION="trust"
        ATTACH=0
        shift
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
        WORKSPACE_REFIT_LAYOUT=1
        REPAIR_LAYOUT=1
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
  local project_config

  if [[ -n "${WORKSPACE_AGENT_CONFIG:-}" ]]; then
    [[ -f "$WORKSPACE_AGENT_CONFIG" ]] && printf '%s\n' "$WORKSPACE_AGENT_CONFIG"
    return 0
  fi

  project_config="$(workspace_project_agent_config)"
  for candidate in \
    "$project_config" \
    "${HOME:-}/.config/my-terminal/workspace_agents.tsv" \
    "$REPO_ROOT/configs/workspace/agents.tsv"; do
    [[ -n "$candidate" && -f "$candidate" ]] || continue
    if [[ "$candidate" == "$project_config" ]] && ! workspace_project_config_is_trusted "$candidate"; then
      continue
    fi
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

    # Columns may be separated by several tabs, which keeps hand-aligned
    # files readable. An empty column is therefore written as "-".
    IFS=$'\t' read -r role title command _extra <<< "$line"
    role="$(trim_space "${role:-}")"
    title="$(trim_space "${title:-}")"
    command="$(trim_space "${command:-}")"
    [[ "$command" != "-" ]] || command=""

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

print_untrusted_agent_config_notice() {
  local untrusted

  untrusted="$(workspace_untrusted_project_config || true)"
  [[ -n "$untrusted" ]] || return 0
  workspace_print_untrusted_notice "$untrusted"
  printf '\n'
}

run_agent() {
  local agent_command
  local agent_dir
  local executable
  local record
  local role
  local shell_path="${SHELL:-/bin/sh}"
  local target_role="${1:-}"
  local title

  cd "$WORK_DIR"
  workspace_set_agent_state "idle"

  if [[ -n "$target_role" ]]; then
    record="$(workspace_agent_record_by_role "$target_role" || true)"
  else
    record="$(first_workspace_agent_record || true)"
  fi

  if [[ -z "$record" ]]; then
    clear 2>/dev/null || true
    print_untrusted_agent_config_notice
    printf 'workspace agent is not configured'
    [[ -n "$target_role" ]] && printf ': %s' "$target_role"
    printf '\n\n'
    exec_shell
  fi

  IFS='|' read -r role title agent_command <<< "$record"

  if [[ -n "$agent_command" ]]; then
    executable="$(agent_command_executable "$agent_command" || true)"
    if [[ -z "$executable" ]] || ! command -v "$executable" >/dev/null 2>&1; then
      clear 2>/dev/null || true
      print_untrusted_agent_config_notice
      printf 'workspace agent configured: %s\n' "$title"
      printf 'command not found in PATH: %s\n' "${executable:-$agent_command}"
      printf 'Install it yourself, edit the agent config, or continue in this shell.\n\n'
      exec_shell
    fi
  fi

  # Only prepare a worktree once the pane is known to have something to run.
  agent_dir="$(workspace_prepare_agent_dir "$role")"
  cd "$agent_dir" 2>/dev/null || cd "$WORK_DIR"

  export WORKSPACE_ROOT="$WORK_DIR"
  export WORKSPACE_AGENT_ROLE="$role"
  export WORKSPACE_AGENT_TITLE="$title"

  print_untrusted_agent_config_notice
  if [[ -z "$agent_command" ]]; then
    exec_shell
  fi

  # A row whose command is a shell gives a prompt, not an agent: text sent to
  # it would be executed, so it is never marked as running.
  if workspace_is_shell_name "$executable"; then
    "$shell_path" -lc "$agent_command" || true
    exec_shell
  fi

  workspace_set_agent_state "running"
  "$shell_path" -lc "$agent_command" || true
  workspace_set_agent_state "idle"
  workspace_discard_pending_input
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

# tmux expands "#" sequences in start directories and job commands. Doubling
# the "#" keeps a value literal.
tmux_literal() {
  printf '%s\n' "${1//#/##}"
}

# Hooks, delayed jobs, and key bindings are command strings that tmux parses
# and then hands to sh. They are kept constant: the script path reaches them
# through the tmux environment, and the session through its numeric id, so a
# directory or session name can never become part of a command.
WORKSPACE_SCRIPT_VARIABLE="MY_TERMINAL_WORKSPACE_SCRIPT"

publish_workspace_script() {
  tmux set-environment -g "$WORKSPACE_SCRIPT_VARIABLE" "$SCRIPT_PATH" >/dev/null 2>&1 || true
}

workspace_script_reference() {
  printf '"$%s"' "$WORKSPACE_SCRIPT_VARIABLE"
}

# Prints the tmux id of the workspace session, such as "$3".
workspace_session_id() {
  local id
  local id_pattern='^[$][0-9]+$'

  id="$(tmux display-message -p -t "$SESSION_TARGET" '#{session_id}' 2>/dev/null || true)"
  [[ "$id" =~ $id_pattern ]] || return 1
  printf '%s\n' "$id"
}

# run_workspace_job DELAY ACTION SESSION_ID [NUMBER...]: asks the tmux server
# to run "--hook ACTION" in the background. Every argument is a number or a
# fixed word, never text that came from a directory or a config file.
run_workspace_job() {
  local action="$2"
  local argument
  local command
  local delay="$1"
  local session_id="$3"
  shift 3

  publish_workspace_script
  command="$(workspace_script_reference) --hook $action \\$session_id"
  for argument in "$@"; do
    command+=" $argument"
  done
  command+=" >/dev/null 2>&1 || true"

  if [[ -n "$delay" ]]; then
    tmux run-shell -b -d "$delay" -t "$SESSION_TARGET" "$command" >/dev/null 2>&1 || true
  else
    tmux run-shell -b -t "$SESSION_TARGET" "$command" >/dev/null 2>&1 || true
  fi
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

  bind_workspace_pick_key
}

bind_workspace_pick_key() {
  local bound
  local key="${WORKSPACE_PICK_KEY:-}"

  # Key bindings belong to the tmux server, so the choice is kept there. A
  # command that does not say which key keeps the one chosen before.
  [[ -n "$key" ]] || key="$(tmux show-options -gqv @workspace_pick_key 2>/dev/null || true)"
  [[ -n "$key" ]] || key="M-0"
  tmux set-option -g @workspace_pick_key "$key" >/dev/null 2>&1 || true

  # Release the keys an earlier run bound to the picker, so changing the key
  # or choosing "none" takes effect. Only picker bindings are touched.
  while read -r bound; do
    [[ -n "$bound" && "$bound" != "$key" ]] || continue
    tmux unbind-key -n "$bound" >/dev/null 2>&1 || true
  done < <(
    tmux list-keys -T root 2>/dev/null |
      awk '/ --pick/ && /workspace_layout[.]sh|MY_TERMINAL_WORKSPACE_SCRIPT/ {
        for (i = 1; i < NF; i++) {
          if ($i == "root") {
            print $(i + 1)
            break
          }
        }
      }' || true
  )

  [[ -n "$key" && "$key" != "none" ]] || return 0
  publish_workspace_script
  # The popup command is read by the default shell of tmux, which may be fish
  # or another shell with its own variable syntax; hand it to sh at once.
  tmux bind-key -n "$key" display-popup -E -w 80% -h 70% "/bin/sh -c '$(workspace_script_reference) --pick'" >/dev/null 2>&1 || true
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
    done < <(tmux list-clients -t "$SESSION_TARGET" -F '#{client_width} #{client_height}' 2>/dev/null || true)
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
    if read -r detected_window_cols detected_window_lines < <(tmux display-message -p -t "$SESSION_TARGET" '#{window_width} #{window_height}' 2>/dev/null); then
      [[ "$detected_window_cols" =~ ^[0-9]+$ ]] && cols="${cols:-$detected_window_cols}"
      [[ "$detected_window_lines" =~ ^[0-9]+$ ]] && lines="${lines:-$detected_window_lines}"
    fi
  fi

  [[ "$cols" =~ ^[0-9]+$ ]] || cols=80
  [[ "$lines" =~ ^[0-9]+$ ]] || lines=24
  printf '%s %s\n' "$cols" "$lines"
}

tmux_workspace_windows() {
  tmux list-windows -t "$SESSION_TARGET" -F '#{window_id}|#{@workspace_managed}|#{@workspace_window_name}|#{window_name}' 2>/dev/null
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
  tmux set-option -p -t "$pane_id" @workspace_pane_title "$title" >/dev/null 2>&1 || true
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
  tmux set-option -t "$SESSION_TARGET" window-size latest >/dev/null 2>&1 || true
  fit_window_to_terminal "$window_id" "$fit_fn" "$term_cols" "$term_lines"
  tmux set-option -t "$SESSION_TARGET" window-size latest >/dev/null 2>&1 || true
}

fit_workspace_to_terminal() {
  local fit_fn
  local term_cols
  local term_lines
  local window_id
  local window_name

  read -r term_cols term_lines < <(detect_tmux_size)
  tmux set-option -t "$SESSION_TARGET" window-size latest >/dev/null 2>&1 || true

  while read -r window_name; do
    window_id="$(window_id_by_name "$window_name" || true)"
    [[ -n "$window_id" ]] || continue

    fit_fn="$(workspace_window_fit_fn "$window_name" || printf 'fit_noop_layout')"
    fit_window_to_terminal "$window_id" "$fit_fn" "$term_cols" "$term_lines"
  done < <(workspace_window_names)

  tmux set-option -t "$SESSION_TARGET" window-size latest >/dev/null 2>&1 || true
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
  local delay="${WORKSPACE_ENTRY_DELAY:-2.5}"
  local session_id

  # Some terminal feature probes can arrive after attach; shield the shell prompt
  # briefly, then restore the intended entry pane once the client settles.
  session_id="$(workspace_session_id)" || return 0
  run_workspace_job "$delay" select-entry "$session_id"
}

# A workspace that is already running is entered the way it was left: same
# window, same pane, and whatever was typed at a prompt still there. Replies
# to terminal probes can still arrive as keystrokes right after attaching,
# so the pane in front is shielded for a moment when it sits at a shell
# prompt. Nothing is selected and nothing is cleared.
shield_active_workspace_pane() {
  local pane_id

  pane_id="$(tmux display-message -p -t "$SESSION_TARGET" '#{pane_id}' 2>/dev/null || true)"
  [[ -n "$pane_id" ]] || return 0
  pane_is_plain_shell "$pane_id" || return 0
  tmux copy-mode -H -t "$pane_id" >/dev/null 2>&1 || return 0
  tmux set-option -p -t "$pane_id" @workspace_shielded 1 >/dev/null 2>&1 || true
}

# Ends the shield on the panes that were shielded, and on no others: a pane
# the user put into copy mode stays there.
release_workspace_shield() {
  local in_mode
  local pane_id
  local shielded

  while IFS='|' read -r pane_id shielded in_mode; do
    [[ "$shielded" == "1" ]] || continue
    if [[ "$in_mode" == "1" ]]; then
      tmux copy-mode -q -t "$pane_id" >/dev/null 2>&1 || true
    fi
    tmux set-option -p -u -t "$pane_id" @workspace_shielded >/dev/null 2>&1 || true
  done < <(
    tmux list-panes -s -t "$SESSION_TARGET" -F '#{pane_id}|#{@workspace_shielded}|#{pane_in_mode}' 2>/dev/null || true
  )
}

schedule_workspace_shield_release() {
  local delay="${WORKSPACE_ENTRY_DELAY:-2.5}"
  local session_id

  session_id="$(workspace_session_id)" || return 0
  run_workspace_job "$delay" release-shield "$session_id"
}

schedule_workspace_fit() {
  local delay="${WORKSPACE_FIT_DELAY:-0.25}"
  local session_id
  local token="$$.$RANDOM"

  session_id="$(workspace_session_id)" || return 0

  tmux set-option -q -t "$SESSION_TARGET" @workspace_fit_token "$token" >/dev/null 2>&1 || true
  tmux set-option -q -t "$SESSION_TARGET" @workspace_fit_cols "${WORKSPACE_COLS:-}" >/dev/null 2>&1 || true
  tmux set-option -q -t "$SESSION_TARGET" @workspace_fit_lines "${WORKSPACE_LINES:-}" >/dev/null 2>&1 || true

  # Only the newest request still holds the token when the delay is over.
  run_workspace_job "$delay" fit-now "$session_id" "$token"
}

set_workspace_hooks() {
  local schedule_fit_cmd

  publish_workspace_script
  schedule_fit_cmd="$(workspace_script_reference) --hook fit \\#{session_id} #{client_width} #{client_height} >/dev/null 2>&1 || true"

  tmux set-hook -t "$SESSION_TARGET" client-resized "run-shell -b '$schedule_fit_cmd'" >/dev/null 2>&1 || true
  tmux set-hook -t "$SESSION_TARGET" client-attached "run-shell -b '$schedule_fit_cmd'" >/dev/null 2>&1 || true
  tmux set-hook -t "$SESSION_TARGET" client-session-changed "run-shell -b '$schedule_fit_cmd'" >/dev/null 2>&1 || true
  tmux set-hook -u -t "$SESSION_TARGET" session-window-changed >/dev/null 2>&1 || true
  tmux set-hook -u -t "$SESSION_TARGET" after-select-window >/dev/null 2>&1 || true
}

attach_or_switch() {
  local is_new="$SESSION_CREATED"

  set_workspace_hooks

  if [[ "$ATTACH" == "1" ]]; then
    if [[ "$is_new" == "1" ]]; then
      shield_workspace_entry_pane
    else
      shield_active_workspace_pane
    fi
  fi

  fit_workspace_to_terminal

  if [[ "$ATTACH" != "1" ]]; then
    # Only a workspace that was just built is put on its entry pane.
    [[ "$is_new" != "1" ]] || select_workspace_entry_pane
    if [[ "$SESSION_CREATED" == "1" ]]; then
      printf 'Created tmux session: %s\n' "$SESSION"
    else
      printf 'Workspace session ready: %s\n' "$SESSION"
    fi
    printf 'Workspace: %s\n' "$WORK_DIR"
    printf 'Attach with: tmux attach -t %s\n' "$SESSION"
    return 0
  fi

  if [[ "$is_new" == "1" ]]; then
    shield_workspace_entry_pane
    schedule_workspace_entry_pane
  else
    schedule_workspace_shield_release
  fi

  if [[ -n "${TMUX:-}" ]]; then
    tmux switch-client -t "$SESSION_TARGET"
  else
    tmux attach-session -t "$SESSION_TARGET"
  fi
}

set_tmux_options() {
  local window_id="$1"

  tmux set-option -t "$SESSION_TARGET" mouse on >/dev/null
  tmux set-option -t "$SESSION_TARGET" status on >/dev/null
  tmux set-option -t "$SESSION_TARGET" status-position bottom >/dev/null
  tmux set-option -t "$SESSION_TARGET" status-bg "#333333" >/dev/null
  tmux set-option -t "$SESSION_TARGET" status-fg white >/dev/null
  tmux set-option -t "$SESSION_TARGET" base-index 1 >/dev/null
  tmux set-option -t "$SESSION_TARGET" status-left " #{?@workspace_label,#{@workspace_label},workspace} " >/dev/null
  tmux set-option -t "$SESSION_TARGET" status-left-length 32 >/dev/null
  tmux set-option -t "$SESSION_TARGET" status-right " %Y-%m-%d %H:%M " >/dev/null
  tmux set-option -t "$SESSION_TARGET" window-size latest >/dev/null 2>&1 || true
  tmux set-window-option -t "$window_id" aggressive-resize on >/dev/null 2>&1 || true
  # Editors and agent CLIs use focus events to notice that you looked away
  # or came back; Claude Code asks for them at startup.
  tmux set-option -s focus-events on >/dev/null 2>&1 || true
  set_workspace_session_metadata
  bind_workspace_keys
  set_workspace_hooks
}

# Records what this session is, so later runs can find it by directory and
# list it next to other workspaces.
set_workspace_session_metadata() {
  local kind
  local root

  tmux set-option -t "$SESSION_TARGET" @workspace_session 1 >/dev/null 2>&1 || true

  root="$(tmux show-options -qv -t "$SESSION_TARGET" @workspace_root 2>/dev/null || true)"
  if [[ -z "$root" ]]; then
    root="$WORK_DIR"
    tmux set-option -t "$SESSION_TARGET" @workspace_root "$root" >/dev/null 2>&1 || true
  fi

  kind="$(tmux show-options -qv -t "$SESSION_TARGET" @workspace_kind 2>/dev/null || true)"
  if [[ -z "$kind" && -n "$SESSION_KIND" ]]; then
    tmux set-option -t "$SESSION_TARGET" @workspace_kind "$SESSION_KIND" >/dev/null 2>&1 || true
  fi

  tmux set-option -t "$SESSION_TARGET" @workspace_label "$(workspace_session_label "${SESSION_NAME:-$SESSION}" "$root")" >/dev/null 2>&1 || true
  store_workspace_session_settings
}

# Settings that shape the agent panes. They are stored on the session and
# handed to every pane explicitly, because panes inherit the tmux server's
# environment rather than the environment of the command that created them.
WORKSPACE_PANE_SETTINGS=(
  WORKSPACE_AGENT_CONFIG
  WORKSPACE_AGENT_CWD
  WORKSPACE_WORKTREE_ROOT
  WORKSPACE_WORKTREE_BRANCH_PREFIX
)

# Settings the panes do not need, but the jobs tmux runs later do. Those jobs
# see the environment of the tmux server, not of the shell that asked.
WORKSPACE_JOB_SETTINGS=(
  WORKSPACE_AGENT_LAYOUT
  WORKSPACE_AGENT_SILENCE
)

workspace_setting_option() {
  printf '@%s\n' "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
}

# Writes every setting, clearing the ones that are not set, so the session
# always says exactly what the workspace was built with.
store_workspace_session_settings() {
  local name
  local value

  for name in "${WORKSPACE_PANE_SETTINGS[@]}" "${WORKSPACE_JOB_SETTINGS[@]}"; do
    value="${!name:-}"
    if [[ -n "$value" ]]; then
      tmux set-option -t "$SESSION_TARGET" "$(workspace_setting_option "$name")" "$value" >/dev/null 2>&1 || true
    else
      tmux set-option -u -t "$SESSION_TARGET" "$(workspace_setting_option "$name")" >/dev/null 2>&1 || true
    fi
  done
}

adopt_workspace_session_settings() {
  local name
  local value

  for name in "${WORKSPACE_PANE_SETTINGS[@]}" "${WORKSPACE_JOB_SETTINGS[@]}"; do
    [[ -z "${!name:-}" ]] || continue
    value="$(tmux show-options -qv -t "$SESSION_TARGET" "$(workspace_setting_option "$name")" 2>/dev/null || true)"
    [[ -n "$value" ]] || continue
    printf -v "$name" '%s' "$value"
  done
}

# A job started by tmux inherits whatever the server was started with. Drop
# all of it: the session is the only source of settings for a job.
forget_inherited_settings() {
  local name

  for name in "${WORKSPACE_PRIVATE_INPUTS[@]}" "${WORKSPACE_JOB_SETTINGS[@]}" WORKSPACE_PICK_KEY; do
    unset "$name"
  done
}

# Panes are started with an argument vector rather than a command string, so
# no shell ever parses the workspace directory, the config path, or anything
# else that comes from outside this script. Every setting is passed, empty
# ones included, so a pane never falls back to a value it happened to
# inherit from the tmux server.
PANE_COMMAND=()

build_pane_command() {
  local name

  PANE_COMMAND=(env)
  for name in "${WORKSPACE_PANE_SETTINGS[@]}" WORKSPACE_TRUST_PROJECT_CONFIG; do
    PANE_COMMAND+=("$name=${!name:-}")
  done
  PANE_COMMAND+=("$SCRIPT_PATH")
}

set_window_pane_options() {
  local silence="${WORKSPACE_AGENT_SILENCE:-}"
  local window_id="$1"
  local window_name="${2:-}"

  tmux display-message -p -t "$window_id" '#{window_id}' >/dev/null 2>&1 || return 0
  tmux set-window-option -t "$window_id" pane-border-status top >/dev/null 2>&1 || true
  # Programs can overwrite pane_title with escape sequences; the workspace
  # label lives in a user option they cannot touch.
  tmux set-window-option -t "$window_id" pane-border-format " #{?@workspace_pane_title,#{@workspace_pane_title},#{pane_title}} " >/dev/null 2>&1 || true
  tmux set-window-option -t "$window_id" aggressive-resize on >/dev/null 2>&1 || true
  tmux set-window-option -t "$window_id" pane-base-index 1 >/dev/null 2>&1 || true

  # "!" marks a bell and "~" marks silence, so a window whose agent finished
  # or is waiting for input stands out while you work elsewhere.
  tmux set-window-option -t "$window_id" window-status-format " #I:#W#{?window_bell_flag,!,}#{?window_silence_flag,~,} " >/dev/null 2>&1 || true
  tmux set-window-option -t "$window_id" window-status-current-format " #I:#W " >/dev/null 2>&1 || true
  # Palette colours, not "#RRGGBB": the status line expands these options as
  # formats, where "#F" would be read as the window flags.
  tmux set-window-option -t "$window_id" window-status-current-style "fg=black,bg=colour214,bold" >/dev/null 2>&1 || true
  tmux set-window-option -t "$window_id" window-status-bell-style "fg=black,bg=colour203,bold" >/dev/null 2>&1 || true
  tmux set-window-option -t "$window_id" window-status-activity-style "fg=black,bg=colour203,bold" >/dev/null 2>&1 || true

  if [[ "$window_name" == "agent" && "$silence" =~ ^[0-9]+$ ]]; then
    tmux set-window-option -t "$window_id" monitor-silence "$silence" >/dev/null 2>&1 || true
  fi
}

configure_dev_window() {
  local bottom
  local right_bottom
  local right_top
  local top_left
  local window_id="$1"

  set_window_pane_options "$window_id"

  top_left="$(tmux display-message -p -t "$window_id" '#{pane_id}')"
  right_top="$(tmux split-window -h -l 36% -P -F '#{pane_id}' -t "$top_left" -c "$(tmux_literal "$WORK_DIR")" "${PANE_COMMAND[@]}" --dir "$WORK_DIR" --pane git)"
  bottom="$(tmux split-window -v -l 32% -P -F '#{pane_id}' -t "$top_left" -c "$(tmux_literal "$WORK_DIR")" "${PANE_COMMAND[@]}" --dir "$WORK_DIR" --pane shell)"
  right_bottom="$(tmux split-window -v -l 50% -P -F '#{pane_id}' -t "$right_top" -c "$(tmux_literal "$WORK_DIR")" "${PANE_COMMAND[@]}" --dir "$WORK_DIR" --pane files)"

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
  local title
  local window_id="$1"

  set_window_pane_options "$window_id" agent

  anchor_pane="$(tmux display-message -p -t "$window_id" '#{pane_id}')"
  while IFS='|' read -r role title _agent_command; do
    pane_mode="agent:$role"
    if [[ "$index" == "0" ]]; then
      agent_pane="$anchor_pane"
    else
      # Split after the newest pane so panes keep the order of the config,
      # and rebalance first so a long agent list never runs out of room.
      tmux select-layout -t "$window_id" tiled >/dev/null 2>&1 || true
      agent_pane="$(tmux split-window -h -P -F '#{pane_id}' -t "$anchor_pane" -c "$(tmux_literal "$WORK_DIR")" "${PANE_COMMAND[@]}" --dir "$WORK_DIR" --pane "$pane_mode")"
    fi

    set_workspace_pane_role "$agent_pane" "$role" "$title"
    anchor_pane="$agent_pane"
    index=$((index + 1))
  done < <(workspace_agent_records)

  fit_agent_layout "$window_id"
}

configure_ssh_window() {
  local ssh_1_pane
  local ssh_2_pane
  local ssh_3_pane
  local ssh_4_pane
  local window_id="$1"

  set_window_pane_options "$window_id"

  ssh_1_pane="$(tmux display-message -p -t "$window_id" '#{pane_id}')"
  ssh_2_pane="$(tmux split-window -h -P -F '#{pane_id}' -t "$ssh_1_pane" -c "$(tmux_literal "$WORK_DIR")" "${PANE_COMMAND[@]}" --dir "$WORK_DIR" --pane shell)"
  ssh_3_pane="$(tmux split-window -v -P -F '#{pane_id}' -t "$ssh_1_pane" -c "$(tmux_literal "$WORK_DIR")" "${PANE_COMMAND[@]}" --dir "$WORK_DIR" --pane shell)"
  ssh_4_pane="$(tmux split-window -v -P -F '#{pane_id}' -t "$ssh_2_pane" -c "$(tmux_literal "$WORK_DIR")" "${PANE_COMMAND[@]}" --dir "$WORK_DIR" --pane shell)"

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
  local window_id="$1"

  set_window_pane_options "$window_id"

  logs_1_pane="$(tmux display-message -p -t "$window_id" '#{pane_id}')"
  logs_2_pane="$(tmux split-window -h -P -F '#{pane_id}' -t "$logs_1_pane" -c "$(tmux_literal "$WORK_DIR")" "${PANE_COMMAND[@]}" --dir "$WORK_DIR" --pane shell)"

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
  local first_agent
  local initial_pane_mode
  local window_name="$1"
  local window_id

  configure_fn="$(workspace_window_configure_fn "$window_name" || true)"
  initial_pane_mode="$(workspace_window_initial_pane_mode "$window_name" || true)"
  [[ -n "$configure_fn" && -n "$initial_pane_mode" ]] || die "no registry entry for workspace window: $window_name"
  declare -F "$configure_fn" >/dev/null || die "missing configure function for workspace window: $window_name"

  # Name the role, so the pane runs the agent it is labelled with even if it
  # were to read another config than this process did.
  if [[ "$initial_pane_mode" == "agent" ]]; then
    first_agent="$(first_workspace_agent_record || true)"
    [[ -z "$first_agent" ]] || initial_pane_mode="agent:${first_agent%%|*}"
  fi

  window_id="$(tmux new-window -d -P -F '#{window_id}' -t "$SESSION_TARGET" -n "$window_name" -c "$(tmux_literal "$WORK_DIR")" "${PANE_COMMAND[@]}" --dir "$WORK_DIR" --pane "$initial_pane_mode")"
  set_workspace_window_metadata "$window_id" "$window_name"
  "$configure_fn" "$window_id"
}

create_remaining_workspace_windows() {
  local window_name

  while read -r window_name; do
    workspace_window_is_primary "$window_name" && continue
    create_workspace_window "$window_name"
  done < <(workspace_window_names)
}

ensure_workspace_windows() {
  local created=0
  local window_name

  while read -r window_name; do
    if ! window_id_by_name "$window_name" >/dev/null; then
      create_workspace_window "$window_name"
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
    tmux split-window "${split_args[@]}" -P -F '#{pane_id}' -t "$anchor_pane" -c "$(tmux_literal "$WORK_DIR")" \
      "${PANE_COMMAND[@]}" --dir "$WORK_DIR" --pane "$pane_mode"
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
    create_missing_workspace_pane "${roles[$index]}" "${titles[$index]}" "${modes[$index]}" "$anchor_pane" "$before" "$direction" || continue
    created=0
  done

  return "$created"
}

repair_workspace_window() {
  local current_name
  local fit_fn
  local full_repair="$3"
  local pane_created=1
  local selected_pane
  local window_id="$1"
  local window_name="$2"

  [[ -n "$window_id" ]] || return 0
  set_workspace_window_metadata "$window_id" "$window_name"
  current_name="$(tmux display-message -p -t "$window_id" '#{window_name}' 2>/dev/null || true)"
  if [[ -n "$current_name" && "$current_name" != "$window_name" ]]; then
    tmux rename-window -t "$window_id" "$window_name" >/dev/null 2>&1 || true
  fi

  set_window_pane_options "$window_id" "$window_name"
  [[ "$full_repair" == "1" ]] || return 0
  selected_pane="$(tmux display-message -p -t "$window_id" '#{pane_id}' 2>/dev/null || true)"
  repair_workspace_pane_roles "$window_id" "$window_name"
  ensure_missing_workspace_panes "$window_id" "$window_name" && pane_created=0
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
  local full_repair="$1"
  local window_id
  local window_name

  ensure_workspace_windows

  while read -r window_name; do
    window_id="$(window_id_by_name "$window_name" || true)"
    [[ -n "$window_id" ]] || continue
    repair_workspace_window "$window_id" "$window_name" "$full_repair"
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
      tmux swap-window -d -s "$window_id" -t "$SESSION_TARGET=$index" >/dev/null 2>&1 ||
        tmux move-window -d -s "$window_id" -t "$SESSION_TARGET=$index" >/dev/null 2>&1 ||
        true
    fi
    index=$((index + 1))
  done < <(workspace_window_names)

  tmux move-window -r -t "$SESSION_TARGET"
}

create_primary_workspace_window() {
  local configure_fn
  local initial_pane_mode
  local term_cols="$1"
  local term_lines="$2"
  local window_id
  local window_name

  window_name="$(workspace_entry_window_name)" || die "no primary workspace window configured"
  configure_fn="$(workspace_window_configure_fn "$window_name" || true)"
  initial_pane_mode="$(workspace_window_initial_pane_mode "$window_name" || true)"
  [[ -n "$configure_fn" && -n "$initial_pane_mode" ]] || die "no registry entry for primary workspace window: $window_name"
  declare -F "$configure_fn" >/dev/null || die "missing configure function for primary workspace window: $window_name"

  tmux new-session -d -x "$term_cols" -y "$term_lines" -s "$SESSION" -n "$window_name" -c "$(tmux_literal "$WORK_DIR")" "${PANE_COMMAND[@]}" --dir "$WORK_DIR" --pane "$initial_pane_mode"
  window_id="$(tmux display-message -p -t "$SESSION_TARGET" '#{window_id}')"
  tmux rename-window -t "$window_id" "$window_name"
  set_workspace_window_metadata "$window_id" "$window_name"
  set_tmux_options "$window_id"
  "$configure_fn" "$window_id"
  printf '%s\n' "$window_id"
}

build_workspace_session() {
  local term_cols="$1"
  local term_lines="$2"

  create_primary_workspace_window "$term_cols" "$term_lines" >/dev/null
  SESSION_CREATED=1
  create_remaining_workspace_windows
  order_workspace_windows
  select_workspace_entry_pane
}

# True when this process runs in a pane of the session it is about to reset.
reset_runs_inside_session() {
  local current

  [[ "${WORKSPACE_RESET_HANDOFF:-0}" != "1" ]] || return 1
  [[ -n "${TMUX:-}" ]] || return 1
  current="$(tmux display-message -p '#{session_name}' 2>/dev/null || true)"
  [[ "$current" == "$SESSION" ]]
}

# Killing the session would kill this process along with it, leaving nothing
# to rebuild the workspace. The tmux server outlives the session, so it runs
# the reset instead.
hand_reset_to_server() {
  local session_id
  local term_cols
  local term_lines
  local trust=0

  session_id="$(workspace_session_id)" || die "cannot find workspace session: $SESSION"
  read -r term_cols term_lines < <(detect_tmux_size)

  # The job only gets numbers. What this command asked for is left on the
  # session, where the job reads it back.
  tmux set-option -t "$SESSION_TARGET" @workspace_root "$WORK_DIR" >/dev/null 2>&1 || true
  store_workspace_session_settings
  [[ "${WORKSPACE_TRUST_PROJECT_CONFIG:-0}" == "1" ]] && trust=1

  run_workspace_job "" reset "$session_id" "$term_cols" "$term_lines" "$trust"
  printf 'Resetting workspace %s; this window switches to the new one in a moment.\n' "$SESSION"
}

# Builds the replacement next to the running session, moves every client
# over, and only then removes the old session, so nobody is dropped out of
# tmux halfway through.
replace_workspace_session() {
  local client
  local clients
  local final="$SESSION"
  local final_target="$SESSION_TARGET"
  local term_cols="$1"
  local term_lines="$2"

  clients="$(tmux list-clients -t "$final_target" -F '#{client_name}' 2>/dev/null || true)"
  [[ -n "$SESSION_KIND" ]] || SESSION_KIND="$(tmux show-options -qv -t "$final_target" @workspace_kind 2>/dev/null || true)"

  # Everything that shows or depends on the name is written with the final
  # name, so the workspace is complete the moment it takes that name.
  SESSION_NAME="$final"
  SESSION="$final-reset-$$"
  SESSION_TARGET="$(workspace_session_target "$SESSION")"
  build_workspace_session "$term_cols" "$term_lines"

  while IFS= read -r client; do
    [[ -n "$client" ]] || continue
    tmux switch-client -c "$client" -t "$SESSION_TARGET" >/dev/null 2>&1 || true
  done <<< "$clients"

  tmux kill-session -t "$final_target" >/dev/null 2>&1 || true
  tmux rename-session -t "$SESSION_TARGET" "$final"
  SESSION="$final"
  SESSION_TARGET="$final_target"

  attach_or_switch
}

create_session() {
  local term_cols
  local term_lines
  local untrusted

  command -v tmux >/dev/null 2>&1 || die "tmux is required"
  build_pane_command
  read -r term_cols term_lines < <(detect_tmux_size)

  untrusted="$(workspace_untrusted_project_config || true)"
  [[ -z "$untrusted" ]] || workspace_print_untrusted_notice "$untrusted" >&2

  if tmux has-session -t "$SESSION_TARGET" 2>/dev/null; then
    if [[ "$RESET" != "1" ]]; then
      repair_workspace_session "$REPAIR"
      attach_or_switch
      return 0
    fi

    if reset_runs_inside_session; then
      hand_reset_to_server
      return 0
    fi

    if [[ "${WORKSPACE_RESET_HANDOFF:-0}" == "1" ]]; then
      replace_workspace_session "$term_cols" "$term_lines"
      return 0
    fi

    tmux kill-session -t "$SESSION_TARGET"
  fi

  build_workspace_session "$term_cols" "$term_lines"
  attach_or_switch
}

require_tmux() {
  command -v tmux >/dev/null 2>&1 || die "tmux is required"
}

# Maintenance commands run from inside a workspace mean "this workspace",
# not whichever session the defaults would pick.
workspace_action_targets_current_session() {
  [[ "$REPAIR" == "1" || "$RESET" == "1" || "$REPAIR_LAYOUT" == "1" ]] && return 0
  [[ "$ACTION" == "send" ]]
}

# --trust and the worktree commands are about a directory, not a session:
# the one the command names, else the workspace it is typed in, else the
# directory it is typed in.
resolve_workspace_directory() {
  local current
  local root

  if [[ "$TARGET_EXPLICIT" != "1" ]]; then
    current="$(workspace_current_managed_session || true)"
    if [[ -n "$current" ]]; then
      root="$(workspace_session_root "$current")"
      [[ -n "$root" && -d "$root" ]] && WORK_DIR="$root"
      return 0
    fi
  fi

  [[ "$PROJECT_MODE" != "1" ]] || WORK_DIR="$(workspace_project_root "$WORK_DIR")"
}

workspace_new_session_kind() {
  if [[ "$SESSION" == "$WORKSPACE_DEFAULT_SESSION" ]]; then
    printf 'daily\n'
  elif [[ "$PROJECT_MODE" == "1" && "$SESSION_EXPLICIT" != "1" ]]; then
    printf 'project\n'
  else
    printf 'named\n'
  fi
}

resolve_workspace_target() {
  local current=""
  local root=""

  if [[ "$SESSION_EXPLICIT" != "1" ]]; then
    # A command that names its target is taken at its word, even when it is
    # typed inside another workspace.
    if [[ "$TARGET_EXPLICIT" != "1" ]] && workspace_action_targets_current_session; then
      current="$(workspace_current_managed_session || true)"
    fi

    if [[ -n "$current" ]]; then
      SESSION="$current"
    elif [[ "$PROJECT_MODE" == "1" ]]; then
      WORK_DIR="$(workspace_project_root "$WORK_DIR")"
      SESSION="$(workspace_project_session_name "$WORK_DIR")"
    else
      SESSION="$WORKSPACE_DEFAULT_SESSION"
    fi
  fi

  SESSION="$(workspace_normalize_session_name "$SESSION")"
  SESSION_TARGET="$(workspace_session_target "$SESSION")"
  [[ "$(workspace_current_session_name || true)" == "$SESSION" ]] && INSIDE_TARGET=1

  if ! workspace_session_exists "$SESSION"; then
    SESSION_KIND="$(workspace_new_session_kind)"
    return 0
  fi

  SESSION_KIND="$(tmux show-options -qv -t "$SESSION_TARGET" @workspace_kind 2>/dev/null || true)"
  root="$(workspace_session_root "$SESSION")"
  [[ -n "$root" && -d "$root" ]] || root=""

  if [[ "$RESET" == "1" ]]; then
    # A reset rebuilds the workspace from what this command was given, so
    # nothing is taken over from the session. Typed inside the workspace, it
    # stays in the directory of the workspace rather than of the pane.
    [[ -n "$SESSION_KIND" ]] || SESSION_KIND="$(workspace_new_session_kind)"
    if [[ "$INSIDE_TARGET" == "1" && "$DIR_EXPLICIT" != "1" && -n "$root" ]]; then
      WORK_DIR="$root"
    fi
    return 0
  fi

  if [[ "$DIR_EXPLICIT" != "1" && -n "$root" ]]; then
    WORK_DIR="$root"
  fi
  adopt_workspace_session_settings
}

# Entry point for the jobs that tmux runs on behalf of the workspace: resize
# hooks, delayed fits, and resets handed over by a pane. tmux passes the
# session as its id and everything else as numbers; directories and settings
# are read back from the session itself.
run_workspace_hook() {
  local cols
  local id_pattern='^[$][0-9]+$'
  local lines
  local name
  local number_pattern='^[0-9]+$'
  local stored
  local token

  require_tmux
  [[ "$HOOK_SESSION_ID" =~ $id_pattern ]] || die "invalid session id: $HOOK_SESSION_ID"
  name="$(tmux display-message -p -t "$HOOK_SESSION_ID:" '#{session_name}' 2>/dev/null || true)"
  [[ -n "$name" ]] || return 0

  forget_inherited_settings
  SESSION="$name"
  SESSION_EXPLICIT=1
  TARGET_EXPLICIT=1
  DIR_EXPLICIT=0
  RESET=0
  resolve_workspace_target

  cols="${HOOK_ARGS[0]:-}"
  lines="${HOOK_ARGS[1]:-}"

  case "$HOOK_ACTION" in
    fit)
      [[ "$cols" =~ $number_pattern && "$lines" =~ $number_pattern ]] || return 0
      WORKSPACE_COLS="$cols"
      WORKSPACE_LINES="$lines"
      schedule_workspace_fit
      ;;
    fit-now)
      token="${HOOK_ARGS[0]:-}"
      stored="$(tmux show-options -qv -t "$SESSION_TARGET" @workspace_fit_token 2>/dev/null || true)"
      [[ -n "$token" && "$token" == "$stored" ]] || return 0

      cols="$(tmux show-options -qv -t "$SESSION_TARGET" @workspace_fit_cols 2>/dev/null || true)"
      lines="$(tmux show-options -qv -t "$SESSION_TARGET" @workspace_fit_lines 2>/dev/null || true)"
      if [[ "$cols" =~ $number_pattern && "$lines" =~ $number_pattern ]]; then
        WORKSPACE_COLS="$cols"
        WORKSPACE_LINES="$lines"
      fi
      fit_workspace_to_terminal
      ;;
    select-entry)
      select_workspace_entry_pane restore
      ;;
    release-shield)
      release_workspace_shield
      ;;
    reset)
      [[ "$cols" =~ $number_pattern && "$lines" =~ $number_pattern ]] || return 0
      WORKSPACE_COLS="$cols"
      WORKSPACE_LINES="$lines"
      WORKSPACE_RESET_HANDOFF=1
      [[ "${HOOK_ARGS[2]:-0}" != "1" ]] || WORKSPACE_TRUST_PROJECT_CONFIG=1
      RESET=1
      create_session
      ;;
    *)
      die "unknown hook action: $HOOK_ACTION"
      ;;
  esac
}

absolute_agent_config_path() {
  local config="${WORKSPACE_AGENT_CONFIG:-}"

  [[ -n "$config" && "$config" != /* && -f "$config" ]] || return 0
  WORKSPACE_AGENT_CONFIG="$(cd "$(dirname "$config")" && pwd -P)/$(basename "$config")"
}

open_picked_workspace() {
  TARGET_EXPLICIT=1
  case "$PICKED_KIND" in
    session)
      SESSION="$PICKED_VALUE"
      SESSION_EXPLICIT=1
      DIR_EXPLICIT=0
      ;;
    dir)
      WORK_DIR="$(resolve_dir "$PICKED_VALUE")"
      DIR_EXPLICIT=1
      PROJECT_MODE=1
      SESSION_EXPLICIT=0
      ;;
    *)
      die "nothing was picked"
      ;;
  esac
}

main() {
  local pick_status

  parse_args "$@"

  if [[ "$LIST_WINDOWS" == "1" ]]; then
    workspace_window_manifest
    exit 0
  fi

  if [[ -n "$PANE_MODE" ]]; then
    run_pane_mode
  fi

  absolute_agent_config_path

  if [[ -n "$HOOK_ACTION" ]]; then
    run_workspace_hook
    exit 0
  fi

  case "$ACTION" in
    pick-preview)
      workspace_pick_preview "$PICK_PREVIEW_KIND" "$PICK_PREVIEW_VALUE"
      exit 0
      ;;
    sessions)
      require_tmux
      workspace_print_sessions
      exit 0
      ;;
    pick-list)
      workspace_pick_candidates
      exit 0
      ;;
    pick)
      require_tmux
      pick_status=0
      workspace_pick_select || pick_status=$?
      # Leaving the picker without a choice is not an error.
      [[ "$pick_status" != "1" ]] || exit 0
      [[ "$pick_status" == "0" ]] || exit 1
      open_picked_workspace
      ;;
  esac

  case "$ACTION" in
    trust)
      resolve_workspace_directory
      workspace_trust_project_config
      exit 0
      ;;
    worktrees)
      resolve_workspace_directory
      workspace_print_worktrees
      exit 0
      ;;
    prune-worktrees)
      resolve_workspace_directory
      workspace_prune_worktrees "$APPLY"
      exit 0
      ;;
  esac

  resolve_workspace_target

  case "$ACTION" in
    send)
      require_tmux
      workspace_session_exists "$SESSION" || die "workspace session is not running: $SESSION"
      [[ "$SEND_TEXT" != "-" ]] || SEND_TEXT="$(cat)"
      workspace_send_to_agents "$SEND_TEXT" "$SEND_FILTER" "$SEND_ENTER"
      exit 0
      ;;
  esac

  if [[ "$SELECT_ENTRY_ONLY" == "1" ]]; then
    require_tmux
    select_workspace_entry_pane restore
    exit 0
  fi

  if [[ "$SCHEDULE_FIT" == "1" ]]; then
    require_tmux
    schedule_workspace_fit
    exit 0
  fi

  if [[ "$FIT_ONLY" == "1" ]]; then
    require_tmux
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
