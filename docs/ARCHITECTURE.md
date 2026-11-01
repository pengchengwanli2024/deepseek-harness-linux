# DSH Linux — 架构与协作规范（v1）

> 目标：基于官方 DeepSeek Harness（@deepseek-ai/dsh）制作一款可在 Linux 桌面直接使用的非官方桌面版。
> 官方桌面仅提供 Windows x64 与 macOS Apple Silicon；Linux 官方只提供 CLI/Web UI。本项目把同一套 Web UI 打包为 Linux 原生桌面应用（AppImage / .deb），并附带离线运行时与 CLI 安装脚本。

## 0. 关键事实（已在本机验证）

- 官方 npm 包：`@deepseek-ai/dsh@0.2.1-rc.5`（latest）。
- Linux 运行方式：`dsh web --no-open --host 127.0.0.1 --port 0`，启动日志会打印带一次性 token 的地址：
  `dsh web: http://127.0.0.1:<port>/?token=<token>`。
  **窗口必须加载这个带 token 的完整 URL**；不带 token 会 303 重定向。
- 运行时依赖 Node.js（`^22.19 || >=24`；本项目固定 Node 24.x）。
- 官方桌面版版本 0.2.1-rc.5；其数据目录通过 `DSH_HOME` 指定。
- Linux 沙箱：`dsh-bash-sandbox` 使用 bubblewrap（bwrap）。系统未安装 bwrap 时应能降级运行；文档需说明。
- 官方安装包/更新源只有 mac-arm64 与 win：`https://download.deepseek.com/dsh-desk/feeds/...`，不存在 Linux 桌面包。

## 1. 产品形态

- 名称：**DeepSeek Harness (Linux)**（展示名），项目代号 `dsh-linux`。
- 应用 ID：`io.github.dshlinux.deepseek-harness`；可执行文件：`deepseek-harness`。
- 版本：`0.2.1`（应用版本），内置 dsh `0.2.1-rc.5`；版本唯一源为仓库根 `versions.json`（appVersion/dshVersion/nodeVersion/electronVersion/electronBuilderVersion），构建号见 `dist/RELEASE.json`。
- 交付物（dist/，同时作为 GitHub Release 资产）：
  - `DeepSeek-Harness-Linux-0.2.1-x86_64.AppImage`
  - `DeepSeek-Harness-Linux-0.2.1-amd64.deb`
  - `DeepSeek-Harness-Linux-0.2.1-arm64.AppImage`
  - `DeepSeek-Harness-Linux-0.2.1-arm64.deb`
  - `SHA256SUMS`、`RELEASE.json`
  - 自动更新元数据：`latest-linux.yml`（x64）、`latest-linux-arm64.yml`（arm64）及 electron-builder 生成的 `*.blockmap`（如有）
  - 可选（不随本次发布）：`deepseek-harness-linux-<ver>-<arch>.tar.gz`（可用 `build-linux.sh <arch> --targets tar.gz` 自行构建）
- 辅助交付：`scripts/install-cli.sh`（无桌面/服务器环境安装 CLI + dsh-web 启动器）。

## 2. 版本与依赖锁定

| 组件 | 版本 | 说明 |
| --- | --- | --- |
| @deepseek-ai/dsh | 0.2.1-rc.5 | npm 生产安装（--omit=dev） |
| Node.js | 24.22.2（官方 dist linux tar.xz） | 运行时，含 npm |
| Electron | 45.2.1 | 桌面壳 |
| electron-builder | 26.18.0 | 打包 |
| electron-updater | 6.8.11 | AppImage 应用内自动更新 |
| 基线镜像 | debian:bookworm-slim / node:24-bookworm | glibc 2.36 构建基线 |

兼容性：glibc >= 2.28（Node 24 要求），建议 Debian 12 / Ubuntu 22.04+；x64 与 arm64；X11 与 Wayland（XWayland）。

## 3. 目录结构与写入所有权

