#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"

# shellcheck source=scripts/common.sh
. "$SCRIPT_DIR/common.sh"

DRY_RUN=0
YES=0
INSTALL_GUI_APPS=0
INSTALL_FONTS=0
PACKAGE_MANAGER=""
OS_NAME=""
PACKAGES=()
REQUIRED_PACKAGES=()
OPTIONAL_PACKAGES=()
FAILED_REQUIRED=()
FAILED_OPTIONAL=()

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

load_linux_package_groups() {
  local required_file="$1"
  local optional_file="$2"

  read_packages "$required_file"
  REQUIRED_PACKAGES=("${PACKAGES[@]}")
  OPTIONAL_PACKAGES=()

  if [[ "$INSTALL_FONTS" == "1" ]]; then
    read_packages "$optional_file"
    OPTIONAL_PACKAGES=("${PACKAGES[@]}")
  fi

  PACKAGES=("${REQUIRED_PACKAGES[@]}")
  if [[ "${#OPTIONAL_PACKAGES[@]}" -gt 0 ]]; then
    PACKAGES+=("${OPTIONAL_PACKAGES[@]}")
  fi
}

reset_package_failures() {
  FAILED_REQUIRED=()
  FAILED_OPTIONAL=()
}

record_package_failure() {
  local group="$1"
  local pkg="$2"

  case "$group" in
    required)
      FAILED_REQUIRED+=("$pkg")
      ;;
    optional)
      FAILED_OPTIONAL+=("$pkg")
      ;;
    *)
      die "unknown package failure group: $group"
      ;;
  esac
}

install_package_group() {
  local installer="$1"
  local sudo_cmd="$2"
  local group="$3"
  local pkg
  shift 3

  for pkg in "$@"; do
    if [[ -n "$sudo_cmd" ]]; then
      "$sudo_cmd" "$installer" install -y "$pkg" || record_package_failure "$group" "$pkg"
    else
      "$installer" install -y "$pkg" || record_package_failure "$group" "$pkg"
    fi
  done
}

print_package_failure_list() {
  local heading="$1"
  local pkg
  shift

  printf '%s\n' "$heading" >&2
  for pkg in "$@"; do
    printf '  - %s\n' "$pkg" >&2
  done
}

finish_linux_package_install() {
  local manager="$1"

  if [[ "${#FAILED_OPTIONAL[@]}" -gt 0 ]]; then
    print_package_failure_list \
      "warning: optional $manager package(s) could not be installed from the enabled repositories:" \
      "${FAILED_OPTIONAL[@]}"
    printf 'warning: optional packages are not required for the base terminal setup.\n' >&2
  fi

  if [[ "${#FAILED_REQUIRED[@]}" -gt 0 ]]; then
    print_package_failure_list \
      "error: required $manager package(s) could not be installed from the enabled repositories:" \
      "${FAILED_REQUIRED[@]}"
    printf 'hint: no third-party repositories were added; install unavailable tools manually if needed.\n' >&2
    printf 'hint: rerun with --no-packages or --link-only if you only want to link configs.\n' >&2
    return 1
  fi

  return 0
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
    local ghostty_args=("--package-manager" "brew")
    [[ "$DRY_RUN" == "1" ]] && ghostty_args+=("--dry-run")
    [[ "$YES" == "1" ]] && ghostty_args+=("--yes")
    "$REPO_ROOT/scripts/install_ghostty.sh" "${ghostty_args[@]}"
  elif [[ "$INSTALL_GUI_APPS" == "1" ]]; then
    local ghostty_args=("--package-manager" "$PACKAGE_MANAGER")
    [[ "$DRY_RUN" == "1" ]] && ghostty_args+=("--dry-run")
    [[ "$YES" == "1" ]] && ghostty_args+=("--yes")
    "$REPO_ROOT/scripts/install_ghostty.sh" "${ghostty_args[@]}"
  fi

  return 0
}

install_apt() {
  load_linux_package_groups "$REPO_ROOT/packages/debian.txt" "$REPO_ROOT/packages/debian-fonts.txt"

  require_command apt-get || die "apt-get not found"
  local sudo_cmd
  sudo_cmd="$(sudo_prefix)"

  if [[ "$DRY_RUN" == "1" ]]; then
    printf 'dry-run: %s apt-get update\n' "$sudo_cmd"
    printf 'dry-run: %s apt-get install -y %s\n' "$sudo_cmd" "${PACKAGES[*]}"
    if [[ "$INSTALL_GUI_APPS" == "1" ]]; then
      "$REPO_ROOT/scripts/install_ghostty.sh" --dry-run --package-manager "$PACKAGE_MANAGER"
    fi
    return 0
  fi

  if [[ -n "$sudo_cmd" ]]; then
    "$sudo_cmd" apt-get update
  else
    apt-get update
  fi

  reset_package_failures
  install_package_group apt-get "$sudo_cmd" required "${REQUIRED_PACKAGES[@]}"
  if [[ "${#OPTIONAL_PACKAGES[@]}" -gt 0 ]]; then
    install_package_group apt-get "$sudo_cmd" optional "${OPTIONAL_PACKAGES[@]}"
  fi
  finish_linux_package_install apt || return 1

  if [[ "$INSTALL_GUI_APPS" == "1" ]]; then
    "$REPO_ROOT/scripts/install_ghostty.sh" --yes --package-manager "$PACKAGE_MANAGER"
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
    if [[ "$INSTALL_GUI_APPS" == "1" ]]; then
      "$REPO_ROOT/scripts/install_ghostty.sh" --dry-run --package-manager "$PACKAGE_MANAGER"
    fi
    return 0
  fi

  if [[ -n "$sudo_cmd" ]]; then
    "$sudo_cmd" pacman -S --needed "${PACKAGES[@]}"
  else
    pacman -S --needed "${PACKAGES[@]}"
  fi

  if [[ "$INSTALL_GUI_APPS" == "1" ]]; then
    "$REPO_ROOT/scripts/install_ghostty.sh" --yes --package-manager "$PACKAGE_MANAGER"
  fi

  return 0
}

install_dnf() {
  load_linux_package_groups "$REPO_ROOT/packages/fedora.txt" "$REPO_ROOT/packages/fedora-fonts.txt"

  require_command dnf || die "dnf not found"
  local sudo_cmd
  sudo_cmd="$(sudo_prefix)"

  if [[ "$DRY_RUN" == "1" ]]; then
    printf 'dry-run: %s dnf install -y %s\n' "$sudo_cmd" "${PACKAGES[*]}"
    if [[ "$INSTALL_GUI_APPS" == "1" ]]; then
      "$REPO_ROOT/scripts/install_ghostty.sh" --dry-run --package-manager "$PACKAGE_MANAGER"
    fi
    return 0
  fi

  reset_package_failures
  install_package_group dnf "$sudo_cmd" required "${REQUIRED_PACKAGES[@]}"
  if [[ "${#OPTIONAL_PACKAGES[@]}" -gt 0 ]]; then
    install_package_group dnf "$sudo_cmd" optional "${OPTIONAL_PACKAGES[@]}"
  fi
  finish_linux_package_install dnf || return 1

  if [[ "$INSTALL_GUI_APPS" == "1" ]]; then
    "$REPO_ROOT/scripts/install_ghostty.sh" --yes --package-manager "$PACKAGE_MANAGER"
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
    PACKAGE_MANAGER="$(detect_default_pm "$OS_NAME")"
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
