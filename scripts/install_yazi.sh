#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
TARGET_HOME="${TEST_HOME:-$HOME}"

# shellcheck source=scripts/common.sh
. "$SCRIPT_DIR/common.sh"

DRY_RUN=0
YES=0
PACKAGE_MANAGER=""
OS_NAME=""
TMP_YAZI_DIR=""
YAZI_BINARY_VERSION="v26.5.6"

usage() {
  cat <<'EOF'
Usage: scripts/install_yazi.sh [--dry-run] [--yes] [--package-manager brew|apt|pacman|dnf]

Installs Yazi without relying on Linux distribution yazi packages.
Linux strategy: existing Homebrew first, existing Cargo second, verified
official release binary fallback for supported architectures.
The script never installs Homebrew, rustup, or Cargo automatically.
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '%s\n' "$*"
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

run_cmd() {
  if [[ "$DRY_RUN" == "1" ]]; then
    printf 'dry-run: %s\n' "$*"
    return 0
  fi

  "$@"
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
      --package-manager)
        [[ $# -ge 2 ]] || die "--package-manager requires a value"
        PACKAGE_MANAGER="$2"
        case "$PACKAGE_MANAGER" in
          brew|apt|pacman|dnf) ;;
          *) die "unsupported package manager: $PACKAGE_MANAGER" ;;
        esac
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

command_or_known_path() {
  local name="$1"
  local candidate

  if command -v "$name" >/dev/null 2>&1; then
    command -v "$name"
    return 0
  fi

  for candidate in \
    "$TARGET_HOME/.local/bin/$name" \
    "$TARGET_HOME/.cargo/bin/$name" \
    "/home/linuxbrew/.linuxbrew/bin/$name" \
    "/opt/homebrew/bin/$name" \
    "/usr/local/bin/$name"; do
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  return 1
}

yazi_ready() {
  command_or_known_path yazi >/dev/null 2>&1 && command_or_known_path ya >/dev/null 2>&1
}

install_with_brew() {
  have_cmd brew || return 1
  run_cmd brew install yazi
}

install_with_cargo() {
  have_cmd cargo || return 1

  if [[ "$DRY_RUN" != "1" ]]; then
    have_cmd make || log "warning: make not found; Cargo build may fail"
    { have_cmd gcc || have_cmd cc; } || log "warning: gcc/cc not found; Cargo build may fail"
  fi

  run_cmd cargo install --force yazi-build
}

download_file() {
  local url="$1"
  local out="$2"

  if have_cmd curl; then
    curl -fL --proto '=https' --tlsv1.2 "$url" -o "$out"
  elif have_cmd wget; then
    wget -O "$out" "$url"
  else
    die "curl or wget is required to download the official Yazi binary"
  fi
}

verify_sha256() {
  local file="$1"
  local expected="$2"
  local actual

  if have_cmd sha256sum; then
    actual="$(sha256sum "$file" | awk '{print $1}')"
  elif have_cmd shasum; then
    actual="$(shasum -a 256 "$file" | awk '{print $1}')"
  else
    die "sha256sum or shasum is required to verify the official Yazi binary"
  fi

  [[ "$actual" == "$expected" ]] || die "checksum mismatch for $(basename "$file")"
}

official_binary_asset() {
  case "$(uname -m 2>/dev/null || true)" in
    aarch64|arm64)
      printf '%s %s\n' \
        "yazi-aarch64-unknown-linux-gnu.zip" \
        "c38b07961e7fc4c76503fd0f4a1b4bd0b379a99835b818cd899b0315c728e1e1"
      ;;
    i386|i686)
      printf '%s %s\n' \
        "yazi-i686-unknown-linux-gnu.zip" \
        "6b971563ad880ef7ff969b45780206285c6096af9bdef330319daddc250477c5"
      ;;
    riscv64)
      printf '%s %s\n' \
        "yazi-riscv64gc-unknown-linux-gnu.zip" \
        "03ebb3fb0bf2cfec65fa0b24c7df51a1ff88f0f4840e134e04a32ad575019626"
      ;;
    *)
      return 1
      ;;
  esac
}