```
/
├── README.md                  # 中文主文档（docs-writer）
├── README.en.md               # 英文简版（docs-writer）
├── LICENSE                    # MIT（lead）
├── NOTICE.md                  # 非官方声明/商标（lead）
├── package.json               # Electron 应用清单（desktop-engineer）
├── docs/
│   ├── ARCHITECTURE.md        # 本文件（lead）
│   ├── INSTALL.zh-CN.md       # docs-writer
│   ├── BUILD.zh-CN.md         # docs-writer
│   ├── FAQ.zh-CN.md           # docs-writer
│   └── assets/                # 截图/图标（qa 产出截图，docs 引用）
├── app/                       # Electron 壳源码（desktop-engineer）
│   ├── main.mjs
│   ├── preload.cjs
│   ├── splash.html
│   └── assets/…
├── assets/                    # 项目图标（lead）
├── scripts/
│   ├── build.sh               # 顶层编排：runtime + app + package（lead）
│   ├── runtime/build-runtime.sh   # 运行时组装（runtime-engineer）
│   ├── package/build-linux.sh     # AppImage/deb/tar 打包（packaging-engineer）
│   ├── test/verify-linux.sh       # 容器验证 + 截图（qa）
│   └── install-cli.sh         # CLI 安装器（lead）
├── runtime/                   # 构建产物：linux-x64/ linux-arm64/（runtime-engineer，gitignore）
├── packaging/                 # electron-builder 配置/模板（packaging-engineer）
├── tests/                     # 测试脚本与断言（qa）
├── build/                     # 共享缓存（gitignore；各用子目录）
└── dist/                      # 交付物（gitignore，但保留给用户）
```

写入规则：只改自己任务 write scope 内的文件；跨域需求通过 send_message 找 Lead。共享缓存用 `build/<agent>/`。

## 4. 运行时契约（runtime/linux-<arch>/）

```
runtime/linux-x64/            # 或 linux-arm64
├── bin/dsh                   # POSIX sh 包装：exec <dir>/node/bin/node <dir>/node_modules/@deepseek-ai/dsh/lib/bin.js "$@"
├── node/                     # 官方 Node 24 发行目录（bin/node, bin/npm, lib/node_modules/npm, LICENSE）
├── node_modules/             # dsh 生产依赖（npm install --omit=dev）
├── office-skills/            # 从 PyPI 运行时 wheel 提取的 office SKILL.md（可选但建议）
├── licenses/                 # Node LICENSE + dsh LICENSE + 第三方说明
└── version.json              # {"dsh":"0.2.1-rc.5","node":"24.22.2","arch":"x64","builtAt":"..."}
```

要求：
- 纯离线可用（不依赖系统 Node/npm）。
- `bin/dsh --version` 输出 `0.2.1-rc.5`。
- `DSH_HOME=/tmp/x bin/dsh web --no-open --host 127.0.0.1 --port 0` 10 秒内打印 token URL；`curl -L` 返回 200。
- 必须剔除无关平台可选依赖（如 node-pty 的 darwin/win prebuild、@koromix/koffi-darwin-*、@img/sharp-darwin-*、sherpa-onnx-darwin-*、libreoffice-kit-darwin-*），保留 linux-<arch> 对应物。
- 总大小目标：<= 700MB/arch（未压缩；AppImage 目标 <= 450MB）。
- 构建脚本可重复执行；在容器内以 `--platform linux/amd64`（x64）或 `linux/arm64`（arm64）运行。
- 不要在运行时目录内写日志。

## 5. Electron 壳契约（app/）

### 5.1 启动流程
1. `app.whenReady()` 前：`app.setName('deepseek-harness')`；处理 `--no-sandbox`（APPIMAGE 环境或 root/容器，见 8）；单实例锁。
2. 解析参数：`--dsh-home=<dir>`、`--port=<n>`、`--host=<ip>`、`--smoke-test`、`--screenshot=<path>`（后两者仅测试用）、`--version`、`--help`。
3. 定位运行时：
   - 打包后：`path.join(process.resourcesPath, 'runtime')`；
   - 开发：`<repo>/runtime/linux-<arch>`（`process.env.DSH_LINUX_RUNTIME` 可覆盖）。
4. 选择空闲端口：`--port 0`；主机固定 `127.0.0.1`。
5. spawn：`<runtime>/bin/dsh web --no-open --host 127.0.0.1 --port 0`，`detached: true`（独立进程组），env：
   - `DSH_HOME`（默认 `app.getPath('userData')/dsh-home`，可用 `--dsh-home` 或 `DSH_LINUX_HOME` 覆盖）
   - `HOME`、`USER`、`PATH`（前置 `<runtime>/node/bin`，保留用户 PATH）
   - `LANG`/`LC_ALL` 继承；`DSH_TELEMETRY_DISABLED` 不默认设置
   - `cwd` = os.homedir()
