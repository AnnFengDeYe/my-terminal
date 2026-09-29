#!/usr/bin/env bash
# shellcheck disable=SC2030,SC2031 # a subshell gives a scenario its own HOME and tmux server
set -euo pipefail

# Workspace tests. Everything runs against a private tmux server, a temporary
# HOME, and a PATH without the real editors or agent CLIs, so the run never
# touches your sessions, your configs, or the network.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
WORKSPACE="$REPO_ROOT/scripts/workspace_layout.sh"
SHOWCASE="$REPO_ROOT/scripts/showcase_layout.sh"

command -v tmux >/dev/null 2>&1 || {
  printf 'test_workspace.sh needs tmux in PATH\n' >&2
  exit 2
}
command -v git >/dev/null 2>&1 || {
  printf 'test_workspace.sh needs git in PATH\n' >&2
  exit 2
}

# A tmux socket path has to fit in sockaddr_un, so keep the root short.
TEST_ROOT="$(mktemp -d /tmp/mtws.XXXXXX)"
TEST_ROOT="$(cd "$TEST_ROOT" && pwd -P)"
OUTER_SOCKET="mtws-outer-$$"

mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/home" "$TEST_ROOT/tmux" "$TEST_ROOT/tmux2" "$TEST_ROOT/tmux3" "$TEST_ROOT/projects"

link_tool() {
  [[ -e "$TEST_ROOT/bin/$1" ]] || ln -s "$2" "$TEST_ROOT/bin/$1"
}

