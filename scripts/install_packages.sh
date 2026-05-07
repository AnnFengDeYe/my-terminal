#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"

DRY_RUN=0
YES=0
INSTALL_GUI_APPS=0
INSTALL_FONTS=0
PACKAGE_MANAGER=""
OS_NAME=""

usage() {
  cat <<'EOF'
Usage: scripts/install_packages.sh [--dry-run] [--yes] [--package-manager brew|apt|pacman|dnf] [--install-gui-apps] [--install-fonts]

Installs terminal packages for the detected platform.
Dry-run prints commands only.
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

run_cmd() {
  if [[ "$DRY_RUN" == "1" ]]; then
    printf 'dry-run: %s\n' "$*"
    return 0
  fi

  "$@"
}

require_command() {
  local cmd="$1"
  if command -v "$cmd" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

sudo_prefix() {
  if [[ "$(id -u)" == "0" ]]; then
    printf ''
    return 0
  fi

  require_command sudo || die "sudo is required for this package manager; install sudo manually or run as root"
  printf 'sudo'
}

read_packages() {
  local file="$1"
  PACKAGES=()

  append_packages "$file"
}

append_packages() {
  local file="$1"
  local line

  [[ -r "$file" ]] || die "package list not found: $file"

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -n "$line" ]] || continue
    PACKAGES+=("$line")
  done < "$file"
}

detect_default_package_manager() {
  OS_NAME="$("$SCRIPT_DIR/detect_os.sh")"

  case "$OS_NAME" in
    macos)
      printf '%s\n' "brew"
      ;;
    debian|ubuntu|raspberrypi)
      printf '%s\n' "apt"
      ;;
    arch)
      printf '%s\n' "pacman"
      ;;
    fedora)
      printf '%s\n' "dnf"
      ;;
    *)
      printf '%s\n' "unknown"
      ;;
  esac
}

install_brew() {
  if ! require_command brew; then
    if [[ "$DRY_RUN" == "1" ]]; then
      printf 'warning: brew is not currently available; dry-run will still show intended commands\n'
    else
      die "Homebrew is not installed. Install Homebrew manually first; this script will not install it for you."
    fi
  fi

  run_cmd brew bundle --file "$REPO_ROOT/Brewfile.common"

  if [[ "$INSTALL_FONTS" == "1" ]]; then
    if [[ "$OS_NAME" == "macos" ]]; then
      run_cmd brew bundle --file "$REPO_ROOT/Brewfile.fonts"
    else
      printf 'notice: Homebrew font casks are macOS-focused; use the system package manager for Linux fonts.\n'
    fi
  fi

  if [[ "$OS_NAME" == "macos" && "$INSTALL_GUI_APPS" == "1" ]]; then
    run_cmd brew bundle --file "$REPO_ROOT/Brewfile.macos"
  elif [[ "$INSTALL_GUI_APPS" == "1" ]]; then
    printf 'notice: Ghostty is optional on Linux; install it manually if your distribution supports it.\n'
  fi

  return 0
}

install_apt() {
  read_packages "$REPO_ROOT/packages/debian.txt"
  [[ "$INSTALL_FONTS" == "1" ]] && append_packages "$REPO_ROOT/packages/debian-fonts.txt"

  require_command apt-get || die "apt-get not found"
  local sudo_cmd
  sudo_cmd="$(sudo_prefix)"

  if [[ "$DRY_RUN" == "1" ]]; then
    printf 'dry-run: %s apt-get update\n' "$sudo_cmd"
    printf 'dry-run: %s apt-get install -y %s\n' "$sudo_cmd" "${PACKAGES[*]}"
    [[ "$INSTALL_GUI_APPS" == "1" ]] && printf 'dry-run: Ghostty is optional on Linux; no apt source will be added automatically\n'
    return 0
  fi

  if [[ -n "$sudo_cmd" ]]; then
    "$sudo_cmd" apt-get update
  else
    apt-get update
  fi

  local failed=0
  local pkg
  for pkg in "${PACKAGES[@]}"; do
    if [[ -n "$sudo_cmd" ]]; then
      "$sudo_cmd" apt-get install -y "$pkg" || failed=$((failed + 1))
    else
      apt-get install -y "$pkg" || failed=$((failed + 1))
    fi
  done

  if [[ "$failed" -gt 0 ]]; then
    printf 'warning: %s apt package(s) could not be installed from the enabled system repositories.\n' "$failed" >&2
    printf 'warning: no third-party apt sources were added; install unavailable tools manually if needed.\n' >&2
  fi

  if [[ "$INSTALL_GUI_APPS" == "1" ]]; then
    printf 'notice: Ghostty is optional on Linux; install it manually if your distribution supports it.\n'
  fi

  return 0
}

