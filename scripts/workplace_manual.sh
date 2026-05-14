#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
CONFIG_FILE="${WORKPLACE_MANUAL_CONFIG:-$REPO_ROOT/configs/zsh/workplace_manual.tsv}"
COLOR_MODE="auto"

usage() {
  cat <<'EOF'
Usage: scripts/workplace_manual.sh [--config FILE] [--color auto|always|never] [--list] [--query TEXT] [--show NAME] [--interactive]

Query the workplace alias/function manual.

Options:
  --config FILE   Read command docs from FILE. Defaults to configs/zsh/workplace_manual.tsv.
  --color MODE    Color output mode: auto, always, or never. Defaults to auto.
  --list          Print the full manual table.
  --query TEXT    Search command name, type, group, command, description, usage, and source.
  --show NAME     Print detailed documentation for one command.
  --interactive   Open an fzf-powered browser when fzf is available; otherwise use a simple prompt.
  --help, -h      Show this help.
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

shell_quote() {
  printf '%q' "$1"
}

ensure_config() {
  [[ -f "$CONFIG_FILE" ]] || die "manual config not found: $CONFIG_FILE"
}

use_color() {
  case "$COLOR_MODE" in
    always) return 0 ;;
    never) return 1 ;;
    auto)
      [[ -t 1 && "${TERM:-}" != "dumb" && -z "${NO_COLOR:-}" ]]
      ;;
    *) die "unknown color mode: $COLOR_MODE" ;;
  esac
}

table_awk() {
  local query="${1:-}"
  local color=0

  use_color && color=1

  ensure_config
  awk -F '\t' -v query="$query" -v color="$color" '
    function c(code, value) {
      return color ? sprintf("\033[%sm%s\033[0m", code, value) : value
    }
    function field(code, value, width) {
      return c(code, sprintf("%-" width "s", value))
    }
    function type_style(value, width) {
      if (value == "alias") {
        return field("33;1", value, width)
      }
      if (value == "function") {
        return field("35;1", value, width)
      }
      return field("37", value, width)
    }
    BEGIN {
      q = tolower(query)
      printf "%s %s %s %s\n", field("36;1", "name", 16), field("35;1", "type", 10), field("34;1", "group", 14), c("1", "description")
      printf "%s %s %s %s\n", field("2", "----", 16), field("2", "----", 10), field("2", "-----", 14), c("2", "-----------")
    }
    /^[[:space:]]*#/ || NF == 0 { next }
    {
      haystack = tolower($1 " " $2 " " $3 " " $4 " " $5 " " $6 " " $7)
      if (q == "" || index(haystack, q) > 0) {
        printf "%s %s %s %s\n", field("36;1", $1, 16), type_style($2, 10), field("34", $3, 14), $5
        found = 1
      }
    }
    END {
      if (q != "" && !found) {
        exit 1
      }
    }
  ' "$CONFIG_FILE"
}

print_table() {
  table_awk
}

query_table() {
  table_awk "$1"
}

entry_markdown() {
  local name="$1"

  ensure_config
  awk -F '\t' -v name="$name" '
    /^[[:space:]]*#/ || NF == 0 { next }
    $1 == name {
      print "# " $1
      print ""
      print "| Field | Value |"
      print "| --- | --- |"
      print "| Type | `" $2 "` |"
      print "| Group | `" $3 "` |"
      print "| Usage | `" $6 "` |"
      print "| Source | `" $7 "` |"
      print ""
      print "## Description"
      print $5
      print ""
      print "## Command"
      print "```sh"
      print $4
      print "```"
      found = 1
      exit
    }
    END {
      if (!found) {
        exit 1
      }
    }
  ' "$CONFIG_FILE"
}

entry_plain() {
  local name="$1"

  ensure_config
  awk -F '\t' -v name="$name" '
    /^[[:space:]]*#/ || NF == 0 { next }
    $1 == name {
      print "Name:        " $1
      print "Type:        " $2
      print "Group:       " $3
      print "Command:     " $4
      print "Description: " $5
      print "Usage:       " $6
      print "Source:      " $7
      found = 1
      exit
    }
    END {
      if (!found) {
        exit 1
      }
    }
  ' "$CONFIG_FILE"
}