# TEST_TOOLS=DIR[:DIR] runs the suite with the programs found in those
# directories, for example an older tmux or another awk, instead of the ones
# the system provides.
test_tools="${TEST_TOOLS:-}"
while [[ -n "$test_tools" ]]; do
  tools_dir="${test_tools%%:*}"
  if [[ "$test_tools" == *:* ]]; then
    test_tools="${test_tools#*:}"
  else
    test_tools=""
  fi

  [[ -d "$tools_dir" ]] || continue
  for tool in "$tools_dir"/*; do
    [[ -f "$tool" && -x "$tool" ]] || continue
    link_tool "$(basename "$tool")" "$tool"
  done
done

link_tool tmux "$(command -v tmux)"
link_tool git "$(command -v git)"

# Stands in for an agent that runs inside an interpreter, the way a Node CLI
# does: the process is called "sh", and only its command line names the agent.
cat > "$TEST_ROOT/bin/fake-agent" <<'FAKE_AGENT'
#!/bin/sh
while IFS= read -r line; do
  printf 'agent got: %s\n' "$line"
done
FAKE_AGENT

# Stands in for an agent that is asking a question: what is typed is not
# shown, and Enter answers.
cat > "$TEST_ROOT/bin/fake-dialog" <<'FAKE_DIALOG'
#!/bin/sh
stty -echo
printf 'Press enter to continue\n'
IFS= read -r answer
printf 'CONFIRMED [%s]\n' "$answer"
stty echo
exec cat
FAKE_DIALOG
chmod +x "$TEST_ROOT/bin/fake-agent" "$TEST_ROOT/bin/fake-dialog"

while IFS='=' read -r name _; do
  case "$name" in
    WORKSPACE_*|SHOWCASE_*|XDG_*|TMUX|TMUX_PANE|GIT_*) unset "$name" ;;
  esac
done < <(env)

export PATH="$TEST_ROOT/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export HOME="$TEST_ROOT/home"
export TMUX_TMPDIR="$TEST_ROOT/tmux"
export TERM="xterm-256color"
export SHELL="/bin/sh"
export GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME="Workspace Test"
export GIT_AUTHOR_EMAIL="workspace-test@example.invalid"
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME"
export GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"

cleanup() {
  tmux kill-server >/dev/null 2>&1 || true
  tmux -L "$OUTER_SOCKET" kill-server >/dev/null 2>&1 || true
  TMUX_TMPDIR="$TEST_ROOT/tmux2" tmux kill-server >/dev/null 2>&1 || true
  TMUX_TMPDIR="$TEST_ROOT/tmux3" tmux kill-server >/dev/null 2>&1 || true

  if [[ "${KEEP_TEST_ROOT:-0}" == "1" ]]; then
    printf 'Keeping test root for inspection: %s\n' "$TEST_ROOT"
    return 0
  fi

  case "$TEST_ROOT" in
    /tmp/mtws.*|/private/tmp/mtws.*)
      rm -rf "$TEST_ROOT"
      ;;
    *)
      printf 'Refusing to remove unexpected test root: %s\n' "$TEST_ROOT" >&2
      ;;
  esac
}
trap cleanup EXIT

fail() {
  printf 'test failure: %s\n' "$*" >&2
  exit 1
}

assert_eq() {
  local actual="$2"
  local expected="$1"
  local label="$3"

  [[ "$actual" == "$expected" ]] || fail "$label: expected [$expected], got [$actual]"
}

assert_contains() {
  local haystack="$1"
  local label="$3"
  local needle="$2"

  [[ "$haystack" == *"$needle"* ]] || fail "$label: expected to find [$needle] in: $haystack"
}

assert_not_contains() {
  local haystack="$1"
  local label="$3"
  local needle="$2"

  [[ "$haystack" != *"$needle"* ]] || fail "$label: did not expect [$needle] in: $haystack"
}

# wait_for LABEL COMMAND...: polls until COMMAND succeeds.
wait_for() {
  local attempts=0
  local label="$1"
  shift

  until "$@" >/dev/null 2>&1; do
    attempts=$((attempts + 1))
    [[ "$attempts" -lt 100 ]] || fail "timed out waiting for: $label"
    sleep 0.1
  done
}

workspace() {
  "$WORKSPACE" "$@"
}

session_names() {
  tmux list-sessions -F '#{session_name}' 2>/dev/null | sort | tr '\n' ' '
}

pane_count() {
  tmux list-panes -t "$1" | wc -l | tr -d ' '
}

pane_roles() {
  tmux list-panes -t "$1" -F '#{@workspace_pane_role}' | tr '\n' ' '
}

pane_by_role() {
  tmux list-panes -t "$1" -F '#{@workspace_pane_role} #{pane_id}' | awk -v role="$2" '$1 == role { print $2; exit }'
}

pane_option() {
  tmux display-message -p -t "$1" "#{$2}"
}

# Everything the pane has printed, with wrapped lines joined. A workspace
# can be narrow enough to wrap a message and to push its first lines into
# the history.
pane_text() {
  tmux capture-pane -p -J -S - -t "$1"
}

pane_state_is() {
  [[ "$(pane_option "$1" @workspace_agent_state)" == "$2" ]]
}

pane_is_in() {
  [[ "$(pane_option "$1" pane_current_path)" == "$2" ]]
}

session_exists() {
  tmux has-session -t "=$1:" 2>/dev/null
}

session_id_of() {
  tmux display-message -p -t "=$1:" '#{session_id}' 2>/dev/null
}

# inside PANE COMMAND...: runs COMMAND the way a shell in PANE would, with
# the tmux variables that tell a program which pane it is in.
inside() {
  local pane="$1"
  shift

  TMUX="$(tmux display-message -p -t "$pane" '#{socket_path},#{pid},0')" TMUX_PANE="$pane" "$@"
}

# start_outer_client SESSION: attaches a real client, 132 columns wide, by
# running the workspace command inside a second tmux server.
start_outer_client() {
  tmux -L "$OUTER_SOCKET" -f /dev/null new-session -d -s outer \
    env -u TMUX -u TMUX_PANE "$WORKSPACE" --session "$1"
  # Older tmux ignores -x and -y for a detached session, so size it here.
  tmux -L "$OUTER_SOCKET" resize-window -t outer -x 132 -y 43
}

# The process group that holds the terminal of a pane, and its command line.
pane_front() {
  local front

  front="$(ps -o tpgid= -p "$(pane_option "$1" pane_pid)" | tr -d '[:space:]')"
  printf '%s %s\n' "$front" "$(ps -o args= -p "$front" 2>/dev/null || true)"
}

pane_front_shows() {
  [[ "$(pane_front "$1")" == *"$2"* ]]
}

pane_front_is_not_root() {
  local front

  front="$(pane_front "$1")"
  [[ -n "${front%% *}" && "${front%% *}" != "$(pane_option "$1" pane_pid)" ]]
}

pane_is_released() {
  [[ "$(pane_option "$1" pane_in_mode)" == "0" && -z "$(pane_option "$1" @workspace_shielded)" ]]
}

picker_keys() {
  tmux list-keys -T root | awk '/ --pick/ { for (i = 1; i < NF; i++) if ($i == "root") print $(i + 1) }' | sort | tr '\n' ' '
}

pane_shows() {
  pane_text "$1" | grep -Fq -- "$2"
}

new_repo() {
  local dir="$1"

  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" checkout -q -b main 2>/dev/null || true
  printf 'hello\n' > "$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" commit -q -m "initial commit"
  (cd "$dir" && pwd -P)
}

write_agents() {
  local file="$1"
  shift

  mkdir -p "$(dirname "$file")"
  printf '# role\ttitle\tcommand\tcwd\n' > "$file"
  printf '%b\n' "$@" >> "$file"
}

printf 'Repository: %s\n' "$REPO_ROOT"
printf 'Test root:  %s\n' "$TEST_ROOT"
printf 'tmux:       %s\n' "$(tmux -V)"
printf 'awk:        %s\n\n' "$(command -v awk)"

# ------------------------------------------------------------------
printf 'Test 1: default layout, sizes, panes, and roles\n'
manifest="$(workspace --list-windows)"
expected_windows="$(printf '%s\n' "$manifest" | awk -F: '{ printf "%s:%s ", $1, $2 }')"
expected_count="$(printf '%s\n' "$manifest" | wc -l | tr -d ' ')"
primary_window="$(printf '%s\n' "$manifest" | awk -F: '$3 == "primary" { print $2; exit }')"
primary_entry_pane="$(printf '%s\n' "$manifest" | awk -F: '$3 == "primary" { print $4; exit }')"

WORKSPACE_COLS=80 WORKSPACE_LINES=24 workspace --session ci-workspace --reset --no-attach >/dev/null
WORKSPACE_COLS=120 WORKSPACE_LINES=36 workspace --session ci-workspace --no-attach >/dev/null

assert_eq "$primary_entry_pane" "$(pane_option "ci-workspace:$primary_window" pane_title)" "entry pane"
assert_eq "latest" "$(tmux show-options -t '=ci-workspace:' -qv window-size)" "window-size"
while IFS=: read -r _ window_name _; do
  assert_eq "120x36" "$(tmux display-message -p -t "ci-workspace:$window_name" '#{window_width}x#{window_height}')" "size of $window_name"
  assert_eq "on" "$(tmux show-window-options -t "ci-workspace:$window_name" -v aggressive-resize)" "aggressive-resize of $window_name"
done <<< "$manifest"

assert_eq "ok" "$(tmux list-panes -t ci-workspace:dev -F '#{@workspace_pane_role} #{pane_width} #{pane_height}' | awk '$1 == "editor" { print ($2 >= 70 && $3 >= 20) ? "ok" : "bad" }')" "editor pane size"
assert_eq "ok" "$(tmux list-panes -t ci-workspace:dev -F '#{@workspace_pane_role} #{pane_width} #{pane_height}' | awk '$1 == "files" { print ($2 >= 40 && $3 >= 15) ? "ok" : "bad" }')" "files pane size"
assert_eq "$expected_count" "$(tmux list-windows -t '=ci-workspace:' | wc -l | tr -d ' ')" "window count"
assert_eq "$expected_windows" "$(tmux list-windows -t '=ci-workspace:' -F '#I:#W' | tr '\n' ' ')" "window order"
assert_eq "4" "$(pane_count ci-workspace:dev)" "dev panes"
assert_eq "2" "$(pane_count ci-workspace:agent)" "agent panes"
assert_eq "4" "$(pane_count ci-workspace:ssh)" "ssh panes"
assert_eq "2" "$(pane_count ci-workspace:logs)" "logs panes"
assert_eq "1" "$(pane_count ci-workspace:btop)" "btop panes"
assert_eq "1" "$(pane_count ci-workspace:manual)" "manual panes"
assert_eq "agent-1 agent-2 " "$(pane_roles ci-workspace:agent)" "agent roles"
assert_eq "Codex Gemini " "$(tmux list-panes -t ci-workspace:agent -F '#{pane_title}' | tr '\n' ' ')" "agent titles"
assert_eq "ssh-1 ssh-3 ssh-2 ssh-4 " "$(pane_roles ci-workspace:ssh)" "ssh roles"
assert_eq "logs-1 logs-2 " "$(pane_roles ci-workspace:logs)" "logs roles"
assert_eq "monitor " "$(pane_roles ci-workspace:btop)" "btop roles"
assert_eq "manual " "$(pane_roles ci-workspace:manual)" "manual roles"
printf 'ok: default layout matches the window registry\n\n'

# ------------------------------------------------------------------
printf 'Test 2: hooks are installed on the session only\n'
for hook in client-resized client-attached client-session-changed; do
  hook_text="$(tmux show-hooks -t '=ci-workspace:' "$hook")"
  assert_contains "$hook_text" "--hook fit" "hook $hook"
  # A hook is a command string that tmux parses again, so it must not carry
  # the directory or the session name.
  assert_not_contains "$hook_text" "$REPO_ROOT" "hook $hook"
  assert_not_contains "$hook_text" "ci-workspace" "hook $hook"
done
for hook in after-select-window session-window-changed; do
  if tmux show-hooks -t '=ci-workspace:' "$hook" 2>/dev/null | grep -q -- '--fit-only\|--schedule-fit\|--hook'; then
    fail "unexpected hook: $hook"
  fi
done
assert_eq "$WORKSPACE" "$(tmux show-environment -g MY_TERMINAL_WORKSPACE_SCRIPT | sed 's/^[^=]*=//')" "published script path"
# The server was started by a command that carried WORKSPACE_COLS and
# WORKSPACE_LINES. Neither may have become part of the server environment,
# where every later pane and job would inherit it.
assert_eq "" "$(tmux show-environment -g | grep '^WORKSPACE_' || true)" "workspace inputs in the server environment"
printf 'ok: resize hooks present and constant, window-change hooks absent\n\n'

printf 'Test 2b: the picker key can be changed and switched off\n'
assert_eq "M-0 " "$(picker_keys)" "default picker key"
WORKSPACE_PICK_KEY=M-9 workspace --session ci-workspace --no-attach >/dev/null
assert_eq "M-9 " "$(picker_keys)" "changed picker key"
workspace --session ci-workspace --no-attach >/dev/null
assert_eq "M-9 " "$(picker_keys)" "picker key is remembered"
WORKSPACE_PICK_KEY=none workspace --session ci-workspace --no-attach >/dev/null
assert_eq "" "$(picker_keys)" "picker key switched off"
WORKSPACE_PICK_KEY=M-0 workspace --session ci-workspace --no-attach >/dev/null
assert_eq "M-0 " "$(picker_keys)" "picker key restored"
printf 'ok: only the chosen key opens the picker\n\n'

# ------------------------------------------------------------------
printf 'Test 3: fit keeps pane ratios, refit restores them, zoom survives\n'
dev_shell_pane="$(pane_by_role ci-workspace:dev shell)"
[[ -n "$dev_shell_pane" ]] || fail "dev shell pane not found"

shell_height() {
  tmux list-panes -t ci-workspace:dev -F '#{@workspace_pane_role} #{pane_height}' | awk '$1 == "shell" { print $2 }'
}

tmux resize-pane -t "$dev_shell_pane" -y 20
WORKSPACE_COLS=140 WORKSPACE_LINES=40 workspace --session ci-workspace --fit-only
assert_eq "140x40" "$(tmux display-message -p -t ci-workspace:dev '#{window_width}x#{window_height}')" "fit size"
[[ "$(shell_height)" -ge 18 ]] || fail "fit should keep the enlarged shell pane"

WORKSPACE_REFIT_LAYOUT=1 WORKSPACE_COLS=140 WORKSPACE_LINES=40 workspace --session ci-workspace --fit-only
[[ "$(shell_height)" -le 14 ]] || fail "refit should restore the default shell height"
assert_eq "ok" "$(tmux list-panes -t ci-workspace:dev -F '#{@workspace_pane_role} #{pane_width} #{pane_height}' | awk '$1 == "git" { print ($2 <= 52 && $3 >= 18) ? "ok" : "bad" }')" "git pane after refit"

tmux resize-pane -t "$dev_shell_pane" -y 20
tmux resize-pane -Z -t "$dev_shell_pane"
assert_eq "1" "$(tmux display-message -p -t ci-workspace:dev '#{window_zoomed_flag}')" "zoomed before refit"
WORKSPACE_REFIT_LAYOUT=1 WORKSPACE_COLS=140 WORKSPACE_LINES=40 workspace --session ci-workspace --fit-only
assert_eq "1" "$(tmux display-message -p -t ci-workspace:dev '#{window_zoomed_flag}')" "zoomed after refit"
tmux resize-pane -Z -t "$dev_shell_pane"
[[ "$(shell_height)" -ge 18 ]] || fail "refit must not touch a zoomed window"
printf 'ok: fit, refit, and zoom behave\n\n'

# ------------------------------------------------------------------
printf 'Test 4: session metadata, status bar, and stable pane labels\n'
assert_eq "1" "$(tmux show-options -t '=ci-workspace:' -qv @workspace_session)" "@workspace_session"
assert_eq "$REPO_ROOT" "$(tmux show-options -t '=ci-workspace:' -qv @workspace_root)" "@workspace_root"
assert_eq "ci-workspace" "$(tmux show-options -t '=ci-workspace:' -qv @workspace_label)" "@workspace_label"
while IFS=: read -r _ window_name _; do
  # The status line expands style options as formats, so a style is only
  # usable when it survives that expansion unchanged.
  for style in window-status-current-style window-status-bell-style window-status-activity-style; do
    raw_style="$(tmux show-window-options -t "ci-workspace:$window_name" -v "$style")"
    assert_contains "$raw_style" "bold" "$style of $window_name"
    assert_eq "$raw_style" "$(tmux display-message -p -t "ci-workspace:$window_name" "#{E:$style}")" "expanded $style of $window_name"
  done
  assert_contains "$(tmux show-window-options -t "ci-workspace:$window_name" -v window-status-format)" "window_bell_flag" "status format of $window_name"
  assert_contains "$(tmux show-window-options -t "ci-workspace:$window_name" -v pane-border-format)" "@workspace_pane_title" "border format of $window_name"
done <<< "$manifest"

files_pane="$(pane_by_role ci-workspace:dev files)"
tmux select-pane -t "$files_pane" -T "title hijacked by an escape sequence"
assert_eq "yazi" "$(tmux display-message -p -t "$files_pane" '#{?@workspace_pane_title,#{@workspace_pane_title},#{pane_title}}')" "border label after title change"
workspace --session ci-workspace --repair --no-attach >/dev/null
assert_eq "yazi" "$(pane_option "$files_pane" pane_title)" "pane title after repair"
printf 'ok: metadata stored, every window styled, labels survive title changes\n\n'

# ------------------------------------------------------------------
printf 'Test 5: repair recreates a closed pane without touching the others\n'
logs_2_pane="$(pane_by_role ci-workspace:logs logs-2)"
logs_1_pane="$(pane_by_role ci-workspace:logs logs-1)"
tmux kill-pane -t "$logs_2_pane"
assert_eq "1" "$(pane_count ci-workspace:logs)" "logs panes after kill"
workspace --session ci-workspace --repair --no-attach >/dev/null
assert_eq "2" "$(pane_count ci-workspace:logs)" "logs panes after repair"
assert_eq "$logs_1_pane" "$(pane_by_role ci-workspace:logs logs-1)" "surviving pane id"
assert_eq "logs-1 logs-2 " "$(pane_roles ci-workspace:logs)" "logs roles after repair"
printf 'ok: repair is non-destructive\n\n'

# ------------------------------------------------------------------
printf 'Test 6: agent config reaches the panes of an already running server\n'
agents_three="$TEST_ROOT/agents-three.tsv"
write_agents "$agents_three" \
  'agent-1\tCodex\tcodex' \
  'agent-2\tGemini\tgemini' \
  'agent-3\tEcho\tcat'
WORKSPACE_AGENT_CONFIG="$agents_three" WORKSPACE_COLS=120 WORKSPACE_LINES=36 \
  workspace --session ci-agents --reset --no-attach >/dev/null
assert_eq "3" "$(pane_count ci-agents:agent)" "custom agent panes"
assert_eq "agent-1 agent-2 agent-3 " "$(pane_roles ci-agents:agent)" "custom agent roles"
echo_pane="$(pane_by_role ci-agents:agent agent-3)"
wait_for "agent-3 to start" pane_state_is "$echo_pane" running
assert_eq "$agents_three" "$(tmux show-options -t '=ci-agents:' -qv @workspace_agent_config)" "stored agent config"

tmux kill-pane -t "$echo_pane"
workspace --session ci-agents --repair --no-attach >/dev/null
assert_eq "3" "$(pane_count ci-agents:agent)" "agent panes after repair"
echo_pane="$(pane_by_role ci-agents:agent agent-3)"
wait_for "repaired agent-3 to start" pane_state_is "$echo_pane" running
printf 'ok: panes and later repairs use the config the session was created with\n\n'

# ------------------------------------------------------------------
printf 'Test 7: session names match exactly, never by prefix\n'
mkdir -p "$TEST_ROOT/projects/api" "$TEST_ROOT/projects/api-v2"
workspace --project --dir "$TEST_ROOT/projects/api-v2" --no-attach >/dev/null
assert_contains "$(session_names)" "ws-api-v2 " "project session created"
tmux new-window -d -t '=ws-api-v2:' -n keep-me

# "ws-api" is a prefix of "ws-api-v2": a bare tmux target would hit the latter.
workspace --session ws-api --dir "$TEST_ROOT/projects/api" --reset --no-attach >/dev/null
assert_contains "$(session_names)" "ws-api " "exact session created"
assert_contains "$(session_names)" "ws-api-v2 " "prefix sibling survived"
tmux list-windows -t '=ws-api-v2:' -F '#W' | grep -qx 'keep-me' || fail "reset of ws-api touched ws-api-v2"
assert_eq "$TEST_ROOT/projects/api-v2" "$(tmux show-options -t '=ws-api-v2:' -qv @workspace_root)" "sibling root"
tmux kill-session -t '=ws-api:'
printf 'ok: resetting ws-api left ws-api-v2 alone\n\n'

# ------------------------------------------------------------------
printf 'Test 8: one workspace per project\n'
mkdir -p "$TEST_ROOT/projects/a/app" "$TEST_ROOT/projects/b/app"
workspace --project --dir "$TEST_ROOT/projects/a/app" --no-attach >/dev/null
workspace --project --dir "$TEST_ROOT/projects/b/app" --no-attach >/dev/null
second_app="$(tmux list-sessions -F '#{session_name}|#{@workspace_root}' | awk -F'|' -v root="$TEST_ROOT/projects/b/app" '$2 == root { print $1 }')"
assert_contains "$(session_names)" "ws-app " "first app session"
[[ "$second_app" == ws-app-* ]] || fail "same-named project should get a suffixed session, got [$second_app]"

before="$(session_names)"
reenter="$(workspace --project --dir "$TEST_ROOT/projects/a/app" --no-attach)"
assert_contains "$reenter" "Workspace session ready: ws-app" "re-entering a project"
assert_eq "$before" "$(session_names)" "sessions after re-entering"
assert_eq "app" "$(tmux show-options -t '=ws-app:' -qv @workspace_label)" "project label"

repo="$(new_repo "$TEST_ROOT/projects/repo")"
mkdir -p "$repo/src/deep"
(cd "$repo/src/deep" && workspace --project --no-attach >/dev/null)
assert_eq "$repo" "$(tmux show-options -t '=ws-repo:' -qv @workspace_root)" "project root from a subdirectory"
assert_eq "project" "$(tmux show-options -t '=ws-repo:' -qv @workspace_kind)" "kind of a project workspace"
wait_for "the shell pane to start in the project" pane_is_in "$(pane_by_role ws-repo:dev shell)" "$repo"

# Naming a folder of the project is the same as standing in it.
before="$(session_names)"
reenter="$(workspace --project --dir "$repo/src/deep" --no-attach)"
assert_contains "$reenter" "Workspace session ready: ws-repo" "project from --dir of a subdirectory"
assert_eq "$before" "$(session_names)" "sessions after naming a subdirectory"

# A workspace that merely started in a directory is not the project
# workspace of that directory.
mkdir -p "$TEST_ROOT/projects/shared"
workspace --session ci-named --dir "$TEST_ROOT/projects/shared" --no-attach >/dev/null
assert_eq "named" "$(tmux show-options -t '=ci-named:' -qv @workspace_kind)" "kind of a named workspace"
workspace --project --dir "$TEST_ROOT/projects/shared" --no-attach >/dev/null
assert_contains "$(session_names)" "ws-shared " "project workspace next to a named one"

mkdir -p "$TEST_ROOT/projects/by-env"
WORKSPACE_SESSION_MODE=project workspace --dir "$TEST_ROOT/projects/by-env" --no-attach >/dev/null
assert_contains "$(session_names)" "ws-by-env " "project mode from the environment"

# The shared daily workspace is still the default.
WORKSPACE_SESSION_MODE=project workspace --global --dir "$TEST_ROOT/projects/api" --no-attach >/dev/null
assert_contains "$(session_names)" "my-terminal-workspace " "daily workspace"
assert_eq "workspace" "$(tmux show-options -t '=my-terminal-workspace:' -qv @workspace_label)" "daily label"
assert_eq "daily" "$(tmux show-options -t '=my-terminal-workspace:' -qv @workspace_kind)" "kind of the daily workspace"
workspace --project --dir "$TEST_ROOT/projects/api" --no-attach >/dev/null
assert_contains "$(session_names)" "ws-api " "project workspace next to the daily one"
tmux kill-session -t '=ws-api:'
printf 'ok: projects get their own session, found again by directory\n\n'

# ------------------------------------------------------------------
printf 'Test 9: listing and picker candidates\n'
listing="$(workspace --sessions)"
assert_contains "$listing" "SESSION" "sessions header"
assert_contains "$listing" "ws-repo" "sessions row"
assert_contains "$listing" "$repo" "sessions root"
assert_not_contains "$listing" "keep-me" "sessions are listed, not windows"

mkdir -p "$TEST_ROOT/projects/fresh"
candidates="$(WORKSPACE_PICK_DIRS="$TEST_ROOT/projects" workspace --pick-list)"
printf '%s\n' "$candidates" | grep -q "^session	ws-repo	" || fail "picker should offer running workspaces"
printf '%s\n' "$candidates" | grep -q "^dir	$TEST_ROOT/projects/fresh	" || fail "picker should offer new project directories"
if printf '%s\n' "$candidates" | grep -q "^dir	$repo	"; then
  fail "picker must not offer a directory that already has a workspace"
fi
printf 'ok: --sessions and --pick-list agree with the running sessions\n\n'

# ------------------------------------------------------------------
printf 'Test 10: maintenance commands act on the workspace they run in\n'
inside_pane="$(pane_by_role ws-repo:logs logs-1)"
tmux kill-pane -t "$(pane_by_role ws-repo:logs logs-2)"
(cd "$TEST_ROOT" && inside "$inside_pane" workspace --repair --no-attach >/dev/null)
assert_eq "2" "$(pane_count ws-repo:logs)" "repair from inside the workspace"
wait_for "the repaired pane to start in the workspace directory" pane_is_in "$(pane_by_role ws-repo:logs logs-2)" "$repo"

# A command that names its target means that target, wherever it is typed.
daily_pane="$(pane_by_role my-terminal-workspace:logs logs-1)"
daily_id="$(session_id_of my-terminal-workspace)"
repo_id="$(session_id_of ws-repo)"
tmux new-window -d -t '=my-terminal-workspace:' -n keep-daily
(cd "$repo/src" && inside "$daily_pane" workspace --project --reset --no-attach >/dev/null)
assert_eq "$daily_id" "$(session_id_of my-terminal-workspace)" "the workspace the command was typed in"
tmux list-windows -t '=my-terminal-workspace:' -F '#W' | grep -qx 'keep-daily' || fail "--project --reset rebuilt the workspace it was typed in"
[[ "$(session_id_of ws-repo)" != "$repo_id" ]] || fail "--project --reset did not rebuild the project workspace"
assert_eq "$repo" "$(tmux show-options -t '=ws-repo:' -qv @workspace_root)" "root of the rebuilt project workspace"
tmux kill-window -t '=my-terminal-workspace:keep-daily'
printf 'ok: maintenance follows the workspace, unless the command names another\n\n'

# ------------------------------------------------------------------
printf 'Test 11: project agent configs are ignored until trusted\n'
trusted_project="$TEST_ROOT/projects/trusted"
write_agents "$trusted_project/.my-terminal/agents.tsv" 'solo\tSolo\tcat'

notice="$(workspace --project --dir "$trusted_project" --no-attach 2>&1 >/dev/null)"
assert_contains "$notice" "ignoring untrusted project agent config" "untrusted notice"
assert_eq "agent-1 agent-2 " "$(pane_roles ws-trusted:agent)" "roles before trust"

# A row that tries to hide behind a carriage return and an escape sequence
# must still be visible to the person who is asked to trust the file.
printf 'hidden\tHidden\tcat\r\033[2K\033[1Aharmless\n' >> "$trusted_project/.my-terminal/agents.tsv"
trust_report="$(workspace --trust --dir "$trusted_project")"
assert_contains "$trust_report" "hidden" "trust shows every row"
if printf '%s' "$trust_report" | LC_ALL=C grep -q "$(printf '[\r\033]')"; then
  fail "trust printed control characters from the project file"
fi
grep -v '^hidden' "$trusted_project/.my-terminal/agents.tsv" > "$TEST_ROOT/agents-clean.tsv"
cp "$TEST_ROOT/agents-clean.tsv" "$trusted_project/.my-terminal/agents.tsv"

workspace --trust --dir "$trusted_project" >/dev/null
notice="$(workspace --project --dir "$trusted_project" --reset --no-attach 2>&1 >/dev/null)"
assert_not_contains "$notice" "untrusted" "notice after trust"
assert_eq "solo " "$(pane_roles ws-trusted:agent)" "roles after trust"

printf 'extra\tExtra\tcat\n' >> "$trusted_project/.my-terminal/agents.tsv"
notice="$(workspace --project --dir "$trusted_project" --reset --no-attach 2>&1 >/dev/null)"
assert_contains "$notice" "ignoring untrusted project agent config" "notice after edit"
assert_eq "agent-1 agent-2 " "$(pane_roles ws-trusted:agent)" "roles after edit"
printf 'ok: trust is per file content\n\n'

# ------------------------------------------------------------------
printf 'Test 12: --send reaches agents and never a shell prompt\n'
agents_send="$TEST_ROOT/agents-send.tsv"
write_agents "$agents_send" \
  'alpha\tAlpha\tcat' \
  'beta\tBeta\tcat' \
  'gamma\tGamma\tmissing-agent-cli-for-tests' \
  'delta\tDelta\tsh'
WORKSPACE_AGENT_CONFIG="$agents_send" workspace --session ci-send --dir "$TEST_ROOT/projects/api" --reset --no-attach >/dev/null
alpha_pane="$(pane_by_role ci-send:agent alpha)"
beta_pane="$(pane_by_role ci-send:agent beta)"
gamma_pane="$(pane_by_role ci-send:agent gamma)"
delta_pane="$(pane_by_role ci-send:agent delta)"
wait_for "alpha to start" pane_state_is "$alpha_pane" running
wait_for "beta to start" pane_state_is "$beta_pane" running
wait_for "gamma to fall back to a shell" pane_shows "$gamma_pane" "command not found in PATH"

# If a shell ever received this, it would print INJECTED-42.
# shellcheck disable=SC2016 # the unexpanded text is the payload
prompt='compare: echo INJECTED-$((40+2))'
prompt_marker="${prompt#compare: echo }"
send_report="$(workspace --session ci-send --send "$prompt")"
assert_contains "$send_report" "sent: alpha (Alpha)" "send report alpha"
assert_contains "$send_report" "sent: beta (Beta)" "send report beta"
assert_contains "$send_report" "skip: gamma (Gamma)" "send report gamma"
# An agent row that is itself a shell is a prompt, whatever the config says.
assert_contains "$send_report" "skip: delta (Delta)" "send report delta"
wait_for "alpha to receive the prompt" pane_shows "$alpha_pane" "$prompt_marker"
wait_for "beta to receive the prompt" pane_shows "$beta_pane" "$prompt_marker"
sleep 0.5
assert_not_contains "$(pane_text "$gamma_pane")" "INJECTED" "shell pane stays untouched"
assert_not_contains "$(pane_text "$delta_pane")" "INJECTED" "shell agent stays untouched"
assert_not_contains "$(pane_text "$alpha_pane")" "INJECTED-42" "prompt is pasted, not evaluated"

workspace --session ci-send --send "only for beta" --to Beta >/dev/null
wait_for "beta to receive the targeted prompt" pane_shows "$beta_pane" "only for beta"
sleep 0.3
assert_not_contains "$(pane_text "$alpha_pane")" "only for beta" "--to filter"

send_report="$(workspace --session ci-send --send "for both of you" --to "alpha, Beta")"
assert_contains "$send_report" "sent: alpha (Alpha)" "--to with a space after the comma"
assert_contains "$send_report" "sent: beta (Beta)" "--to with a space after the comma"

# A pane in copy mode would swallow Enter; the text has to arrive and be
# submitted all the same. cat prints a submitted line a second time.
tmux copy-mode -t "$beta_pane"
workspace --session ci-send --send "through copy mode" --to beta >/dev/null
beta_got_it_twice() {
  [[ "$(pane_text "$beta_pane" | grep -c 'through copy mode')" -ge 2 ]]
}
wait_for "beta to receive and submit the text" beta_got_it_twice
assert_eq "0" "$(pane_option "$beta_pane" pane_in_mode)" "copy mode after --send"

printf 'from stdin\n' | workspace --session ci-send --send - --to alpha >/dev/null
wait_for "alpha to receive stdin text" pane_shows "$alpha_pane" "from stdin"

if workspace --session ci-send --send "nobody home" --to gamma >/dev/null 2>&1; then
  fail "--send should fail when no agent received the text"
fi
if workspace --session ci-send --send "nobody home" --to nobody >/dev/null 2>&1; then
  fail "--send should fail when no pane matches"
fi

# Respawning a pane with another program leaves "running" behind on the pane.
# The recorded process no longer owns the pane, so the state must not count.
alpha_pid="$(pane_option "$alpha_pane" pane_pid)"
tmux respawn-pane -k -t "$alpha_pane" /bin/sh
pane_is_respawned() {
  local pid

  pid="$(pane_option "$alpha_pane" pane_pid)"
  [[ -n "$pid" && "$pid" != "$alpha_pid" ]]
}
wait_for "alpha to be respawned as a shell" pane_is_respawned
assert_eq "running" "$(pane_option "$alpha_pane" @workspace_agent_state)" "stale state after respawn"
send_report="$(workspace --session ci-send --send "$prompt" --to alpha,beta)"
assert_contains "$send_report" "skip: alpha (Alpha)" "send report after respawn"
assert_contains "$send_report" "sent: beta (Beta)" "send report after respawn"
sleep 0.5
assert_not_contains "$(pane_text "$alpha_pane")" "INJECTED" "respawned shell stays untouched"

# Panes are served one after another. An agent that exits while the others
# are being served has left a shell behind by the time its turn comes.
agents_race="$TEST_ROOT/agents-race.tsv"
race_fifo="$TEST_ROOT/race.fifo"
mkfifo "$race_fifo"
# The third agent reads from a pipe, so the test decides when it exits.
write_agents "$agents_race" \
  'r1\tFirst\tcat' \
  'r2\tSecond\tcat' \
  "r3\\tLeaving\\tcat $race_fifo"
WORKSPACE_AGENT_CONFIG="$agents_race" workspace --session ci-race --dir "$TEST_ROOT/projects/api" --reset --no-attach >/dev/null
race_pane="$(pane_by_role ci-race:agent r3)"
wait_for "r1 to start" pane_state_is "$(pane_by_role ci-race:agent r1)" running
wait_for "r3 to start" pane_state_is "$race_pane" running
WORKSPACE_SEND_DELAY=1.5 workspace --session ci-race --send "$prompt" > "$TEST_ROOT/race-report.txt" &
race_send=$!
: > "$race_fifo"
wait_for "r3 to be back at its shell" pane_state_is "$race_pane" idle
wait "$race_send" || true
send_report="$(cat "$TEST_ROOT/race-report.txt")"
assert_contains "$send_report" "sent: r1 (First)" "send report r1"
assert_contains "$send_report" "skip: r3 (Leaving)" "send report r3"
sleep 0.5
assert_not_contains "$(pane_text "$race_pane")" "INJECTED-42" "a shell left behind by an agent"
printf 'ok: prompts are pasted into agents only\n\n'

# ------------------------------------------------------------------
printf 'Test 12b: what holds the terminal decides, not what was recorded\n'
agents_front="$TEST_ROOT/agents-front.tsv"
write_agents "$agents_front" \
  'm1\tManual\tfake-agent' \
  'd1\tDialog\tfake-dialog'
WORKSPACE_AGENT_CONFIG="$agents_front" workspace --session ci-front --dir "$TEST_ROOT/projects/api" --reset --no-attach >/dev/null
manual_pane="$(pane_by_role ci-front:agent m1)"
dialog_pane="$(pane_by_role ci-front:agent d1)"
wait_for "m1 to start" pane_state_is "$manual_pane" running
wait_for "d1 to start" pane_state_is "$dialog_pane" running
wait_for "d1 to ask its question" pane_shows "$dialog_pane" "Press enter to continue"

# An agent that is asking a question does not show pasted text. Enter would
# answer the question, so it is not pressed.
send_report="$(workspace --session ci-front --send "a question for the agents" || true)"
assert_contains "$send_report" "sent: m1 (Manual)" "send report m1"
assert_contains "$send_report" "held: d1 (Dialog)" "send report d1"
wait_for "m1 to answer" pane_shows "$manual_pane" "agent got: a question for the agents"
sleep 0.5
assert_not_contains "$(pane_text "$dialog_pane")" "CONFIRMED" "a question answered by --send"
if workspace --session ci-front --send "only the dialog" --to d1 >/dev/null 2>&1; then
  fail "--send should fail when the only agent held the text back"
fi

# Answered by hand, the same agent takes the next prompt.
tmux send-keys -t "$dialog_pane" C-u Enter
wait_for "d1 to continue" pane_shows "$dialog_pane" "CONFIRMED"
send_report="$(workspace --session ci-front --send "after the question" --to d1)"
assert_contains "$send_report" "sent: d1 (Dialog)" "send report d1 after its question"
wait_for "d1 to receive the prompt" pane_shows "$dialog_pane" "after the question"

# An agent that was quit and started again by hand is no longer the process
# the workspace started. It is recognised by its command line, which names
# the agent even though the process is the interpreter.
tmux send-keys -t "$manual_pane" C-d
wait_for "m1 to be back at its shell" pane_state_is "$manual_pane" idle
send_report="$(workspace --session ci-front --send "nobody is there" --to m1 || true)"
assert_contains "$send_report" "skip: m1 (Manual)" "send report m1 at its shell"
tmux send-keys -t "$manual_pane" "fake-agent" Enter
wait_for "m1 to be started by hand" pane_front_shows "$manual_pane" "fake-agent"
assert_eq "idle" "$(pane_option "$manual_pane" @workspace_agent_state)" "state of an agent started by hand"
send_report="$(workspace --session ci-front --send "after the restart" --to m1)"
assert_contains "$send_report" "sent: m1 (Manual)" "send report m1 after a restart by hand"
wait_for "m1 to answer again" pane_shows "$manual_pane" "agent got: after the restart"

# A login profile that replaces the shell never runs the command it was
# given. The pane is marked as running, yet a prompt is what holds the
# terminal.
(
  export TMUX_TMPDIR="$TEST_ROOT/tmux3"
  export HOME="$TEST_ROOT/home-profile"
  mkdir -p "$HOME"
  printf 'exec /bin/sh -i\n' > "$HOME/.profile"
  write_agents "$TEST_ROOT/agents-profile.tsv" 'h1\tReplaced\tcat'
  WORKSPACE_AGENT_CONFIG="$TEST_ROOT/agents-profile.tsv" workspace --session ci-profile --dir "$TEST_ROOT/projects/api" --no-attach >/dev/null
  profile_pane="$(pane_by_role ci-profile:agent h1)"
  wait_for "h1 to be marked as running" pane_state_is "$profile_pane" running
  wait_for "the shell of the profile to take the terminal" pane_front_is_not_root "$profile_pane"
  send_report="$(workspace --session ci-profile --send "$prompt" || true)"
  assert_contains "$send_report" "skip: h1 (Replaced)" "send report for a replaced shell"
  sleep 0.5
  assert_not_contains "$(pane_text "$profile_pane")" "INJECTED" "a shell started by a login profile"
)
TMUX_TMPDIR="$TEST_ROOT/tmux3" tmux kill-server >/dev/null 2>&1 || true
printf 'ok: dialogs are left alone, restarts are found, replaced shells are skipped\n\n'

# ------------------------------------------------------------------
printf 'Test 13: agents can work in their own git worktrees\n'
wt_repo="$(new_repo "$TEST_ROOT/projects/wt")"
agents_wt="$TEST_ROOT/agents-wt.tsv"
mkdir -p "$wt_repo/sub/dir"
write_agents "$agents_wt" \
  'w1\tIsolated\tcat\tworktree' \
  'w2\tShared\tcat' \
  'w3\tSubdir\tcat\tsub/dir' \
  'w4\tNowhere\tcat\tdoes/not/exist' \
  'w5\tPlain\t-\tsub/dir' \
  'w6\t\tAligned\t\tcat\t\tsub/dir'
WORKSPACE_AGENT_CONFIG="$agents_wt" workspace --project --dir "$wt_repo" --no-attach >/dev/null
assert_eq "w1 w2 w3 w4 w5 w6 " "$(pane_roles ws-wt:agent)" "agent pane order"
w1_pane="$(pane_by_role ws-wt:agent w1)"
w2_pane="$(pane_by_role ws-wt:agent w2)"
w3_pane="$(pane_by_role ws-wt:agent w3)"
w4_pane="$(pane_by_role ws-wt:agent w4)"
w5_pane="$(pane_by_role ws-wt:agent w5)"
wait_for "w1 to start" pane_state_is "$w1_pane" running
wait_for "w2 to start" pane_state_is "$w2_pane" running
wait_for "w3 to start" pane_state_is "$w3_pane" running
wait_for "w4 to start" pane_state_is "$w4_pane" running
assert_eq "$wt_repo/sub/dir" "$(pane_option "$w3_pane" pane_current_path)" "relative agent cwd"
assert_eq "$wt_repo" "$(pane_option "$w4_pane" pane_current_path)" "missing agent cwd falls back"
assert_contains "$(pane_text "$w4_pane")" "agent cwd not found for w4" "missing agent cwd notice"
# "-" in the command column is a plain shell, and it still honours cwd.
wait_for "w5 to open its shell in the cwd" pane_is_in "$w5_pane" "$wt_repo/sub/dir"
assert_eq "idle" "$(pane_option "$w5_pane" @workspace_agent_state)" "shell pane state"
# Columns aligned with several tabs mean the same as single tabs.
w6_pane="$(pane_by_role ws-wt:agent w6)"
wait_for "w6 to start" pane_state_is "$w6_pane" running
assert_eq "Aligned" "$(pane_option "$w6_pane" @workspace_pane_title)" "title from an aligned row"
assert_eq "$wt_repo/sub/dir" "$(pane_option "$w6_pane" pane_current_path)" "cwd from an aligned row"

w1_dir="$(pane_option "$w1_pane" pane_current_path)"
[[ "$w1_dir" == "$HOME/.local/share/my-terminal/worktrees/wt-"*/w1 ]] || fail "w1 should run in its worktree, got [$w1_dir]"
assert_eq "$wt_repo" "$(pane_option "$w2_pane" pane_current_path)" "w2 directory"
assert_eq "agent/w1" "$(git -C "$w1_dir" rev-parse --abbrev-ref HEAD)" "worktree branch"
assert_eq "main" "$(git -C "$wt_repo" rev-parse --abbrev-ref HEAD)" "workspace checkout branch"
[[ -z "$(git -C "$wt_repo" status --porcelain)" ]] || fail "worktrees must not dirty the workspace checkout"

