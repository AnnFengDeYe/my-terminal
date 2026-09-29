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
mkdir -p "$TMP_HOME/.config/ghostty" "$TMP_HOME/.config/kitty" "$TMP_HOME/.config/alacritty"
printf 'theme = dark\nfont-family = Monospace\n' > "$TMP_HOME/.config/ghostty/config"
printf 'font_family Monospace\nfont_size 10\n' > "$TMP_HOME/.config/kitty/kitty.conf"
printf '[window]\ntitle = "Terminal"\n' > "$TMP_HOME/.config/alacritty/alacritty.toml"
printf 'keep existing temp\n' > "$TMP_HOME/.config/alacritty/alacritty.toml.tmp"
HOME="$TMP_HOME" TEST_HOME="$TMP_HOME" "$REPO_ROOT/scripts/apply_terminal_font.sh" --yes --skip-font-check >/dev/null
grep -q '^font-family = JetBrainsMono Nerd Font Mono$' "$TMP_HOME/.config/ghostty/config" || fail "Ghostty font family was not updated"
grep -q '^font-size = 11$' "$TMP_HOME/.config/ghostty/config" || fail "Ghostty font size was not updated"
grep -q '^font_family JetBrainsMono Nerd Font Mono$' "$TMP_HOME/.config/kitty/kitty.conf" || fail "Kitty font family was not updated"
grep -q '^font_size 11$' "$TMP_HOME/.config/kitty/kitty.conf" || fail "Kitty font size was not updated"
grep -q '^\[font\]$' "$TMP_HOME/.config/alacritty/alacritty.toml" || fail "Alacritty font table was not added"
grep -q '^family = "JetBrainsMono Nerd Font Mono"$' "$TMP_HOME/.config/alacritty/alacritty.toml" || fail "Alacritty font family was not updated"
grep -q '^keep existing temp$' "$TMP_HOME/.config/alacritty/alacritty.toml.tmp" || fail "Alacritty existing temp file should not be overwritten"
printf 'ok: Ghostty, Kitty, and Alacritty font configs updated\n\n'

printf 'Test 8: linking keeps the git identity in ~/.gitconfig.local\n'
git_home="$TMP_HOME/git-identity"
mkdir -p "$git_home"
printf '[user]\n\tname = Test Person\n\temail = test.person@example.invalid\n' > "$git_home/.gitconfig"

git_identity() {
  env -u XDG_CONFIG_HOME -u GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM=1 HOME="$git_home" git config --global --includes --get "$1"
}

if grep -q '<YOUR_' "$REPO_ROOT/configs/git/gitconfig"; then
  fail "the linked gitconfig must not carry a placeholder identity"
fi
HOME="$git_home" TEST_HOME="$git_home" "$REPO_ROOT/install.sh" --dry-run --link-only --backup >/dev/null
assert_missing "$git_home/.gitconfig.local"
HOME="$git_home" TEST_HOME="$git_home" "$REPO_ROOT/install.sh" --link-only --backup --yes >/dev/null
assert_symlink "$git_home/.gitconfig"
[[ -f "$git_home/.gitconfig.local" && ! -L "$git_home/.gitconfig.local" ]] || fail "expected ~/.gitconfig.local to be created"
[[ "$(git_identity user.name)" == "Test Person" ]] || fail "git user.name was lost by linking"
[[ "$(git_identity user.email)" == "test.person@example.invalid" ]] || fail "git user.email was lost by linking"

printf '# edited by hand\n' >> "$git_home/.gitconfig.local"
rm "$git_home/.gitconfig"
printf '[user]\n\tname = Someone Else\n' > "$git_home/.gitconfig"
HOME="$git_home" TEST_HOME="$git_home" "$REPO_ROOT/install.sh" --link-only --backup --yes >/dev/null
grep -q '^# edited by hand$' "$git_home/.gitconfig.local" || fail "an existing ~/.gitconfig.local was overwritten"
[[ "$(git_identity user.name)" == "Test Person" ]] || fail "an existing ~/.gitconfig.local should keep winning"
printf 'ok: identity moved to ~/.gitconfig.local and an existing one is kept\n\n'

