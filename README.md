# Terminal Starter Kit

Cross-platform terminal dotfiles for macOS and Linux. The repository manages copied configs under `configs/` and links them into a target `HOME` only when explicitly requested.

## Supported Platforms

- macOS, using Homebrew
- Debian, Ubuntu, Raspberry Pi OS, using apt
- Arch Linux, using pacman
- Fedora, using dnf

## Managed Tools

- zsh, zsh-syntax-highlighting
- tmux, starship
- fzf, zoxide, eza, bat, ripgrep, fd
- lazygit, neovim, yazi
- Ghostty config, optional GUI terminal
- JetBrainsMono Nerd Font

## Safety Rules

- Default behavior is read-only.
- Use `--dry-run` before real installs.
- Real writes require `--yes`.
- Existing config targets require `--backup`.
- Backups are stored next to the original target, for example `.zshrc.backup.20260507-160000`.
- Tests use a temporary `HOME` and never run real package installation.
- Import only copies from the current `HOME` into this repository. It never writes back to source configs.

## Quick Start

For the simplest guided setup:

```sh
./setup.sh
```

The menu is Chinese by default and can preview, install, check, restore, or open advanced options. Change the default language in `setup.conf`, or run:

```sh
./setup.sh --lang en
```

Advanced options include link-only setup, optional GUI apps, local config import, and command reference.

The menu preview is concise: it lists tool, font, and config-link status without writing files. For the detailed low-level dry-run:

```sh
./install.sh --dry-run
```

Install CLI tools, link configs, install Nerd Font, and switch login shell to zsh:

```sh
./install.sh --install-packages --install-fonts --set-default-shell --backup --yes
```

Link configs only:

```sh
./install.sh --link-only --backup --yes
```

Install optional GUI apps such as Ghostty on supported platforms:

```sh
./install.sh --install-packages --install-gui-apps --install-fonts --backup --yes
```

Check the result:

```sh
./scripts/doctor.sh
```

Run safe tests:

```sh
./test_install.sh
```

## Import Existing Configs

Preview import:

```sh
./scripts/import_existing_configs.sh --dry-run
```

Import and sanitize repository copies:

```sh
./scripts/import_existing_configs.sh --yes --sanitize
```

If repository copies already exist:

```sh
./scripts/import_existing_configs.sh --yes --sanitize --overwrite-repo-copy
```

Sanitization only edits files under `configs/`. The report is written to `scripts/sanitize_report.md`.

## Config Links

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

## Package Files

- `Brewfile.common`: macOS and Linux Homebrew CLI tools
- `Brewfile.macos`: macOS-only optional casks
- `Brewfile.fonts`: macOS font casks
- `packages/debian.txt`, `packages/arch.txt`, `packages/fedora.txt`: Linux CLI packages
- `packages/*-fonts.txt`: Linux font dependencies

Linux package availability depends on the enabled distribution repositories. The scripts do not add third-party repositories and do not run `curl | bash`.

Yazi is handled separately from Linux distro package lists:

- macOS: Homebrew
- Linux: existing Homebrew first, existing Cargo second, verified official binary fallback where supported
- The project does not install Homebrew, rustup, or Cargo automatically
- Cargo fallback uses the official `cargo install --force yazi-build` flow

## Fonts

`--install-fonts` installs JetBrainsMono Nerd Font into the current user's font directory:

- macOS: `~/Library/Fonts/NerdFonts/JetBrainsMono`
- Linux: `~/.local/share/fonts/NerdFonts/JetBrainsMono`

The font application script supports LXTerminal, Ghostty, Kitty, Foot, and conservative Alacritty defaults. SSH font rendering is controlled by the local terminal app.

## Ghostty

Ghostty is optional GUI software. `--install-gui-apps` uses safe package routes:

- macOS: Homebrew cask
- Arch Linux: official `pacman` package
- Debian, Ubuntu, Raspberry Pi OS: enabled `apt` repository first, then Snap
- Fedora: enabled `dnf` repository first, then Snap

The scripts do not add third-party apt sources, PPAs, COPR repositories, or run community `curl | bash` installers. On Linux, Snap fallback may install `snapd` from the enabled system repositories.

## Restore

Preview restore:

```sh
./scripts/restore_backups.sh --dry-run
```

Restore latest adjacent backups and remove repository-managed symlinks:

```sh
./scripts/restore_backups.sh --yes
```

Manual restore is also possible:

```sh
unlink ~/.zshrc
mv ~/.zshrc.backup.YYYYMMDD-HHMMSS ~/.zshrc
```

## Verified On Raspberry Pi

The Raspberry Pi deployment has been tested for apt package install, config symlinks, zsh as the default shell, Starship prompt, zsh-syntax-highlighting, Nerd Font install, LXTerminal font application, restore logic, and doctor checks.