worktrees="$(workspace --worktrees --dir "$wt_repo")"
assert_contains "$worktrees" "agent/w1" "worktree listing"
assert_contains "$worktrees" "in use" "worktree listing state"
assert_contains "$(workspace --prune-worktrees --yes --dir "$wt_repo")" "keep:   w1 (a shell or pane is running inside it)" "prune while in use"
[[ -d "$w1_dir" ]] || fail "an in-use worktree was removed"

tmux kill-session -t '=ws-wt:'
printf 'draft\n' > "$w1_dir/notes.txt"
assert_contains "$(workspace --prune-worktrees --yes --dir "$wt_repo")" "keep:   w1 (uncommitted changes)" "prune with changes"

git -C "$w1_dir" add notes.txt
git -C "$w1_dir" commit -q -m "agent work"
assert_contains "$(workspace --prune-worktrees --yes --dir "$wt_repo")" "keep:   w1 (1 unmerged commit(s) on agent/w1)" "prune with unmerged work"
# Asked from the worktree itself, the branch must still be compared with the
# main checkout rather than with its own HEAD.
assert_contains "$(workspace --prune-worktrees --yes --dir "$w1_dir")" "keep:   w1 (1 unmerged commit(s) on agent/w1)" "prune asked from the worktree"
assert_contains "$(cd "$w1_dir" && workspace --prune-worktrees --yes)" "keep:   w1 (a shell or pane is running inside it)" "prune from inside the worktree"
[[ -f "$w1_dir/notes.txt" ]] || fail "unmerged agent work was removed"

