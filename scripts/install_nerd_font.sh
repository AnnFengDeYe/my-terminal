#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
TARGET_HOME="${TEST_HOME:-$HOME}"
OS_NAME=""

DRY_RUN=0
YES=0
FONT_NAME="JetBrainsMono"
FONT_VERSION="v3.4.0"
FONT_DIR=""
ARCHIVE_EXT="tar.xz"
BASE_URL="https://github.com/ryanoasis/nerd-fonts/releases/download"
TMP_NERD_FONT_DIR=""

usage() {
  cat <<'EOF'
Usage: scripts/install_nerd_font.sh [--dry-run] [--yes] [--font JetBrainsMono] [--version v3.4.0]

Installs a Nerd Font archive from the official ryanoasis/nerd-fonts GitHub
release into the current user's font directory and refreshes fontconfig.
It downloads font archives only; it never executes downloaded code.
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
      --font)
        [[ $# -ge 2 ]] || die "--font requires a value"
        FONT_NAME="$2"
        shift 2
        ;;
      --version)
        [[ $# -ge 2 ]] || die "--version requires a value"
        FONT_VERSION="$2"
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

detect_os() {
  case "$(uname -s 2>/dev/null || true)" in
    Darwin) printf '%s\n' "macos" ;;
    Linux) printf '%s\n' "linux" ;;
    *) printf '%s\n' "unknown" ;;
  esac
}

default_font_dir() {
  case "$OS_NAME" in
    macos)
      printf '%s\n' "$TARGET_HOME/Library/Fonts/NerdFonts/$FONT_NAME"
      ;;
    linux)
      printf '%s\n' "$TARGET_HOME/.local/share/fonts/NerdFonts/$FONT_NAME"
      ;;
    *)
      printf '%s\n' "$TARGET_HOME/.local/share/fonts/NerdFonts/$FONT_NAME"
      ;;
  esac
}

validate() {
  OS_NAME="$(detect_os)"
  [[ -n "$FONT_DIR" ]] || FONT_DIR="$(default_font_dir)"

  [[ -n "$TARGET_HOME" ]] || die "target HOME is empty"
  [[ "$TARGET_HOME" == /* ]] || die "target HOME must be absolute: $TARGET_HOME"
  [[ "$TARGET_HOME" != "/" ]] || die "refusing to use / as HOME"
  [[ "$FONT_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || die "unsafe font name: $FONT_NAME"
  [[ "$FONT_VERSION" =~ ^v[0-9]+(\.[0-9]+){1,2}$ ]] || die "unsafe font version: $FONT_VERSION"
  [[ "$FONT_DIR" == "$TARGET_HOME"/* ]] || die "font dir is outside HOME: $FONT_DIR"
}

need_command() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || die "$cmd is required"
}

download_file() {
  local url="$1"
  local out="$2"

  if command -v curl >/dev/null 2>&1; then
    curl -fL --proto '=https' --tlsv1.2 "$url" -o "$out"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$out" "$url"
  else
    die "curl or wget is required"
  fi
}

extract_font_archive() {
  local archive="$1"
  local extract_dir

  mkdir -p "$FONT_DIR"
  extract_dir="$(mktemp -d "${TMPDIR:-/tmp}/nerd-font-extract.XXXXXX")"

  case "$archive" in
    *.tar.xz)
      need_command tar
      tar -xJf "$archive" -C "$extract_dir"
      ;;
    *.zip)
      need_command unzip
      unzip -oq "$archive" -d "$extract_dir"
      ;;
    *)
      die "unsupported font archive: $archive"
      ;;
  esac

  find "$extract_dir" -type f \( -name '*.ttf' -o -name '*.otf' \) -exec cp {} "$FONT_DIR"/ \;
  rm -rf "$extract_dir"
}

verify_checksum() {
  local sums="$1"
  local archive="$2"
  local archive_name
  local expected
  local actual

  archive_name="$(basename "$archive")"

  if ! grep -F " $archive_name" "$sums" > "$archive.sha256"; then
    die "checksum for $archive_name not found in SHA256SUMS"
  fi

  if command -v sha256sum >/dev/null 2>&1; then
    (cd "$(dirname "$archive")" && sha256sum -c "$(basename "$archive").sha256")
    return 0
  fi

  if command -v shasum >/dev/null 2>&1; then
    expected="$(awk '{print $1}' "$archive.sha256")"
    actual="$(shasum -a 256 "$archive" | awk '{print $1}')"
    [[ "$actual" == "$expected" ]] || die "checksum mismatch for $archive_name"
    log "checksum ok: $archive_name"
    return 0
  fi

  log "warning: no SHA-256 checksum tool found; continuing because only font files will be extracted"
}

install_font() {
  local tmp_dir
  local archive
  local sums
  local font_url
  local sums_url

  tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/nerd-font.XXXXXX")"
  TMP_NERD_FONT_DIR="$tmp_dir"
  archive="$tmp_dir/$FONT_NAME.$ARCHIVE_EXT"
  sums="$tmp_dir/SHA256SUMS"
  font_url="$BASE_URL/$FONT_VERSION/$FONT_NAME.$ARCHIVE_EXT"
  sums_url="$BASE_URL/$FONT_VERSION/SHA256SUMS"

  cleanup() {
    [[ -n "${TMP_NERD_FONT_DIR:-}" ]] && rm -rf "$TMP_NERD_FONT_DIR"
  }
  trap cleanup EXIT

  log "Font: $FONT_NAME"
  log "Version: $FONT_VERSION"
  log "Detected OS: $OS_NAME"
  log "Install dir: $FONT_DIR"

  if [[ "$DRY_RUN" == "1" ]]; then
    log "dry-run: would download $font_url"
    log "dry-run: would verify against $sums_url when available"
    log "dry-run: would extract .ttf/.otf files into $FONT_DIR"
    if [[ "$OS_NAME" == "linux" ]]; then
      log "dry-run: would run fc-cache -f $FONT_DIR"
    else
      log "dry-run: would install fonts for the current macOS user"
    fi
    return 0
  fi

  [[ "$YES" == "1" ]] || die "no changes made; pass --dry-run to preview or --yes to install"

  download_file "$font_url" "$archive"
  if download_file "$sums_url" "$sums"; then
    verify_checksum "$sums" "$archive"
  else
    log "warning: checksum file was not available at $sums_url; continuing because only font files will be extracted"
  fi

  extract_font_archive "$archive"
  find "$FONT_DIR" -type f \( -name '*.ttf' -o -name '*.otf' \) -exec chmod 0644 {} +
  if command -v fc-cache >/dev/null 2>&1; then
    fc-cache -f "$FONT_DIR"
  elif [[ "$OS_NAME" == "linux" ]]; then
    die "fc-cache is required on Linux; install fontconfig first"
  else
    log "notice: fc-cache is not available; macOS apps may need to be restarted to see new fonts"
  fi

  log "installed: $FONT_NAME Nerd Font into $FONT_DIR"
}

main() {
  parse_args "$@"
  validate
  install_font
}

main "$@"
