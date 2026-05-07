#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$SCRIPT_DIR"

DRY_RUN=0
YES=0
DO_BACKUP=0
INSTALL_PACKAGES=0
LINK_ONLY=0
NO_PACKAGES=0
INSTALL_GUI_APPS=0
INSTALL_FONTS=0
SET_DEFAULT_SHELL=0
PACKAGE_MANAGER=""

usage() {
  cat <<'EOF'
Usage: ./install.sh [options]

Safe defaults:
  ./install.sh --dry-run

Options:
  --dry-run                       Print actions only
  --yes                           Allow real writes/install commands
  --backup                        Backup existing config targets before linking
  --install-packages              Install packages, then link configs
  --link-only                     Link configs only
  --no-packages                   Do not install packages
  --install-gui-apps              Include optional GUI apps such as Ghostty
  --no-gui-apps                   Do not install optional GUI apps
  --install-fonts                 Install terminal-friendly fonts
  --no-fonts                      Do not install fonts
  --set-default-shell             Change the login shell to zsh
  --no-set-default-shell          Do not change the login shell
  --package-manager brew|apt|pacman|dnf
  --help                          Show help
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

detect_default_pm() {
  local os="$1"
  case "$os" in
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

parse_args() {
  if [[ $# -eq 0 ]]; then
    usage
    printf '\nNo changes made. Start with: ./install.sh --dry-run\n'
    exit 0
  fi

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
      --backup)
        DO_BACKUP=1
        shift
        ;;
      --install-packages)
        INSTALL_PACKAGES=1
        shift
        ;;
      --link-only)
        LINK_ONLY=1
        shift
        ;;
      --no-packages)
        NO_PACKAGES=1
        shift
        ;;
      --install-gui-apps)
        INSTALL_GUI_APPS=1
        shift
        ;;
      --no-gui-apps)
        INSTALL_GUI_APPS=0
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
      --set-default-shell)
        SET_DEFAULT_SHELL=1
        shift
        ;;
      --no-set-default-shell)
        SET_DEFAULT_SHELL=0
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

main() {
  parse_args "$@"

  local os
  local pm
  os="$("$REPO_ROOT/scripts/detect_os.sh")"
  pm="${PACKAGE_MANAGER:-$(detect_default_pm "$os")}"

  printf 'Repository: %s\n' "$REPO_ROOT"
  printf 'Target HOME: %s\n' "${TEST_HOME:-$HOME}"
  printf 'Detected OS: %s\n' "$os"
  printf 'Package manager: %s\n' "$pm"
  printf 'Install GUI apps: %s\n' "$INSTALL_GUI_APPS"
  printf 'Install fonts: %s\n' "$INSTALL_FONTS"
  printf 'Set default shell: %s\n' "$SET_DEFAULT_SHELL"
  [[ "$DRY_RUN" == "1" ]] && printf 'Mode: dry-run\n'

  if [[ "$DRY_RUN" != "1" && "$YES" != "1" ]]; then
    die "no changes made; pass --dry-run to preview or --yes to modify the system"
  fi

  local link_args=()
  [[ "$DRY_RUN" == "1" ]] && link_args+=("--dry-run")
  [[ "$YES" == "1" ]] && link_args+=("--yes")
  [[ "$DO_BACKUP" == "1" ]] && link_args+=("--backup")

  if [[ "$LINK_ONLY" == "1" ]]; then
    printf '\nPackage step: skipped because --link-only was supplied\n'
  elif [[ "$NO_PACKAGES" == "1" ]]; then
    printf '\nPackage step: skipped because --no-packages was supplied\n'
  elif [[ "$INSTALL_PACKAGES" == "1" ]]; then
    local pkg_args=("--package-manager" "$pm")
    [[ "$DRY_RUN" == "1" ]] && pkg_args+=("--dry-run")
    [[ "$YES" == "1" ]] && pkg_args+=("--yes")
    if [[ "$INSTALL_GUI_APPS" == "1" ]]; then
      pkg_args+=("--install-gui-apps")
    else
      pkg_args+=("--no-gui-apps")
    fi
    if [[ "$INSTALL_FONTS" == "1" ]]; then
      pkg_args+=("--install-fonts")
    else
      pkg_args+=("--no-fonts")
    fi
    printf '\nPackage step:\n'
    "$REPO_ROOT/scripts/install_packages.sh" "${pkg_args[@]}"

    local yazi_args=("--package-manager" "$pm")
    [[ "$DRY_RUN" == "1" ]] && yazi_args+=("--dry-run")
    [[ "$YES" == "1" ]] && yazi_args+=("--yes")
    printf '\nYazi step:\n'
    "$REPO_ROOT/scripts/install_yazi.sh" "${yazi_args[@]}"
  else
    printf '\nPackage step: not selected; use --install-packages to install software\n'
  fi

  if [[ "$INSTALL_FONTS" == "1" ]]; then
    local font_args=()
    local terminal_font_args=()
    [[ "$DRY_RUN" == "1" ]] && font_args+=("--dry-run")
    [[ "$YES" == "1" ]] && font_args+=("--yes")
    [[ "$DRY_RUN" == "1" ]] && terminal_font_args+=("--dry-run")
    [[ "$YES" == "1" ]] && terminal_font_args+=("--yes")
    printf '\nNerd Font step:\n'
    "$REPO_ROOT/scripts/install_nerd_font.sh" "${font_args[@]}"
    printf '\nTerminal font step:\n'
    "$REPO_ROOT/scripts/apply_terminal_font.sh" "${terminal_font_args[@]}"
  else
    printf '\nNerd Font step: skipped; use --install-fonts to install and apply terminal fonts\n'
  fi

  printf '\nConfig link step:\n'
  "$REPO_ROOT/scripts/link_configs.sh" "${link_args[@]}"

  if [[ "$SET_DEFAULT_SHELL" == "1" ]]; then
    local shell_args=()
    [[ "$DRY_RUN" == "1" ]] && shell_args+=("--dry-run")
    [[ "$YES" == "1" ]] && shell_args+=("--yes")
    printf '\nDefault shell step:\n'
    "$REPO_ROOT/scripts/set_default_shell.sh" "${shell_args[@]}"
  else
    printf '\nDefault shell step: skipped; use --set-default-shell to switch to zsh\n'
  fi
}

main "$@"