git -C "$wt_repo" merge -q agent/w1
plan="$(workspace --prune-worktrees --dir "$wt_repo")"
assert_contains "$plan" "would remove: w1" "prune plan"
assert_contains "$plan" "No changes made" "prune plan is a dry run"
[[ -d "$w1_dir" ]] || fail "prune without --yes removed a worktree"

assert_contains "$(workspace --prune-worktrees --yes --dir "$wt_repo")" "removed: w1" "prune applied"
[[ ! -e "$w1_dir" ]] || fail "merged worktree still exists"
if git -C "$wt_repo" show-ref --verify --quiet refs/heads/agent/w1; then
  fail "merged agent branch still exists"
fi
[[ -f "$wt_repo/notes.txt" ]] || fail "merged work is missing from the workspace checkout"

workspace --project --dir "$wt_repo" --agent-worktrees --no-attach >/dev/null
assert_eq "worktree" "$(tmux show-options -t '=ws-wt:' -qv @workspace_agent_cwd)" "stored agent cwd"
wt_first_pane="$(pane_by_role ws-wt:agent agent-1)"
wait_for "agent-1 to fall back to a shell" pane_shows "$wt_first_pane" "command not found in PATH"
assert_contains "$(workspace --worktrees --dir "$wt_repo")" "No agent worktrees" "no worktree for a missing agent CLI"
tmux kill-session -t '=ws-wt:'

