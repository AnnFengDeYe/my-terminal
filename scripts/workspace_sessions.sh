#!/usr/bin/env bash
# Session helpers for workspace_layout.sh: exact-match session targets,
# per-project session names, session listing, and the workspace picker.
#
# This file is sourced, not executed. The caller provides die() and the
# WORK_DIR / SESSION / SESSION_TARGET globals.

WORKSPACE_DEFAULT_SESSION="my-terminal-workspace"
WORKSPACE_PROJECT_SESSION_PREFIX="ws-"

# tmux rewrites "." and ":" in session names; do the same up front so later
# lookups use the name tmux actually stored.
workspace_normalize_session_name() {
  local name="$1"

  name="${name//./_}"
  name="${name//:/_}"
  printf '%s\n' "$name"
}

# tmux resolves a bare "-t NAME" by prefix, so "ws-api" would silently match
# "ws-api-v2". "=NAME:" forces an exact session match for every command.
workspace_session_target() {
  printf '=%s:\n' "$1"
}

workspace_session_exists() {
  tmux has-session -t "$(workspace_session_target "$1")" 2>/dev/null
}

workspace_short_hash() {
  local sum

  sum="$(printf '%s' "$1" | cksum)"
  sum="${sum%% *}"
  printf '%06x\n' "$((sum & 0xffffff))"
}

workspace_sanitize_token() {
  local token

  token="$(
    printf '%s' "$1" |
      LC_ALL=C tr -c 'A-Za-z0-9_-' '-' |
      LC_ALL=C sed -e 's/--*/-/g' -e 's/^-//' -e 's/-$//'
  )"
  [[ -n "$token" ]] || token="project"
  printf '%s\n' "${token:0:32}"
}

# Replaces control characters with "?". Names and files from a project are
# shown on the terminal, where an escape sequence or a carriage return could
# hide or rewrite what is being shown.
workspace_printable() {
  LC_ALL=C tr '\000-\010\013-\037\177' '?'
}

