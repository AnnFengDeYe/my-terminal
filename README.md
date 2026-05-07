# my-config

一个跨平台终端配置仓库，用来快速部署一套可恢复、可测试的 terminal starter kit。

支持 macOS、Debian、Ubuntu、Raspberry Pi OS、Arch Linux、Fedora。仓库会管理 CLI 工具、终端字体和 dotfiles 软链接；默认不会修改系统，真实写入前必须确认。

## 快速开始

进入仓库后运行：

```sh
./setup.sh
```

第一次使用建议按这个顺序：

1. 选择 `1) 预览安装`
2. 确认工具、字体、配置链接状态
3. 选择 `2) 开始安装`
4. 输入大写 `YES`
5. 安装完成后重新打开终端，或重新 SSH 登录

菜单默认中文。需要英文界面：

```sh
./setup.sh --lang en
```

默认语言可在 [setup.conf](./setup.conf) 中修改。

## 菜单说明

| 选项 | 功能 | 是否写入系统 |
| --- | --- | --- |
| `1) 预览安装` | 只显示系统、工具、字体、配置链接状态 | 否 |
| `2) 开始安装` | 安装 CLI 工具、安装 Nerd Font、链接配置、切换默认 shell 为 zsh | 是，需输入 `YES` |
| `3) 检查配置` | 运行 doctor 检查工具和软链接状态 | 否 |
| `4) 恢复备份` | 删除本仓库管理的软链接，并恢复最近备份 | 是，需输入 `YES` |
| `5) 高级选项` | 只链接配置、安装 GUI 应用、导入本机配置、查看命令 | 按所选操作决定 |
| `l) 切换语言` | 在中文和英文菜单间切换 | 否 |
| `0) 退出` | 退出安装器 | 否 |

## 管理内容

CLI / TUI 工具：

- `zsh`
- `zsh-syntax-highlighting`
- `tmux`
- `starship`
- `fzf`
- `zoxide`
- `eza`
- `bat` / `batcat`
- `ripgrep`
- `fd` / `fdfind`
- `lazygit`
- `neovim` / `nvim`
- `yazi`

可选 GUI：

- `ghostty`

字体：

- `JetBrainsMono Nerd Font`

## 常用命令

| 目标 | 命令 |
| --- | --- |
| 打开交互菜单 | `./setup.sh` |
| 英文菜单 | `./setup.sh --lang en` |
| 详细 dry-run | `./install.sh --dry-run` |
| 推荐安装 | `./install.sh --install-packages --install-fonts --set-default-shell --backup --yes` |
| 推荐安装并包含 Ghostty | `./install.sh --install-packages --install-gui-apps --install-fonts --set-default-shell --backup --yes` |
| 只链接配置 | `./install.sh --link-only --backup --yes` |
| 检查配置 | `./scripts/doctor.sh` |
| 预览恢复 | `./scripts/restore_backups.sh --dry-run` |
| 一键恢复 | `./scripts/restore_backups.sh --yes` |
| 导入当前本机配置预览 | `./scripts/import_existing_configs.sh --dry-run` |
| 导入并脱敏 | `./scripts/import_existing_configs.sh --yes --sanitize` |
| 安全测试 | `./test_install.sh` |

## 支持平台

| 平台 | 默认包管理器 |
| --- | --- |
| macOS | Homebrew |
| Debian | apt |
| Ubuntu | apt |
| Raspberry Pi OS | apt |
| Arch Linux | pacman |
| Fedora | dnf |

Linux 也可以手动指定 Homebrew：

```sh
./install.sh --install-packages --package-manager brew --backup --yes
```

脚本不会自动安装 Homebrew、rustup、第三方 apt 源、PPA、COPR，也不会执行 `curl | bash`。

## 配置链接

安装时会把仓库中的配置软链接到目标 HOME。已有配置不会被覆盖，会先在原位置旁边生成备份。

| 仓库配置 | 目标位置 |
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

Ghostty 的 macOS 配置保持较大窗口；Linux / Raspberry Pi OS 使用小窗口配置，目前是 `70 x 20`。

## 安全策略

- 默认不修改系统。
- 预览模式只读，不创建文件、不安装软件、不创建软链接。
- 真实写入必须带 `--yes`。
- 覆盖已有配置前必须带 `--backup`。
- 备份放在原目标旁边，例如 `~/.zshrc.backup.20260507-160000`。
- `test_install.sh` 使用临时 HOME，不会写入真实 HOME。
- 导入配置只允许从当前 HOME 复制到仓库 `configs/`，不会反向写回。
- Neovim 配置只复制和链接，不自动运行插件同步。

## 字体和终端

`--install-fonts` 会把 JetBrainsMono Nerd Font 安装到当前用户字体目录，并尽量应用到常见终端配置。

支持的终端配置包括：

- Ghostty
- LXTerminal
- Kitty
- Foot
- Alacritty 的保守默认配置

SSH 场景下，字体渲染最终由本地终端决定；树莓派桌面终端会使用远程系统上的字体配置。

## Ghostty

Ghostty 是可选 GUI 应用，不在默认 CLI 安装中强制安装。

安装 Ghostty：

```sh
./install.sh --install-packages --install-gui-apps --install-fonts --backup --yes
```

Linux 上会尽量使用系统包管理器或 Snap。脚本不会添加第三方源，也不会下载未知二进制。安装成功后会创建应用菜单入口；支持桌面的 Linux 还会创建桌面启动器。

## Yazi

Yazi 不依赖 Debian / Ubuntu / Raspberry Pi OS 的 apt 版本。

安装策略：

1. 优先使用已有 Homebrew
2. 失败后使用已有 Cargo
3. 再按平台尝试受支持的官方发布包

脚本不会自动安装 Homebrew、rustup 或 Cargo。

## 恢复

推荐用菜单：

```sh
./setup.sh
```

然后选择 `4) 恢复备份`。

命令方式：

```sh
./scripts/restore_backups.sh --dry-run
./scripts/restore_backups.sh --yes
```

恢复逻辑只处理“指向本仓库的软链接”。如果要手动恢复某个文件：

```sh
unlink ~/.zshrc
mv ~/.zshrc.backup.YYYYMMDD-HHMMSS ~/.zshrc
```

## 导入本机配置

预览：

```sh
./scripts/import_existing_configs.sh --dry-run
```

导入并脱敏仓库副本：

```sh
./scripts/import_existing_configs.sh --yes --sanitize
```

脱敏报告会写入 [scripts/sanitize_report.md](./scripts/sanitize_report.md)。导入不会修改真实源配置。

## 测试

本地安全测试：

```sh
./test_install.sh
```

这个测试会创建临时 HOME，只验证 dry-run、备份、软链接、恢复、字体配置和 GUI dry-run 逻辑，不执行真实包安装。

树莓派上已验证：

- CLI 工具安装
- zsh 默认 shell
- Starship prompt
- zsh-syntax-highlighting
- Nerd Font 安装和终端应用
- Ghostty 安装、桌面入口、Linux 小窗口配置
- Yazi 安装策略
- 备份和恢复
- `doctor.sh` 检查

## 目录

```text
.
├── setup.sh
├── install.sh
├── test_install.sh
├── configs/
├── packages/
├── scripts/
├── Brewfile.common
├── Brewfile.fonts
└── Brewfile.macos
```