# A lock left behind by a pane that was killed must not hold up the next one.
lock_repo="$(new_repo "$TEST_ROOT/projects/locked")"
mkdir -p "$lock_repo/.git/my-terminal-worktree.lock"
printf '999999\n' > "$lock_repo/.git/my-terminal-worktree.lock/pid"
write_agents "$TEST_ROOT/agents-lock.tsv" 'w1\tIsolated\tcat\tworktree'
WORKSPACE_AGENT_CONFIG="$TEST_ROOT/agents-lock.tsv" workspace --project --dir "$lock_repo" --no-attach >/dev/null
lock_pane="$(pane_by_role ws-locked:agent w1)"
wait_for "the agent to start despite a stale lock" pane_state_is "$lock_pane" running
assert_eq "agent/w1" "$(git -C "$(pane_option "$lock_pane" pane_current_path)" rev-parse --abbrev-ref HEAD)" "worktree after a stale lock"
[[ ! -e "$lock_repo/.git/my-terminal-worktree.lock" ]] || fail "the worktree lock was not released"

# When git cannot tell whether a branch is merged, the worktree is kept.
lock_worktree="$(pane_option "$lock_pane" pane_current_path)"
tmux kill-session -t '=ws-locked:'
printf 'work\n' > "$lock_worktree/work.txt"
git -C "$lock_worktree" add work.txt
git -C "$lock_worktree" commit -q -m "agent work"
git -C "$lock_repo" checkout -q --orphan scratch
assert_contains "$(workspace --prune-worktrees --yes --dir "$lock_repo")" "keep:   w1 (cannot compare agent/w1 with the current checkout)" "prune without a merge base"
[[ -f "$lock_worktree/work.txt" ]] || fail "a worktree with unknown merge state was removed"
printf 'ok: worktrees isolate agents and prune only what is safe to lose\n\n'

