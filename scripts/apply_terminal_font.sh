#!/usr/bin/env bash
set -euo pipefail

TARGET_HOME="${TEST_HOME:-$HOME}"
DRY_RUN=0
YES=0
SKIP_FONT_CHECK=0
FONT_FAMILY="JetBrainsMono Nerd Font Mono"
FONT_SIZE="11"

usage() {
  cat <<'EOF'
Usage: scripts/apply_terminal_font.sh [--dry-run] [--yes] [--font-family NAME] [--font-size SIZE]

Applies the configured Nerd Font to supported terminal emulators:
LXTerminal, Ghostty, Kitty, Foot, and conservative Alacritty defaults.
Without --yes, no files are modified.
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '%s\n' "$*"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      --yes)
        YES=1
        shift
        ;;
      --font-family)
        [[ $# -ge 2 ]] || die "--font-family requires a value"
        FONT_FAMILY="$2"
        shift 2
        ;;
      --font-size)
        [[ $# -ge 2 ]] || die "--font-size requires a value"
        FONT_SIZE="$2"
        shift 2
        ;;
      --skip-font-check)
        SKIP_FONT_CHECK=1
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
}

validate() {
  [[ -n "$TARGET_HOME" ]] || die "target HOME is empty"
  [[ "$TARGET_HOME" == /* ]] || die "target HOME must be absolute: $TARGET_HOME"
  [[ "$TARGET_HOME" != "/" ]] || die "refusing to use / as HOME"
  [[ "$FONT_SIZE" =~ ^[0-9]+$ ]] || die "font size must be numeric"
}

timestamp() {
  date +%Y%m%d-%H%M%S
}

backup_copy() {
  local target="$1"
  local backup
  local i=1

  [[ "$target" == "$TARGET_HOME"/* ]] || die "target is outside HOME: $target"
  [[ -e "$target" || -L "$target" ]] || return 0

  backup="${target}.backup.$(timestamp)"
  while [[ -e "$backup" || -L "$backup" ]]; do
    backup="${target}.backup.$(timestamp).$i"
    i=$((i + 1))
  done

  if [[ "$DRY_RUN" == "1" ]]; then
    log "backup: would copy $target -> $backup"
    return 0
  fi

  cp -p "$target" "$backup"
  log "backup: copied $target -> $backup"
}

check_font_available() {
  local match

  [[ "$SKIP_FONT_CHECK" == "1" ]] && return 0

  if ! command -v fc-match >/dev/null 2>&1; then
    log "notice: fc-match not found; skipping fontconfig verification"
    return 0
  fi

  match="$(fc-match "$FONT_FAMILY" 2>/dev/null || true)"
  if printf '%s\n' "$match" | grep -Eiq 'Nerd|JetBrainsMonoNerd|JetBrains.*Nerd'; then
    log "font: matched $match"
    return 0
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    log "dry-run: font $FONT_FAMILY is not currently matched; installer should run first"
    return 0
  fi

  die "font $FONT_FAMILY is not available to fontconfig; run install_nerd_font.sh first"
}

write_or_replace_line() {
  local target="$1"
  local pattern="$2"
  local replacement="$3"
  local tmp

  mkdir -p "$(dirname "$target")"
  tmp="$(mktemp "${TMPDIR:-/tmp}/terminal-font.XXXXXX")"

  if [[ -f "$target" ]]; then
    awk -v pattern="$pattern" -v replacement="$replacement" '
      BEGIN { changed=0 }
      $0 ~ pattern && changed == 0 {
        print replacement
        changed=1
        next
      }
      { print }
      END {
        if (changed == 0) {
          print replacement
        }
      }
    ' "$target" > "$tmp"
  else
    printf '%s\n' "$replacement" > "$tmp"
  fi

  mv "$tmp" "$target"
}

append_line_if_missing() {
  local target="$1"
  local line="$2"

  mkdir -p "$(dirname "$target")"
  if [[ -f "$target" ]] && grep -Fxq "$line" "$target"; then
    return 0
  fi

  printf '%s\n' "$line" >> "$target"
}

write_lxterminal_config() {
  local target="$1"
  local tmp
  local font_line="fontname=$FONT_FAMILY $FONT_SIZE"

  mkdir -p "$(dirname "$target")"
  tmp="$(mktemp "${TMPDIR:-/tmp}/lxterminal.XXXXXX")"

  if [[ -f "$target" ]]; then
    awk -v font_line="$font_line" '
      BEGIN { in_general=0; seen_general=0; set_font=0 }
      /^\[general\]$/ {
        if (in_general && !set_font) { print font_line; set_font=1 }
        in_general=1; seen_general=1; print; next
      }
      /^\[/ {
        if (in_general && !set_font) { print font_line; set_font=1 }
        in_general=0; print; next
      }
      in_general && /^fontname=/ {
        if (!set_font) { print font_line; set_font=1 }
        next
      }
      { print }
      END {
        if (!seen_general) {
          print "[general]"
          print font_line
        } else if (in_general && !set_font) {
          print font_line
        }
      }
    ' "$target" > "$tmp"
  else
    {
      printf '[general]\n'
      printf '%s\n' "$font_line"
    } > "$tmp"
  fi

  mv "$tmp" "$target"
}

apply_ini_terminal() {
  local name="$1"
  local target="$2"
  local command_name="$3"
  local line="$4"
  local pattern="$5"

  if ! command -v "$command_name" >/dev/null 2>&1 && [[ ! -e "$target" ]]; then
    log "skip: $name not found"
    return 1
  fi

  log "apply: $name -> $target"
  if [[ "$DRY_RUN" == "1" ]]; then
    [[ -e "$target" ]] && backup_copy "$target"
    log "dry-run: would set $line"
    return 0
  fi

  [[ "$YES" == "1" ]] || die "no changes made; pass --dry-run to preview or --yes to apply terminal font"
  backup_copy "$target"
  write_or_replace_line "$target" "$pattern" "$line"
  log "applied: $name font set to $FONT_FAMILY $FONT_SIZE"
}

apply_lxterminal() {
  local target="$TARGET_HOME/.config/lxterminal/lxterminal.conf"

  if ! command -v lxterminal >/dev/null 2>&1 && [[ ! -e "$target" ]]; then
    log "skip: LXTerminal not found"
    return 1
  fi

  log "apply: LXTerminal -> $target"
  if [[ "$DRY_RUN" == "1" ]]; then
    [[ -e "$target" ]] && backup_copy "$target"
    log "dry-run: would set fontname=$FONT_FAMILY $FONT_SIZE"
    return 0
  fi

  [[ "$YES" == "1" ]] || die "no changes made; pass --dry-run to preview or --yes to apply terminal font"
  backup_copy "$target"
  write_lxterminal_config "$target"
  log "applied: LXTerminal font set to $FONT_FAMILY $FONT_SIZE"
}

apply_ghostty() {
  local targets=(
    "$TARGET_HOME/.config/ghostty/config"
    "$TARGET_HOME/Library/Application Support/com.mitchellh.ghostty/config"
  )
  local target=""
  local t

  for t in "${targets[@]}"; do
    if [[ -e "$t" ]]; then
      target="$t"
      break
    fi
  done

  if [[ -z "$target" ]]; then
    if command -v ghostty >/dev/null 2>&1; then
      target="${targets[0]}"
    else
      log "skip: Ghostty not found"
      return 1
    fi
  fi

  log "apply: Ghostty -> $target"
  if [[ "$DRY_RUN" == "1" ]]; then
    [[ -e "$target" ]] && backup_copy "$target"
    log "dry-run: would set font-family = $FONT_FAMILY"
    log "dry-run: would set font-size = $FONT_SIZE"
    return 0
  fi

  [[ "$YES" == "1" ]] || die "no changes made; pass --dry-run to preview or --yes to apply terminal font"
  backup_copy "$target"
  write_or_replace_line "$target" '^[[:space:]]*font-family[[:space:]]*=' "font-family = $FONT_FAMILY"
  write_or_replace_line "$target" '^[[:space:]]*font-size[[:space:]]*=' "font-size = $FONT_SIZE"
  log "applied: Ghostty font set to $FONT_FAMILY $FONT_SIZE"
}

apply_kitty() {
  if apply_ini_terminal \
    "Kitty" \
    "$TARGET_HOME/.config/kitty/kitty.conf" \
    "kitty" \
    "font_family $FONT_FAMILY" \
    '^[[:space:]]*font_family[[:space:]]+'
  then
    if [[ "$DRY_RUN" != "1" ]]; then
      write_or_replace_line "$TARGET_HOME/.config/kitty/kitty.conf" '^[[:space:]]*font_size[[:space:]]+' "font_size $FONT_SIZE"
    else
      log "dry-run: would set font_size $FONT_SIZE"
    fi
    return 0
  fi

  return 1
}

apply_foot() {
  local target="$TARGET_HOME/.config/foot/foot.ini"
  local line="font=$FONT_FAMILY:size=$FONT_SIZE"

  if ! command -v foot >/dev/null 2>&1 && [[ ! -e "$target" ]]; then
    log "skip: Foot not found"
    return 1
  fi

  log "apply: Foot -> $target"
  if [[ "$DRY_RUN" == "1" ]]; then
    [[ -e "$target" ]] && backup_copy "$target"
    log "dry-run: would set $line under [main]"
    return 0
  fi

  [[ "$YES" == "1" ]] || die "no changes made; pass --dry-run to preview or --yes to apply terminal font"
  backup_copy "$target"
  mkdir -p "$(dirname "$target")"
  if [[ ! -e "$target" ]]; then
    printf '[main]\n%s\n' "$line" > "$target"
  elif grep -q '^[[:space:]]*font=' "$target"; then
    write_or_replace_line "$target" '^[[:space:]]*font=' "$line"
  else
    append_line_if_missing "$target" "$line"
  fi
  log "applied: Foot font set to $FONT_FAMILY $FONT_SIZE"
}

apply_alacritty() {
  local target="$TARGET_HOME/.config/alacritty/alacritty.toml"

  if ! command -v alacritty >/dev/null 2>&1 && [[ ! -e "$target" ]]; then
    log "skip: Alacritty not found"
    return 1
  fi

  log "apply: Alacritty -> $target"
  if [[ "$DRY_RUN" == "1" ]]; then
    [[ -e "$target" ]] && backup_copy "$target"
    if [[ -e "$target" ]] && grep -Eq '^\[font(\.|])' "$target"; then
      log "dry-run: would skip existing Alacritty font table to avoid invalid TOML"
    else
      log "dry-run: would write Alacritty font table"
    fi
    return 0
  fi

  [[ "$YES" == "1" ]] || die "no changes made; pass --dry-run to preview or --yes to apply terminal font"
  backup_copy "$target"
  mkdir -p "$(dirname "$target")"
  if [[ -e "$target" ]] && grep -Eq '^\[font(\.|])' "$target"; then
    log "warning: Alacritty already has font config; skipped to avoid invalid TOML"
    return 0
  fi

  {
    [[ -f "$target" ]] && cat "$target"
    printf '\n[font]\n'
    printf 'size = %s\n' "$FONT_SIZE"
    printf '\n[font.normal]\n'
    printf 'family = "%s"\n' "$FONT_FAMILY"
  } > "$target.tmp"
  mv "$target.tmp" "$target"
  log "applied: Alacritty font set to $FONT_FAMILY $FONT_SIZE"
}

main() {
  parse_args "$@"
  validate
  check_font_available

  if [[ "$DRY_RUN" != "1" && "$YES" != "1" ]]; then
    die "no changes made; pass --dry-run to preview or --yes to apply terminal font"
  fi

  local applied=0
  apply_lxterminal && applied=1
  apply_ghostty && applied=1
  apply_kitty && applied=1
  apply_foot && applied=1
  apply_alacritty && applied=1

  if [[ "$applied" == "0" ]]; then
    log "warning: no supported terminal emulator config was found to update"
  fi
}

main "$@"
