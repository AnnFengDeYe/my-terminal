#!/usr/bin/env bash
# Agent helpers for workspace_layout.sh: project config trust, per-agent
# working directories, git worktree isolation, and prompt broadcast.
#
# This file is sourced, not executed. The caller provides die(),
# workspace_agent_config_file(), window_id_by_name(), and the WORK_DIR /
# SESSION globals. workspace_sessions.sh must be sourced first.

workspace_state_dir() {
  printf '%s\n' "${XDG_STATE_HOME:-${HOME:-}/.local/state}/my-terminal"
}

workspace_data_dir() {
  printf '%s\n' "${XDG_DATA_HOME:-${HOME:-}/.local/share}/my-terminal"
}

# ------------------------------------------------------------------
# Project config trust
#
# .my-terminal/agents.tsv lives inside a project and names commands that
# start automatically, so a freshly cloned repository must not be able to
# run anything until its config has been reviewed.
# ------------------------------------------------------------------

workspace_project_agent_config() {
  printf '%s\n' "$WORK_DIR/.my-terminal/agents.tsv"
}

# Prints the SHA-256 of a file. Fails when no tool can compute one: a weaker
# checksum would let different content pass as the file that was reviewed.
workspace_file_checksum() {
  local file="$1"
  local sum=""

  if command -v sha256sum >/dev/null 2>&1; then
    sum="$(sha256sum < "$file" | awk '{ print $1 }')"
  elif command -v shasum >/dev/null 2>&1; then
    sum="$(shasum -a 256 < "$file" | awk '{ print $1 }')"
  elif command -v openssl >/dev/null 2>&1; then
    sum="$(openssl dgst -sha256 < "$file" | awk '{ print $NF }')"
  fi

  [[ "${#sum}" == "64" ]] || return 1
  printf '%s\n' "$sum"
}

workspace_trust_record() {
  local file="$1"
  local key

  key="$(printf '%s' "$file" | cksum | awk '{ print $1 "-" $2 }')"
  printf '%s/trust/%s\n' "$(workspace_state_dir)" "$key"
}

workspace_project_config_is_trusted() {
  local current_sum
  local file="$1"
  local record
  local stored_path=""
  local stored_sum=""

  [[ "${WORKSPACE_TRUST_PROJECT_CONFIG:-0}" == "1" ]] && return 0

  record="$(workspace_trust_record "$file")"
  [[ -f "$record" ]] || return 1

  {
    IFS= read -r stored_sum || true
    IFS= read -r stored_path || true
  } < "$record"

  [[ "$stored_path" == "$file" ]] || return 1
  current_sum="$(workspace_file_checksum "$file")" || return 1
  [[ -n "$stored_sum" && "$stored_sum" == "$current_sum" ]]
}

# Prints the project config path when it exists but has not been trusted.
workspace_untrusted_project_config() {
  local file

  [[ -z "${WORKSPACE_AGENT_CONFIG:-}" ]] || return 1
  file="$(workspace_project_agent_config)"
  [[ -f "$file" ]] || return 1
  workspace_project_config_is_trusted "$file" && return 1
  printf '%s\n' "$file"
}

workspace_print_untrusted_notice() {
  local file="$1"

  printf 'notice: ignoring untrusted project agent config: %s\n' "$(workspace_display_path "$file")"
  printf '        review it, then run: workplace --trust\n'
}

workspace_trust_project_config() {
  local file
  local record
  local sum

  file="$(workspace_project_agent_config)"
  [[ -f "$file" ]] || die "no project agent config to trust: $file"
  sum="$(workspace_file_checksum "$file")" ||
    die "trust needs sha256sum, shasum, or openssl to fingerprint the config"

  # Shown with control characters replaced, so the file cannot hide a row
  # from the person reviewing it.
  printf 'Project agent config: %s\n\n' "$(workspace_display_path "$file")"
  workspace_printable < "$file" | sed -e 's/^/    /'
  printf '\n'

  record="$(workspace_trust_record "$file")"
  mkdir -p "$(dirname "$record")"
  printf '%s\n%s\n' "$sum" "$file" > "$record"

  printf 'Trusted. These commands will start in the agent window of this project.\n'
  printf 'Editing the file revokes trust until you run workplace --trust again.\n'
}

