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

make_fake_package_manager() {
  local fake_bin="$1"
  local command_name="$2"

  mkdir -p "$fake_bin"
  cat > "$fake_bin/sudo" <<'FAKE_SUDO'
#!/usr/bin/env bash
exec "$@"
FAKE_SUDO

  cat > "$fake_bin/$command_name" <<'FAKE_PM'
#!/usr/bin/env bash
set -euo pipefail

log="${FAKE_PM_LOG:?FAKE_PM_LOG is required}"
printf '%s' "$0" >> "$log"
for arg in "$@"; do
  printf ' %s' "$arg" >> "$log"
done
printf '\n' >> "$log"

case "${1:-}" in
  update)
    exit 0
    ;;
  install)
    pkg=""
    for arg in "$@"; do
      pkg="$arg"
    done
    if [[ "$pkg" == "${FAKE_REQUIRED_FAIL:-}" || "$pkg" == "${FAKE_OPTIONAL_FAIL:-}" ]]; then
      printf 'fake package failure: %s\n' "$pkg" >&2
      exit 42
    fi
    ;;
esac

exit 0
FAKE_PM

  chmod +x "$fake_bin/sudo" "$fake_bin/$command_name"
}

make_fake_doctor_tools() {
  local target_home="$1"
  local fake_bin="$target_home/.local/bin"
  local fake_brew_prefix="$target_home/fake-brew-prefix"
  local cmd

  mkdir -p "$fake_bin" "$fake_brew_prefix/share/zsh-syntax-highlighting"
  for cmd in zsh tmux starship btop fzf zoxide eza bat fd rg lazygit nvim yazi ya ghostty; do
    printf '#!/usr/bin/env sh\nexit 0\n' > "$fake_bin/$cmd"
    chmod +x "$fake_bin/$cmd"
  done

  cat > "$fake_bin/brew" <<FAKE_BREW
#!/usr/bin/env sh
if [ "\${1:-}" = "--prefix" ]; then
  printf '%s\n' "$fake_brew_prefix"
  exit 0
fi
exit 0
FAKE_BREW
  chmod +x "$fake_bin/brew"
  printf '# fake zsh-syntax-highlighting\n' > "$fake_brew_prefix/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh"
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
os_name="$("$REPO_ROOT/scripts/detect_os.sh")"
if [[ "$os_name" == "macos" ]]; then
  expected_ghostty_source="$REPO_ROOT/configs/ghostty/config"
else
  expected_ghostty_source="$REPO_ROOT/configs/ghostty/config.linux"
fi
[[ "$(readlink "$TMP_HOME/.config/ghostty/config")" == "$expected_ghostty_source" ]] || fail "Ghostty config source mismatch for $os_name"
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

printf 'Test 5b: Ghostty GUI install dry-run does not create files\n'
HOME="$TMP_HOME" TEST_HOME="$TMP_HOME" "$REPO_ROOT/scripts/install_ghostty.sh" --dry-run --package-manager brew >/dev/null
assert_missing "$TMP_HOME/.config/ghostty.extra"
printf 'ok: Ghostty dry-run made no HOME changes\n\n'

printf 'Test 5c: Linux desktop entries install inside temporary HOME only\n'
mkdir -p "$TMP_HOME/.local/bin"
printf '#!/usr/bin/env sh\nprintf \"Ghostty test\\n\"\n' > "$TMP_HOME/.local/bin/ghostty"
chmod +x "$TMP_HOME/.local/bin/ghostty"
HOME="$TMP_HOME" TEST_HOME="$TMP_HOME" TEST_OS=linux "$REPO_ROOT/scripts/install_desktop_entries.sh" --yes >/dev/null
[[ -f "$TMP_HOME/.local/share/applications/com.mitchellh.ghostty.desktop" ]] || fail "expected Ghostty app menu entry"
[[ -f "$TMP_HOME/Desktop/Ghostty.desktop" ]] || fail "expected Ghostty desktop launcher"
grep -q '^Name=Ghostty$' "$TMP_HOME/.local/share/applications/com.mitchellh.ghostty.desktop" || fail "Ghostty app menu entry missing name"
grep -q "^Exec=$TMP_HOME/.local/bin/ghostty$" "$TMP_HOME/Desktop/Ghostty.desktop" || fail "Ghostty desktop launcher has wrong exec path"
[[ -x "$TMP_HOME/Desktop/Ghostty.desktop" ]] || fail "Ghostty desktop launcher should be executable"
printf 'ok: Linux desktop entries created inside temporary HOME\n\n'

printf 'Test 5d: Yazi official binary fallback supports Linux x86_64\n'
# shellcheck source=scripts/install_yazi.sh
. "$REPO_ROOT/scripts/install_yazi.sh"
expected_yazi_x86_asset="yazi-x86_64-unknown-linux-gnu.zip 1c9096f0a83b8102c194385f644cdeff93cc8269426163c9d033041ebd537bd2"
[[ "$(official_binary_asset x86_64)" == "$expected_yazi_x86_asset" ]] || fail "expected Yazi x86_64 official binary asset"
[[ "$(official_binary_asset amd64)" == "$expected_yazi_x86_asset" ]] || fail "expected Yazi amd64 official binary asset"
printf 'ok: Yazi x86_64 official binary fallback is mapped\n\n'

printf 'Test 5e: apt required package failures stop the package step\n'
fake_bin="$TMP_HOME/fake-apt-required"
fake_log="$TMP_HOME/fake-apt-required.log"
fake_out="$TMP_HOME/fake-apt-required.out"
fake_err="$TMP_HOME/fake-apt-required.err"
make_fake_package_manager "$fake_bin" apt-get
if PATH="$fake_bin:$PATH" FAKE_PM_LOG="$fake_log" FAKE_REQUIRED_FAIL=lazygit HOME="$TMP_HOME" TEST_HOME="$TMP_HOME" "$REPO_ROOT/scripts/install_packages.sh" --yes --package-manager apt >"$fake_out" 2>"$fake_err"; then
  fail "expected apt required package failure to return non-zero"
fi
grep -q '^error: required apt package(s) could not be installed' "$fake_err" || fail "expected apt required package error"
grep -q '^  - lazygit$' "$fake_err" || fail "expected failed apt package name"
grep -q 'install -y neovim' "$fake_log" || fail "expected apt install loop to continue after required failure"
printf 'ok: apt required package failures are reported and return non-zero\n\n'

printf 'Test 5f: apt optional font package failures warn but do not stop\n'
fake_bin="$TMP_HOME/fake-apt-optional"
fake_log="$TMP_HOME/fake-apt-optional.log"
fake_out="$TMP_HOME/fake-apt-optional.out"
fake_err="$TMP_HOME/fake-apt-optional.err"
make_fake_package_manager "$fake_bin" apt-get
PATH="$fake_bin:$PATH" FAKE_PM_LOG="$fake_log" FAKE_OPTIONAL_FAIL=fontconfig HOME="$TMP_HOME" TEST_HOME="$TMP_HOME" "$REPO_ROOT/scripts/install_packages.sh" --yes --package-manager apt --install-fonts >"$fake_out" 2>"$fake_err" || fail "optional apt font package failure should not return non-zero"
grep -q '^warning: optional apt package(s) could not be installed' "$fake_err" || fail "expected apt optional package warning"
grep -q '^  - fontconfig$' "$fake_err" || fail "expected failed optional apt package name"
if grep -q '^error: required' "$fake_err"; then
  fail "optional apt font package failure should not be reported as required"
fi
printf 'ok: apt optional font package failures remain non-fatal\n\n'

printf 'Test 5g: dnf required package failures stop the package step\n'
fake_bin="$TMP_HOME/fake-dnf-required"
fake_log="$TMP_HOME/fake-dnf-required.log"
fake_out="$TMP_HOME/fake-dnf-required.out"
fake_err="$TMP_HOME/fake-dnf-required.err"
make_fake_package_manager "$fake_bin" dnf
if PATH="$fake_bin:$PATH" FAKE_PM_LOG="$fake_log" FAKE_REQUIRED_FAIL=eza HOME="$TMP_HOME" TEST_HOME="$TMP_HOME" "$REPO_ROOT/scripts/install_packages.sh" --yes --package-manager dnf >"$fake_out" 2>"$fake_err"; then
  fail "expected dnf required package failure to return non-zero"
fi
grep -q '^error: required dnf package(s) could not be installed' "$fake_err" || fail "expected dnf required package error"
grep -q '^  - eza$' "$fake_err" || fail "expected failed dnf package name"
grep -q 'install -y bat' "$fake_log" || fail "expected dnf install loop to continue after required failure"
printf 'ok: dnf required package failures are reported and return non-zero\n\n'

printf 'Test 5h: doctor default mode treats unmanaged configs as warnings\n'
doctor_home="$TMP_HOME/doctor-default"
doctor_out="$TMP_HOME/doctor-default.out"
doctor_err="$TMP_HOME/doctor-default.err"
make_fake_doctor_tools "$doctor_home"
HOME="$doctor_home" TEST_HOME="$doctor_home" "$REPO_ROOT/scripts/doctor.sh" >"$doctor_out" 2>"$doctor_err" || fail "doctor default mode should not fail for unmanaged configs"
grep -q 'Config link mode: default' "$doctor_out" || fail "expected doctor default link mode"
grep -q 'warning: .*\.zshrc is not linked yet' "$doctor_out" || fail "expected unmanaged .zshrc warning"
grep -q 'Doctor summary: 0 failure(s)' "$doctor_out" || fail "doctor default mode should have no failures"
printf 'ok: doctor default mode reports unmanaged configs as warnings\n\n'

printf 'Test 5i: doctor strict mode fails on unmanaged configs\n'
doctor_home="$TMP_HOME/doctor-strict"
doctor_out="$TMP_HOME/doctor-strict.out"
doctor_err="$TMP_HOME/doctor-strict.err"
make_fake_doctor_tools "$doctor_home"
if HOME="$doctor_home" TEST_HOME="$doctor_home" "$REPO_ROOT/scripts/doctor.sh" --strict >"$doctor_out" 2>"$doctor_err"; then
  fail "doctor strict mode should fail for unmanaged configs"
fi
grep -q 'Config link mode: strict' "$doctor_out" || fail "expected doctor strict link mode"
grep -q 'fail: .*\.zshrc is not linked yet' "$doctor_out" || fail "expected strict .zshrc failure"
printf 'ok: doctor strict mode reports unmanaged configs as failures\n\n'

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
