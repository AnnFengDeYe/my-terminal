#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
WORKSPACE="$SCRIPT_DIR/workspace_layout.sh"

CONFIG=""
WORK_DIR="$(pwd -P)"
WAIT_SECONDS=20
SESSION="agent-check"
MARKER="workspace paste check"
CHECK_ROOT=""

usage() {
  cat <<'EOF'
Usage: scripts/check_agents.sh [--config FILE] [--dir PATH] [--wait SECONDS]

Starts the agents of a workspace for real and checks that each one takes a
pasted prompt, which is what `workplace --send` relies on.

The agents run in a tmux server of their own, so your sessions are not
touched, but with your own HOME, so they are signed in the way they usually
are. A short text is pasted into each agent. Enter is never pressed: nothing
is submitted and no model is called. The agents are closed at the end.

An agent that does not show the pasted text is usually asking a question
first, such as signing in or trusting the directory. The last lines of its
screen are printed so you can see which.

Options:
  --config FILE   Check the agents of FILE instead of the usual agents.tsv.
  --dir PATH      Start the agents in PATH. Defaults to the current directory.
  --wait SECONDS  How long an agent may take to start. Defaults to 20.
  --help, -h      Show this help.
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

parse_args() {
  local number_pattern='^[1-9][0-9]*$'

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config)
        [[ $# -ge 2 ]] || die "--config requires a file"
        [[ -f "$2" ]] || die "agent config not found: $2"
        CONFIG="$(cd "$(dirname "$2")" && pwd -P)/$(basename "$2")"
        shift 2
        ;;
      --dir)
        [[ $# -ge 2 ]] || die "--dir requires a path"
        [[ -d "$2" ]] || die "not a directory: $2"
        WORK_DIR="$(cd "$2" && pwd -P)"
        shift 2
        ;;
      --wait)
        [[ $# -ge 2 && "$2" =~ $number_pattern ]] || die "--wait requires a number of seconds"
        WAIT_SECONDS="$2"
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

cleanup() {
  [[ -n "$CHECK_ROOT" ]] || return 0
  tmux kill-server >/dev/null 2>&1 || true
  case "$CHECK_ROOT" in
    /tmp/mtag.*|/private/tmp/mtag.*) rm -rf "$CHECK_ROOT" ;;
  esac
}

# Prints "pane|role|title|state" for every agent pane.
agent_panes() {
  tmux list-panes -t "=$SESSION:agent" \
    -F '#{pane_id}|#{@workspace_pane_role}|#{@workspace_pane_title}|#{@workspace_agent_state}' 2>/dev/null || true
}

pane_screen() {
  tmux capture-pane -p -J -t "$1" 2>/dev/null || true
}

# Waits until an agent has started or has fallen back to its shell.
wait_for_agent() {
  local elapsed=0
  local pane_id="$1"
  local screen
  local state

  while [[ "$elapsed" -lt $((WAIT_SECONDS * 2)) ]]; do
    state="$(tmux display-message -p -t "$pane_id" '#{@workspace_agent_state}' 2>/dev/null || true)"
    screen="$(pane_screen "$pane_id")"
    if [[ "$state" == "running" && -n "${screen//[[:space:]]/}" ]]; then
      return 0
    fi
    [[ "$screen" != *"command not found in PATH"* ]] || return 0
    sleep 0.5
    elapsed=$((elapsed + 1))
  done
}

print_screen_tail() {
  pane_screen "$1" | grep -v '^[[:space:]]*$' | tail -n 6 | cut -c1-100 | sed 's/^/      | /' || true
}

main() {
  local asking=0
  local missing=0
  local pane_id
  local panes
  local ready=0
  local role
  local screen
  local state
  local title

  parse_args "$@"
  command -v tmux >/dev/null 2>&1 || die "tmux is required"

  # A socket path has to fit in sockaddr_un, so the directory is kept short.
  CHECK_ROOT="$(mktemp -d /tmp/mtag.XXXXXX)"
  trap cleanup EXIT
  export TMUX_TMPDIR="$CHECK_ROOT"
  unset TMUX TMUX_PANE

  printf 'Starting the agents in %s\n' "$WORK_DIR"
  if [[ -n "$CONFIG" ]]; then
    printf 'Agent config: %s\n' "$CONFIG"
    WORKSPACE_AGENT_CONFIG="$CONFIG" WORKSPACE_COLS=200 WORKSPACE_LINES=50 \
      "$WORKSPACE" --session "$SESSION" --dir "$WORK_DIR" --no-attach >/dev/null
  else
    WORKSPACE_COLS=200 WORKSPACE_LINES=50 \
      "$WORKSPACE" --session "$SESSION" --dir "$WORK_DIR" --no-attach >/dev/null
  fi

  panes="$(agent_panes)"
  [[ -n "$panes" ]] || die "the workspace has no agent panes"

  while IFS='|' read -r pane_id role title state; do
    [[ -n "$pane_id" && -n "$role" ]] || continue
    wait_for_agent "$pane_id"
  done <<< "$panes"
  # Agents draw their prompt a moment after they start.
  sleep 2

  printf '\n'
  while IFS='|' read -r pane_id role title state; do
    [[ -n "$pane_id" && -n "$role" ]] || continue
    state="$(tmux display-message -p -t "$pane_id" '#{@workspace_agent_state}' 2>/dev/null || true)"

    if [[ "$state" != "running" ]]; then
      printf '%-10s %-12s not started\n' "$role" "$title"
      print_screen_tail "$pane_id"
      missing=$((missing + 1))
      continue
    fi

    "$WORKSPACE" --session "$SESSION" --send "$MARKER" --no-enter --to "$role" >/dev/null 2>&1 || true
    sleep 1.5
    screen="$(pane_screen "$pane_id")"

    if [[ "$screen" == *"$MARKER"* ]]; then
      printf '%-10s %-12s takes pasted text\n' "$role" "$title"
      ready=$((ready + 1))
    else
      printf '%-10s %-12s did not show pasted text; it may be asking a question\n' "$role" "$title"
      print_screen_tail "$pane_id"
      asking=$((asking + 1))
    fi
  done <<< "$panes"

  printf '\nAgent check: %s ready, %s asking or busy, %s not started\n' "$ready" "$asking" "$missing"
  printf 'Nothing was submitted. The agents are being closed.\n'
  [[ "$asking" == "0" && "$missing" == "0" ]]
}

main "$@"
