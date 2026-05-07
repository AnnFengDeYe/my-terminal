#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REAL_HOME="${HOME:?HOME is required}"
TMP_HOME="$(mktemp -d)"

cleanup() {
  if [[ "${KEEP_TEST_HOME:-0}" == "1" ]]; then
    printf 'Keeping temporary HOME for inspection: %s\n' "$TMP_HOME"
    return 0
  fi

  case "$TMP_HOME" in
    /tmp/*|/private/tmp/*|/var/folders/*|/private/var/folders/*)
      rm -rf "$TMP_HOME"
      ;;
    *)
      printf 'Refusing to remove unexpected temporary path: %s\n' "$TMP_HOME" >&2
      ;;
  esac
}
trap cleanup EXIT

fail() {
  printf 'test failure: %s\n' "$*" >&2
  exit 1
}

assert_symlink() {
  local path="$1"
  [[ -L "$path" ]] || fail "expected symlink: $path"
}

assert_backup_exists() {
  local pattern="$1"
  compgen -G "$pattern" >/dev/null || fail "expected backup matching: $pattern"
}

assert_missing() {
  local path="$1"
  [[ ! -e "$path" && ! -L "$path" ]] || fail "expected path to be absent: $path"
}

printf 'Real HOME:      %s\n' "$REAL_HOME"
printf 'Temporary HOME: %s\n' "$TMP_HOME"
printf 'Repository:     %s\n\n' "$REPO_ROOT"

printf 'Test 1: dry-run must not create config files\n'
HOME="$TMP_HOME" TEST_HOME="$TMP_HOME" "$REPO_ROOT/install.sh" --dry-run --link-only --backup >/dev/null
assert_missing "$TMP_HOME/.zshrc"
assert_missing "$TMP_HOME/.config"
printf 'ok: dry-run made no changes\n\n'

printf 'Test 1b: guided setup preview must not create config files\n'
preview_menu="$(printf '1\n0\n' | HOME="$TMP_HOME" TEST_HOME="$TMP_HOME" "$REPO_ROOT/setup.sh")"
printf '%s\n' "$preview_menu" | grep -q '安装预览' || fail "expected concise Chinese install preview"
printf '%s\n' "$preview_menu" | grep -q 'CLI 工具状态' || fail "expected concise CLI status"
assert_missing "$TMP_HOME/.zshrc"
assert_missing "$TMP_HOME/.config"
printf 'ok: guided setup preview made no changes\n\n'

printf 'Test 1c: guided setup supports Chinese default and English override\n'
menu_zh="$(printf '0\n' | HOME="$TMP_HOME" TEST_HOME="$TMP_HOME" "$REPO_ROOT/setup.sh")"
printf '%s\n' "$menu_zh" | grep -q '终端配置安装器' || fail "expected Chinese setup menu by default"
menu_en="$(printf '0\n' | HOME="$TMP_HOME" TEST_HOME="$TMP_HOME" "$REPO_ROOT/setup.sh" --lang en)"
printf '%s\n' "$menu_en" | grep -q 'Terminal Starter Kit Setup' || fail "expected English setup menu with --lang en"
printf 'ok: guided setup language selection works\n\n'

printf 'Test 1d: concise preview supports English override\n'
preview_en="$(HOME="$TMP_HOME" TEST_HOME="$TMP_HOME" "$REPO_ROOT/scripts/preview_install.sh" --lang en)"
printf '%s\n' "$preview_en" | grep -q 'Install Preview' || fail "expected English install preview"
printf '%s\n' "$preview_en" | grep -q 'CLI tool status' || fail "expected English CLI status"
printf 'ok: concise preview language selection works\n\n'

printf 'Test 2: link-only with backups in temporary HOME\n'
mkdir -p "$TMP_HOME/.config/nvim"
printf 'temporary zshrc\n' > "$TMP_HOME/.zshrc"
printf 'temporary nvim init\n' > "$TMP_HOME/.config/nvim/init.lua"

HOME="$TMP_HOME" TEST_HOME="$TMP_HOME" "$REPO_ROOT/install.sh" --link-only --backup --yes >/dev/null

assert_symlink "$TMP_HOME/.zshrc"
assert_symlink "$TMP_HOME/.zprofile"
assert_symlink "$TMP_HOME/.zshenv"
assert_symlink "$TMP_HOME/.tmux.conf"
assert_symlink "$TMP_HOME/.gitconfig"
assert_symlink "$TMP_HOME/.config/starship.toml"
assert_symlink "$TMP_HOME/.config/ghostty/config"
assert_symlink "$TMP_HOME/.config/lazygit/config.yml"
assert_symlink "$TMP_HOME/.config/nvim"
assert_symlink "$TMP_HOME/.config/yazi"
assert_backup_exists "$TMP_HOME/.zshrc.backup.*"
assert_backup_exists "$TMP_HOME/.config/nvim.backup.*"
printf 'ok: links and backups created inside temporary HOME\n\n'

printf 'Test 3: existing correct symlinks are skipped safely\n'
before="$(readlink "$TMP_HOME/.zshrc")"
HOME="$TMP_HOME" TEST_HOME="$TMP_HOME" "$REPO_ROOT/install.sh" --link-only --backup --yes >/dev/null
after="$(readlink "$TMP_HOME/.zshrc")"
[[ "$before" == "$after" ]] || fail "correct symlink changed unexpectedly"
printf 'ok: correct symlink remained unchanged\n\n'

printf 'Test 4: quick restore returns backups and removes managed symlinks\n'
HOME="$TMP_HOME" TEST_HOME="$TMP_HOME" "$REPO_ROOT/scripts/restore_backups.sh" --dry-run >/dev/null
HOME="$TMP_HOME" TEST_HOME="$TMP_HOME" "$REPO_ROOT/scripts/restore_backups.sh" --yes >/dev/null
[[ -f "$TMP_HOME/.zshrc" ]] || fail "expected restored .zshrc file"
[[ ! -L "$TMP_HOME/.zshrc" ]] || fail "restored .zshrc should not be a symlink"
grep -q 'temporary zshrc' "$TMP_HOME/.zshrc" || fail "restored .zshrc content mismatch"
[[ -d "$TMP_HOME/.config/nvim" ]] || fail "expected restored nvim directory"
[[ ! -L "$TMP_HOME/.config/nvim" ]] || fail "restored nvim should not be a symlink"
[[ -f "$TMP_HOME/.config/nvim/init.lua" ]] || fail "expected restored nvim init.lua"
assert_missing "$TMP_HOME/.zprofile"
printf 'ok: quick restore restored backups and removed repository-managed links\n\n'

printf 'Test 5: full dry-run includes fonts and default shell without changes\n'
restored_zshrc_before="$(cat "$TMP_HOME/.zshrc")"
HOME="$TMP_HOME" TEST_HOME="$TMP_HOME" "$REPO_ROOT/install.sh" --dry-run --install-packages --install-fonts --set-default-shell >/dev/null
restored_zshrc_after="$(cat "$TMP_HOME/.zshrc")"
[[ "$restored_zshrc_before" == "$restored_zshrc_after" ]] || fail "full dry-run changed restored .zshrc"
printf 'ok: full dry-run made no changes\n\n'

printf 'Test 6: terminal font apply updates LXTerminal config in temporary HOME\n'
mkdir -p "$TMP_HOME/.config/lxterminal"
printf '[general]\nfontname=Monospace 10\n' > "$TMP_HOME/.config/lxterminal/lxterminal.conf"
HOME="$TMP_HOME" TEST_HOME="$TMP_HOME" "$REPO_ROOT/scripts/apply_terminal_font.sh" --yes --skip-font-check >/dev/null
grep -q '^fontname=JetBrainsMono Nerd Font Mono 11$' "$TMP_HOME/.config/lxterminal/lxterminal.conf" || fail "LXTerminal font was not updated"
assert_backup_exists "$TMP_HOME/.config/lxterminal/lxterminal.conf.backup.*"
printf 'ok: LXTerminal font config updated and backed up\n\n'

printf 'Test 7: terminal font apply updates cross-platform terminal configs\n'
mkdir -p "$TMP_HOME/.config/ghostty" "$TMP_HOME/.config/kitty"
printf 'theme = dark\nfont-family = Monospace\n' > "$TMP_HOME/.config/ghostty/config"
printf 'font_family Monospace\nfont_size 10\n' > "$TMP_HOME/.config/kitty/kitty.conf"
HOME="$TMP_HOME" TEST_HOME="$TMP_HOME" "$REPO_ROOT/scripts/apply_terminal_font.sh" --yes --skip-font-check >/dev/null
grep -q '^font-family = JetBrainsMono Nerd Font Mono$' "$TMP_HOME/.config/ghostty/config" || fail "Ghostty font family was not updated"
grep -q '^font-size = 11$' "$TMP_HOME/.config/ghostty/config" || fail "Ghostty font size was not updated"
grep -q '^font_family JetBrainsMono Nerd Font Mono$' "$TMP_HOME/.config/kitty/kitty.conf" || fail "Kitty font family was not updated"
grep -q '^font_size 11$' "$TMP_HOME/.config/kitty/kitty.conf" || fail "Kitty font size was not updated"
printf 'ok: Ghostty and Kitty font configs updated\n\n'

printf 'All tests passed. No package installation commands were executed.\n'