# ------------------------------------------------------------------
printf 'Test 14: a real client attaches and the workspace fits it\n'
start_outer_client ci-workspace
client_attached() {
  [[ -n "$(tmux list-clients -t '=ci-workspace:' -F '#{client_name}' 2>/dev/null)" ]]
}
wait_for "a client to attach to ci-workspace" client_attached
window_fits_client() {
  [[ "$(tmux display-message -p -t ci-workspace:dev '#{window_width}')" == "132" ]]
}
wait_for "the workspace to fit the client" window_fits_client
assert_eq "dev" "$(tmux display-message -p -t '=ci-workspace:' '#{window_name}')" "window after attach"
printf 'ok: attach works through the exact-match target\n\n'

# ------------------------------------------------------------------
printf 'Test 15: --reset typed inside the workspace rebuilds it in place\n'
session_id() {
  tmux display-message -p -t '=ci-workspace:' '#{session_id}' 2>/dev/null
}
old_session_id="$(session_id)"
tmux new-window -d -t '=ci-workspace:' -n scratch
session_was_replaced() {
  local current

  current="$(session_id)"
  [[ -n "$current" && "$current" != "$old_session_id" ]]
}

# Attaching parks the entry pane in copy mode for a moment; typing has to
# wait until it is released.
entry_pane="$(pane_by_role ci-workspace:dev shell)"
entry_pane_released() {
  [[ "$(pane_option "$entry_pane" pane_in_mode)" == "0" ]]
}
wait_for "the entry pane to be released" entry_pane_released
# The pane is a real shell here, so the command is typed the way a user
# would: through the published script variable, not a quoted path.
# shellcheck disable=SC2016 # expanded by the shell in the pane
tmux send-keys -t "$entry_pane" '"$MY_TERMINAL_WORKSPACE_SCRIPT" --reset' Enter
wait_for "the workspace to be replaced" session_was_replaced
wait_for "the client to follow the new workspace" client_attached

