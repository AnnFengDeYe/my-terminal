# 🚀 my-terminal

[![CI](https://github.com/AnnFengDeYe/my-terminal/actions/workflows/ci.yml/badge.svg)](https://github.com/AnnFengDeYe/my-terminal/actions/workflows/ci.yml)
![Shell](https://img.shields.io/badge/Shell-Bash-4EAA25?logo=gnu-bash&logoColor=white)
![Platform](https://img.shields.io/badge/Platform-macOS%20%7C%20Linux%20%7C%20Raspberry%20Pi-blue)
![License](https://img.shields.io/github/license/AnnFengDeYe/my-terminal)

[English](README.en.md) | [中文](README.md)

**Cross-platform · Out-of-the-box · Reproducible Terminal Starter Kit.**

While there is no shortage of excellent terminal tools, seamlessly integrating them into a work environment that aligns with intuitive human-computer interaction often requires spending significant time resolving compatibility and dependency issues. This project shares a configuration setup based on my personal workflow habits and visual aesthetics. It resolves the common friction and conflicts among plugins, allowing you to quickly replicate a smooth, out-of-the-box terminal workflow.

It supports macOS, Debian, Ubuntu, Raspberry Pi OS, Arch Linux, and Fedora. The repository manages CLI tools, terminal fonts, and dotfile symlinks. The default entrypoint does not write to the system directly; all real writes require explicit confirmation, and existing configs are backed up before replacement.

## 🖼️ Workspace Preview

![my-terminal workspace](assets/workspace-layout.jpg)

`workspace_layout.sh` creates a long-lived tmux workspace designed for daily use:

- The bottom **tmux workspace bar** switches between contexts with `1:dev`, `2:agent`, `3:ssh`, `4:logs`, `5:btop`, and `6:manual`.
- **`1:dev`**: the main development workspace with `Code` / `Command` / `Git` / `Files` panes.
- **`2:agent`**: AI assistant workspace split into `Codex` / `Gemini` by default. If the matching CLI is installed, the pane enters it automatically; otherwise it stays as a normal shell.
- **`3:ssh`**: remote session workspace with a 4-pane `ssh-1` to `ssh-4` grid for multiple devices.
- **`4:logs`**: tests, logs, and watch commands split into `logs-1` / `logs-2`.
- **`5:btop`**: a dedicated system monitor page running `btop` by default.
- **`6:manual`**: an alias and function manual for quickly looking up common `zshrc` commands.

The `manual` data lives in `configs/zsh/workplace_manual.tsv`; edit that table when adding or changing aliases, then run `./scripts/workplace_manual.sh --check` to confirm the manual still matches `zshrc` (`--sync` fixes drifted line numbers).

Start a workspace for the current directory:

```sh
./scripts/workspace_layout.sh
```

If the zsh config from this repository is loaded, use the shortcut command:

```sh
workplace
```

Start a workspace for another project:

```sh
./scripts/workspace_layout.sh --dir ~/your-project
```

On startup, it detects the current terminal size and fits the tmux workspace to the full terminal window. When entering an existing workspace, it only syncs window size and preserves current pane ratios and zoom state, so enlarged panes are not reset to the default layout. Set `WORKSPACE_COLS` / `WORKSPACE_LINES` when you need a fixed size.

### 🗂️ One workspace per project

`workplace` enters a single shared daily workspace by default. With `--project` (alias `wp`), every project gets its own. A project is the git repository that contains the directory, or the directory itself outside a repository, so running the command from any subdirectory, or pointing `--dir` at one, returns to the same workspace. The daily workspace and workspaces named with `--session` never count as the project workspace of a directory, even when they were started there.

| Command | What it does |
| --- | --- |
| `wp` / `workplace --project` | Enter the workspace of the current project, creating it when needed |
| `wpick` / `workplace --pick` | Pick a running workspace, or a project directory to open as a new one; `Alt+0` opens the same picker inside tmux |
| `wls` / `workplace --sessions` | List running workspaces with their kind (`daily` / `project` / `named`) and directory |

- The picker offers directories from your zoxide history; set `WORKSPACE_PICK_DIRS=~/projects:~/work` to add parent directories. It shows a preview when fzf is installed and falls back to a numbered menu otherwise.
- Set `WORKSPACE_SESSION_MODE=project` to make `workplace` per-project by default; `workplace --global` then enters the daily workspace.
- The left side of the status bar names the current workspace and the current window is highlighted; a window that rings the bell is marked with `!`.
- Change `Alt+0` with `WORKSPACE_PICK_KEY`, or set it to `none` to remove the binding. The key belongs to the whole tmux server and is remembered once set.
- Entering or switching to a running workspace leaves it the way it was: its window, its pane, and anything half typed.
- When another command named `wp` is installed (WP-CLI, for example), the `wp` alias is not defined; use `workplace --project` instead.

### 🤖 Agent window

The default agent config lives in `configs/workspace/agents.tsv`. This repository does not install Codex, Gemini, or any other AI CLI automatically; each pane only checks whether the configured command exists, starts it when available, and falls back to a shell when it is missing. To customize agents, set `WORKSPACE_AGENT_CONFIG=/path/to/agents.tsv`, create `~/.config/my-terminal/workspace_agents.tsv`, or create `.my-terminal/agents.tsv` inside a project:

```tsv
# role	title	command	cwd
agent-1	Codex	codex	worktree
agent-2	Gemini	gemini	worktree
agent-3	Claude	claude
```

Columns are separated by tabs, and several tabs may be used to align them; an empty column is therefore written as `-`, for example `-` in the command column for a plain shell. The optional 4th column, `cwd`, is where the agent starts: leaving it out means the workspace directory, `worktree` means a git worktree of its own, and anything else is a path (relative to the workspace directory, or starting with `/` or `~/`). The agent process can read `WORKSPACE_ROOT`, `WORKSPACE_AGENT_ROLE`, and `WORKSPACE_AGENT_TITLE` from its environment.

Settings such as `WORKSPACE_AGENT_CONFIG` and `--agent-worktrees` are kept with the workspace they created: entering it again or running `--repair` uses them without being told. They are not passed on to the shells inside the workspace, so a command typed there starts from your own environment and never carries the settings of one workspace into another.

**Project configs must be trusted first.** The commands in `.my-terminal/agents.tsv` start automatically when the workspace opens, so a freshly cloned repository must not be able to run anything. An untrusted project config is ignored with a notice, and the next config in line is used instead. Review the file, then run `workplace --trust` once; editing the file revokes trust until you run it again.

**Let several agents edit in parallel.** Agents that share one working directory overwrite each other. `worktree` gives each agent its own git worktree and branch (`agent/<role>`) and leaves your checkout alone:

```sh
workplace --project --agent-worktrees   # every agent uses a worktree this time
workplace --worktrees                   # branch and state of each worktree
git merge agent/agent-1                 # merge an agent's work from your checkout
workplace --prune-worktrees             # preview what can be removed
workplace --prune-worktrees --yes       # remove it
```

Worktrees are created outside the repository (`~/.local/share/my-terminal/worktrees/`, change it with `WORKSPACE_WORKTREE_ROOT`), so editors, search tools, and language servers never see a second copy of the code. Pruning only removes worktrees that cannot lose work: anything with uncommitted changes, unmerged commits, or a pane still running inside it is kept.

**Ask every agent the same question.** `wsend` (`workplace --send`) pastes text into every running agent and presses Enter, which makes answers easy to compare:

```sh
wsend "review the staged diff and list risky changes"
wsend "answer this one only" --to Claude   # filter by role or title, comma-separated
git diff --staged | wsend -                # read the text from stdin
wsend "do not commit yet" --no-enter       # paste without pressing Enter
```

Only panes whose agent holds the terminal receive the text. Panes sitting at a shell prompt, in ssh, or in a REPL are skipped, so backticks or `$(...)` inside a prompt are never executed by a shell; an agent that you quit and started again by hand is recognised as well. Enter is only pressed once the text shows up in the agent: an agent that is asking a question (signing in, trusting a directory, confirming an action, offering an update) does not show pasted text, and Enter would answer for you. Such a pane is reported as `held` and left for you.

**Check that your agents work here.** `./scripts/check_agents.sh` starts the configured agents for real in a tmux server of their own, pastes a short text into each, and reports what happened. It never presses Enter, submits nothing, and closes the agents at the end.

**Know when an agent needs you.** When an agent rings the bell, `2:agent` in the status bar is marked with `!` and changes colour. If your CLI never rings the bell, `export WORKSPACE_AGENT_SILENCE=30` in your shell config: the agent window is marked with `~`, and the terminal bell rings once, after 30 quiet seconds.

### 🔧 Repair and reset

`workplace` starts or enters the workspace. When entering an existing workspace, you are back at the window and pane you left, with anything half typed still there; it also performs a light, non-destructive repair: it restores managed window names, ordering, tmux hooks, and options without deleting unknown windows or stopping running tasks.

If a managed pane was closed, or pane titles / roles were changed, run `workplace --repair` to recreate missing managed panes and repair pane metadata; it does not delete existing panes or unknown windows. Use `workplace --repair-layout` when you also want to refit managed pane layouts. `workplace --reset` deletes and recreates the whole tmux session, which stops any tasks running inside it.

`--reset` rebuilds with the settings of that one command, not with the ones the workspace had: to keep a custom agent config or worktrees, name them again when you reset; leave them out to go back to the defaults.

Run inside a workspace, these commands act on the workspace you are in; when the command names another target with `--session`, `--project`, `--global`, or `--dir`, the command wins. `workplace --reset` run from inside builds the new workspace first, moves your terminal over, and only then removes the old one, so you are never dropped out of tmux, and it rebuilds in the directory the workspace already had; run from outside, it rebuilds in the current directory.

Pane border labels are stored by the workspace, so a program that rewrites the terminal title with escape sequences cannot change them.

## ✨ Key Features

- **🌍 Cross-platform install**: detects the OS and uses the matching package manager: Homebrew, apt, pacman, or dnf. Linux can also use Homebrew when explicitly selected.
- **🛡️ Safety first**: preview mode is read-only. It does not create files, install packages, or create symlinks. Real writes require `--yes`, and replacing existing configs requires `--backup`.
- **🧩 Restorable configs**: existing configs are backed up next to the original target, for example `~/.zshrc.backup.20260507-160000`.
- **🧪 Automated tests**: GitHub Actions runs Bash / zsh syntax checks, ShellCheck, temporary-HOME safety tests, and tmux workspace tests on both Ubuntu and macOS. Both test suites also run locally without touching your configs or tmux sessions.
- **🤖 A workspace built for several agents**: one workspace per project, agents that work in parallel in their own git worktrees, and one command to ask all of them; agent configs that come with a project only run after you trust them.
- **🎭 Privacy sanitization**: existing local configs can be imported into repository copies, with sensitive data sanitized only inside the repository.

## ⚡ Quick Start

Enter the repository and start the interactive menu:

```sh
./setup.sh
```

Recommended first run:

1. Select `1) Preview install` to inspect the OS, tools, fonts, and config link status.
2. Select `2) Start install` after reviewing the preview.
3. Type uppercase `YES` when prompted.
4. Reopen your terminal, or reconnect over SSH.

The menu defaults to Chinese. To use English:

```sh
./setup.sh --lang en
```

The default language can be changed in [setup.conf](./setup.conf).

## 🧭 Menu Actions

| Option | Action | Writes to system |
| --- | --- | --- |
| `1) Preview install` | Shows OS, package manager, tool, font, and config link status | No |
| `2) Start install` | Installs CLI tools, installs Nerd Font, links configs, and sets zsh as the default shell | Yes, requires `YES` |
| `3) Check configuration` | Runs `doctor.sh` to check tools and symlink status | No |
| `4) Restore backups` | Removes repository-managed symlinks and restores the latest backups | Yes, requires `YES` |
| `5) Advanced options` | Link-only setup, optional GUI apps, local config import, and command reference | Depends on selected action |
| `l) Switch language` | Switches between Chinese and English menus | No |
| `0) Exit` | Exits the installer | No |

## 🧰 Included Tools

This repository can automatically install and configure these tools:

**💻 Core CLI / TUI**

- **Shell and prompt**: `zsh`, `zsh-syntax-highlighting`, `starship`
- **CLI enhancements**: `eza`, `bat` / `batcat`, `zoxide`, `ripgrep`, `fd` / `fdfind`, `fzf`. Debian, Ubuntu, and Raspberry Pi OS install `bat` and `fd` as `batcat` and `fdfind`; the installer links them as `bat` and `fd` in `~/.local/bin` so the aliases, fzf previews, Yazi, and LazyVim can find them.
- **System monitor**: `btop`
- **Terminal and file workflow**: `tmux`, `yazi`
- **Developer tools**: `neovim` / `nvim`, `lazygit`

**🖥️ Optional GUI app**

- **Ghostty**: installed only through advanced options or `--install-gui-apps`. macOS uses the larger window profile; Linux / Raspberry Pi OS uses the smaller `70 x 20` profile.

**🔤 Font**

- **JetBrainsMono Nerd Font**: installed into the user font directory and applied where possible to Ghostty, Kitty, Alacritty, LXTerminal, Foot, and similar terminals.

## 🌍 Supported Platforms

| Platform | Default package manager |
| --- | --- |
| macOS | Homebrew |
| Debian | apt |
| Ubuntu | apt |
| Raspberry Pi OS | apt |
| Arch Linux | pacman |
| Fedora | dnf |

Optional Homebrew on Linux:

```sh
./install.sh --install-packages --package-manager brew --backup --yes
```

The scripts do not automatically install Homebrew, rustup, third-party apt sources, PPAs, COPR repositories, or run `curl | bash`.

## 🔗 Config Links

During install, configs under `configs/` are symlinked into the target HOME. Existing targets are never overwritten directly; they are backed up first.

| Repository source | Target path |
| --- | --- |
| `configs/zsh/zshrc` | `~/.zshrc` |
| `configs/zsh/zprofile` | `~/.zprofile` |
| `configs/zsh/zshenv` | `~/.zshenv` |
| `configs/tmux/tmux.conf` | `~/.tmux.conf` |
| `configs/starship/starship.toml` | `~/.config/starship.toml` |
| `configs/ghostty/config` | macOS: `~/.config/ghostty/config` |
| `configs/ghostty/config.linux` | Linux / Raspberry Pi OS: `~/.config/ghostty/config` |
| `configs/yazi/` | `~/.config/yazi` |
| `configs/lazygit/config.yml` | `~/.config/lazygit/config.yml` |
| `configs/nvim/` | `~/.config/nvim` |
| `configs/git/gitconfig` | `~/.gitconfig` |

`configs/git/gitconfig` holds shared defaults only. It carries no identity and ends by including `~/.gitconfig.local`. If you already have a `~/.gitconfig` when the link is created, it is copied to `~/.gitconfig.local` first (an existing one is never overwritten), so your name, email, signing, and credential settings keep working. Put personal settings in `~/.gitconfig.local`, for example `git config --file ~/.gitconfig.local user.name "Your Name"`; `git config --global` follows the symlink and edits the repository file.

## 🛠️ Command Reference

| Goal | Command |
| --- | --- |
| Open interactive menu | `./setup.sh` |
| English menu | `./setup.sh --lang en` |
| Safe preview | `./install.sh --dry-run` |
| Recommended install | `./install.sh --install-packages --install-fonts --set-default-shell --backup --yes` |
| Recommended install with Ghostty | `./install.sh --install-packages --install-gui-apps --install-fonts --set-default-shell --backup --yes` |
| Link configs only | `./install.sh --link-only --backup --yes` |
| Check configuration | `./scripts/doctor.sh` |
| Check that the alias manual matches zshrc | `./scripts/workplace_manual.sh --check`, fix line numbers with `--sync` |
| Link `batcat` / `fdfind` as `bat` / `fd` | `./scripts/install_command_shims.sh --yes` |
| Quickly enter daily workspace | `workplace` |
| Enter the workspace of the current project | `wp` or `workplace --project` |
| Pick or create a project workspace | `wpick` or `workplace --pick`, `Alt+0` inside tmux |
| List running workspaces | `wls` or `workplace --sessions` |
| Send one prompt to every agent | `wsend "..."` or `workplace --send "..."` |
| Give each agent its own worktree | `workplace --project --agent-worktrees` |
| List / clean up agent worktrees | `workplace --worktrees`, `workplace --prune-worktrees [--yes]` |
| Trust the agent config of a project | `workplace --trust` |
| Check that your agents take a prompt | `./scripts/check_agents.sh` |
| Non-destructively repair workspace | `workplace --repair` or `./scripts/workspace_layout.sh --repair` |
| Recreate workspace | `workplace --reset` or `./scripts/workspace_layout.sh --reset` |
| Open README showcase layout | `./scripts/showcase_layout.sh --reset` |
| Preview restore | `./scripts/restore_backups.sh --dry-run` |
| Run restore | `./scripts/restore_backups.sh --yes` |
| Preview local config import | `./scripts/import_existing_configs.sh --dry-run` |
| Import local configs with sanitization | `./scripts/import_existing_configs.sh --yes --sanitize` |
| Run install safety tests | `./test_install.sh` |
| Run workspace tests | `./test_workspace.sh` |

## 🔁 Restore and Import

Restore only touches symlinks managed by this repository. It does not delete normal files. The `~/.gitconfig.local` file and the `bat` / `fd` links in `~/.local/bin` created during install are kept; delete them by hand if you no longer want them.

```sh
./scripts/restore_backups.sh --dry-run
./scripts/restore_backups.sh --yes
```

Import only copies from the current HOME into repository `configs/`. It never writes back to the real source configs.

```sh
./scripts/import_existing_configs.sh --dry-run
./scripts/import_existing_configs.sh --yes --sanitize
```

The sanitization report is written to [scripts/sanitize_report.md](./scripts/sanitize_report.md).

## 📂 Repository Layout

```text
.
├── setup.sh               # interactive entrypoint
├── install.sh             # core install script
├── test_install.sh        # temporary-HOME safety tests
├── test_workspace.sh      # workspace tests on an isolated tmux server
├── LICENSE                # MIT License
├── assets/                # README images and showcase assets
├── configs/               # dotfiles to link
├── packages/              # platform package lists
├── scripts/               # doctor, restore, import, and maintenance scripts
├── Brewfile.common        # common Homebrew CLI dependencies
└── Brewfile.fonts         # Homebrew font dependencies
```

## 📄 License

This project is licensed under the [MIT License](./LICENSE).