printf 'Test 9: renamed Debian binaries are linked to their upstream names\n'
shim_home="$TMP_HOME/shims"
shim_bin="$TMP_HOME/shim-bin"
shim_path="$shim_bin:/usr/bin:/bin"
mkdir -p "$shim_home" "$shim_bin"
for cmd in batcat fdfind; do
  printf '#!/usr/bin/env sh\nexit 0\n' > "$shim_bin/$cmd"
  chmod +x "$shim_bin/$cmd"
done

run_shims() {
  PATH="$shim_path" MY_TERMINAL_EXTRA_PATH="" HOME="$shim_home" TEST_HOME="$shim_home" \
    "$REPO_ROOT/scripts/install_command_shims.sh" "$@"
}

run_shims --dry-run >/dev/null
assert_missing "$shim_home/.local"
run_shims --yes >/dev/null
run_shims --yes >/dev/null
for pair in bat:batcat fd:fdfind; do
  shim_name="${pair%%:*}"
  shim_alt="${pair#*:}"
  if PATH="/usr/bin:/bin" command -v "$shim_name" >/dev/null 2>&1; then
    assert_missing "$shim_home/.local/bin/$shim_name"
  else
    assert_symlink "$shim_home/.local/bin/$shim_name"
    [[ "$(readlink "$shim_home/.local/bin/$shim_name")" == "$shim_bin/$shim_alt" ]] || fail "$shim_name should point to $shim_alt"
  fi
done

shim_keep_home="$TMP_HOME/shims-keep"
mkdir -p "$shim_keep_home/.local/bin"
printf 'not a program\n' > "$shim_keep_home/.local/bin/bat"
PATH="$shim_path" MY_TERMINAL_EXTRA_PATH="" HOME="$shim_keep_home" TEST_HOME="$shim_keep_home" \
  "$REPO_ROOT/scripts/install_command_shims.sh" --yes >/dev/null
[[ -f "$shim_keep_home/.local/bin/bat" && ! -L "$shim_keep_home/.local/bin/bat" ]] || fail "an existing file was replaced by a shim"
grep -q '^not a program$' "$shim_keep_home/.local/bin/bat" || fail "an existing file was modified by a shim"
printf 'ok: shims created once, existing files left alone\n\n'

printf 'Test 9b: doctor explains renamed binaries and a missing git identity\n'
doctor_home="$TMP_HOME/doctor-renamed"
doctor_out="$TMP_HOME/doctor-renamed.out"
make_fake_doctor_tools "$doctor_home"
mv "$doctor_home/.local/bin/bat" "$doctor_home/.local/bin/batcat"
mv "$doctor_home/.local/bin/fd" "$doctor_home/.local/bin/fdfind"
PATH="/usr/bin:/bin" MY_TERMINAL_EXTRA_PATH="" HOME="$doctor_home" TEST_HOME="$doctor_home" \
  "$REPO_ROOT/scripts/doctor.sh" >"$doctor_out" 2>&1 || fail "renamed binaries should not fail doctor"
if ! PATH="/usr/bin:/bin" command -v bat >/dev/null 2>&1; then
  grep -q 'warning: bat is only available as batcat' "$doctor_out" || fail "expected renamed bat warning"
fi
if ! PATH="/usr/bin:/bin" command -v fd >/dev/null 2>&1; then
  grep -q 'warning: fd is only available as fdfind' "$doctor_out" || fail "expected renamed fd warning"
fi
grep -q 'warning: git identity is not set' "$doctor_out" || fail "expected missing git identity warning"
grep -q 'Doctor summary: 0 failure(s)' "$doctor_out" || fail "renamed binaries should be warnings only"

printf '[user]\n\tname = <YOUR_NAME>\n\temail = <YOUR_EMAIL>\n[core]\n\teditor = missing-editor-for-tests -w\n' > "$doctor_home/.gitconfig"
PATH="/usr/bin:/bin" MY_TERMINAL_EXTRA_PATH="" HOME="$doctor_home" TEST_HOME="$doctor_home" \
  "$REPO_ROOT/scripts/doctor.sh" >"$doctor_out" 2>&1 || fail "placeholder identity should not fail doctor"