assert_eq "$expected_windows" "$(tmux list-windows -t '=ci-workspace:' -F '#I:#W' | tr '\n' ' ')" "windows after reset"
assert_eq "ci-workspace" "$(tmux show-options -t '=ci-workspace:' -qv @workspace_label)" "label after reset"
assert_eq "$REPO_ROOT" "$(tmux show-options -t '=ci-workspace:' -qv @workspace_root)" "root after reset"
assert_contains "$(tmux show-hooks -t '=ci-workspace:' client-resized)" "--hook fit" "hooks after reset"
assert_not_contains "$(session_names)" "reset" "temporary session left behind"
printf 'ok: clients moved to the rebuilt workspace, nothing left behind\n\n'

# ------------------------------------------------------------------
printf 'Test 15b: switching through the picker leaves the workspace as it was\n'
tmux select-window -t ws-repo:logs
repo_shell="$(pane_by_role ws-repo:dev shell)"
tmux send-keys -t "$repo_shell" "half typed command"
choice="$(workspace --pick-list | awk -F '\t' '$1 == "session" && $2 == "ws-repo" { print NR }')"
[[ -n "$choice" ]] || fail "ws-repo is missing from the picker"

client_is_on() {
  [[ "$(tmux list-clients -F '#{client_session}' | head -n 1)" == "$1" ]]
}
entry_pane="$(pane_by_role ci-workspace:dev shell)"
wait_for "the entry pane to be released" entry_pane_released
# shellcheck disable=SC2016 # expanded by the shell in the pane
tmux send-keys -t "$entry_pane" '"$MY_TERMINAL_WORKSPACE_SCRIPT" --pick' Enter
wait_for "the picker to ask for a choice" pane_shows "$entry_pane" "Select [1-"
tmux send-keys -t "$entry_pane" "$choice" Enter
wait_for "the client to switch to ws-repo" client_is_on ws-repo
sleep 3
assert_eq "logs" "$(tmux display-message -p -t '=ws-repo:' '#{window_name}')" "window of the workspace switched to"
assert_contains "$(pane_text "$repo_shell")" "half typed command" "input of the workspace switched to"
assert_eq "0" "$(pane_option "$repo_shell" pane_in_mode)" "copy mode in the workspace switched to"
tmux send-keys -t "$repo_shell" C-u
tmux -L "$OUTER_SOCKET" kill-server
printf 'ok: the picker only switches\n\n'

# ------------------------------------------------------------------
printf 'Test 15c: entering a running workspace leaves it the way it was\n'
workspace --session ci-reenter --dir "$TEST_ROOT/projects/api" --no-attach >/dev/null
tmux select-window -t ci-reenter:logs
reenter_pane="$(pane_by_role ci-reenter:logs logs-1)"
tmux select-pane -t "$reenter_pane"
tmux send-keys -t "$reenter_pane" "half typed command"
reenter_dev="$(pane_by_role ci-reenter:dev shell)"
tmux send-keys -t "$reenter_dev" "typed in the entry pane"

workspace --session ci-reenter --no-attach >/dev/null
assert_eq "logs" "$(tmux display-message -p -t '=ci-reenter:' '#{window_name}')" "window after entering without attaching"

start_outer_client ci-reenter
reenter_client_attached() {
  [[ -n "$(tmux list-clients -t '=ci-reenter:' -F '#{client_name}' 2>/dev/null)" ]]
}
wait_for "a client to attach to ci-reenter" reenter_client_attached
assert_eq "logs" "$(tmux display-message -p -t '=ci-reenter:' '#{window_name}')" "window after attaching"
assert_eq "$reenter_pane" "$(tmux display-message -p -t '=ci-reenter:' '#{pane_id}')" "pane after attaching"
wait_for "the shield on the pane in front to end" pane_is_released "$reenter_pane"
sleep 0.5
assert_eq "logs" "$(tmux display-message -p -t '=ci-reenter:' '#{window_name}')" "window after the shield ended"
assert_contains "$(pane_text "$reenter_pane")" "half typed command" "input of the pane in front"
assert_contains "$(pane_text "$reenter_dev")" "typed in the entry pane" "input of the entry pane"
tmux -L "$OUTER_SOCKET" kill-server

# Copy mode that the user entered is not the shield, and stays.
tmux copy-mode -t "$reenter_pane"
start_outer_client ci-reenter
wait_for "a client to attach to ci-reenter again" reenter_client_attached
sleep 4
assert_eq "1" "$(pane_option "$reenter_pane" pane_in_mode)" "copy mode the user entered"
tmux send-keys -t "$reenter_pane" -X cancel
tmux send-keys -t "$reenter_pane" C-u
tmux send-keys -t "$reenter_dev" C-u
tmux -L "$OUTER_SOCKET" kill-server
printf 'ok: same window, same pane, same input\n\n'

# ------------------------------------------------------------------
printf 'Test 16: a hostile directory name is only ever a directory name\n'
marker_dir="$TEST_ROOT/markers"
mkdir -p "$marker_dir"
tab="$(printf '\t')"
write_agents "$TEST_ROOT/agents-hostile.tsv" 'only\tOnly\tcat\tworktree'

hostile_names=(
  # A control character makes printf %q switch to $'...', whose quote ends
  # the quoting of a tmux hook; the rest used to be parsed as tmux commands.
  "parser$tab ; run-shell \"touch $marker_dir/tmux-parser\" ; display-message "
  # tmux replaces "#T" with the pane title, which any program can set.
  "title#Tsuffix"
  # Everything a shell would act on, plus quotes and non-ASCII text.
  "shell \$(touch $marker_dir/subshell) \`touch $marker_dir/backtick\` ; touch $marker_dir/semicolon ; 'q' \"d\" 目录"
)

hostile_index=0
for hostile_name in "${hostile_names[@]}"; do
  hostile_index=$((hostile_index + 1))
  hostile_session="ci-hostile-$hostile_index"
  hostile="$TEST_ROOT/projects/$hostile_name"
  mkdir -p "$hostile"
  hostile="$(cd "$hostile" && pwd -P)"
  git -C "$hostile" init -q
  git -C "$hostile" commit -q --allow-empty -m "initial commit"

  WORKSPACE_AGENT_CONFIG="$TEST_ROOT/agents-hostile.tsv" WORKSPACE_COLS=120 WORKSPACE_LINES=36 \
    workspace --session "$hostile_session" --dir "$hostile" --no-attach >/dev/null

  assert_eq "$hostile" "$(tmux show-options -t "=$hostile_session:" -qv @workspace_root)" "root of $hostile_session"
  hostile_shell="$(pane_by_role "$hostile_session:dev" shell)"
  wait_for "the shell pane of $hostile_session to start in its directory" pane_is_in "$hostile_shell" "$hostile"
  wait_for "the agent of $hostile_session to start" pane_state_is "$(pane_by_role "$hostile_session:agent" only)" running
  for hook in client-resized client-attached client-session-changed; do
    hook_text="$(tmux show-hooks -t "=$hostile_session:" "$hook")"
    assert_contains "$hook_text" "--hook fit" "hook $hook of $hostile_session"
    assert_not_contains "$hook_text" "projects" "hook $hook of $hostile_session"
  done

  while read -r pane_id; do
    tmux select-pane -t "$pane_id" -T "z; touch $marker_dir/pane-title; echo "
  done < <(tmux list-panes -s -t "=$hostile_session:" -F '#{pane_id}')

  start_outer_client "$hostile_session"
  hostile_client_attached() {
    [[ -n "$(tmux list-clients -t "=$hostile_session:" -F '#{client_name}' 2>/dev/null)" ]]
  }
  hostile_window_is() {
    [[ "$(tmux display-message -p -t "$hostile_session:dev" '#{window_width}')" == "$1" ]]
  }
  hostile_session_id() {
    tmux display-message -p -t "=$hostile_session:" '#{session_id}' 2>/dev/null
  }
  hostile_was_replaced() {
    local current

    current="$(hostile_session_id)"
    [[ -n "$current" && "$current" != "$old_hostile_id" ]]
  }
  wait_for "a client to attach to $hostile_session" hostile_client_attached
  wait_for "$hostile_session to fit the client" hostile_window_is 132

  # From here on only the resize hook can make the window follow the client.
  tmux -L "$OUTER_SOCKET" resize-window -t outer -x 101 -y 31
  wait_for "the resize hook to refit $hostile_session" hostile_window_is 101

  old_hostile_id="$(hostile_session_id)"
  hostile_shell="$(pane_by_role "$hostile_session:dev" shell)"
  (cd "$TEST_ROOT" && inside "$hostile_shell" workspace --reset >/dev/null)
  wait_for "$hostile_session to be replaced" hostile_was_replaced
  wait_for "the client to follow $hostile_session" hostile_client_attached
  assert_eq "$hostile" "$(tmux show-options -t "=$hostile_session:" -qv @workspace_root)" "root of $hostile_session after reset"

  sleep 1
  tmux -L "$OUTER_SOCKET" kill-server
