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

manual_rows() {
  local query="${1:-}"
  local show_header="${2:-1}"

  ensure_config
  awk -F '\t' -v query="$query" -v show_header="$show_header" '
    BEGIN {
      q = tolower(query)
      if (show_header) {
        print "name\ttype\tgroup\tdescription"
        print "----\t----\t-----\t-----------"
      }
    }
    /^[[:space:]]*#/ || NF == 0 { next }
    {
      haystack = tolower($1 " " $2 " " $3 " " $4 " " $5 " " $6 " " $7)
      if (q == "" || index(haystack, q) > 0) {
        printf "%s\t%s\t%s\t%s\n", $1, $2, $3, $5
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

columnize_manual_rows() {
  if command -v column >/dev/null 2>&1; then
    column -t -s $'\t'
    return 0
  fi

  awk -F '\t' '{ printf "%-16s  %-10s  %-14s  %s\n", $1, $2, $3, $4 }'
}

colorize_manual_columns() {
  local color=0
  local mode="${1:-auto}"

  if [[ "$mode" == "always" ]]; then
    color=1
  elif use_color; then
    color=1
  fi

  awk -v color="$color" '
    function c(code, value) {
      return color ? sprintf("\033[%sm%s\033[0m", code, value) : value
    }
    function styled_type(value) {
      if (value == "alias") {
        return c("33;1", value)
      }
      if (value == "function") {
        return c("35;1", value)
      }
      return c("37", value)
    }
    function next_gap() {
      rest = substr(line, pos)
      if (match(rest, /^ +/)) {
        gap = substr(rest, 1, RLENGTH)
        pos += RLENGTH
        return gap
      }
      return ""
    }
    {
      line = $0
      name = $1
      type = $2
      group = $3
      pos = 1 + length(name)
      sep1 = next_gap()
      pos += length(type)
      sep2 = next_gap()
      pos += length(group)
      sep3 = next_gap()
      description = substr(line, pos)

      if (name == "name" && type == "type" && group == "group") {
        print c("36;1", name) sep1 c("35;1", type) sep2 c("34;1", group) sep3 c("1", description)
      } else if (name == "----" && type == "----" && group == "-----") {
        print c("2", name) sep1 c("2", type) sep2 c("2", group) sep3 c("2", description)
      } else {
        print c("36;1", name) sep1 styled_type(type) sep2 c("34", group) sep3 description
      }
    }
  '
}

table_awk() {
  local query="${1:-}"

  manual_rows "$query" 1 | columnize_manual_rows | colorize_manual_columns
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
  manual_rows "" 0 | columnize_manual_rows | colorize_manual_columns always
}

interactive_manual() {
  local fzf_args
  local name
  local preview_cmd
  local query
  local selected

  ensure_config

  if command -v fzf >/dev/null 2>&1; then
    preview_cmd="WORKPLACE_MANUAL_CONFIG=$(shell_quote "$CONFIG_FILE") $(shell_quote "$SCRIPT_DIR/workplace_manual.sh") --color always --show {1}"
    fzf_args=(
      --ansi
      --prompt='manual> '
      '--delimiter=[[:space:]][[:space:]]+'
      '--nth=1,3'
      --preview="$preview_cmd"
      --preview-window=right:60%:wrap
      '--bind=ctrl-/:toggle-preview'
      '--color=fg:252,bg:-1,hl:39,fg+:255,bg+:236,hl+:81,pointer:81,marker:219,prompt:39,spinner:39,header:244,border:240'
    )
    if [[ "${WORKPLACE_MANUAL_FULL_HEIGHT:-0}" == "1" ]]; then
      fzf_args+=(--height=100%)
    fi

    selected="$(
      fzf_lines |
        fzf "${fzf_args[@]}"
    )" || return 0

    name="${selected%%[[:space:]]*}"
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
