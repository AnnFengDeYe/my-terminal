#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
OS_NAME="$("$SCRIPT_DIR/detect_os.sh")"

DRY_RUN=0
YES=0
PACKAGE_MANAGER=""
INSTALL_SNAPD=1

PATH="/snap/bin:/home/linuxbrew/.linuxbrew/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
export PATH

usage() {
  cat <<'EOF'
Usage: scripts/install_ghostty.sh [--dry-run] [--yes] [--package-manager brew|apt|pacman|dnf] [--no-install-snapd]

Installs optional Ghostty GUI terminal support where a safe package route is
available.

Strategy:
  - macOS: Homebrew cask
  - Arch: pacman official repository
  - Debian/Ubuntu/Raspberry Pi OS: enabled apt repository first, then Snap
  - Fedora: enabled dnf repository first, then Snap

This script does not add third-party apt sources, PPAs, COPR repositories, or
run community curl | bash installers.
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '%s\n' "$*"
}

require_yes() {
  [[ "$DRY_RUN" == "1" || "$YES" == "1" ]] || die "no Ghostty install performed; pass --dry-run to preview or --yes to install"
}

require_command() {
  command -v "$1" >/dev/null 2>&1
}

sudo_prefix() {
  if [[ "$(id -u)" == "0" ]]; then
    printf ''
    return 0
  fi

  require_command sudo || die "sudo is required for system package installation"
  printf 'sudo'
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
      --no-install-snapd)
        INSTALL_SNAPD=0
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

ghostty_installed() {
  command -v ghostty >/dev/null 2>&1
}

default_package_manager() {
  case "$OS_NAME" in
    macos) printf '%s\n' "brew" ;;
    debian|ubuntu|raspberrypi) printf '%s\n' "apt" ;;
    arch) printf '%s\n' "pacman" ;;
    fedora) printf '%s\n' "dnf" ;;
    *) printf '%s\n' "unknown" ;;
  esac
}

apt_package_available() {
  require_command apt-cache || return 1
  apt-cache policy ghostty 2>/dev/null | awk '/Candidate:/ && $2 != "(none)" { found=1 } END { exit found ? 0 : 1 }'
}

dnf_package_available() {
  require_command dnf || return 1
  dnf -q list --available ghostty >/dev/null 2>&1
}

install_macos_brew() {
  require_command brew || {
    if [[ "$DRY_RUN" == "1" ]]; then
      log "dry-run: brew is not available; would ask the user to install Homebrew first"
      return 0
    fi
    die "Homebrew is required for Ghostty on macOS; install Homebrew first"
  }

  run_cmd brew install --cask ghostty
}

install_arch_pacman() {
  require_command pacman || die "pacman not found"
  local sudo_cmd
  sudo_cmd="$(sudo_prefix)"

  if [[ -n "$sudo_cmd" ]]; then
    run_cmd "$sudo_cmd" pacman -S --needed ghostty
  else
    run_cmd pacman -S --needed ghostty
  fi
}

install_snapd_with_pm() {
  local pm="$1"
  local sudo_cmd
  sudo_cmd="$(sudo_prefix)"

  if require_command snap; then
    return 0
  fi

  if [[ "$INSTALL_SNAPD" != "1" ]]; then
    die "snap is not installed and --no-install-snapd was supplied"
  fi

  case "$pm" in
    apt)
      require_command apt-get || die "apt-get not found; cannot install snapd"
      if [[ -n "$sudo_cmd" ]]; then
        run_cmd "$sudo_cmd" apt-get update
        run_cmd "$sudo_cmd" apt-get install -y snapd
      else
        run_cmd apt-get update
        run_cmd apt-get install -y snapd
      fi
      ;;
    dnf)
      require_command dnf || die "dnf not found; cannot install snapd"
      if [[ -n "$sudo_cmd" ]]; then
        run_cmd "$sudo_cmd" dnf install -y snapd
      else
        run_cmd dnf install -y snapd
      fi
      ;;
    pacman)
      require_command pacman || die "pacman not found; cannot install snapd"
      if [[ -n "$sudo_cmd" ]]; then
        run_cmd "$sudo_cmd" pacman -S --needed snapd
      else
        run_cmd pacman -S --needed snapd
      fi
      ;;
    *)
      die "snap is not installed; install snapd manually for this platform"
      ;;
  esac
}