done

leftovers="$(find "$marker_dir" -mindepth 1 | head -n 5)"
[[ -z "$leftovers" ]] || fail "a directory name or pane title was executed as a command: $leftovers"
printf 'ok: panes, hooks, resize, and reset all treat names as data\n\n'

# ------------------------------------------------------------------
printf 'Test 17: settings stay with the workspace they were given to\n'
move_a="$TEST_ROOT/projects/move-a"
move_b="$TEST_ROOT/projects/move-b"
mkdir -p "$move_a" "$move_b"
git -C "$move_a" init -q
git -C "$move_a" commit -q --allow-empty -m "initial commit"
write_agents "$TEST_ROOT/agents-a.tsv" 'alpha\tAlpha\tcat'
write_agents "$TEST_ROOT/agents-b.tsv" 'bravo\tBravo\tcat' 'charlie\tCharlie\tcat'

WORKSPACE_AGENT_CONFIG="$TEST_ROOT/agents-a.tsv" WORKSPACE_AGENT_SILENCE=45 \
  workspace --session ci-move --dir "$move_a" --agent-worktrees --no-attach >/dev/null
assert_eq "worktree" "$(tmux show-options -t '=ci-move:' -qv @workspace_agent_cwd)" "stored agent cwd"
assert_eq "45" "$(tmux show-window-options -t ci-move:agent -v monitor-silence)" "agent silence"
wait_for "alpha to start" pane_state_is "$(pane_by_role ci-move:agent alpha)" running

# The shells of a workspace must not carry its settings: a command typed in
# one of them would apply them to whatever it opens next.
move_shell="$(pane_by_role ci-move:logs logs-1)"
tmux send-keys -t "$move_shell" "env > '$TEST_ROOT/pane-env.txt'" Enter
wait_for "the pane to report its environment" test -s "$TEST_ROOT/pane-env.txt"
leaked="$(grep -E '^WORKSPACE_(AGENT_CONFIG|AGENT_CWD|TRUST_PROJECT_CONFIG|DIR|SESSION|COLS|LINES)=' "$TEST_ROOT/pane-env.txt" || true)"
assert_eq "" "$leaked" "workspace settings in the environment of a pane"

# Entering again keeps what the workspace was built with.
workspace --session ci-move --no-attach >/dev/null
assert_eq "$TEST_ROOT/agents-a.tsv" "$(tmux show-options -t '=ci-move:' -qv @workspace_agent_config)" "settings after entering again"
assert_eq "worktree" "$(tmux show-options -t '=ci-move:' -qv @workspace_agent_cwd)" "settings after entering again"

# A reset from outside rebuilds with what this command says, where it says.
(cd "$move_b" && workspace --session ci-move --reset --no-attach >/dev/null)
assert_eq "$move_b" "$(tmux show-options -t '=ci-move:' -qv @workspace_root)" "root after a reset from another directory"
assert_eq "" "$(tmux show-options -t '=ci-move:' -qv @workspace_agent_cwd)" "agent cwd after a reset without the flag"
assert_eq "" "$(tmux show-options -t '=ci-move:' -qv @workspace_agent_config)" "agent config after a reset without it"
assert_eq "agent-1 agent-2 " "$(pane_roles ci-move:agent)" "roles after a reset without a config"
assert_eq "named" "$(tmux show-options -t '=ci-move:' -qv @workspace_kind)" "kind after a reset"

# Typed inside the workspace, a reset stays in the directory of the
# workspace, and what the command asks for reaches the rebuilt workspace.
move_shell="$(pane_by_role ci-move:logs logs-1)"
move_id="$(session_id_of ci-move)"
move_was_replaced() {
  local current

  current="$(session_id_of ci-move)"
  [[ -n "$current" && "$current" != "$move_id" ]]
}
(
  cd "$move_a"
  WORKSPACE_AGENT_CONFIG="$TEST_ROOT/agents-b.tsv" WORKSPACE_AGENT_SILENCE=30 WORKSPACE_AGENT_LAYOUT=vertical \
    inside "$move_shell" workspace --reset >/dev/null
)
wait_for "ci-move to be replaced" move_was_replaced
wait_for "the rebuilt workspace to get its name back" session_exists ci-move
assert_eq "$move_b" "$(tmux show-options -t '=ci-move:' -qv @workspace_root)" "root after a reset typed inside"
assert_eq "bravo charlie " "$(pane_roles ci-move:agent)" "roles after a reset typed inside"
assert_eq "$TEST_ROOT/agents-b.tsv" "$(tmux show-options -t '=ci-move:' -qv @workspace_agent_config)" "config after a reset typed inside"
assert_eq "30" "$(tmux show-window-options -t ci-move:agent -v monitor-silence)" "silence after a reset typed inside"
assert_eq "vertical" "$(tmux show-options -t '=ci-move:' -qv @workspace_agent_layout)" "layout after a reset typed inside"
bravo_pane="$(pane_by_role ci-move:agent bravo)"
charlie_pane="$(pane_by_role ci-move:agent charlie)"
assert_eq "$(pane_option "$bravo_pane" pane_left)" "$(pane_option "$charlie_pane" pane_left)" "vertical agent layout"

# A one-off trust bypass belongs to the command that carried it. It must not
# reach a project that was opened later, neither through the tmux server,
# which keeps the environment it was started with, nor through a shell
# inside the first workspace.
(
  export TMUX_TMPDIR="$TEST_ROOT/tmux2"
  mine="$TEST_ROOT/projects/mine"
  write_agents "$mine/.my-terminal/agents.tsv" 'mine\tMine\tcat'
  for cloned in "$TEST_ROOT/projects/cloned-1" "$TEST_ROOT/projects/cloned-2"; do
    write_agents "$cloned/.my-terminal/agents.tsv" "pwn\tPwn\ttouch $TEST_ROOT/markers/$(basename "$cloned"); cat"
  done

  WORKSPACE_TRUST_PROJECT_CONFIG=1 WORKSPACE_AGENT_CWD=worktree workspace --project --dir "$mine" --no-attach >/dev/null
  assert_eq "mine " "$(pane_roles ws-mine:agent)" "roles with a one-off bypass"
  assert_eq "" "$(tmux show-environment -g | grep '^WORKSPACE_' || true)" "one-off settings in the server environment"
  assert_eq "" "$(tmux show-options -t '=ws-mine:' -qv @workspace_trust_project_config)" "bypass stored on the session"

  notice="$(workspace --project --dir "$TEST_ROOT/projects/cloned-1" --no-attach 2>&1 >/dev/null)"
  assert_contains "$notice" "ignoring untrusted project agent config" "notice for a project opened later"
  assert_eq "agent-1 agent-2 " "$(pane_roles ws-cloned-1:agent)" "roles of a project opened later"
  assert_eq "" "$(tmux show-options -t '=ws-cloned-1:' -qv @workspace_agent_cwd)" "settings of a project opened later"

  mine_shell="$(pane_by_role ws-mine:logs logs-1)"
  # shellcheck disable=SC2016 # expanded by the shell in the pane
  tmux send-keys -t "$mine_shell" "cd '$TEST_ROOT/projects/cloned-2' && "'"$MY_TERMINAL_WORKSPACE_SCRIPT" --project --no-attach' Enter
  wait_for "the project typed inside ws-mine to open" session_exists ws-cloned-2
  # The command runs in a pane, so its workspace is still being built.
  wait_for "its last window to be ready" tmux list-panes -t ws-cloned-2:manual
  assert_eq "agent-1 agent-2 " "$(pane_roles ws-cloned-2:agent)" "roles of a project opened from inside"
  wait_for "its first agent pane to settle" pane_shows "$(pane_by_role ws-cloned-2:agent agent-1)" "command not found in PATH"
)
leftovers="$(find "$TEST_ROOT/markers" -mindepth 1 | head -n 5)"
[[ -z "$leftovers" ]] || fail "an untrusted project config was executed: $leftovers"
TMUX_TMPDIR="$TEST_ROOT/tmux2" tmux kill-server >/dev/null 2>&1 || true
printf 'ok: settings are neither inherited nor left behind\n\n'

# ------------------------------------------------------------------
printf 'Test 18: README showcase layout\n'
SHOWCASE_COLS=120 SHOWCASE_LINES=36 "$SHOWCASE" --session ci-showcase --reset --no-attach >/dev/null
assert_eq "4" "$(tmux list-windows -t '=ci-showcase:' | wc -l | tr -d ' ')" "showcase windows"
assert_eq "4" "$(pane_count ci-showcase:1)" "showcase panes"
printf 'ok: showcase layout created\n\n'

printf 'All workspace tests passed.\n'