workspace_display_path() {
  local path="$1"

  if [[ -n "${HOME:-}" && "$path" == "$HOME" ]]; then
    path="~"
  elif [[ -n "${HOME:-}" && "$path" == "$HOME"/* ]]; then
    # shellcheck disable=SC2088 # a literal "~" is the point: this is display text
    path="~/${path#"$HOME"/}"
  fi

  printf '%s\n' "$path" | workspace_printable
}

# A project is the enclosing git repository when there is one, so running
# from any subdirectory lands in the same workspace.
workspace_project_root() {
  local dir="$1"
  local top=""

  if command -v git >/dev/null 2>&1; then
    top="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null || true)"
  fi

  if [[ -n "$top" && -d "$top" ]]; then
    (cd "$top" && pwd -P)
  else
    printf '%s\n' "$dir"
  fi
}

workspace_session_root() {
  local root
  local target

  target="$(workspace_session_target "$1")"
  root="$(tmux show-options -qv -t "$target" @workspace_root 2>/dev/null || true)"
  if [[ -z "$root" ]]; then
    root="$(tmux display-message -p -t "$target" '#{session_path}' 2>/dev/null || true)"
  fi
  printf '%s\n' "$root"
}

# Prints "name|attached|windows|kind|root" for every managed workspace
# session. Sessions created before @workspace_session existed are recognised
# by their managed windows.
workspace_managed_session_records() {
  local attached
  local kind
  local legacy_names
  local managed
  local name
  local root
  local windows

  legacy_names="$(
    tmux list-windows -a -F '#{@workspace_managed}|#{session_name}' 2>/dev/null |
      sed -n 's/^1|//p' |
      sort -u || true
  )"

  while IFS='|' read -r name attached windows managed kind root; do
    [[ -n "$name" ]] || continue
    if [[ "$managed" != "1" ]]; then
      printf '%s\n' "$legacy_names" | grep -Fxq -- "$name" || continue
    fi
    printf '%s|%s|%s|%s|%s\n' "$name" "$attached" "$windows" "$kind" "$root"
  done < <(
    tmux list-sessions \
      -F '#{session_name}|#{session_attached}|#{session_windows}|#{@workspace_session}|#{@workspace_kind}|#{?@workspace_root,#{@workspace_root},#{session_path}}' \
      2>/dev/null || true
  )
}

workspace_session_is_managed() {
  local attached
  local kind
  local name
  local root
  local windows

  while IFS='|' read -r name attached windows kind root; do
    [[ "$name" == "$1" ]] && return 0
  done < <(workspace_managed_session_records)

  return 1
}

# Finds the project workspace of a directory. The daily workspace and named
# sessions are never returned, even when they were started in that directory:
# --project promises a workspace that belongs to the project.
workspace_find_session_by_root() {
  local attached
  local kind
  local name
  local root
  local windows

  while IFS='|' read -r name attached windows kind root; do
    if [[ "$kind" == "project" && "$root" == "$1" ]]; then
      printf '%s\n' "$name"
      return 0
    fi
  done < <(workspace_managed_session_records)

  return 1
}

workspace_project_session_name() {
  local candidate
  local existing
  local root="$1"

  existing="$(workspace_find_session_by_root "$root" || true)"
  if [[ -n "$existing" ]]; then
    printf '%s\n' "$existing"
    return 0
  fi

  candidate="$WORKSPACE_PROJECT_SESSION_PREFIX$(workspace_sanitize_token "$(basename "$root")")"
  if workspace_session_exists "$candidate"; then
    # Same directory name, different project: keep both apart.
    candidate="$candidate-$(workspace_short_hash "$root")"
  fi
  printf '%s\n' "$candidate"
}

workspace_session_label() {
  local label
  local root="$2"
  local session="$1"

  if [[ "$session" == "$WORKSPACE_DEFAULT_SESSION" ]]; then
    label="workspace"
  elif [[ "$session" == "$WORKSPACE_PROJECT_SESSION_PREFIX"* && -n "$root" ]]; then
    label="$(basename "$root")"
  else
    label="$session"
  fi

  # The status line reads "#[...]" as a style, so a label must not carry "#".
  printf '%s\n' "${label//#/}"
}

# Prints the session this shell is running in.
workspace_current_session_name() {
  local name

  [[ -n "${TMUX:-}" ]] || return 1
  name="$(tmux display-message -p '#{session_name}' 2>/dev/null || true)"
  [[ -n "$name" ]] || return 1
  printf '%s\n' "$name"
}

# Prints the session this shell is running in when it is a managed workspace.
workspace_current_managed_session() {
  local name

  name="$(workspace_current_session_name)" || return 1
  workspace_session_is_managed "$name" || return 1
  printf '%s\n' "$name"
}

workspace_print_sessions() {
  local attached
  local kind
  local name
  local records
  local root
  local state
  local width=7
  local windows

  records="$(workspace_managed_session_records)"
  if [[ -z "$records" ]]; then
    printf 'No workspace sessions are running.\n'
    printf 'Start one with: workplace (daily workspace) or workplace --project (this project)\n'
    return 0
  fi

  while IFS='|' read -r name attached windows kind root; do
    ((${#name} > width)) && width=${#name}
  done <<< "$records"

  printf "%-${width}s  %-8s  %-8s  %-7s  %s\n" "SESSION" "KIND" "ATTACHED" "WINDOWS" "ROOT"
  while IFS='|' read -r name attached windows kind root; do
    state="no"
    [[ "$attached" != "0" ]] && state="yes"
    printf "%-${width}s  %-8s  %-8s  %-7s  %s\n" "$name" "${kind:--}" "$state" "$windows" "$(workspace_display_path "$root")"
  done <<< "$records"
}

workspace_pick_directories() {
  local child
  local parent
  local parents="${WORKSPACE_PICK_DIRS:-}"

  if command -v zoxide >/dev/null 2>&1; then
    zoxide query -l 2>/dev/null | sed -n '1,200p' || true
  fi

  while [[ -n "$parents" ]]; do
    parent="${parents%%:*}"
    if [[ "$parents" == *:* ]]; then
      parents="${parents#*:}"
    else
      parents=""
    fi

    [[ -n "$parent" && -d "$parent" ]] || continue
    for child in "$parent"/*/; do
      [[ -d "$child" ]] || continue
      printf '%s\n' "${child%/}"
    done
  done
}

# Prints "kind<TAB>value<TAB>display" rows: running workspaces first, then
# directories that do not have a workspace yet.
workspace_pick_candidates() {
  local attached
  local dir
  local kind
  local marker
  local name
  local root
  local seen=$'\n'
  local windows

  while IFS='|' read -r name attached windows kind root; do
    [[ -n "$name" ]] || continue
    marker=" "
    [[ "$attached" != "0" ]] && marker="*"
    printf 'session\t%s\t%s %-24s %s\n' "$name" "$marker" "$name" "$(workspace_display_path "$root")"
    [[ "$kind" == "project" ]] && seen+="$root"$'\n'
  done < <(workspace_managed_session_records)

  # A directory is offered as its project: picking any folder of a
  # repository opens the workspace of that repository.
  while IFS= read -r dir; do
    [[ -n "$dir" && -d "$dir" ]] || continue
    dir="$(workspace_project_root "$dir")"
    [[ "$seen" == *$'\n'"$dir"$'\n'* ]] && continue
    seen+="$dir"$'\n'
    printf 'dir\t%s\t+ %-24s %s\n' "$dir" "$(basename "$dir" | workspace_printable)" "$(workspace_display_path "$dir")"
  done < <(workspace_pick_directories)
}

workspace_pick_preview() {
  local kind="$1"
  local value="$2"

  case "$kind" in
    session)
      tmux list-windows -t "$(workspace_session_target "$value")" -F ' #I:#W  #{window_panes} pane(s)' 2>/dev/null || true
      printf '\n'
      tmux capture-pane -e -p -t "$(workspace_session_target "$value")" 2>/dev/null || true
      ;;
    dir)
      printf 'New project workspace: %s\n\n' "$(workspace_display_path "$value")"
      if command -v eza >/dev/null 2>&1; then
        eza --icons=auto --group-directories-first -- "$value" 2>/dev/null || true
      else
        ls -- "$value" 2>/dev/null || true
      fi
      ;;
  esac
}

