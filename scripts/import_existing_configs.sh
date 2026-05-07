#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
CONFIG_ROOT="$REPO_ROOT/configs"
REAL_HOME="${HOME:?HOME is required}"

DRY_RUN=0
YES=0
OVERWRITE_REPO_COPY=0
SANITIZE=0
IMPORTED=0
SKIPPED=0
FAILED=0
REPORT_LINES=""

usage() {
  cat <<'EOF'
Usage: scripts/import_existing_configs.sh [--dry-run] [--yes] [--overwrite-repo-copy] [--sanitize]

Copies existing local terminal configs into this repository:
  real HOME -> repository configs/

It never writes back to real HOME. Without --yes, it only prints the plan.
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

note_report() {
  local file="$1"
  local kind="$2"
  REPORT_LINES="${REPORT_LINES}- ${file}: ${kind}
"
}

repo_rel() {
  local path="$1"
  case "$path" in
    "$REPO_ROOT"/*)
      printf '%s\n' "${path#"$REPO_ROOT"/}"
      ;;
    *)
      printf '%s\n' "$path"
      ;;
  esac
}

validate_source() {
  local src="$1"
  [[ "$src" == "$REAL_HOME"/* ]] || die "source is outside HOME: $src"
  [[ "$src" != *$'\n'* ]] || die "source path contains newline"
}

validate_repo_target() {
  local dst="$1"
  [[ "$dst" == "$CONFIG_ROOT"/* ]] || die "destination is outside repository configs: $dst"
  [[ "$dst" != *$'\n'* ]] || die "destination path contains newline"
}

backup_repo_copy() {
  local dst="$1"
  local backup
  local i=1

  validate_repo_target "$dst"
  [[ -e "$dst" || -L "$dst" ]] || return 0

  backup="${dst}.repo-backup.$(date +%Y%m%d-%H%M%S)"
  while [[ -e "$backup" || -L "$backup" ]]; do
    backup="${dst}.repo-backup.$(date +%Y%m%d-%H%M%S).$i"
    i=$((i + 1))
  done

  if [[ "$DRY_RUN" == "1" ]]; then
    printf 'dry-run: would backup existing repo copy %s -> %s\n' "$(repo_rel "$dst")" "$(repo_rel "$backup")"
    return 0
  fi

  mv "$dst" "$backup"
  printf 'backup: existing repo copy moved %s -> %s\n' "$(repo_rel "$dst")" "$(repo_rel "$backup")"
}

prepare_destination() {
  local dst="$1"

  validate_repo_target "$dst"

  if [[ -e "$dst" || -L "$dst" ]]; then
    if [[ "$OVERWRITE_REPO_COPY" != "1" ]]; then
      printf 'skip: repository copy already exists at %s; pass --overwrite-repo-copy to replace it safely\n' "$(repo_rel "$dst")"
      SKIPPED=$((SKIPPED + 1))
      return 1
    fi
    backup_repo_copy "$dst"
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    printf 'dry-run: would create parent directory %s\n' "$(repo_rel "$(dirname "$dst")")"
    return 0
  fi

  mkdir -p "$(dirname "$dst")"
}

import_file() {
  local label="$1"
  local src="$2"
  local dst="$3"

  validate_source "$src"
  validate_repo_target "$dst"
  printf 'plan: %s: %s -> %s\n' "$label" "$src" "$(repo_rel "$dst")"

  if [[ ! -e "$src" && ! -L "$src" ]]; then
    printf 'skip: %s missing\n' "$label"
    SKIPPED=$((SKIPPED + 1))
    return 0
  fi

  if [[ "$DRY_RUN" == "1" || "$YES" != "1" ]]; then
    printf 'dry-run: would copy file %s -> %s\n' "$src" "$(repo_rel "$dst")"
    return 0
  fi

  prepare_destination "$dst" || return 0
  cp "$src" "$dst"
  IMPORTED=$((IMPORTED + 1))
  printf 'imported: %s -> %s\n' "$label" "$(repo_rel "$dst")"
}

import_dir() {
  local label="$1"
  local src="$2"
  local dst="$3"

  validate_source "$src"
  validate_repo_target "$dst"
  printf 'plan: %s: %s -> %s\n' "$label" "$src" "$(repo_rel "$dst")"

  if [[ ! -d "$src" ]]; then
    printf 'skip: %s missing\n' "$label"
    SKIPPED=$((SKIPPED + 1))
    return 0
  fi

  if [[ "$DRY_RUN" == "1" || "$YES" != "1" ]]; then
    printf 'dry-run: would copy directory %s -> %s with cache/temp exclusions\n' "$src" "$(repo_rel "$dst")"
    return 0
  fi

  command -v rsync >/dev/null 2>&1 || die "rsync is required to import directories safely"
  prepare_destination "$dst" || return 0
  mkdir -p "$dst"

  rsync -a --no-links \
    --exclude='.git/' \
    --exclude='node_modules/' \
    --exclude='.DS_Store' \
    --exclude='*.swp' \
    --exclude='*.swo' \
    --exclude='*.swn' \
    --exclude='*~' \
    --exclude='*.bak' \
    --exclude='*.backup' \
    --exclude='*.backup.*' \
    --exclude='cache/' \
    --exclude='tmp/' \
    --exclude='undo/' \
    --exclude='swap/' \
    "$src"/ "$dst"/

  IMPORTED=$((IMPORTED + 1))
  printf 'imported: %s -> %s\n' "$label" "$(repo_rel "$dst")"
}

is_text_file() {
  local file="$1"
  [[ -f "$file" ]] || return 1
  [[ ! -s "$file" ]] && return 0
  LC_ALL=C grep -Iq . "$file"
}

sanitize_text_file() {
  local file="$1"
  local rel
  rel="$(repo_rel "$file")"

  is_text_file "$file" || return 0

  if grep -Eq '[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}' "$file"; then
    note_report "$rel" "email address placeholder applied"
  fi

  if [[ -n "${REAL_HOME:-}" ]] && grep -Fq "$REAL_HOME" "$file"; then
    note_report "$rel" "absolute HOME path replaced with \$HOME"
  fi

  if [[ -n "${USER:-}" ]] && grep -Fq "$USER" "$file"; then
    note_report "$rel" "local username placeholder applied"
  fi

  if grep -Eiq '(token|api[_-]?key|secret|password)[[:space:]]*[:=]' "$file"; then
    note_report "$rel" "secret-like assignment redacted"
  fi

  if [[ "$rel" == "configs/git/gitconfig" ]] || [[ "$rel" == "configs/git/gitconfig.example" ]]; then
    if grep -Eiq '^[[:space:]]*(name|email|signingkey|helper)[[:space:]]*=' "$file"; then
      note_report "$rel" "git identity/signing/credential fields normalized"
    fi
  fi

  if [[ "$rel" == "configs/ghostty/config" ]]; then
    if grep -Eiq '^[[:space:]]*(command|shell)[[:space:]]*=[[:space:]]*/.*zsh[[:space:]]*$' "$file"; then
      note_report "$rel" "Ghostty shell path replaced with portable zsh command"
    fi
  fi

  SANITIZE_HOME="$REAL_HOME" SANITIZE_USER="${USER:-}" perl -0pi -e '
    my $home = $ENV{"SANITIZE_HOME"} // "";
    my $user = $ENV{"SANITIZE_USER"} // "";
    s/^([ \t]*helper[ \t]*=[ \t]*).*(\/Users\/|\/home\/).*$/${1}<YOUR_CREDENTIAL_HELPER>/gmi;
    s/\Q$home\E/\$HOME/g if length $home;
    s/[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}/<YOUR_EMAIL>/g;
    s/^([ \t]*(?:export[ \t]+)?[A-Za-z0-9_]*(?:TOKEN|API_KEY|SECRET|PASSWORD)[A-Za-z0-9_]*[ \t]*=?[ \t]*).+$/\1<REDACTED>/gmi;
    s/^([ \t]*[A-Za-z0-9_.-]*(?:token|api[_-]?key|secret|password)[A-Za-z0-9_.-]*[ \t]*:[ \t]*).+$/\1<REDACTED>/gmi;
    s#(https?://)[^/\s:@]+:[^/\s:@]+@#${1}<REDACTED>@#g;
    s/\Q$user\E/<YOUR_USERNAME>/g if length $user;
  ' "$file"

  if [[ "$rel" == "configs/git/gitconfig" ]] || [[ "$rel" == "configs/git/gitconfig.example" ]]; then
    perl -0pi -e '
      s/^([ \t]*name[ \t]*=[ \t]*).*$/${1}<YOUR_NAME>/gmi;
      s/^([ \t]*email[ \t]*=[ \t]*).*$/${1}<YOUR_EMAIL>/gmi;
      s/^([ \t]*signingkey[ \t]*=[ \t]*).*$/${1}<YOUR_SIGNING_KEY>/gmi;
    ' "$file"
  fi

  if [[ "$rel" == "configs/ghostty/config" ]]; then
    perl -0pi -e '
      s/^([ \t]*(?:command|shell)[ \t]*=[ \t]*)\/.*zsh[ \t]*$/${1}zsh/gmi;
    ' "$file"
  fi
}

sanitize_configs() {
  local report="$SCRIPT_DIR/sanitize_report.md"

  if [[ "$DRY_RUN" == "1" || "$YES" != "1" ]]; then
    printf 'dry-run: would sanitize repository copies only and write %s\n' "$(repo_rel "$report")"
    return 0
  fi

  if [[ -f "$CONFIG_ROOT/git/gitconfig" ]]; then
    if [[ -e "$CONFIG_ROOT/git/gitconfig.example" || -L "$CONFIG_ROOT/git/gitconfig.example" ]]; then
      if [[ "$OVERWRITE_REPO_COPY" == "1" ]]; then
        backup_repo_copy "$CONFIG_ROOT/git/gitconfig.example"
        cp "$CONFIG_ROOT/git/gitconfig" "$CONFIG_ROOT/git/gitconfig.example"
      else
        printf 'skip: configs/git/gitconfig.example already exists; pass --overwrite-repo-copy to replace it safely\n'
      fi
    else
      cp "$CONFIG_ROOT/git/gitconfig" "$CONFIG_ROOT/git/gitconfig.example"
    fi
  fi

  while IFS= read -r file; do
    sanitize_text_file "$file"
  done < <(find "$CONFIG_ROOT" -type f -not -path '*/.git/*' -print)

  {
    printf '# Sanitization Report\n\n'
    printf 'Generated by `scripts/import_existing_configs.sh --sanitize`.\n\n'
    printf 'This report lists categories of replacements only. It intentionally does not include original secrets, tokens, keys, passwords, usernames, emails, or private paths.\n\n'
    if [[ -n "$REPORT_LINES" ]]; then
      printf '%s' "$REPORT_LINES"
    else
      printf 'No obvious sensitive values were replaced.\n'
    fi
  } > "$report"

  printf 'sanitize: wrote %s\n' "$(repo_rel "$report")"
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
      --overwrite-repo-copy)
        OVERWRITE_REPO_COPY=1
        shift
        ;;
      --sanitize)
        SANITIZE=1
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

