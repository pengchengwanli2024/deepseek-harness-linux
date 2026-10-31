# 安装指南（DeepSeek Harness Linux · 中文）

> 适用范围：应用版本 0.2.1，内置 dsh 0.2.1-rc.5，Node.js 24.22.2。
> 如果你只想快速装好，请先看 [README 的「安装」一节](../README.md#3-安装)；本文是完整的安装、配置、卸载与排错说明。

## 目录

- [1. 选择安装方式](#1-选择安装方式)
- [2. 通用准备](#2-通用准备)
- [3. AppImage 安装](#3-appimage-安装)
- [4. deb 安装](#4-deb-安装)
- [5. 可选：自行构建 tar.gz](#5-可选自行构建-targz)
- [6. CLI 安装脚本](#6-cli-安装脚本)
- [7. 首次启动与 API Key 配置](#7-首次启动与-api-key-配置)
- [8. 桌面集成](#8-桌面集成)
- [9. 离线 / 内网安装](#9-离线--内网安装)
- [10. 升级与卸载](#10-升级与卸载)
- [11. 安装故障排查](#11-安装故障排查)

---

## 1. 选择安装方式

| 方式 | 适合场景 | 沙箱强度 | 自动更新 | 系统集成 |
| --- | --- | --- | --- | --- |
| AppImage | 个人桌面、想免安装、可放任意目录 | 较弱（`--no-sandbox`） | 手动替换 | 手动建快捷方式 |
| deb | 长期使用、需要系统沙箱与菜单项 | 强（setuid chrome-sandbox） | 手动重新安装 | 完整（菜单/路径/依赖） |
| 自建 tar.gz | 便携、U 盘、无 root 权限（不随发布提供） | 较弱 | 手动替换 | 无 |
| CLI 脚本 | 服务器 / 无桌面 / 只要 Web UI | 取决于 dsh 自身沙箱 | 重跑脚本 | 生成 `dsh-web.desktop` |

> **体积**（实测）：x64 AppImage ≈ 256 MiB、deb ≈ 219 MiB；arm64 AppImage ≈ 258 MiB、deb ≈ 214 MiB；安装后约 0.9–1.1 GB（运行时解压后约 797 MB）。精确字节数与 SHA-256 见 `dist/RELEASE.json` 与 `dist/SHA256SUMS`。
>
> 发布物为 **4 个安装包**（2 架构 × AppImage/deb），**不含 tar.gz**。

> 若你在公司电脑上处理敏感代码，建议使用 **deb**：它是唯一能保留 Electron setuid 沙箱的安装方式。

## 2. 通用准备

### 2.1 确认架构

```bash
uname -m
```

- `x86_64` → 使用 `x86_64` / `amd64` 产物
- `aarch64` 或 `arm64` → 使用 `arm64` 产物

### 2.2 确认 glibc

```bash
ldd --version | head -1
```

需要 **≥ 2.28**（Debian 10+、Ubuntu 20.04+ 均满足）。低版本系统无法运行内置的 Node.js 24。

### 2.3 校验下载文件

```bash
# 与安装包放在同一目录
sha256sum -c SHA256SUMS --ignore-missing
```

查看构建信息：

```bash
cat RELEASE.json
```

## 3. AppImage 安装

### 3.1 运行

```bash
chmod +x DeepSeek-Harness-Linux-0.2.1-x86_64.AppImage
./DeepSeek-Harness-Linux-0.2.1-x86_64.AppImage
```

### 3.2 如果提示 FUSE 错误

典型报错：`dlopen(): error loading libfuse.so.2`。

```bash
# Debian 12 / Ubuntu 22.04
sudo apt install libfuse2
# Ubuntu 24.04+（该版本只有 t64 变体）
sudo apt install libfuse2t64
# Fedora
sudo dnf install fuse-libs
# Arch
sudo pacman -S fuse2
```

不想安装 FUSE 时，**推荐**使用 AppImage 的提取运行模式（非 root 也可，应用会自动处理沙箱降级）：

```bash
APPIMAGE_EXTRACT_AND_RUN=1 ./DeepSeek-Harness-Linux-0.2.1-x86_64.AppImage
```

也可以手动解包后运行，但需要显式加 `--no-sandbox`：

```bash
./DeepSeek-Harness-Linux-0.2.1-x86_64.AppImage --appimage-extract
./squashfs-root/deepseek-harness --no-sandbox
```

解包后的 `squashfs-root/` 可以移动到任意目录（例如 `~/Applications/dsh-linux/`）长期使用。

> **注意**：以 AppImage 方式（含 `APPIMAGE_EXTRACT_AND_RUN=1`）运行时，应用会自动启用 `--no-sandbox`；**手动** `--appimage-extract` 后直接运行需要自行加 `--no-sandbox`。原因与权衡见 [FAQ](FAQ.zh-CN.md#3-appimage-为什么要禁用沙箱)。

### 3.3 移到固定位置

```bash
mkdir -p ~/Applications
mv DeepSeek-Harness-Linux-0.2.1-x86_64.AppImage ~/Applications/
chmod +x ~/Applications/DeepSeek-Harness-Linux-0.2.1-x86_64.AppImage
```

然后按 [第 8 节](#8-桌面集成) 创建 `.desktop` 快捷方式。

## 4. deb 安装

### 4.1 安装

```bash
sudo apt install ./DeepSeek-Harness-Linux-0.2.1-amd64.deb
```

若当前 `apt` 不支持下述路径形式，使用 dpkg + 修复依赖：

```bash
sudo dpkg -i DeepSeek-Harness-Linux-0.2.1-amd64.deb
sudo apt-get -f install
```

### 4.2 包信息

| 项目 | 值 |
| --- | --- |
| 包名 | `deepseek-harness-linux` |
| 可执行文件 | `/usr/bin/deepseek-harness`（指向 `/opt/DeepSeek Harness/deepseek-harness` 的符号链接，可直接在终端运行） |
| 应用 ID | `io.github.dshlinux.deepseek-harness` |
| 桌面文件 | `/usr/share/applications/` 下的 DeepSeek Harness 入口 |
| 运行依赖 | GTK3、NSS、GBM、ALSA、AT-SPI、X11 等桌面库，由 `apt` 自动解析（Debian 12 / Ubuntu 24.04 的 t64 变体也由包依赖与 apt 处理） |
| 推荐依赖 | `bubblewrap`、`fonts-noto-cjk` |

安装脚本（`postinst`）会通过 `dpkg -L` 定位并给 Electron 的 `chrome-sandbox` 设置 `root:root` + `4755`（setuid），因此 deb 版可以使用完整的 Electron 沙箱；同时刷新 desktop/mime 数据库。

> **文件名说明**：x64 的 deb 交付名为 `...-amd64.deb`（Debian 架构名），AppImage 为 `...-x86_64.AppImage`；最终以 `dist/` 实际文件为准。

### 4.3 建议安装的可选组件

```bash
sudo apt install bubblewrap fonts-noto-cjk
```

- `bubblewrap`：dsh 命令沙箱依赖它；缺失时会降级运行。
- `fonts-noto-cjk`：避免界面中文显示为方块。

### 4.4 启动

```bash
deepseek-harness
```

或从应用菜单打开 “DeepSeek Harness”。

## 5. 可选：自行构建 tar.gz

正式发布**不包含** tar.gz。如确需便携目录（例如放 U 盘），可自行构建：

```bash
bash scripts/package/build-linux.sh x64 --targets tar.gz
# 产物：dist/deepseek-harness-linux-0.2.1-x86_64.tar.gz

tar -xzf dist/deepseek-harness-linux-0.2.1-x86_64.tar.gz
cd deepseek-harness-0.2.1-x86_64      # 解压出的顶层目录，以实际结果为准
./deepseek-harness
```

- 无需 root，解压即用；目录可整体复制到其他同架构机器。
- 与 AppImage 类似，不保留 setuid 沙箱（手动解包/便携运行请加 `--no-sandbox`）。
- 构建前置与参数见 [BUILD.zh-CN.md](BUILD.zh-CN.md)。

## 6. CLI 安装脚本

适合：无图形界面的服务器、容器、或只想在浏览器里使用 Web UI 的用户。

### 6.1 安装

```bash
# 在仓库根目录执行
bash scripts/install-cli.sh
```

默认行为：

1. 检测系统 Node.js：满足 `≥ 24` 或 `22.19+` 则直接使用，否则下载 Node.js 24.22.2；
2. 在 `$PREFIX/lib/deepseek-harness` 安装 `@deepseek-ai/dsh@0.2.1-rc.5`（生产依赖）；
3. 在 `$PREFIX/bin` 生成 `dsh-linux` 与 `dsh-web`；
4. 写入 `dsh-web.desktop` 桌面入口。

安装后目录体积约 **1.1 GB**（含内置 Node.js 24 与 dsh 依赖）。磁盘紧张时可加 `--system-node` 复用系统 Node（需 ≥ 22.19）。

### 6.2 参数

| 参数 | 说明 |
| --- | --- |
| `--prefix DIR` | 安装前缀，默认 `$HOME/.local` |
| `--version VER` | dsh 版本，默认 `0.2.1-rc.5` |
| `--system-node` | 强制使用系统 Node（必须 `≥ 22.19`） |
| `--uninstall` | 卸载程序（保留用户数据） |

示例：

```bash
# 自定义前缀（用户目录，无需 root）
bash scripts/install-cli.sh --prefix "$HOME/.local/dsh"
# 系统级前缀需要 root（桌面文件仍写入调用用户的 XDG 目录，一般不推荐）
sudo bash scripts/install-cli.sh --prefix /opt/deepseek-harness
bash scripts/install-cli.sh --version 0.2.1-rc.5
bash scripts/install-cli.sh --system-node
```

### 6.3 使用

确保 `$PREFIX/bin` 在 `PATH` 中（`~/.local/bin` 通常已被发行版加入）：

```bash
dsh-linux --version        # 输出 0.2.1-rc.5
dsh-linux web --help       # 完整 dsh CLI
dsh-web                    # 启动 Web UI 并打开浏览器
dsh-web --no-open          # 服务器场景：不打开浏览器
dsh-web --no-open --host 127.0.0.1 --port 8080
```

> `dsh-web` 默认 `DSH_HOME=$HOME/.config/deepseek-harness/dsh-home`。自定义：`DSH_HOME=/data/dsh dsh-web`。

### 6.4 开机自启（可选，systemd 用户服务）

示例 unit（`~/.config/systemd/user/dsh-web.service`）：

```ini
[Unit]
Description=DeepSeek Harness Web UI
After=network-online.target

[Service]
Type=simple
ExecStart=%h/.local/bin/dsh-web --no-open --host 127.0.0.1 --port 8080
Restart=on-failure
Environment=DSH_HOME=%h/.config/deepseek-harness/dsh-home

[Install]
WantedBy=default.target
```

```bash
systemctl --user daemon-reload
systemctl --user enable --now dsh-web
systemctl --user status dsh-web
```

> 这是可选的运维示例，参数请按实际需要调整；Web UI 的访问 URL（含 token）会打印在服务日志中：`journalctl --user -u dsh-web -f`。

## 7. 首次启动与 API Key 配置

### 7.1 三种数据目录语义（先搞清楚）

本项目有三种运行方式，默认数据目录（`DSH_HOME`）各不相同：

| 运行方式 | 默认 `DSH_HOME` | 覆盖方式 |
| --- | --- | --- |
| 桌面版（AppImage / deb） | `~/.config/deepseek-harness/dsh-home` | `--dsh-home <dir>` > `DSH_LINUX_HOME` |
| `install-cli.sh` 的 `dsh-linux` / `dsh-web` | `~/.config/deepseek-harness/dsh-home` | `DSH_HOME` 环境变量 |
| 直接运行上游 `dsh` | `~/.dsh` | `DSH_HOME` 环境变量 |

桌面版相关路径：

| 路径 | 用途 |
| --- | --- |
| `~/.config/deepseek-harness/` | Electron `userData`（`XDG_CONFIG_HOME` 优先） |
| `~/.config/deepseek-harness/window-state.json` | 窗口尺寸/位置 |
| `~/.config/deepseek-harness/dsh-home/` | 默认 `DSH_HOME` |
| `~/.config/deepseek-harness/logs/server.log` | 服务日志（>5 MB 轮转为 `server.log.1`） |
| `~/Documents/deepseek-harness/` | 默认工作区（系统启用 Documents 目录时自动创建） |

> 三套目录相互独立。不要把上游 `~/.dsh` 的数据直接当作桌面版数据目录；如确需复用，用 `--dsh-home ~/.dsh` 显式指定。

### 7.2 启动流程

1. 显示启动画面；
2. 在后台启动 `dsh web --no-open --host 127.0.0.1 --port 0`；
3. 解析服务日志中带 token 的 URL 并加载到主窗口。

首次启动会初始化数据目录（`~/.config/deepseek-harness/`），并创建默认工作区（`~/Documents/deepseek-harness`）；若系统没有启用 `Documents` 目录，则弹出 **「选择工作区目录」** 对话框。

应用菜单提供：**文件**（打开数据目录、打开日志目录、退出）、**编辑**（标准编辑操作）、**视图**（重新加载、缩放、全屏；未打包/开发模式含开发者工具）、**帮助**（项目主页、日志目录、关于）。菜单语言根据系统区域自动选择（中文或英文）。

常用快捷键：`Ctrl+R` 重新加载、`Ctrl+Shift+R` 强制重新加载、`Ctrl++` / `Ctrl+-` / `Ctrl+0` 缩放、`F11` 全屏、`Ctrl+Q` 退出。

### 7.3 配置 API Key

**方式 A：界面配置（推荐）**

1. 打开 **设置（Settings）**；
2. 进入 **模型（Models）** 页面；
3. 在 **DeepSeek** 提供方行填写 **API 密钥**；
4. 点击 **应用 / 保存**。

密钥以只写方式保存到 `$DSH_HOME/.credentials.yaml`，保存后界面不会回显。

**方式 B：环境变量**

```bash
export DEEPSEEK_API_KEY="sk-..."
deepseek-harness
```

**方式 C：`$DSH_HOME/.env`**

```bash
mkdir -p ~/.config/deepseek-harness/dsh-home
printf 'DEEPSEEK_API_KEY=sk-...\n' >> ~/.config/deepseek-harness/dsh-home/.env
```

> 解析优先级：已保存凭据 > 启动进程环境 > 工作目录 `.env` > `$DSH_HOME/.env`。
> 修改后需重启应用。不要把 API Key 提交到 git 或写入项目目录的 `.env`。

### 7.4 验证

新建会话，输入：

```text
列出当前工作区顶层文件，并告诉我这个仓库是做什么的。
```

能看到模型回复并伴随工具调用即成功。

## 8. 桌面集成

deb 安装包已自动创建菜单项，无需手动操作。

AppImage 用户（或自建 tar.gz 用户）可手动创建 `~/.local/share/applications/deepseek-harness.desktop`：

```ini
[Desktop Entry]
Type=Application
Name=DeepSeek Harness
Comment=DeepSeek Harness desktop (unofficial Linux build)
Exec=/home/YOUR_USER/Applications/DeepSeek-Harness-Linux-0.2.1-x86_64.AppImage
Icon=/path/to/icon.png
Terminal=false
Categories=Development;Utility;
StartupWMClass=DeepSeek Harness
```

替换 `YOUR_USER` 与实际路径后：

```bash
chmod +x ~/.local/share/applications/deepseek-harness.desktop
update-desktop-database ~/.local/share/applications 2>/dev/null || true
```

> `Icon` 可指向项目内的 `assets/icon.png`（若你保留了仓库）。

## 9. 离线 / 内网安装

- **AppImage / deb**（以及自建 tar.gz）：安装包自带 Node.js 与 dsh 依赖，安装过程不需要联网。
- **CLI 脚本**：默认需要从 nodejs.org 与 npm registry 下载。内网环境可：
  - 由管理员预先安装 Node.js ≥ 22.19，然后 `--system-node`；
  - 或配置 npm 镜像后再运行脚本。

  ```bash
  npm config set registry https://registry.npmmirror.com
  bash scripts/install-cli.sh
  ```

> 应用运行期仍需要访问模型 API（或内网网关）。可设置 `DEEPSEEK_BASE_URL` 指向私有网关，或配置代理（见 [FAQ](FAQ.zh-CN.md#9-公司代理下模型请求失败怎么办)）。

## 10. 升级与卸载

### 10.1 升级

| 方式 | 操作 |
| --- | --- |
| deb | `sudo apt install ./DeepSeek-Harness-Linux-<新版本>-amd64.deb` |
| AppImage | 下载新文件替换旧文件 |
| 自建 tar.gz | 解压覆盖旧目录 |
| CLI | 重新执行 `bash scripts/install-cli.sh`（或加 `--version`） |

升级**不会**删除用户数据（`~/.config/deepseek-harness`）。

### 10.2 卸载

```bash
# deb
sudo apt remove deepseek-harness-linux
# 如需同时删除系统级配置（一般没有）
sudo apt purge deepseek-harness-linux

# AppImage：删除可执行文件；自建 tar.gz：删除解压目录
rm -f ~/Applications/DeepSeek-Harness-Linux-0.2.1-x86_64.AppImage
rm -rf ~/Applications/squashfs-root

# CLI
bash scripts/install-cli.sh --uninstall
```

### 10.3 彻底清理用户数据

```bash
# 先备份（见 FAQ「数据备份」）
rm -rf ~/.config/deepseek-harness
# 工作区目录请自行确认后删除：
# ~/Documents/deepseek-harness
```

## 11. 安装故障排查

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| `libfuse.so.2` 缺失 | 未安装 FUSE2 | Debian 12/Ubuntu 22.04：`sudo apt install libfuse2`；Ubuntu 24.04+：`sudo apt install libfuse2t64`；或 `APPIMAGE_EXTRACT_AND_RUN=1` 运行（手动解包需加 `--no-sandbox`） |
| `GLIBC_2.xx not found` | 系统 glibc 过低 | 升级到 Debian 12/Ubuntu 22.04+ |
| 命令找不到：`deepseek-harness` | deb 未装成功 | 重跑 `sudo apt-get -f install`；检查 `/usr/bin/deepseek-harness` |
| 启动后白屏/黑屏 | Wayland 兼容问题 | 先用 X11 登录会话，或参考 FAQ |
| 窗口启动即退出 | 端口/沙箱/权限问题 | 查看 `~/.config/deepseek-harness/logs/server.log` |
| 菜单中文是方块 | 缺中文字体 | `sudo apt install fonts-noto-cjk` |
| CLI 安装报 npm EPERM/EACCES | 宿主 npm 缓存权限异常 | 清理缓存或指定缓存：`npm --cache /tmp/npm-cache install ...`；或用 `--system-node` |
| CLI 提示 Node 太旧 | 系统 Node < 22.19 | 去掉 `--system-node` 让脚本下载 Node 24 |

更多运行期问题见 **[FAQ.zh-CN.md](FAQ.zh-CN.md)**。