# Sets PICKED_KIND / PICKED_VALUE for the caller. Returns 1 when the user
# chose nothing, and 2 when the picker could not run.
# shellcheck disable=SC2034 # PICKED_* are read by workspace_layout.sh
workspace_pick_select() {
  local candidates
  local choice
  local count=0
  local display
  local index
  local kind
  local line
  local preview_cmd
  local value

  PICKED_KIND=""
  PICKED_VALUE=""

  candidates="$(workspace_pick_candidates)"
  if [[ -z "$candidates" ]]; then
    printf 'Nothing to pick: no workspace is running and no project directories were found.\n' >&2
    printf 'Visit a few projects so zoxide learns them, or set WORKSPACE_PICK_DIRS=dir1:dir2.\n' >&2
    return 2
  fi

  if command -v fzf >/dev/null 2>&1 && [[ -t 0 && -t 1 ]]; then
    # fzf hands the preview to $SHELL, which may not be a POSIX shell. The
    # command is a constant that passes everything on to sh; the script path
    # travels in the environment, so no path is parsed as code.
    export MY_TERMINAL_WORKSPACE_SCRIPT="$SCRIPT_PATH"
    # shellcheck disable=SC2016 # expanded by the preview shell, not here
    preview_cmd='/bin/sh -c '"'"'"$MY_TERMINAL_WORKSPACE_SCRIPT" --pick-preview "$1" "$2"'"'"' sh {1} {2}'
    line="$(
      printf '%s\n' "$candidates" |
        fzf --prompt='workspace> ' \
          --delimiter=$'\t' \
          --with-nth=3 \
          --no-sort \
          --layout=reverse \
          --header='* attached   + new project workspace' \
          --preview="$preview_cmd" \
          --preview-window=right:55%
    )" || return 1
  else
    [[ -t 0 ]] || {
      printf 'The workspace picker needs an interactive terminal.\n' >&2
      return 2
    }

    while IFS=$'\t' read -r kind value display; do
      count=$((count + 1))
      printf '%3s) %s\n' "$count" "$display"
      [[ "$count" -ge 30 ]] && break
    done <<< "$candidates"

    printf '\nSelect [1-%s]: ' "$count"
    IFS= read -r choice || return 1
    [[ "$choice" =~ ^[0-9]+$ ]] || return 1
    ((choice >= 1 && choice <= count)) || return 1

    index=0
    line=""
    while IFS= read -r display; do
      index=$((index + 1))
      if [[ "$index" == "$choice" ]]; then
        line="$display"
        break
      fi
    done <<< "$candidates"
  fi

  [[ -n "$line" ]] || return 1
  IFS=$'\t' read -r kind value display <<< "$line"
  [[ -n "$kind" && -n "$value" ]] || return 1

  PICKED_KIND="$kind"
  PICKED_VALUE="$value"
}