grep -q 'warning: git identity is still a placeholder' "$doctor_out" || fail "expected placeholder identity warning"
grep -q 'warning: git core.editor is .* but missing-editor-for-tests is not installed' "$doctor_out" || fail "expected missing git editor warning"

# An editor whose path contains spaces is quoted in the git config.
mkdir -p "$doctor_home/My Apps"
printf '#!/usr/bin/env sh\nexit 0\n' > "$doctor_home/My Apps/edit"
chmod +x "$doctor_home/My Apps/edit"
printf "[user]\n\tname = Test Person\n\temail = test.person@example.invalid\n[core]\n\teditor = '%s' --wait\n" "$doctor_home/My Apps/edit" > "$doctor_home/.gitconfig"
PATH="/usr/bin:/bin" MY_TERMINAL_EXTRA_PATH="" HOME="$doctor_home" TEST_HOME="$doctor_home" \
  "$REPO_ROOT/scripts/doctor.sh" >"$doctor_out" 2>&1 || fail "a quoted editor path should not fail doctor"
grep -q 'ok: git identity is set' "$doctor_out" || fail "expected the git identity to be recognised"
grep -q "ok: git editor $doctor_home/My Apps/edit found" "$doctor_out" || fail "expected the quoted git editor to be found: $(grep editor "$doctor_out")"
printf 'ok: doctor points at the fix\n\n'

printf 'Test 12: importing a gitconfig never brings an identity into the repository\n'
import_repo="$TMP_HOME/import-repo"
import_home="$TMP_HOME/import-home"
mkdir -p "$import_repo" "$import_home"
cp -R "$REPO_ROOT/scripts" "$REPO_ROOT/configs" "$import_repo/"
printf '[user]\n\tname = Real Person\n\temail = real.person@example.invalid\n\tsigningkey = ABCDEF0123\n[push]\n\tdefault = current\n' > "$import_home/.gitconfig"
HOME="$import_home" USER="import-test-user" "$import_repo/scripts/import_existing_configs.sh" --yes --sanitize --overwrite-repo-copy >/dev/null
imported_gitconfig="$import_repo/configs/git/gitconfig"
if grep -Eiq 'Real Person|real\.person|ABCDEF0123|<YOUR_' "$imported_gitconfig"; then
  fail "imported gitconfig still carries an identity: $(cat "$imported_gitconfig")"
fi
if grep -Eiq '^[[:space:]]*(name|email|signingkey)[[:space:]]*=' "$imported_gitconfig"; then
  fail "imported gitconfig still has identity keys"
fi
grep -q 'default = current' "$imported_gitconfig" || fail "imported gitconfig lost a non-identity setting"
grep -q 'path = ~/.gitconfig.local' "$imported_gitconfig" || fail "imported gitconfig should include ~/.gitconfig.local"
grep -q 'Real Person' "$import_home/.gitconfig" || fail "import must not modify the source config"

# A config without a final newline must not swallow the include section.
printf '[user]\n\tname = Real Person\n[push]\n\tdefault = current' > "$import_home/.gitconfig"
HOME="$import_home" USER="import-test-user" "$import_repo/scripts/import_existing_configs.sh" --yes --sanitize --overwrite-repo-copy >/dev/null
[[ "$(git config --file "$imported_gitconfig" --get push.default)" == "current" ]] || fail "import damaged the last setting: $(cat "$imported_gitconfig")"
# shellcheck disable=SC2088 # git stores the path with a literal "~"
expected_include="~/.gitconfig.local"
[[ "$(git config --file "$imported_gitconfig" --get include.path)" == "$expected_include" ]] || fail "import lost the include: $(cat "$imported_gitconfig")"
printf 'ok: identity stripped from the repository copy, source untouched\n\n'

printf 'All tests passed. No package installation commands were executed.\n'