install_with_official_binary() {
  local asset_info
  local asset
  local checksum
  local url
  local archive
  local bin_dir
  local yazi_bin
  local ya_bin

  [[ "$OS_NAME" != "macos" ]] || return 1

  asset_info="$(official_binary_asset || true)"
  [[ -n "$asset_info" ]] || return 1
  asset="${asset_info%% *}"
  checksum="${asset_info##* }"
  url="https://github.com/sxyazi/yazi/releases/download/$YAZI_BINARY_VERSION/$asset"
  bin_dir="$TARGET_HOME/.local/bin"

  if [[ "$DRY_RUN" == "1" ]]; then
    log "dry-run: would download official Yazi binary $url"
    log "dry-run: would verify sha256:$checksum"
    log "dry-run: would install yazi and ya into $bin_dir"
    return 0
  fi

  have_cmd unzip || die "unzip is required to extract the official Yazi binary"
  [[ "$YES" == "1" ]] || die "no Yazi install performed; pass --dry-run to preview or --yes to install"
  [[ "$TARGET_HOME" == /* && "$TARGET_HOME" != "/" ]] || die "unsafe HOME: $TARGET_HOME"

  TMP_YAZI_DIR="$(mktemp -d "${TMPDIR:-/tmp}/yazi-install.XXXXXX")"
  cleanup() {
    [[ -n "${TMP_YAZI_DIR:-}" ]] && rm -rf "$TMP_YAZI_DIR"
  }
  trap cleanup EXIT

  archive="$TMP_YAZI_DIR/$asset"
  download_file "$url" "$archive"
  verify_sha256 "$archive" "$checksum"
  unzip -oq "$archive" -d "$TMP_YAZI_DIR/extract"

  yazi_bin="$(find "$TMP_YAZI_DIR/extract" -type f -name yazi -perm -111 | head -n 1)"
  ya_bin="$(find "$TMP_YAZI_DIR/extract" -type f -name ya -perm -111 | head -n 1)"
  [[ -n "$yazi_bin" && -n "$ya_bin" ]] || die "official Yazi archive did not contain yazi and ya executables"

  mkdir -p "$bin_dir"
  cp "$yazi_bin" "$bin_dir/yazi"
  cp "$ya_bin" "$bin_dir/ya"
  chmod 0755 "$bin_dir/yazi" "$bin_dir/ya"
}

main() {
  parse_args "$@"

  OS_NAME="$("$SCRIPT_DIR/detect_os.sh")"
  if [[ -z "$PACKAGE_MANAGER" ]]; then
    PACKAGE_MANAGER="$(detect_default_pm "$OS_NAME")"
  fi

  printf 'Detected OS: %s\n' "$OS_NAME"
  printf 'Package manager: %s\n' "$PACKAGE_MANAGER"
  [[ "$DRY_RUN" == "1" ]] && printf 'Mode: dry-run\n'

  if yazi_ready; then
    log "ok: yazi found at $(command_or_known_path yazi)"
    log "ok: ya found at $(command_or_known_path ya)"
    return 0
  fi

  if [[ "$DRY_RUN" != "1" && "$YES" != "1" ]]; then
    die "no Yazi install performed; pass --dry-run to preview or --yes to install"
  fi

  case "$OS_NAME" in
    macos)
      have_cmd brew || die "Homebrew is required for macOS Yazi install"
      install_with_brew
      ;;
    debian|ubuntu|raspberrypi|arch|fedora|unknown-linux)
      if install_with_brew; then
        :
      else
        log "brew: not found; falling back to Cargo"
        if ! install_with_cargo; then
          log "cargo: not found; falling back to verified official Yazi binary"
          install_with_official_binary || die "Homebrew, Cargo, or a supported official Yazi binary is required"
        fi
      fi
      ;;
    *)
      if install_with_brew; then
        :
      else
        install_with_cargo || die "unsupported OS for automatic Yazi install: $OS_NAME"
      fi
      ;;
  esac

  if [[ "$DRY_RUN" == "1" ]]; then
    return 0
  fi

  if yazi_ready; then
    log "installed: yazi at $(command_or_known_path yazi)"
    log "installed: ya at $(command_or_known_path ya)"
  else
    die "Yazi install finished, but yazi/ya were not found. Check PATH, especially $TARGET_HOME/.cargo/bin."
  fi
}

main "$@"
