# Terminal Starter Kit

A conservative, cross-platform dotfiles starter kit for a terminal workflow on macOS and Linux. It manages copied config files from `configs/` and links them into a target `HOME` only when explicitly requested.

Supported platforms:

- macOS
- Debian
- Ubuntu
- Raspberry Pi OS
- Arch Linux
- Fedora

Managed tools:

- zsh
- zsh-syntax-highlighting
- tmux
- starship
- fzf
- zoxide
- eza
- bat
- ripgrep
- fd
- lazygit
- neovim / nvim
- yazi
- Ghostty, optional GUI terminal emulator
- JetBrainsMono Nerd Font installation and supported terminal font application

## Feature Status

Core repository features:

- Safe dry-run mode for install, linking, import, restore, font install, terminal font application, and default-shell switching.
- CLI package installation through platform package managers.
- Optional GUI app handling for Ghostty without forcing it on Linux.
- Config symlink management from `configs/` into `HOME`.
- Adjacent timestamped backups before replacing existing config targets.
- Quick restore from adjacent backups.
- Existing local config import into repository copies, with optional sanitization.
- JetBrainsMono Nerd Font install for macOS and Linux users.
- Terminal font application for LXTerminal, Ghostty, Kitty, Foot, and conservative Alacritty defaults.
- Optional default shell switch to zsh through `--set-default-shell`.
- Doctor checks for installed tools and managed symlinks.
- Safety tests with a temporary `HOME`.

Platform support:

| Feature | macOS | Debian / Ubuntu | Raspberry Pi OS | Arch Linux | Fedora |
| --- | --- | --- | --- | --- | --- |
| OS detection | supported | supported | supported | supported | supported |
| CLI package install | Homebrew | apt | apt | pacman | dnf |
| Config symlinks | supported | supported | supported | supported | supported |
| Timestamp backups | supported | supported | supported | supported | supported |
| Quick restore | supported | supported | supported | supported | supported |
| Nerd Font install | user font dir | user font dir | user font dir | user font dir | user font dir |
| Terminal font apply | Ghostty / Kitty / Foot / Alacritty configs when present | LXTerminal / Ghostty / Kitty / Foot / Alacritty configs when present | LXTerminal tested, others config-based | LXTerminal / Ghostty / Kitty / Foot / Alacritty configs when present | LXTerminal / Ghostty / Kitty / Foot / Alacritty configs when present |
| Default shell switch to zsh | supported | supported | tested | supported | supported |
| Ghostty install | optional Homebrew cask | not forced | not forced | not forced | not forced |

Raspberry Pi OS has been tested as a real deployment target for package install, config links, zsh default shell, Starship prompt, zsh-syntax-highlighting, Nerd Font install, LXTerminal font application, VNC enablement outside this repository, quick restore logic, and doctor checks. Other supported platforms use the same scripts and safety model, but package availability depends on the enabled distribution repositories.

Known package caveat: some distribution versions may not provide every tool in the default repositories. For example, `yazi` may be missing from Debian or Raspberry Pi OS apt sources. The install script warns and continues instead of adding third-party repositories.

## Safety Model

The default behavior is read-only. Real writes require `--yes`, and existing config targets require `--backup` before they are replaced by symlinks.

- Start with `./install.sh --dry-run`.
- `--dry-run` prints actions only. It does not create files, symlinks, backups, or install packages.
- Existing targets are backed up next to the original path as `.backup.YYYYMMDD-HHMMSS`.
- `scripts/import_existing_configs.sh` copies from the current `HOME` into this repository only. It never writes back to source configs.
- `test_install.sh` uses a temporary `HOME` from `mktemp -d` and never runs package installation commands.

## Import Existing Configs

Preview the import first:

```sh
./scripts/import_existing_configs.sh --dry-run
```

Import and sanitize repository copies:

```sh
./scripts/import_existing_configs.sh --yes --sanitize
```

If a repository copy already exists, the import script skips it unless you explicitly allow a safe repository-side replacement:

```sh
./scripts/import_existing_configs.sh --yes --sanitize --overwrite-repo-copy
```

Sanitization only edits files under `configs/`. The original files in `HOME` are not changed. The report is written to `scripts/sanitize_report.md` and lists replacement categories only, not original secrets or private values.

## Install

Preview on any platform:

```sh
./install.sh --dry-run
```

Install CLI packages and link configs:

```sh
./install.sh --install-packages --backup --yes
```

Link configs only, without installing software:

```sh
./install.sh --link-only --backup --yes
```

Linux users who intentionally use Homebrew can opt in:

```sh
./install.sh --install-packages --package-manager brew --backup --yes
```

This repository does not install Homebrew for you.

Install optional GUI apps on supported platforms:

```sh
./install.sh --install-packages --install-gui-apps --backup --yes
```

