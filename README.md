# DeepSeek Harness (Linux)

[![License: MIT](https://img.shields.io/github/license/pengchengwanli2024/deepseek-harness-linux?label=License)](LICENSE)
[![Latest release](https://img.shields.io/github/v/release/pengchengwanli2024/deepseek-harness-linux?sort=semver)](https://github.com/pengchengwanli2024/deepseek-harness-linux/releases/latest)
[![CI](https://img.shields.io/github/actions/workflow/status/pengchengwanli2024/deepseek-harness-linux/ci.yml?label=CI)](https://github.com/pengchengwanli2024/deepseek-harness-linux/actions/workflows/ci.yml)
[![Platform](https://img.shields.io/badge/platform-Linux%20x86__64%20%7C%20arm64-informational)](docs/INSTALL.zh-CN.md)

**仓库**：<https://github.com/pengchengwanli2024/deepseek-harness-linux> · **上游**：<https://github.com/deepseek-ai/deepseek-harness>

> **非官方 Linux 桌面版** · 基于官方 npm 包 [`@deepseek-ai/dsh@0.2.1-rc.5`](https://www.npmjs.com/package/@deepseek-ai/dsh) 构建
>
> 应用版本 **0.2.2** · 内置 dsh **0.2.1-rc.5** · Node.js **24.22.2** · Electron **45.2.1**

**DeepSeek Harness (Linux)** 把 DeepSeek Harness 的 Web UI 封装成一个可直接在 Linux 桌面运行的桌面应用（Electron），提供 **AppImage、.deb** 两种图形化安装方式（x86_64 与 arm64），以及面向服务器/无桌面环境的 **CLI 安装脚本**。应用内置独立的 Node.js 运行时与 dsh 依赖，**不要求系统预装 Node.js**，安装后即可离线启动。

> [!IMPORTANT]
> 本项目是**社区制作的非官方发行版**，与 DeepSeek（深度求索）无隶属、赞助或背书关系。"DeepSeek"、"DeepSeek Harness" 及相关名称、标识归其权利人所有。详见 [NOTICE.md](NOTICE.md)。

![DeepSeek Harness (Linux) 主界面](docs/assets/screenshot.png)

*首次启动后的主界面（尚未选择工作区；界面语言随系统区域设置）。*

---

## 目录

- [1. 功能特性](#1-功能特性)
- [2. 系统要求](#2-系统要求)
- [3. 安装](#3-安装)
- [4. 首次启动与配置](#4-首次启动与配置)
- [5. 数据目录与日志](#5-数据目录与日志)
- [6. 环境变量](#6-环境变量)
- [7. 更新机制、升级与卸载](#7-更新机制升级与卸载)
- [8. 命令行参数](#8-命令行参数)
- [9. 从源码构建](#9-从源码构建)
- [10. 常见问题](#10-常见问题)
- [11. 版本与许可证](#11-版本与许可证)
- [12. 已知限制](#12-已知限制)
- [13. 参与贡献](#13-参与贡献)
- [14. 安全](#14-安全)

---

## 1. 功能特性

- **完整 Harness 体验**：对话、工具调用、会话与工作区管理、计划模式、插件、MCP、定时任务等能力均来自官方 `dsh web`，本项目只负责桌面封装与运行时分发。
- **开箱即用**：内置 Node.js 24.22.2 与 dsh 0.2.1-rc.5 生产依赖，无需系统 Node、无需联网拉取依赖（模型请求仍需要网络）。
- **原生桌面体验**：独立窗口、启动画面、单实例（重复启动聚焦已有窗口）、窗口尺寸/位置记忆（`window-state.json`）、中英文菜单（按系统区域自动选择）、外链使用系统浏览器打开、刷新/缩放/全屏快捷键、关于对话框（显示 Electron/Chromium/Node 与数据目录）。
- **进程托管**：随窗口启动/退出 dsh 服务；服务异常退出时弹窗提示，可一键重启；退出时终止整个进程组，无残留进程。
- **本地安全模型**：服务仅监听 `127.0.0.1`，使用一次性 token URL 建立访问；不对外网暴露端口。
- **双架构交付**：x86_64（amd64）与 arm64（aarch64），AppImage + deb 四种文件（2 架构 × 2 类型）+ `SHA256SUMS` + `RELEASE.json`。
- **服务器可用**：`scripts/install-cli.sh` 在无桌面环境安装 CLI（`dsh-linux`）与 Web UI 启动器（`dsh-web`）。

## 2. 系统要求

| 项目 | 要求 |
| --- | --- |
| 发行版 | Debian 12+、Ubuntu 22.04+，或其他 **glibc ≥ 2.28** 的发行版 |
| CPU 架构 | x86_64（amd64）或 aarch64（arm64） |
| 显示环境 | X11，或 Wayland（通过 XWayland 运行） |
| 内存 | 建议 4 GB 以上（dsh 服务 + Electron 渲染进程） |
| 磁盘 | 下载包约 **220–270 MB**（AppImage ≈256–258 MiB，deb ≈214–219 MiB）；安装后约 **0.9–1.1 GB**（含解压后的运行时；精确值见 `dist/RELEASE.json`） |
| 桌面依赖 | deb 由 `apt` 自动安装 GTK3/NSS/GBM 等依赖；AppImage 需要 `libfuse2`（Debian 12 / Ubuntu 22.04）或 `libfuse2t64`（Ubuntu 24.04+），也可解包运行 |
| 可选组件 | `bubblewrap`（命令沙箱）、`fonts-noto-cjk`（中文字体） |

> **glibc 说明**：内置 Node.js 24 官方二进制要求 glibc ≥ 2.28。低于该基线的系统（如 CentOS 7）无法运行，请升级系统。

## 3. 安装

发布产物托管在 [GitHub Releases](https://github.com/pengchengwanli2024/deepseek-harness-linux/releases)（自行构建时位于 `dist/`）：

| 文件 | 适用平台 |
| --- | --- |
| `DeepSeek-Harness-Linux-0.2.2-x86_64.AppImage` | x86_64 通用（免安装） |
| `DeepSeek-Harness-Linux-0.2.2-amd64.deb` | Debian/Ubuntu x86_64 |
| `DeepSeek-Harness-Linux-0.2.2-arm64.AppImage` | arm64 通用（免安装） |
| `DeepSeek-Harness-Linux-0.2.2-arm64.deb` | Debian/Ubuntu arm64 |
| `SHA256SUMS` / `RELEASE.json` | 校验和 / 构建元数据 |

> 发布物为上述 **4 个安装包**。便携 tar.gz **不随发布提供**，如有需要可按 [BUILD 文档](docs/BUILD.zh-CN.md) 自行构建（`scripts/package/build-linux.sh <arch> --targets tar.gz`）。

> **体积**（实测）：x64 AppImage ≈ 256 MiB、deb ≈ 219 MiB；arm64 AppImage ≈ 258 MiB、deb ≈ 214 MiB。安装后磁盘占用约 0.9–1.1 GB。精确字节数与 SHA-256 见 `dist/RELEASE.json` 与 `dist/SHA256SUMS`。

先校验下载文件（推荐）：

```bash
sha256sum -c SHA256SUMS --ignore-missing
```

### 方式一：AppImage（免安装，推荐给个人桌面）

```bash
chmod +x DeepSeek-Harness-Linux-0.2.2-x86_64.AppImage
./DeepSeek-Harness-Linux-0.2.2-x86_64.AppImage
```

如果提示找不到 FUSE（`libfuse.so.2`）：

```bash
# Debian 12 / Ubuntu 22.04
sudo apt install libfuse2
# Ubuntu 24.04+（只有 t64 变体）
sudo apt install libfuse2t64
```

不安装 FUSE 时，推荐使用 AppImage 自带的提取运行模式（非 root 也可，应用会自动处理沙箱降级）：

```bash
APPIMAGE_EXTRACT_AND_RUN=1 ./DeepSeek-Harness-Linux-0.2.2-x86_64.AppImage
```

也可以手动解包后再运行（此时需自行加 `--no-sandbox`）：

```bash
./DeepSeek-Harness-Linux-0.2.2-x86_64.AppImage --appimage-extract
./squashfs-root/deepseek-harness --no-sandbox
```

> AppImage 无法保留 setuid 权限，应用会以 `--no-sandbox` 方式启动 Electron（见 [FAQ：--no-sandbox 意味着什么](docs/FAQ.zh-CN.md#3-appimage-为什么要禁用沙箱)）。如果你更看重沙箱强度，请使用 deb。

### 方式二：deb（推荐给长期使用/需要系统沙箱）

```bash
sudo apt install ./DeepSeek-Harness-Linux-0.2.2-amd64.deb
# 若 apt 不支持下述相对路径语法，等价写法：
# sudo dpkg -i DeepSeek-Harness-Linux-0.2.2-amd64.deb
# sudo apt-get -f install

deepseek-harness          # 命令行启动
# 或从应用菜单打开 “DeepSeek Harness”
```

包名：`deepseek-harness-linux`；安装后可直接在终端运行 `deepseek-harness`——`/usr/bin/deepseek-harness` 是指向 `/opt/DeepSeek-Harness/deepseek-harness` 的符号链接。安装脚本会为 `chrome-sandbox` 设置 4755 权限，因此 Electron 沙箱生效。建议同时安装可选依赖：

```bash
sudo apt install bubblewrap fonts-noto-cjk
```

### 方式三（可选）：自行构建便携 tar.gz

发布物中**不包含** tar.gz。如需免安装的便携目录，可自行构建：

```bash
bash scripts/package/build-linux.sh x64 --targets tar.gz
# 产物：dist/deepseek-harness-linux-0.2.2-x86_64.tar.gz
tar -xzf dist/deepseek-harness-linux-0.2.2-x86_64.tar.gz
cd deepseek-harness-0.2.2-x86_64      # 解压出的顶层目录，以实际结果为准
./deepseek-harness
```

构建前置与参数见 [docs/BUILD.zh-CN.md](docs/BUILD.zh-CN.md)。

### 方式四：CLI 安装脚本（无桌面 / 服务器 / 只想用 Web UI）

脚本会安装独立的 Node.js 运行时（系统中已有 Node ≥ 22.19 时可复用）与 `@deepseek-ai/dsh`，并在 `~/.local/bin` 生成两个启动器：

```bash
# 在仓库根目录执行
bash scripts/install-cli.sh

# 可选参数
bash scripts/install-cli.sh --prefix "$HOME/.local"   # 安装前缀，默认 ~/.local
bash scripts/install-cli.sh --version 0.2.1-rc.5      # 指定 dsh 版本，默认 0.2.1-rc.5
bash scripts/install-cli.sh --system-node             # 强制使用系统 Node（需 ≥ 22.19）
bash scripts/install-cli.sh --uninstall               # 卸载（保留用户数据）
```

安装完成后（确保 `~/.local/bin` 在 `PATH` 中）：

```bash
dsh-linux --version      # 0.2.1-rc.5，完整 dsh CLI（web/headless/tui/plugin ...）
dsh-web                  # 启动 Web UI 并自动打开浏览器
dsh-web --no-open        # 仅启动服务，不打开浏览器（服务器场景）
```

> CLI 方式安装后约占用 1.1 GB（含内置 Node.js 运行时与 dsh 依赖）；如系统已有 Node ≥ 22.19，可用 `--system-node` 复用系统 Node 以节省空间。
> 用户数据默认位于 `~/.config/deepseek-harness/dsh-home`（可通过 `DSH_HOME` 覆盖）。

更完整的安装说明（桌面集成、离线安装、权限、故障排查）见 **[docs/INSTALL.zh-CN.md](docs/INSTALL.zh-CN.md)**。

## 4. 首次启动与配置

### 4.1 启动

- **AppImage**：在终端执行可执行文件；或自行创建 `.desktop` 快捷方式。
- **deb**：应用菜单搜索 “DeepSeek Harness”，或终端执行 `deepseek-harness`。

首次启动会显示启动画面，随后在主窗口加载 Harness 界面。服务完全在本机运行，监听 `127.0.0.1` 的随机端口。

### 4.2 配置模型 API Key

有三种方式，任选其一：

1. **在界面中配置（推荐）**
   打开 **设置（Settings）→ 模型（Models）**，在 **DeepSeek** 提供方行填写 **API 密钥（API Key）**，点击**应用/保存**。
   密钥以只写方式保存到当前 profile 的凭据中（`$DSH_HOME/.credentials.yaml`），界面不会回显已保存的密钥。

2. **通过环境变量**
   启动应用前导出，应用会继承该环境：

   ```bash
   export DEEPSEEK_API_KEY="sk-..."
   deepseek-harness
   ```

3. **写入 `$DSH_HOME/.env`**
   桌面版默认 `$DSH_HOME` 为 `~/.config/deepseek-harness/dsh-home`：

   ```bash
   mkdir -p ~/.config/deepseek-harness/dsh-home
   printf 'DEEPSEEK_API_KEY=sk-...\n' >> ~/.config/deepseek-harness/dsh-home/.env
   ```

> **优先级**：已保存的凭据 > 启动环境变量 > 工作目录 `.env` > `$DSH_HOME/.env`。
> 工作目录的 `.env` 优先级高于 `$DSH_HOME/.env`，请在受信任的项目目录中使用。
> 修改环境变量或 `.env` 后需要**重启应用**才能生效。

### 4.3 选择工作区

- 若系统存在 `Documents` 目录，首次使用会自动创建默认工作区 `~/Documents/deepseek-harness`；
- 否则（或你想使用其他目录）会弹出 **「选择工作区目录」** 对话框，选择或新建一个项目目录即可；
- 之后可随时在界面中切换/添加工作区。

> 工作区是 dsh 执行命令、读写文件的根目录。**请只在受信任的目录中使用**，不要把包含敏感凭据的目录随便加入工作区。

### 4.4 验证安装

新建一个会话，输入例如：

```text
列出当前工作区的顶层文件，并总结这个项目是做什么的。
```

如果能看到模型回复并伴随工具调用（读取目录/文件），说明安装与配置成功。

## 5. 数据目录与日志

### 三种 `DSH_HOME` 语义（重要）

本项目的三种运行方式各自有默认数据目录，互不冲突：

| 运行方式 | 默认 `DSH_HOME` | 说明 |
| --- | --- | --- |
| 本项目桌面版（AppImage / deb） | `~/.config/deepseek-harness/dsh-home` | 即 Electron `userData` 下的 `dsh-home`；可用 `--dsh-home` 或 `DSH_LINUX_HOME` 覆盖 |
| `scripts/install-cli.sh` 安装的 `dsh-linux` / `dsh-web` | `~/.config/deepseek-harness/dsh-home` | 启动器脚本默认设置；可用 `DSH_HOME` 覆盖 |
| 直接运行上游 `dsh`（如 `npx @deepseek-ai/dsh`） | `~/.dsh` | 上游 dsh 自身默认值，本项目不改变它 |

> 覆盖优先级（桌面版）：`--dsh-home` > `DSH_LINUX_HOME` > 默认值。
> `DSH_HOME` 环境变量本身由桌面壳显式设置，用于启动子进程 `dsh web`。

### 桌面版（AppImage / deb）

| 路径 | 用途 |
| --- | --- |
| `~/.config/deepseek-harness/` | Electron `userData`：配置、窗口状态、缓存 |
| `~/.config/deepseek-harness/window-state.json` | 窗口尺寸/位置记忆 |
| `~/.config/deepseek-harness/dsh-home/` | 默认 `DSH_HOME`：profiles、工作区/会话存储、凭据 |
| `~/.config/deepseek-harness/logs/server.log` | dsh 服务 stdout/stderr 日志（追加写入；超过 5 MB 轮转为 `server.log.1`） |
| `~/Documents/deepseek-harness/` | 默认工作区目录（在系统启用 Documents 目录时自动创建） |

> `XDG_CONFIG_HOME` 已设置时，`~/.config` 相应替换为 `$XDG_CONFIG_HOME`。

### CLI 安装版

| 路径 | 用途 |
| --- | --- |
| `~/.local/lib/deepseek-harness/` | CLI 安装目录（内置 Node.js + dsh 依赖） |
| `~/.local/bin/dsh-linux`、`~/.local/bin/dsh-web` | 启动器 |
| `~/.local/share/applications/dsh-web.desktop` | 桌面入口 |
| `~/.config/deepseek-harness/dsh-home/` | CLI 默认 `DSH_HOME` |
| `~/.cache/dsh-linux/npm/` | 安装时的 npm 缓存 |

查看服务日志：

```bash
tail -f ~/.config/deepseek-harness/logs/server.log
```

## 6. 环境变量

| 变量 | 作用 | 默认值 |
| --- | --- | --- |
| `DSH_HOME` | dsh 数据主目录（profiles、会话、凭据） | 桌面版 `~/.config/deepseek-harness/dsh-home`；裸 `dsh` 为 `~/.dsh` |
| `DSH_LINUX_HOME` | 桌面版对 `DSH_HOME` 的覆盖（优先级低于 `--dsh-home`） | 未设置 |
| `--dsh-home=<dir>` | 启动参数覆盖数据目录（优先级高于环境变量） | 未设置 |
| `DEEPSEEK_API_KEY` | 官方 DeepSeek API 密钥（环境后备） | 未设置 |
| `DEEPSEEK_BASE_URL` | 自定义 API 端点（代理/私有网关） | 官方端点 |
| `DSH_AGENTS_HOME` | 共享 agent 配置根目录 | `~/.agents` |
| `http_proxy` / `https_proxy` / `all_proxy` / `no_proxy` | 出站 HTTP 代理（大小写均可，小写优先；回环地址直连） | 未设置 |
| `DSH_TELEMETRY_DISABLED` | 设为非空值可禁用遥测 | 未设置 |
| `LANG` / `LC_ALL` | 界面语言（`zh_CN.UTF-8` 显示中文） | 继承系统 |
| `DSH_LINUX_NO_SANDBOX` | 设为 `1` 强制给 Electron 传 `--no-sandbox`（AppImage/root 下自动启用） | 未设置 |
| `DSH_LINUX_DISABLE_GPU` | 设为 `1` 禁用硬件加速（虚拟机/远程桌面无 GPU 时有用） | 未设置 |
| `DSH_LINUX_RUNTIME` / `DSH_LINUX_NODE` / `DSH_LINUX_DSH_ENTRY` | 开发调试：覆盖运行时路径 / Node 路径 / dsh 入口 | 未设置 |
| `DSH_LINUX_DISABLE_UPDATER` | 设为 `1` 禁用应用内自动更新检查 | 未设置 |
| `DSH_LINUX_UPDATE_FEED_URL` | 覆盖应用内更新源（generic provider，镜像/调试用） | 使用 GitHub Releases |

> 代理变量同样会从 `$DSH_HOME/.env` 读取；生效顺序为：进程环境 > 工作目录 `.env` > `$DSH_HOME/.env`。

## 7. 更新机制、升级与卸载

### 7.1 更新机制

- **应用内更新（AppImage）**：AppImage 打包版启动后会在后台静默检查 GitHub Releases（启动约 8 秒后），也可通过菜单 **帮助 → 检查更新…** 手动检查；发现新版本时提示下载，下载完成后重启即可安装。更新源为 GitHub Releases，元数据为发布资产中的 `latest-linux*.yml` 与 blockmap 文件。
- **deb 手动升级**：deb 版本不启用应用内更新，请从 Releases 下载新包重新安装（见 7.2）。
- **自动跟随上游**：维护者侧通过 CI 每日检查上游 `@deepseek-ai/dsh` 版本，发现新版本后更新版本号、构建两架构安装包并发布到 Releases。链路说明见 [docs/CI.zh-CN.md](docs/CI.zh-CN.md)，维护者操作见 [docs/MAINTAINING.zh-CN.md](docs/MAINTAINING.zh-CN.md)。
- **关闭自动检查**：设置环境变量 `DSH_LINUX_DISABLE_UPDATER=1` 启动即可禁用（离线/测试环境）。

### 7.2 升级

升级即下载新版本安装包重新安装（用户数据保留）：

```bash
# deb
sudo apt install ./DeepSeek-Harness-Linux-0.2.2-amd64.deb

# AppImage：下载新文件后替换旧文件即可，或等待应用内更新提示按提示重启

# CLI
bash scripts/install-cli.sh            # 重新执行即升级到默认版本
bash scripts/install-cli.sh --version 0.2.1-rc.5
```

### 7.3 卸载

```bash
# deb
sudo apt remove deepseek-harness-linux

# AppImage：删除可执行文件即可

# CLI
bash scripts/install-cli.sh --uninstall
```

**用户数据默认不会被删除**。如需彻底清理（不可恢复，请先备份）：

```bash
rm -rf ~/.config/deepseek-harness     # 配置 + DSH_HOME + 日志
# 工作区 ~/Documents/deepseek-harness 请自行确认后再删除
```

## 8. 命令行参数

桌面应用支持以下参数（完整列表以本节为准；`--help` 输出为摘要）：

| 参数 | 说明 |
| --- | --- |
| `--dsh-home=<dir>` / `--dsh-home <dir>` | 指定 `DSH_HOME` 数据目录 |
| `--host=<ip>` / `--host <ip>` | 服务监听地址（默认 `127.0.0.1`，需为本地接口的具体地址） |
| `--port=<n>` / `--port <n>` | 服务端口（默认 `0`，由系统分配空闲端口） |
| `--version` / `-V` | 打印应用版本及 Electron/Chromium/Node 版本并退出 |
| `--help` / `-h` | 打印帮助并退出 |
| `--smoke-test` | 自动化验证：服务就绪并加载页面后打印 `SMOKE_OK <url>` 退出（测试用） |
| `--screenshot=<path>` | 页面加载完成 2 秒后截图保存为 PNG，打印 `SCREENSHOT_OK <path>`（测试用） |
| `--updater-check` | 检查更新并输出 `UPDATE_AVAILABLE` / `UPDATE_NONE` / `UPDATE_ERROR` 后退出（测试用） |
| `--dev` | 开发模式：显示开发者工具菜单项与 F12（仅调试用） |

```bash
deepseek-harness --version
deepseek-harness --dsh-home ~/dsh-data --port 8080
deepseek-harness --smoke-test
deepseek-harness --screenshot=/tmp/dsh.png
```

> `--version` 输出示例（多行）：应用版本行 + `Electron … / Chromium … / Node …`。
> 测试钩子（`--smoke-test`、`--screenshot`）用于 CI/自动化验证，普通用户无需使用。

## 9. 从源码构建

前置：Linux 或 macOS 宿主机、Docker（构建在容器内完成）、Node.js ≥ 22（顶层编排脚本使用）。宿主 npm 缓存异常时可设置 `npm_config_cache` 环境变量指向可写目录。

```bash
git clone https://github.com/pengchengwanli2024/deepseek-harness-linux.git
cd deepseek-harness-linux
```

```bash
# 一键构建（默认 x64 + arm64，产出 AppImage/deb；tar.gz 用 --targets tar.gz 可选）
bash scripts/build.sh

# 只构建 x64
bash scripts/build.sh --arch x64

# 跳过运行时（复用已有 runtime/），只重打包
bash scripts/build.sh --skip-runtime

# 指定产物类型
bash scripts/build.sh --arch arm64 --targets AppImage,deb
```

产物输出到 `dist/`，附带 `SHA256SUMS` 与 `RELEASE.json`。完整参数、分步构建、容器验证与故障排查见 **[docs/BUILD.zh-CN.md](docs/BUILD.zh-CN.md)**。

## 10. 常见问题

- AppImage 无法启动 / 提示 FUSE 错误
- 为什么 AppImage 会以 `--no-sandbox` 运行？安全吗？
- Wayland 下黑屏 / 窗口空白
- 缺少 `bubblewrap` 会影响什么？
- 中文显示为方块
- 端口被占用 / 服务启动失败
- 公司代理 / 私有网关下模型报错
- API Key 无效或模型不可用
- 日志在哪里、如何反馈问题
- 单实例行为
- 如何备份/迁移数据

以上问题及解决方法见 **[docs/FAQ.zh-CN.md](docs/FAQ.zh-CN.md)**。

## 11. 版本与许可证

| 组件 | 版本 |
| --- | --- |
| 应用版本 | 0.2.2 |
| @deepseek-ai/dsh | 0.2.1-rc.5 |
| Node.js | 24.22.2 |
| Electron | 45.2.1 |
| electron-builder | 26.18.0 |
| 构建基线 | Debian 12 / `node:24-bookworm`（glibc 2.36） |
| 运行时兼容 | glibc ≥ 2.28 |

版本信息的唯一来源是 [`versions.json`](versions.json)；具体构建时间、文件大小与校验和见 `dist/RELEASE.json` 与 `dist/SHA256SUMS`。

**许可证**：

- 本项目代码：[MIT](LICENSE)
- 上游 DeepSeek Harness（`@deepseek-ai/dsh`）：MIT
- 内置 Node.js、Electron 及第三方依赖：遵循各自许可证，详见运行包内 `licenses/` 与各 npm 包的 `LICENSE` 文件
- 变更记录：[CHANGELOG.md](CHANGELOG.md)
- 非官方声明与商标说明：[NOTICE.md](NOTICE.md)

## 12. 已知限制

- **非官方构建**：应用内自动更新仅 AppImage 支持，deb 需手动下载新包；功能一致性以官方 CLI/Web UI 为准。
- **无托盘**：关闭窗口即退出应用（同时停止 dsh 服务）。
- **AppImage 沙箱较弱**：受 AppImage 机制限制无法使用 setuid sandbox，默认 `--no-sandbox`；需要更强隔离请用 deb。
- **不内置 Python/Office 运行时**：office 技能使用 dsh 自带的 libreoffice-kit-wasm；需要系统 LibreOffice 的功能按官方行为。
- **Linux 桌面安全依赖发行版配置**：用户命名空间/SUID 沙箱不可用时，命令沙箱会降级或不可用。
- **Wayland**：默认走 XWayland，个别合成器下可能需要手动指定 `--ozone-platform=wayland`。
- **官方 Windows/macOS 桌面专属能力**（强制更新、系统原生目录选择器等）在 Linux 版中不保证一致。

---

## 13. 参与贡献

欢迎提交缺陷报告、功能建议、文档改进与上游版本跟进。开始之前请阅读：

- [CONTRIBUTING.md](CONTRIBUTING.md)：开发环境、构建/验证命令、提交与 PR 规范
- [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)：行为准则（Contributor Covenant 2.1）
- [SECURITY.md](SECURITY.md)：安全问题**私下**报告渠道
- [docs/MAINTAINING.zh-CN.md](docs/MAINTAINING.zh-CN.md)：发布、自动跟随上游与安全响应维护手册

快速开始：

```bash
git clone https://github.com/pengchengwanli2024/deepseek-harness-linux.git
cd deepseek-harness-linux

# 构建当前架构（需要 Docker）
bash scripts/build.sh --arch x64

# 运行容器化验收（按需选择 --mode）
bash scripts/test/verify-linux.sh --arch x64 --mode runtime,shell
```

> 本项目是社区制作的非官方发行版；dsh 本身的功能问题请反馈到上游仓库 <https://github.com/deepseek-ai/deepseek-harness>。

## 14. 安全

- 请**不要**在公开 issue 中披露漏洞细节、API Key、token 或可复现的敏感信息。
- 私下报告：GitHub Security Advisories（[Report a vulnerability](https://github.com/pengchengwanli2024/deepseek-harness-linux/security/advisories/new)），详见 [SECURITY.md](SECURITY.md)。
- 支持范围：最新 Release。上游 dsh、Node.js、Electron/Chromium 的问题请反馈给对应项目。
- 安全设计：dsh 服务仅监听 `127.0.0.1` 并使用一次性 token URL；AppImage 因无法保留 setuid 而以 `--no-sandbox` 运行，需要更强隔离请使用 deb；日志可能包含提示词与本地路径，反馈前请脱敏。

---

## 致谢

- [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)：上游项目与 `@deepseek-ai/dsh`。
- Electron、Node.js 及其全部开源依赖的作者与维护者。

如本项目侵犯了任何权利，请通过仓库 issue 联系，我们会及时处理。