main() {
  parse_args "$@"

  printf 'Repository: %s\n' "$REPO_ROOT"
  printf 'Source HOME: %s\n' "$REAL_HOME"
  [[ "$DRY_RUN" == "1" ]] && printf 'Mode: dry-run\n'

  if [[ "$YES" != "1" ]]; then
    printf 'No --yes supplied; this run will only print the import plan.\n'
    DRY_RUN=1
  fi

  import_file "zshrc" "$REAL_HOME/.zshrc" "$CONFIG_ROOT/zsh/zshrc"
  import_file "zprofile" "$REAL_HOME/.zprofile" "$CONFIG_ROOT/zsh/zprofile"
  import_file "zshenv" "$REAL_HOME/.zshenv" "$CONFIG_ROOT/zsh/zshenv"
  import_file "powerlevel10k" "$REAL_HOME/.p10k.zsh" "$CONFIG_ROOT/zsh/p10k.zsh"
  import_dir "zsh config directory" "$REAL_HOME/.config/zsh" "$CONFIG_ROOT/zsh/config"

  import_file "tmux.conf" "$REAL_HOME/.tmux.conf" "$CONFIG_ROOT/tmux/tmux.conf"
  import_dir "tmux config directory" "$REAL_HOME/.config/tmux" "$CONFIG_ROOT/tmux/config"

  import_file "starship" "$REAL_HOME/.config/starship.toml" "$CONFIG_ROOT/starship/starship.toml"
  import_dir "yazi" "$REAL_HOME/.config/yazi" "$CONFIG_ROOT/yazi"
  import_dir "lazygit" "$REAL_HOME/.config/lazygit" "$CONFIG_ROOT/lazygit"
  import_dir "nvim" "$REAL_HOME/.config/nvim" "$CONFIG_ROOT/nvim"
  import_dir "ghostty" "$REAL_HOME/.config/ghostty" "$CONFIG_ROOT/ghostty"
  import_file "gitconfig" "$REAL_HOME/.gitconfig" "$CONFIG_ROOT/git/gitconfig"

  if [[ "$SANITIZE" == "1" ]]; then
    sanitize_configs
  fi

  printf '\nImport summary:\n'
  printf '  imported: %s\n' "$IMPORTED"
  printf '  skipped:  %s\n' "$SKIPPED"
  printf '  failed:   %s\n' "$FAILED"
}

main "$@"