Install terminal fonts. This installs the official JetBrainsMono Nerd Font into
the current user's font directory and applies it to supported terminal emulators:

```sh
./install.sh --install-packages --install-fonts --backup --yes
```

Font install locations:

- macOS: `~/Library/Fonts/NerdFonts/JetBrainsMono`
- Linux: `~/.local/share/fonts/NerdFonts/JetBrainsMono`

Supported terminal font application:

- LXTerminal, common on Raspberry Pi OS desktop
- Ghostty
- Kitty
- Foot
- Alacritty, conservative defaults only when no existing font table would be overwritten

For SSH sessions from macOS into Linux, the visible font is controlled by the macOS terminal app. For VNC desktop sessions, the Linux desktop terminal config is used.

Install packages, fonts, link configs, and switch the login shell to zsh:

```sh
./install.sh --install-packages --install-fonts --set-default-shell --backup --yes
```

Install CLI tools only:

```sh
./install.sh --install-packages --no-gui-apps --backup --yes
```

## Package Managers

macOS defaults to Homebrew and uses:

- `Brewfile.common` for CLI tools
- `Brewfile.macos` for optional macOS casks such as Ghostty
- `Brewfile.fonts` for macOS font casks

Linux defaults:

- Debian, Ubuntu, Raspberry Pi OS: `apt`
- Arch Linux: `pacman`
- Fedora: `dnf`

The Linux package lists live under `packages/`. Some tools such as `lazygit`, `yazi`, `eza`, and `zoxide` may not exist in every distribution version. The scripts do not add third-party apt/dnf repositories, do not run `curl | bash`, and do not compile Ghostty from source.

On Debian and Ubuntu, binary names may differ:

- `bat` may be installed as `batcat`
- `fd` may be installed as `fdfind`

## Config Links

The link step manages:

- `configs/zsh/zshrc` -> `~/.zshrc`
- `configs/zsh/zprofile` -> `~/.zprofile`
- `configs/zsh/zshenv` -> `~/.zshenv`
- `configs/tmux/tmux.conf` -> `~/.tmux.conf`
- `configs/starship/starship.toml` -> `~/.config/starship.toml`
- `configs/ghostty/config` -> `~/.config/ghostty/config`
- `configs/yazi/` -> `~/.config/yazi`
- `configs/lazygit/config.yml` -> `~/.config/lazygit/config.yml`
- `configs/nvim/` -> `~/.config/nvim`
- `configs/git/gitconfig` -> `~/.gitconfig`

If a target already points to the correct repository file, it is skipped. If it exists and is not managed by this repository, use `--backup --yes` to move it aside before linking.

## Doctor

Check installed tools and symlink status:

```sh
./scripts/doctor.sh
```

`doctor.sh` only checks. It does not install packages, create symlinks, or modify configs.

## Quick Restore

Preview restore actions:

```sh
./scripts/restore_backups.sh --dry-run
```

Restore the latest adjacent backups and remove symlinks managed by this repository:

```sh
./scripts/restore_backups.sh --yes
```

The restore script only unlinks targets that point back to this repository. It skips unrelated files, directories, and symlinks.

## Tests

Run the safety test suite:

```sh
./test_install.sh
```

The tests use a temporary `HOME`, verify dry-run behavior, verify symlink creation, verify backup behavior, and do not run `brew bundle`, `apt install`, `pacman -S`, or `dnf install`.

## Manual Restore Or Uninstall

To stop using a linked config, remove the symlink and restore the adjacent backup if one exists:

```sh
unlink ~/.zshrc
mv ~/.zshrc.backup.YYYYMMDD-HHMMSS ~/.zshrc
```

Use the actual backup timestamp created on your machine. For directory configs such as `~/.config/nvim`, remove the symlink and move the matching `nvim.backup.YYYYMMDD-HHMMSS` directory back into place.

## Shell

By default this repository does not change your default shell. If you want to switch manually after installing zsh:

```sh
chsh -s "$(which zsh)"
```

It can also switch automatically when explicitly requested:

```sh
./install.sh --set-default-shell --backup --yes
```

The shell switch step validates that `zsh` is installed, adds it to `/etc/shells` if needed, and then runs `chsh`. It still supports `--dry-run` and requires `--yes`.

## Ghostty

Ghostty is optional. This repository manages Ghostty config when present, but does not force-install Ghostty on Linux. On macOS, it can be installed through Homebrew cask or the official DMG. On Linux, use the installation method recommended by the Ghostty project or your distribution.

## Neovim

The repository stores a copy of the existing `nvim` config. It does not run Neovim, install plugins, run Lazy sync, run PackerSync, or run Mason installs.

## Lazygit

The default lazygit config avoids automatic push, rebase, and other high-risk Git workflow automation. If you import an existing lazygit config with custom commands, review it before sharing.