install_pacman() {
  read_packages "$REPO_ROOT/packages/arch.txt"
  [[ "$INSTALL_FONTS" == "1" ]] && append_packages "$REPO_ROOT/packages/arch-fonts.txt"

  require_command pacman || die "pacman not found"
  local sudo_cmd
  sudo_cmd="$(sudo_prefix)"

  if [[ "$DRY_RUN" == "1" ]]; then
    printf 'dry-run: %s pacman -S --needed %s\n' "$sudo_cmd" "${PACKAGES[*]}"
    [[ "$INSTALL_GUI_APPS" == "1" ]] && printf 'dry-run: Ghostty is optional; install it manually if available in your repositories\n'
    return 0
  fi

  if [[ -n "$sudo_cmd" ]]; then
    "$sudo_cmd" pacman -S --needed "${PACKAGES[@]}"
  else
    pacman -S --needed "${PACKAGES[@]}"
  fi

  if [[ "$INSTALL_GUI_APPS" == "1" ]]; then
    printf 'notice: Ghostty is optional; install it manually if available in your repositories.\n'
  fi

  return 0
}

install_dnf() {
  read_packages "$REPO_ROOT/packages/fedora.txt"
  [[ "$INSTALL_FONTS" == "1" ]] && append_packages "$REPO_ROOT/packages/fedora-fonts.txt"

  require_command dnf || die "dnf not found"
  local sudo_cmd
  sudo_cmd="$(sudo_prefix)"

  if [[ "$DRY_RUN" == "1" ]]; then
    printf 'dry-run: %s dnf install -y %s\n' "$sudo_cmd" "${PACKAGES[*]}"
    [[ "$INSTALL_GUI_APPS" == "1" ]] && printf 'dry-run: Ghostty is optional on Linux; no third-party repository will be added automatically\n'
    return 0
  fi

  local failed=0
  local pkg
  for pkg in "${PACKAGES[@]}"; do
    if [[ -n "$sudo_cmd" ]]; then
      "$sudo_cmd" dnf install -y "$pkg" || failed=$((failed + 1))
    else
      dnf install -y "$pkg" || failed=$((failed + 1))
    fi
  done

  if [[ "$failed" -gt 0 ]]; then
    printf 'warning: %s dnf package(s) could not be installed from the enabled repositories.\n' "$failed" >&2
    printf 'warning: no third-party repositories were added; install unavailable tools manually if needed.\n' >&2
  fi

  if [[ "$INSTALL_GUI_APPS" == "1" ]]; then
    printf 'notice: Ghostty is optional on Linux; install it manually if your distribution supports it.\n'
  fi

  return 0
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
      --install-gui-apps)
        INSTALL_GUI_APPS=1
        shift
        ;;
      --install-fonts)
        INSTALL_FONTS=1
        shift
        ;;
      --no-fonts)
        INSTALL_FONTS=0
        shift
        ;;
      --no-gui-apps)
        INSTALL_GUI_APPS=0
        shift
        ;;
      --package-manager)
        [[ $# -ge 2 ]] || die "--package-manager requires a value"
        PACKAGE_MANAGER="$2"
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

main() {
  parse_args "$@"

  OS_NAME="$("$SCRIPT_DIR/detect_os.sh")"
  if [[ -z "$PACKAGE_MANAGER" ]]; then
    PACKAGE_MANAGER="$(detect_default_package_manager)"
  fi

  printf 'Detected OS: %s\n' "$OS_NAME"
  printf 'Package manager: %s\n' "$PACKAGE_MANAGER"
  printf 'Install fonts: %s\n' "$INSTALL_FONTS"
  [[ "$DRY_RUN" == "1" ]] && printf 'Mode: dry-run\n'

  if [[ "$DRY_RUN" != "1" && "$YES" != "1" ]]; then
    die "no packages installed; pass --dry-run to preview or --yes to install"
  fi

  case "$PACKAGE_MANAGER" in
    brew)
      install_brew
      ;;
    apt)
      install_apt
      ;;
    pacman)
      install_pacman
      ;;
    dnf)
      install_dnf
      ;;
    unknown)
      die "could not choose a package manager automatically; pass --package-manager brew|apt|pacman|dnf"
      ;;
    *)
      die "unsupported package manager: $PACKAGE_MANAGER"
      ;;
  esac
}

main "$@"