6. 读取 stdout/stderr（逐行）：
   - 匹配 `/(https?:\/\/(?:127\.0\.0\.1|localhost):\d+\/?\?token=[A-Za-z0-9_-]+)/` → 主窗口加载该 URL。
   - 60s 未就绪或子进程提前退出 → 错误页/对话框（含日志路径、重试、退出）。
7. 窗口：1280×800（记忆上次尺寸/位置），最小 960×640，`show: false`→ready-to-show 再显示；标题 `DeepSeek Harness`；应用图标；`backgroundColor: '#0f1115'`。
8. 行为：单实例聚焦；外链用 `shell.openExternal`；禁止应用内导航到非 localhost；Ctrl+= / Ctrl+- / Ctrl+0 缩放、F11 全屏、Ctrl+R 刷新；`app.on('before-quit')` 先 SIGTERM 进程组，5s 后 SIGKILL；窗口全部关闭即退出（无托盘）。
9. 菜单：File（打开工作区目录、退出）、Edit（标准编辑）、View（刷新、缩放、全屏）、Help（关于/日志目录/项目主页）。菜单语言按 `app.getLocale()`：zh* → 中文，否则英文。
10. 错误处理：服务崩溃对话框（重启/打开日志/退出）；日志写入 `userData/logs/server.log`（追加，单文件上限 5MB）。
11. 测试钩子：
    - `--smoke-test`：服务就绪 → 加载页面 → 页面 did-finish-load 后打印 `SMOKE_OK <url>` 并退出 0（超时 60s 退出 1）。
    - `--screenshot=<path>`：did-finish-load + 2s 后 `webContents.capturePage()` 写 PNG，打印 `SCREENSHOT_OK <path>`，退出 0。

### 5.2 安全
- `contextIsolation: true`、`nodeIntegration: false`、`sandbox: true`；preload 仅通过 contextBridge 暴露 `{ platform, version, isPackaged }`。
- `setWindowOpenHandler` → 外部浏览器；`will-navigate` 仅允许自身 origin。
- 权限：允许 clipboard-sanitized-write / notifications（如需），其余拒绝。

## 6. 打包契约

- 用 electron-builder 26.18.0 在 Linux 容器内构建（不要跨平台手工拼装）。
- `packaging/` 放配置模板；`scripts/package/build-linux.sh <arch>`：
  1. 校验 `runtime/linux-<arch>` 与 `app/` 存在；
  2. 安装根 `package.json` 的 electron 依赖（缓存 `build/cache/electron`）；
  3. 用 `packaging/after-pack.cjs` 钩子把 `runtime/linux-<arch>` 完整复制到 `resources/runtime`（app.asar 仅含壳代码；electron-builder 的 extraResources 会跳过根级 node_modules）；
  4. 输出 AppImage、deb、tar.gz 到 `dist/`，文件名见 §1；
  5. deb 的 `postinst` 给 `chrome-sandbox` 设 4755；`Depends` 至少含 libgtk-3-0、libnss3、libgbm1、libasound2、libatspi2.0-0、libxss1、libxtst6、xdg-utils；`Recommends: bubblewrap, fonts-noto-cjk`。
  6. 生成 `dist/SHA256SUMS` 与 `dist/RELEASE.json`（版本、dsh/node/electron 版本、构建时间、commit）。
- 应用图标：`assets/icon.png`（1024×1024）；桌面文件 Categories=Development;Utility;，StartupWMClass=DeepSeek-Harness。

## 7. 构建流水线（顶层）

`scripts/build.sh [--arch x64|arm64|all] [--skip-runtime] [--skip-app] [--targets AppImage,deb]`：
1. `scripts/runtime/build-runtime.sh`（每 arch 一次）
2. `npm ci`（根目录，Electron 壳依赖；缓存到 build/cache/npm）
3. `scripts/package/build-linux.sh`（每 arch 一次）
4. 按架构合并 SHA256SUMS/RELEASE.json 并输出摘要；版本默认从 `versions.json` 读取，环境变量（APP_VERSION/DSH_VERSION/NODE_VERSION/ELECTRON_VERSION/BUILDER_VERSION）可覆盖。

开发快捷方式（根 package.json scripts）：`npm start`（DSH_LINUX_RUNTIME 指向本机 runtime）、`npm run dist:linux`。

## 8. Linux 专属处理

