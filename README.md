# 🚀 my-terminal

[![CI](https://github.com/AnnFengDeYe/my-terminal/actions/workflows/ci.yml/badge.svg)](https://github.com/AnnFengDeYe/my-terminal/actions/workflows/ci.yml)
![Shell](https://img.shields.io/badge/Shell-Bash-4EAA25?logo=gnu-bash&logoColor=white)
![Platform](https://img.shields.io/badge/Platform-macOS%20%7C%20Linux%20%7C%20Raspberry%20Pi-blue)
![License](https://img.shields.io/github/license/AnnFengDeYe/my-terminal)

[中文](README.md) | [English](README.en.md)

一个跨平台、可恢复、可测试的 **Terminal Starter Kit**，用于快速部署一套开箱即用的高效终端环境。

支持 macOS、Debian、Ubuntu、Raspberry Pi OS、Arch Linux 和 Fedora。仓库统一管理 CLI 工具、终端字体和 dotfiles 软链接；默认入口不会直接写入系统，所有真实写入操作都需要显式确认，并会在覆盖前备份原配置。

## 🖼️ Workspace 预览

![my-terminal workspace](assets/workspace-layout.jpg)

`workspace_layout.sh` 会创建一个可长期使用的 tmux 工作区，而不是只用于截图的演示画面：

- 底部 **tmux workspace bar** 使用 `1:dev`、`2:ai`、`3:ssh`、`4:logs` 在不同工作上下文之间切换。
- **`1:dev`**：主开发工作区，包含 `Code` / `Command` / `Files` / `Git` 四个 pane。
- **`2:ai`**：AI 辅助工作区，可运行 Codex CLI。
- **`3:ssh`**：远程连接工作区。
- **`4:logs`**：测试、日志和 watch 命令工作区。

启动当前目录的工作区：

```sh
./scripts/workspace_layout.sh --reset
```

如果已通过本仓库加载 zsh 配置，可以直接使用快速命令：

```sh
workplace
```

`workplace` 会启动或进入当前目录的日常 workspace；需要重建会话时可运行 `workplace --reset`。

启动时会自动检测当前终端尺寸并让 tmux workspace 铺满整个终端窗口；进入已有 workspace 时也会重新调整 4 个 pane 的布局，避免旧尺寸留下空白占位。需要固定尺寸时可设置 `WORKSPACE_COLS` / `WORKSPACE_LINES`。

为其他项目启动工作区：

```sh
./scripts/workspace_layout.sh --dir ~/your-project --reset
```

## ✨ 核心特性

- **🌍 跨平台安装**：自动识别系统并调用对应包管理器：Homebrew、apt、pacman 或 dnf。Linux 也可以手动指定 Homebrew。
- **🛡️ 安全优先**：预览模式只读，不创建文件、不安装软件、不创建软链接。真实写入必须带 `--yes`，覆盖已有配置必须带 `--backup`。
- **🧩 可恢复配置**：原有配置会备份到同目录，例如 `~/.zshrc.backup.20260507-160000`。
- **🧪 自动化测试**：GitHub Actions 会运行 Bash 语法检查、ShellCheck、临时 HOME 安全测试，以及 tmux workspace / showcase smoke test。
- **🎭 隐私脱敏**：可将当前本机配置导入仓库副本，并只在仓库内执行敏感信息脱敏。

## ⚡ 快速开始

进入仓库目录，运行交互式菜单：

```sh
./setup.sh
```

首次使用建议流程：

1. 选择 `1) 预览安装`，检查系统、工具、字体和配置链接状态。
2. 确认无误后选择 `2) 开始安装`。
3. 按提示输入大写 `YES`。
4. 安装完成后重新打开终端，或重新 SSH 登录。

菜单默认中文。英文界面：

```sh
./setup.sh --lang en
```

默认语言可在 [setup.conf](./setup.conf) 中修改。

## 🧭 菜单功能

| 选项 | 功能 | 是否写入系统 |
| --- | --- | --- |
| `1) 预览安装` | 显示系统、包管理器、工具、字体和配置链接状态 | 否 |
| `2) 开始安装` | 安装 CLI 工具、安装 Nerd Font、链接配置，并切换默认 shell 为 zsh | 是，需输入 `YES` |
| `3) 检查配置` | 运行 `doctor.sh` 检查工具和软链接状态 | 否 |
| `4) 恢复备份` | 删除本仓库管理的软链接，并恢复最近备份 | 是，需输入 `YES` |
| `5) 高级选项` | 只链接配置、包含 GUI 应用、导入本机配置、查看命令 | 按所选操作决定 |
| `l) 切换语言` | 在中文和英文菜单间切换 | 否 |
| `0) 退出` | 退出安装器 | 否 |

## 🧰 包含工具

本仓库可自动安装并配置以下工具：

**💻 核心 CLI / TUI**

- **Shell 与提示符**：`zsh`、`zsh-syntax-highlighting`、`starship`
- **命令行增强**：`eza`、`bat` / `batcat`、`zoxide`、`ripgrep`、`fd` / `fdfind`、`fzf`
- **终端与文件工作流**：`tmux`、`yazi`
- **开发工具**：`neovim` / `nvim`、`lazygit`

**🖥️ 可选 GUI 应用**

- **Ghostty**：需通过高级选项或 `--install-gui-apps` 安装。macOS 使用较大窗口配置；Linux / Raspberry Pi OS 使用 `70 x 20` 小窗口配置。

**🔤 字体**

- **JetBrainsMono Nerd Font**：安装到用户字体目录，并尽量应用到 Ghostty、Kitty、Alacritty、LXTerminal、Foot 等终端。

## 🌍 支持平台

| 平台 | 默认包管理器 |
| --- | --- |
| macOS | Homebrew |
| Debian | apt |
| Ubuntu | apt |
| Raspberry Pi OS | apt |
| Arch Linux | pacman |
| Fedora | dnf |

Linux 可选 Homebrew：

```sh
./install.sh --install-packages --package-manager brew --backup --yes
```

脚本不会自动安装 Homebrew、rustup、第三方 apt 源、PPA、COPR，也不会执行 `curl | bash`。

## 🔗 配置映射关系

执行安装时，会把 `configs/` 下的配置软链接到目标 HOME。已有目标不会被直接覆盖，会先备份再链接。

| 仓库源文件 | 目标路径 |
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

## 🛠️ 常用命令速查

| 目标操作 | 命令 |
| --- | --- |
| 打开交互菜单 | `./setup.sh` |
| 英文菜单 | `./setup.sh --lang en` |
| 安全预览 | `./install.sh --dry-run` |
| 推荐安装 | `./install.sh --install-packages --install-fonts --set-default-shell --backup --yes` |
| 推荐安装，包含 Ghostty | `./install.sh --install-packages --install-gui-apps --install-fonts --set-default-shell --backup --yes` |
| 只链接配置 | `./install.sh --link-only --backup --yes` |
| 检查配置 | `./scripts/doctor.sh` |
| 快速进入日常 workspace | `workplace` |
| 重建日常 workspace | `workplace --reset` 或 `./scripts/workspace_layout.sh --reset` |
| 打开 README 展示布局 | `./scripts/showcase_layout.sh --reset` |
| 预览恢复 | `./scripts/restore_backups.sh --dry-run` |
| 执行恢复 | `./scripts/restore_backups.sh --yes` |
| 预览导入本机配置 | `./scripts/import_existing_configs.sh --dry-run` |
| 导入本机配置并脱敏 | `./scripts/import_existing_configs.sh --yes --sanitize` |
| 运行安全测试 | `./test_install.sh` |

## 🔁 恢复与导入

恢复只处理“指向本仓库的软链接”，不会删除普通文件。

```sh
./scripts/restore_backups.sh --dry-run
./scripts/restore_backups.sh --yes
```

导入只从当前 HOME 复制到仓库 `configs/`，不会反向写回真实配置。

```sh
./scripts/import_existing_configs.sh --dry-run
./scripts/import_existing_configs.sh --yes --sanitize
```

脱敏报告写入 [scripts/sanitize_report.md](./scripts/sanitize_report.md)。

## 📂 目录结构

```text
.
├── setup.sh               # 交互式主入口
├── install.sh             # 核心安装脚本
├── test_install.sh        # 临时 HOME 安全测试
├── LICENSE                # MIT License
├── assets/                # README 图片和展示资源
├── configs/               # 待链接的 dotfiles
├── packages/              # 平台包列表
├── scripts/               # doctor、restore、import 等维护脚本
├── Brewfile.common        # Homebrew 通用 CLI 依赖
├── Brewfile.fonts         # Homebrew 字体依赖
└── Brewfile.macos         # macOS 专属依赖
```

## 📄 License

本项目使用 [MIT License](./LICENSE)。
