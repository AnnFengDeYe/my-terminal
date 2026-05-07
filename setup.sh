#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$SCRIPT_DIR"
TARGET_HOME="${TEST_HOME:-$HOME}"

usage() {
  cat <<'EOF'
Usage: ./setup.sh

Starts a beginner-friendly interactive menu for this terminal starter kit.
The menu keeps the same safety rules as install.sh:

  - dry-run previews do not write files
  - real changes require typing YES
  - existing configs are backed up before linking
EOF
}

is_tty() {
  [[ -t 0 ]]
}

pause_if_tty() {
  is_tty || return 0
  printf '\nPress Enter to return to the menu...'
  read -r _ || true
}

print_header() {
  clear 2>/dev/null || true
  cat <<EOF
Terminal Starter Kit
Repository:  $REPO_ROOT
Target HOME: $TARGET_HOME

Choose an option. Preview first if you are unsure.
EOF
}

confirm_real_action() {
  local title="$1"

  cat <<EOF

This action can modify the target HOME:
  $TARGET_HOME

Action:
  $title

Existing managed config targets will be backed up next to the original path
before repository symlinks are created.

Type YES to continue:
EOF

  local answer
  read -r answer || return 1
  [[ "$answer" == "YES" ]]
}

run_preview() {
  "$REPO_ROOT/install.sh" --dry-run --install-packages --install-fonts --set-default-shell --backup
}

run_recommended_install() {
  local title="install CLI tools, install Nerd Font, link configs, and set zsh as the login shell"
  if confirm_real_action "$title"; then
    "$REPO_ROOT/install.sh" --install-packages --install-fonts --set-default-shell --backup --yes
  else
    printf 'Canceled. No changes made.\n'
  fi
}

run_link_only() {
  local title="link repository configs only, with backups"
  if confirm_real_action "$title"; then
    "$REPO_ROOT/install.sh" --link-only --backup --yes
  else
    printf 'Canceled. No changes made.\n'
  fi
}

run_gui_install() {
  local title="install CLI tools, optional GUI apps, Nerd Font, link configs, and set zsh as the login shell"
  if confirm_real_action "$title"; then
    "$REPO_ROOT/install.sh" --install-packages --install-gui-apps --install-fonts --set-default-shell --backup --yes
  else
    printf 'Canceled. No changes made.\n'
  fi
}

run_restore() {
  printf '\nRestore preview:\n'
  "$REPO_ROOT/scripts/restore_backups.sh" --dry-run

  local title="remove repository-managed symlinks and restore the latest adjacent backups"
  if confirm_real_action "$title"; then
    "$REPO_ROOT/scripts/restore_backups.sh" --yes
  else
    printf 'Canceled. No changes made.\n'
  fi
}

run_import() {
  printf '\nImport preview:\n'
  "$REPO_ROOT/scripts/import_existing_configs.sh" --dry-run

  cat <<'EOF'

Import copies configs from the current HOME into this repository only.
It does not write back to source configs. Existing repository copies are not
overwritten by this menu option.
EOF

  local title="import current HOME configs into repository copies with sanitization"
  if confirm_real_action "$title"; then
    "$REPO_ROOT/scripts/import_existing_configs.sh" --yes --sanitize
  else
    printf 'Canceled. No changes made.\n'
  fi
}

show_commands() {
  cat <<'EOF'

Common commands:

  ./install.sh --dry-run
  ./install.sh --install-packages --install-fonts --set-default-shell --backup --yes
  ./install.sh --link-only --backup --yes
  ./install.sh --install-packages --install-gui-apps --install-fonts --set-default-shell --backup --yes
  ./scripts/doctor.sh
  ./scripts/restore_backups.sh --dry-run
  ./scripts/restore_backups.sh --yes
  ./scripts/import_existing_configs.sh --dry-run
  ./scripts/import_existing_configs.sh --yes --sanitize
  ./test_install.sh
EOF
}

main_menu() {
  local choice

  while true; do
    print_header
    cat <<'EOF'

1) Preview recommended install
2) Recommended install
3) Link configs only
4) Install with optional GUI apps
5) Run doctor check
6) Restore latest backups
7) Import existing local configs
8) Show command reference
0) Exit

EOF
    printf 'Select [0-8]: '
    if ! read -r choice; then
      printf '\nNo input received. Exiting.\n'
      exit 0
    fi

    case "$choice" in
      1)
        run_preview
        pause_if_tty
        ;;
      2)
        run_recommended_install
        pause_if_tty
        ;;
      3)
        run_link_only
        pause_if_tty
        ;;
      4)
        run_gui_install
        pause_if_tty
        ;;
      5)
        "$REPO_ROOT/scripts/doctor.sh"
        pause_if_tty
        ;;
      6)
        run_restore
        pause_if_tty
        ;;
      7)
        run_import
        pause_if_tty
        ;;
      8)
        show_commands
        pause_if_tty
        ;;
      0|q|Q)
        printf 'Bye.\n'
        exit 0
        ;;
      *)
        printf 'Unknown option: %s\n' "$choice"
        pause_if_tty
        ;;
    esac
  done
}

main() {
  case "${1:-}" in
    --help|-h)
      usage
      exit 0
      ;;
    "")
      main_menu
      ;;
    *)
      printf 'ERROR: unknown option: %s\n' "$1" >&2
      usage >&2
      exit 1
      ;;
  esac
}

main "$@"