# ------------------------------------------------------------------
# Per-agent working directory
# ------------------------------------------------------------------

# Prints the raw cwd setting for a role: the 4th agents.tsv column, falling
# back to WORKSPACE_AGENT_CWD. Empty means the workspace directory.
workspace_agent_cwd_spec() {
  local config_file
  local role="$1"
  local spec=""

  config_file="$(workspace_agent_config_file || true)"
  if [[ -n "$config_file" && -f "$config_file" ]]; then
    spec="$(
      awk -F '\t+' -v role="$role" '
        /^[[:space:]]*#/ { next }
        {
          name = $1
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
          if (name == role) {
            cwd = $4
            sub(/\r$/, "", cwd)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", cwd)
            print cwd
            exit
          }
        }
      ' "$config_file"
    )"
  fi

  [[ -n "$spec" ]] || spec="${WORKSPACE_AGENT_CWD:-}"
  printf '%s\n' "$spec"
}

workspace_git_common_dir() {
  local common
  local dir="$1"

  command -v git >/dev/null 2>&1 || return 1
  common="$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null)" || return 1
  [[ -n "$common" ]] || return 1
  [[ "$common" == /* ]] || common="$dir/$common"
  [[ -d "$common" ]] || return 1
  (cd "$common" && pwd -P)
}

# Directory holding this repository's agent worktrees. It lives outside the
# repository so editors, search tools, and language servers never see a
# second copy of the code.
workspace_worktree_base() {
  local common
  local repo_name
  local root

  common="$(workspace_git_common_dir "$WORK_DIR")" || return 1
  if [[ "$(basename "$common")" == ".git" ]]; then
    repo_name="$(basename "$(dirname "$common")")"
  else
    repo_name="$(basename "$common")"
    repo_name="${repo_name%.git}"
  fi

  root="${WORKSPACE_WORKTREE_ROOT:-$(workspace_data_dir)/worktrees}"
  printf '%s/%s-%s\n' "$root" "$(workspace_sanitize_token "$repo_name")" "$(workspace_short_hash "$common")"
}

workspace_agent_worktree_path() {
  local base
  local role="$1"

  [[ -n "$role" && "$role" != "." && "$role" != ".." ]] || return 1
  base="$(workspace_worktree_base)" || return 1
  printf '%s/%s\n' "$base" "$role"
}

workspace_agent_branch() {
  printf '%s%s\n' "${WORKSPACE_WORKTREE_BRANCH_PREFIX:-agent/}" "$1"
}

# Creates the worktree for a role when it does not exist yet. Panes start in
# parallel, so creation is serialised with a lock directory.
workspace_ensure_agent_worktree() {
  local branch
  local common
  local lock
  local path
  local role="$1"
  local status=0

  path="$(workspace_agent_worktree_path "$role")" || {
    printf 'worktree: %s is not inside a git repository\n' "$WORK_DIR"
    return 1
  }
  [[ -e "$path/.git" ]] && return 0

  branch="$(workspace_agent_branch "$role")"
  git check-ref-format --branch "$branch" >/dev/null 2>&1 || {
    printf 'worktree: %s is not a valid branch name\n' "$branch"
    return 1
  }

  common="$(workspace_git_common_dir "$WORK_DIR")" || return 1
  lock="$common/my-terminal-worktree.lock"
  workspace_lock_worktrees "$lock"

  if [[ ! -e "$path/.git" ]]; then
    printf 'worktree: creating %s on branch %s\n' "$path" "$branch"
    mkdir -p "$(dirname "$path")"
    if git -C "$WORK_DIR" show-ref --verify --quiet "refs/heads/$branch"; then
      git -C "$WORK_DIR" worktree add "$path" "$branch" || status=$?
    else
      git -C "$WORK_DIR" worktree add -b "$branch" "$path" HEAD || status=$?
    fi
  fi

  workspace_unlock_worktrees "$lock"
  return "$status"
}

# Panes start in parallel and each may create a worktree, so creation takes
# turns. The lock records its owner: a lock whose owner is gone is stale and
# is taken over at once instead of being waited for.
workspace_lock_worktrees() {
  local lock="$1"
  local owner
  local owner_pattern='^[0-9]+$'
  local waited=0

  until mkdir "$lock" 2>/dev/null; do
    # No lock directory means mkdir failed for another reason, such as a
    # read-only repository. Waiting would not change that.
    [[ -d "$lock" ]] || return 0

    owner="$(cat "$lock/pid" 2>/dev/null || true)"
    if [[ "$owner" =~ $owner_pattern ]] && ! kill -0 "$owner" 2>/dev/null; then
      rm -f "$lock/pid"
      rmdir "$lock" 2>/dev/null || true
      continue
    fi

    waited=$((waited + 1))
    [[ "$waited" == "1" ]] && printf 'worktree: waiting for another pane to finish creating its worktree\n'
    # An owner that never wrote its id was killed right after taking the lock.
    if [[ -z "$owner" && "$waited" -gt 10 ]] || [[ "$waited" -gt 240 ]]; then
      rm -f "$lock/pid"
      rmdir "$lock" 2>/dev/null || true
      continue
    fi
    sleep 0.5
  done

  printf '%s\n' "$$" > "$lock/pid"
}

workspace_unlock_worktrees() {
  local lock="$1"

  [[ "$(cat "$lock/pid" 2>/dev/null || true)" == "$$" ]] || return 0
  rm -f "$lock/pid"
  rmdir "$lock" 2>/dev/null || true
}

# Prints the directory an agent pane should start in. Diagnostics go to
# stderr so the pane shows them above the agent.
workspace_prepare_agent_dir() {
  local path=""
  local role="$1"
  local spec

  spec="$(workspace_agent_cwd_spec "$role")"
  # shellcheck disable=SC2088 # agents.tsv is not shell: expand "~" by hand
  case "$spec" in
    ""|".")
      printf '%s\n' "$WORK_DIR"
      return 0
      ;;
    worktree)
      if workspace_ensure_agent_worktree "$role" >&2; then
        workspace_agent_worktree_path "$role"
        return 0
      fi
      printf 'worktree: unavailable for %s; using %s\n\n' "$role" "$WORK_DIR" >&2
      printf '%s\n' "$WORK_DIR"
      return 0
      ;;
    "~") path="${HOME:-}" ;;
    "~/"*) path="${HOME:-}/${spec#"~/"}" ;;
    /*) path="$spec" ;;
    *) path="$WORK_DIR/$spec" ;;
  esac

  if [[ -n "$path" && -d "$path" ]]; then
    (cd "$path" && pwd -P)
  else
    printf 'agent cwd not found for %s: %s; using %s\n\n' "$role" "$spec" "$WORK_DIR" >&2
    printf '%s\n' "$WORK_DIR"
  fi
}

# Records whether the agent is running, together with the process that says
# so. A pane that is respawned with another command gets a new process id,
# which makes a stale "running" recognisable.
workspace_set_agent_state() {
  [[ -n "${TMUX_PANE:-}" ]] || return 0
  tmux set-option -p -t "$TMUX_PANE" @workspace_agent_state "$1" >/dev/null 2>&1 || true
  tmux set-option -p -t "$TMUX_PANE" @workspace_agent_pid "$$" >/dev/null 2>&1 || true
}

workspace_is_shell_name() {
  local name="${1##*/}"

  case "${name#-}" in
    sh|bash|zsh|fish|dash|ash|ksh|mksh|pdksh|tcsh|csh|nu|elvish|xonsh|pwsh|busybox) return 0 ;;
  esac

  return 1
}