entry_ansi() {
  local name="$1"

  ensure_config
  awk -F '\t' -v name="$name" '
    function c(code, value) {
      return sprintf("\033[%sm%s\033[0m", code, value)
    }
    /^[[:space:]]*#/ || NF == 0 { next }
    $1 == name {
      print c("36;1", $1)
      print ""
      print c("2", "type") "        " c("35;1", $2)
      print c("2", "group") "       " c("34;1", $3)
      print c("2", "usage") "       " c("33", $6)
      print c("2", "source") "      " c("2", $7)
      print ""
      print c("1", "Description")
      print $5
      print ""
      print c("1", "Command")
      print c("32", $4)
      found = 1
      exit
    }
    END {
      if (!found) {
        exit 1
      }
    }
  ' "$CONFIG_FILE"
}

show_entry() {
  local name="$1"

  if use_color && command -v bat >/dev/null 2>&1; then
    entry_markdown "$name" | bat --language=markdown --style=plain --color=always
    return 0
  fi

  if use_color; then
    entry_ansi "$name"
  else
    entry_plain "$name"
  fi
}

fzf_lines() {
  ensure_config
  awk -F '\t' '
    function c(code, value) {
      return sprintf("\033[%sm%s\033[0m", code, value)
    }
    function field(code, value, width) {
      return c(code, sprintf("%-" width "s", value))
    }
    function type_style(value, width) {
      if (value == "alias") {
        return field("33;1", value, width)
      }
      if (value == "function") {
        return field("35;1", value, width)
      }
      return field("37", value, width)
    }
    /^[[:space:]]*#/ || NF == 0 { next }
    {
      row = sprintf("%s %s %s %s", field("36;1", $1, 16), type_style($2, 10), field("34", $3, 14), $5)
      printf "%s\t%s\n", $1, row
    }
  ' "$CONFIG_FILE"
}

interactive_manual() {
  local fzf_height_opts=()
  local name
  local preview_cmd
  local query
  local selected

  ensure_config

  if command -v fzf >/dev/null 2>&1; then
    if [[ "${WORKPLACE_MANUAL_FULL_HEIGHT:-0}" == "1" ]]; then
      fzf_height_opts=(--height=100%)
    fi

    preview_cmd="WORKPLACE_MANUAL_CONFIG=$(shell_quote "$CONFIG_FILE") $(shell_quote "$SCRIPT_DIR/workplace_manual.sh") --color always --show {1}"
    selected="$(
      fzf_lines |
        fzf \
          --ansi \
          "${fzf_height_opts[@]}" \
          --prompt='manual> ' \
          --delimiter=$'\t' \
          --with-nth=2 \
          --preview="$preview_cmd" \
          --preview-window=right:60%:wrap \
          --color='fg:252,bg:-1,hl:39,fg+:255,bg+:236,hl+:81,pointer:81,marker:219,prompt:39,spinner:39,header:244,border:240'
    )" || return 0

    name="${selected%%$'\t'*}"
    clear 2>/dev/null || true
    COLOR_MODE="always"
    show_entry "$name"
    return 0
  fi

  COLOR_MODE="always"
  print_table
  if [[ -t 0 ]]; then
    printf '\nSearch manual> '
    IFS= read -r query || return 0
    [[ -n "$query" ]] || return 0
    printf '\n'
    query_table "$query" || printf 'No manual entries matched: %s\n' "$query"
  fi
}

main() {
  local mode="list"
  local value=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config)
        [[ $# -ge 2 ]] || die "--config requires a file"
        CONFIG_FILE="$2"
        shift 2
        ;;
      --color)
        [[ $# -ge 2 ]] || die "--color requires auto, always, or never"
        case "$2" in
          auto|always|never) COLOR_MODE="$2" ;;
          *) die "--color requires auto, always, or never" ;;
        esac
        shift 2
        ;;
      --list)
        mode="list"
        shift
        ;;
      --query)
        [[ $# -ge 2 ]] || die "--query requires text"
        mode="query"
        value="$2"
        shift 2
        ;;
      --show)
        [[ $# -ge 2 ]] || die "--show requires a command name"
        mode="show"
        value="$2"
        shift 2
        ;;
      --interactive)
        mode="interactive"
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

  case "$mode" in
    list) print_table ;;
    query) query_table "$value" ;;
    show) show_entry "$value" ;;
    interactive) interactive_manual ;;
    *) die "unknown mode: $mode" ;;
  esac
}

main "$@"