- **Electron 沙箱**：deb 安装后 chrome-sandbox 4755；AppImage 无法保留 setuid，启动时若 `process.env.APPIMAGE` 或 root，`app.commandLine.appendSwitch('no-sandbox')`（在 ready 前）。README 说明该权衡。
- **Wayland**：默认 XWayland；如黑屏可 `--ozone-platform=wayland`（文档说明）。
- **bubblewrap 缺失**：dsh 的 bash sandbox 会降级；deb Recommends bubblewrap；AppImage 文档提示 `sudo apt install bubblewrap`。
- **中文字体**：Recommends fonts-noto-cjk；否则界面中文可能方块。
- **数据目录**：`$XDG_CONFIG_HOME/deepseek-harness`（userData：logs、dsh-home/profiles 等）。

## 9. 验收标准（必须全部通过）

- AC1 运行时：x64/arm64 `bin/dsh --version`=0.2.1-rc.5；web 启动打印 token URL；curl -L 200；无插件加载错误。
- AC2 桌面：在 `ubuntu:24.04` + xvfb 容器中 AppImage（extract 运行）与 deb 均能启动，`--screenshot` 产出非空 PNG；退出后无 dsh 子进程残留。
- AC3 安装：deb 在干净 ubuntu:24.04 容器中 `dpkg -i` + `apt-get -f install` 成功；`/usr/bin/deepseek-harness` 存在；能启动。
- AC4 单实例/错误处理：二次启动聚焦已有窗口；服务器被杀后 UI 有错误提示且可重启。
- AC5 文档：README 含安装、首次配置（API Key）、数据目录、卸载、FAQ、构建说明、非官方声明；截图来自真实运行。
- AC6 交付：dist 内四件套 + SHA256SUMS + RELEASE.json + `latest-linux*.yml`；校验和可复算。
- AC7 自动更新：AppImage 打包后含 `electron-updater`，`latest-linux*.yml` 的 path/sha512/size 与实际 AppImage 一致；`--updater-check` 能输出 UPDATE_AVAILABLE/UPDATE_NONE；非 AppImage（deb）不启用自动下载。

## 10. 版本、自动升级与发布

- 版本唯一源：`versions.json`；发版前 `scripts/update-dsh.sh --apply` 更新版本并同步 package.json/README/docs。
- 上游跟随：`.github/workflows/upstream-watch.yml` 每日检查 npm `dist-tags.latest`，有新版本则自动 bump、commit/push、打 tag 并 dispatch `release.yml`。
- 发布：`.github/workflows/release.yml` 在原生 x64/arm64 runner 上构建四件套，合并元数据并创建 GitHub Release；`latest-linux*.yml` 必须随 release 上传。
- 应用内更新：AppImage 通过 electron-updater 从 GitHub Releases 检查/下载/安装；deb 用户手动下载新版；可用 `DSH_LINUX_DISABLE_UPDATER=1` 或 `DSH_LINUX_UPDATE_FEED_URL` 覆盖。
- 用户侧说明与维护流程见 README §7 与 `docs/CI.zh-CN.md`、`docs/MAINTAINING.zh-CN.md`。

## 11. 协作规则

- 先 `team_task_get` 读取任务，再 `team_task_update(action=claim, expected_revision=当前值)`；完成时 `complete`。
- 只写自己 write scope；跨域改动先在任务评论/消息中说明，由 Lead 协调。
- Docker：容器名自取前缀（`dsh-rt-*`、`dsh-pkg-*`、`dsh-qa-*`），不要删除他人容器；构建缓存放 `build/<agent>/`。
- 网络：宿主 `web_fetch` 对部分域名受限，统一用 `curl`（容器内亦可）。
- 进度：每完成一个里程碑 `send_message` 给 lead（一句话 + 证据路径）；阻塞立即上报。
- 时间盒：单步超过 5 分钟无进展先降级方案并上报。
- 不要执行 `present`；交付展示由 Lead 统一完成。

## 12. 已知限制

- 非官方构建；AppImage 支持应用内自动更新（GitHub Releases），deb 需手动升级；无强制更新/托盘。
- 自动更新包未做代码签名（Linux AppImage 常态），更新源为 GitHub Releases；如更换仓库需同步 `packaging/electron-builder.yml` 的 publish 配置。
- 官方 Windows/macOS 桌面专属功能（强制更新、原生目录选择器、系统级通知样式）不保证一致；Web UI 功能完整。
- 不内置 Python/Office 运行时；office 技能使用 dsh 自带的 libreoffice-kit-wasm。需要系统 LibreOffice 的功能按官方 CLI 行为。
- Linux 桌面安全沙箱依赖发行版 userns/SUID 配置，AppImage 可能以 `--no-sandbox` 运行。