# ------------------------------------------------------------------
# Worktree listing and cleanup
# ------------------------------------------------------------------

# Prints "role|branch|path" for each agent worktree of this repository.
workspace_agent_worktree_records() {
  local base
  local branch=""
  local line
  local path=""
  local real_path

  base="$(workspace_worktree_base)" || return 0
  [[ -d "$base" ]] || return 0
  base="$(cd "$base" && pwd -P)"

  while IFS= read -r line; do
    case "$line" in
      "worktree "*)
        path="${line#worktree }"
        branch=""
        ;;
      "branch "*)
        branch="${line#branch }"
        branch="${branch#refs/heads/}"
        ;;
      "")
        if [[ -n "$path" ]]; then
          real_path="$path"
          [[ -d "$path" ]] && real_path="$(cd "$path" && pwd -P)"
          if [[ "$real_path" == "$base"/* ]]; then
            printf '%s|%s|%s\n' "$(basename "$real_path")" "$branch" "$real_path"
          fi
        fi
        path=""
        branch=""
        ;;
    esac
  done < <(
    git -C "$WORK_DIR" worktree list --porcelain 2>/dev/null || true
    printf '\n'
  )
}

workspace_worktree_is_dirty() {
  local changes

  changes="$(git -C "$1" status --porcelain 2>/dev/null || true)"
  [[ -n "$changes" ]]
}

# The checkout agent work is merged into: the workspace directory, unless
# that is itself an agent worktree, in which case the repository's main
# checkout. Measuring a branch against its own worktree would always say
# "merged".
workspace_reference_checkout() {
  local base
  local line
  local here

  here="$(cd "$WORK_DIR" && pwd -P)"
  base="$(workspace_worktree_base)" || {
    printf '%s\n' "$here"
    return 0
  }
  [[ -d "$base" ]] && base="$(cd "$base" && pwd -P)"

  if [[ "$here" != "$base"/* ]]; then
    printf '%s\n' "$here"
    return 0
  fi

  while IFS= read -r line; do
    if [[ "$line" == "worktree "* ]]; then
      printf '%s\n' "${line#worktree }"
      return 0
    fi
  done < <(git -C "$WORK_DIR" worktree list --porcelain 2>/dev/null || true)

  printf '%s\n' "$here"
}

# Commits on the agent branch that the reference checkout does not have yet.
# Prints "unknown" when git cannot tell, for example on a branch without
# commits. Unknown must never be read as "nothing to lose".
workspace_worktree_unmerged_count() {
  local branch="$1"
  local count

  count="$(git -C "$(workspace_reference_checkout)" rev-list --count "HEAD..$branch" 2>/dev/null || true)"
  [[ "$count" =~ ^[0-9]+$ ]] || count="unknown"
  printf '%s\n' "$count"
}

workspace_worktree_in_use() {
  local here
  local pane_path
  local path="$1"

  here="$(pwd -P)"
  [[ "$here" == "$path" || "$here" == "$path"/* ]] && return 0

  command -v tmux >/dev/null 2>&1 || return 1
  while IFS= read -r pane_path; do
    [[ "$pane_path" == "$path" || "$pane_path" == "$path"/* ]] && return 0
  done < <(tmux list-panes -a -F '#{pane_current_path}' 2>/dev/null || true)

  return 1
}

workspace_worktree_state() {
  local branch="$1"
  local path="$2"
  local state=""
  local unmerged

  if [[ ! -d "$path" ]]; then
    printf 'missing\n'
    return 0
  fi

  if workspace_worktree_is_dirty "$path"; then
    state="uncommitted changes"
  else
    state="clean"
  fi

  if [[ -n "$branch" ]]; then
    unmerged="$(workspace_worktree_unmerged_count "$branch")"
    case "$unmerged" in
      0) ;;
      unknown) state+=", cannot compare with the current checkout" ;;
      *) state+=", $unmerged unmerged commit(s)" ;;
    esac
  else
    state+=", detached"
  fi

  workspace_worktree_in_use "$path" && state+=", in use"
  printf '%s\n' "$state"
}

workspace_print_worktrees() {
  local branch
  local path
  local records
  local role

  workspace_git_common_dir "$WORK_DIR" >/dev/null || die "not a git repository: $WORK_DIR"

  records="$(workspace_agent_worktree_records)"
  if [[ -z "$records" ]]; then
    printf 'No agent worktrees for %s\n' "$(workspace_display_path "$WORK_DIR")"
    printf 'Enable them with: workplace --agent-worktrees, or set the cwd column to "worktree" in agents.tsv\n'
    return 0
  fi

  while IFS='|' read -r role branch path; do
    printf '%s\n' "$role"
    printf '  branch: %s\n' "${branch:-(detached)}"
    printf '  state:  %s\n' "$(workspace_worktree_state "$branch" "$path")"
    printf '  path:   %s\n' "$(workspace_display_path "$path")"
  done <<< "$records"

  printf '\nMerge agent work from %s, for example: git merge <branch>\n' "$(workspace_display_path "$(workspace_reference_checkout)")"
  printf 'Remove finished worktrees with: workplace --prune-worktrees\n'
}

# Removes only worktrees that cannot lose work: no uncommitted changes, no
# unmerged commits, and no pane running inside them.
workspace_prune_worktrees() {
  local apply="$1"
  local branch
  local kept=0
  local path
  local records
  local reference
  local removable=0
  local role
  local unmerged

  workspace_git_common_dir "$WORK_DIR" >/dev/null || die "not a git repository: $WORK_DIR"
  reference="$(workspace_reference_checkout)"

  records="$(workspace_agent_worktree_records)"
  if [[ -z "$records" ]]; then
    printf 'No agent worktrees for %s\n' "$(workspace_display_path "$WORK_DIR")"
    return 0
  fi

  while IFS='|' read -r role branch path; do
    if [[ ! -d "$path" ]]; then
      printf 'keep:   %s (directory is missing; run git worktree prune)\n' "$role"
      kept=$((kept + 1))
      continue
    fi

    if workspace_worktree_in_use "$path"; then
      printf 'keep:   %s (a shell or pane is running inside it)\n' "$role"
      kept=$((kept + 1))
      continue
    fi

    if workspace_worktree_is_dirty "$path"; then
      printf 'keep:   %s (uncommitted changes)\n' "$role"
      kept=$((kept + 1))
      continue
    fi

    if [[ -z "$branch" ]]; then
      printf 'keep:   %s (detached HEAD)\n' "$role"
      kept=$((kept + 1))
      continue
    fi

    unmerged="$(workspace_worktree_unmerged_count "$branch")"
    if [[ "$unmerged" == "unknown" ]]; then
      printf 'keep:   %s (cannot compare %s with the current checkout)\n' "$role" "$branch"
      kept=$((kept + 1))
      continue
    fi
    if [[ "$unmerged" != "0" ]]; then
      printf 'keep:   %s (%s unmerged commit(s) on %s)\n' "$role" "$unmerged" "$branch"
      kept=$((kept + 1))
      continue
    fi

    removable=$((removable + 1))
    if [[ "$apply" != "1" ]]; then
      printf 'would remove: %s (%s)\n' "$role" "$(workspace_display_path "$path")"
      continue
    fi

    if git -C "$reference" worktree remove "$path"; then
      git -C "$reference" branch -d "$branch" >/dev/null 2>&1 ||
        printf 'note:   kept branch %s\n' "$branch"
      printf 'removed: %s (%s)\n' "$role" "$(workspace_display_path "$path")"
    else
      printf 'keep:   %s (git refused to remove it)\n' "$role"
      removable=$((removable - 1))
      kept=$((kept + 1))
    fi
  done <<< "$records"

  if [[ "$apply" != "1" && "$removable" -gt 0 ]]; then
    printf '\nNo changes made. Re-run with --yes to remove %s worktree(s).\n' "$removable"
  fi
  printf '\nSummary: %s removable, %s kept\n' "$removable" "$kept"
}

# ------------------------------------------------------------------
# Prompt broadcast
# ------------------------------------------------------------------

workspace_lowercase() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

workspace_send_matches_filter() {
  local filter="$1"
  local role="$2"
  local title="$3"

  [[ -n "$filter" ]] || return 0
  # "alpha, beta" means the same as "alpha,beta".
  filter="$(printf '%s' "$filter" | sed -e 's/[[:space:]]*,[[:space:]]*/,/g' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  filter=",$(workspace_lowercase "$filter"),"
  [[ "$filter" == *",$(workspace_lowercase "$role"),"* ]] && return 0
  [[ -n "$title" && "$filter" == *",$(workspace_lowercase "$title"),"* ]] && return 0
  return 1
}

# A pane at a shell prompt would execute pasted text, including any command
# substitution inside a prompt. A pane qualifies only when the workspace
# started the agent and that same process still owns the pane, or when the
# program in the foreground is the configured agent itself. Anything else,
# such as ssh, a REPL, or a shell inside a wrapper, is left alone.
workspace_pane_runs_agent() {
  local agent_pid="$2"
  local command="$4"
  local executable="$5"
  local pane_pid="$3"
  local state="$1"

  if [[ "$state" == "running" && -n "$agent_pid" && "$agent_pid" == "$pane_pid" ]]; then
    return 0
  fi

  [[ -n "$executable" && -n "$command" ]] || return 1
  workspace_is_shell_name "$executable" && return 1
  [[ "${command#-}" == "${executable##*/}" ]]
}

# Asks tmux about one pane right now. Panes are served one after another, so
# what was true when the list was read may no longer be true for this pane.
workspace_pane_runs_agent_now() {
  local agent_pid
  local command
  local executable="$2"
  local pane_id="$1"
  local pane_pid
  local state

  IFS='|' read -r state agent_pid pane_pid command < <(
    tmux display-message -p -t "$pane_id" \
      '#{@workspace_agent_state}|#{@workspace_agent_pid}|#{pane_pid}|#{pane_current_command}' 2>/dev/null ||
      printf '|||\n'
  ) || true

  workspace_pane_runs_agent "${state:-}" "${agent_pid:-}" "${pane_pid:-}" "${command:-}" "$executable"
}

# Drops input that was typed or pasted but not read yet. An agent that exits
# leaves its pane to a shell, and that shell must not find a prompt waiting.
workspace_discard_pending_input() {
  [[ -t 0 ]] || return 0
  command -v perl >/dev/null 2>&1 || return 0
  perl -MPOSIX -e 'POSIX::tcflush(0, POSIX::TCIFLUSH)' 2>/dev/null || true
}

# Prints the program a role is configured to run, without arguments.
workspace_agent_executable() {
  local command
  local role
  local title

  IFS='|' read -r role title command < <(workspace_agent_record_by_role "$1" || true) || true
  [[ -n "${command:-}" ]] || return 0
  agent_command_executable "$command" || true
}

workspace_send_to_agents() {
  local buffer="workspace-send-$$"
  local delay="${WORKSPACE_SEND_DELAY:-0.2}"
  local enter="$3"
  local executable
  local filter="$2"
  local in_mode
  local matched=0
  local pane_id
  local role
  local sent=0
  local text="$1"
  local title
  local window_id

  [[ -n "$text" ]] || die "--send needs text to send"
  window_id="$(window_id_by_name agent || true)"
  [[ -n "$window_id" ]] || die "workspace session has no agent window: $SESSION"

  tmux set-buffer -b "$buffer" -- "$text"

  while IFS='|' read -r pane_id role in_mode title; do
    [[ -n "$pane_id" && -n "$role" ]] || continue
    workspace_send_matches_filter "$filter" "$role" "$title" || continue
    matched=$((matched + 1))
    executable="$(workspace_agent_executable "$role")"

    if ! workspace_pane_runs_agent_now "$pane_id" "$executable"; then
      printf 'skip: %s (%s) is not running its agent\n' "$role" "${title:-$role}"
      continue
    fi

    # Keys sent to a pane in copy mode go to copy mode, not to the agent.
    if [[ "$in_mode" == "1" ]]; then
      tmux send-keys -t "$pane_id" -X cancel >/dev/null 2>&1 || true
    fi

    tmux paste-buffer -p -b "$buffer" -t "$pane_id"
    if [[ "$enter" == "1" ]]; then
      sleep "$delay"
      if ! workspace_pane_runs_agent_now "$pane_id" "$executable"; then
        printf 'skip: %s (%s) stopped before the text was submitted\n' "$role" "${title:-$role}"
        continue
      fi
      tmux send-keys -t "$pane_id" Enter
    fi
    printf 'sent: %s (%s)\n' "$role" "${title:-$role}"
    sent=$((sent + 1))
  done < <(
    tmux list-panes -t "$window_id" \
      -F '#{pane_id}|#{@workspace_pane_role}|#{pane_in_mode}|#{@workspace_pane_title}' \
      2>/dev/null || true
  )

  tmux delete-buffer -b "$buffer" >/dev/null 2>&1 || true

  if [[ "$matched" == "0" ]]; then
    printf 'No agent pane matched: %s\n' "${filter:-all}" >&2
    return 1
  fi
  [[ "$sent" -gt 0 ]]
}