prepare_snapd_runtime() {
  local sudo_cmd
  sudo_cmd="$(sudo_prefix)"

  if [[ "$DRY_RUN" == "1" ]]; then
    printf 'dry-run: would enable snapd socket when systemd is available\n'
    printf 'dry-run: would create /snap -> /var/lib/snapd/snap only if /snap is absent and required\n'
    printf 'dry-run: would wait for snapd seed initialization\n'
    return 0
  fi

  require_command snap || die "snap command not found after snapd install"

  if require_command systemctl; then
    if [[ -n "$sudo_cmd" ]]; then
      "$sudo_cmd" systemctl enable --now snapd.socket || true
    else
      systemctl enable --now snapd.socket || true
    fi
  fi

  if [[ -d /var/lib/snapd/snap && ! -e /snap ]]; then
    if [[ -n "$sudo_cmd" ]]; then
      "$sudo_cmd" ln -s /var/lib/snapd/snap /snap
    else
      ln -s /var/lib/snapd/snap /snap
    fi
  fi

  snap wait system seed.loaded >/dev/null 2>&1 || true
}

install_snap_ghostty() {
  local pm="$1"
  local sudo_cmd

  install_snapd_with_pm "$pm"
  prepare_snapd_runtime

  if [[ "$DRY_RUN" == "1" ]]; then
    printf 'dry-run: sudo snap install ghostty --classic\n'
    return 0
  fi

  sudo_cmd="$(sudo_prefix)"
  require_command snap || die "snap command not found"
  if [[ -n "$sudo_cmd" ]]; then
    "$sudo_cmd" snap install ghostty --classic
  else
    snap install ghostty --classic
  fi
}

install_apt_or_snap() {
  require_command apt-get || die "apt-get not found"
  local sudo_cmd
  sudo_cmd="$(sudo_prefix)"

  if apt_package_available; then
    if [[ -n "$sudo_cmd" ]]; then
      run_cmd "$sudo_cmd" apt-get install -y ghostty
    else
      run_cmd apt-get install -y ghostty
    fi
    return 0
  fi

  log "notice: ghostty is not available from the enabled apt repositories; using Snap fallback"
  install_snap_ghostty apt
}

install_dnf_or_snap() {
  require_command dnf || die "dnf not found"
  local sudo_cmd
  sudo_cmd="$(sudo_prefix)"

  if dnf_package_available; then
    if [[ -n "$sudo_cmd" ]]; then
      run_cmd "$sudo_cmd" dnf install -y ghostty
    else
      run_cmd dnf install -y ghostty
    fi
    return 0
  fi

  log "notice: ghostty is not available from the enabled dnf repositories; using Snap fallback"
  install_snap_ghostty dnf
}

main() {
  parse_args "$@"
  require_yes

  [[ -n "$PACKAGE_MANAGER" ]] || PACKAGE_MANAGER="$(default_package_manager)"

  log "Ghostty install:"
  log "Detected OS: $OS_NAME"
  log "Package manager: $PACKAGE_MANAGER"
  [[ "$DRY_RUN" == "1" ]] && log "Mode: dry-run"

  if ghostty_installed; then
    log "skip: ghostty is already installed at $(command -v ghostty)"
    return 0
  fi

  case "$OS_NAME:$PACKAGE_MANAGER" in
    macos:brew)
      install_macos_brew
      ;;
    arch:pacman)
      install_arch_pacman
      ;;
    debian:apt|ubuntu:apt|raspberrypi:apt)
      install_apt_or_snap
      ;;
    fedora:dnf)
      install_dnf_or_snap
      ;;
    *:brew)
      log "notice: Homebrew cask installation is macOS-focused; using Snap fallback on Linux"
      install_snap_ghostty "$(default_package_manager)"
      ;;
    *)
      if [[ "$OS_NAME" == "linux" || "$OS_NAME" == *linux* ]]; then
        install_snap_ghostty "$(default_package_manager)"
      else
        die "unsupported Ghostty install route for OS=$OS_NAME package-manager=$PACKAGE_MANAGER"
      fi
      ;;
  esac
}

main "$@"
