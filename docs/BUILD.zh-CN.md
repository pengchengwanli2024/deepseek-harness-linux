# 构建指南（DeepSeek Harness Linux · 中文）

> 面向想自行构建本项目发布包的开发者。最终用户安装请见 [INSTALL.zh-CN.md](INSTALL.zh-CN.md)。
>
> 版本基线：应用 0.2.2 · dsh 0.2.1-rc.5 · Node.js 24.22.2 · Electron 45.2.1 · electron-builder 26.18.0。

## 目录

- [1. 构建架构](#1-构建架构)
- [2. 前置条件](#2-前置条件)
- [3. 快速开始](#3-快速开始)
- [4. 顶层脚本参数](#4-顶层脚本参数)
- [5. 分步构建](#5-分步构建)
- [6. 产物与命名](#6-产物与命名)
- [7. Docker 与双架构](#7-docker-与双架构)
- [8. 构建后验证](#8-构建后验证)
- [9. 常见构建问题](#9-常见构建问题)
- [10. 发布清单](#10-发布清单)

---

## 1. 构建架构

```text
scripts/build.sh                     顶层编排（--arch / --skip-* / --targets）
├── scripts/runtime/build-runtime.sh  运行时组装（Docker：node:24-bookworm；缓存 build/cache）
│     └── runtime/linux-<arch>/       bin/dsh + node/ + node_modules/ + version.json
├── npm ci                            安装 Electron 壳依赖（缓存 build/cache/npm）
└── scripts/package/build-linux.sh    electron-builder 打包（Linux 容器）
      └── dist/                       发布：AppImage×2 + deb×2 + SHA256SUMS + RELEASE.json
                                      （tar.gz 可由 --targets tar.gz 自行构建）
```

关键原则：

- **运行时与壳分离**：`app.asar` 只包含 Electron 壳代码，运行时通过 `afterPack` 钩子复制进 `resources/runtime`（electron-builder 会跳过根级 `node_modules`，故不能用 `extraResources`）。
- **纯离线运行时**：运行时内置官方 Node.js 发行版与 dsh 生产依赖，不依赖构建机或用户系统的 Node。
- **容器内构建**：x64/arm64 均在 Linux 容器内完成，避免跨平台手工拼装。
- **可重复执行**：每个脚本都能重复运行；共享缓存放 `build/`（已 gitignore）。

## 2. 前置条件

| 依赖 | 要求 | 说明 |
| --- | --- | --- |
| Docker | 20.10+，支持 `--platform` | 运行时组装与打包都在容器内 |
| Node.js（宿主） | ≥ 22（建议 24） | 顶层脚本用 `node -e` 生成 RELEASE.json；`npm ci` 安装壳依赖 |
| 磁盘 | ≥ 20 GB 空闲 | 双架构运行时 + Electron 缓存 + 产物 |
| 网络 | 可访问 npm registry 与 nodejs.org | 首次构建需要下载 Node 发行版与 dsh 依赖 |
| 可选：xvfb | 仅容器验证需要 | 无头环境下运行 Electron 做 smoke-test/截图 |

> **Apple Silicon 上构建 x64**：Docker 通过 `--platform linux/amd64` + Rosetta 模拟，速度较慢但可用；arm64 为原生速度。
> **宿主 npm 缓存损坏（EPERM）**：本项目所有 npm 操作都显式指定缓存目录（`build/cache/npm`），不要复用宿主的默认 `~/.npm`。

## 3. 快速开始

```bash
# 双架构全量构建（默认 --arch all，产出 AppImage/deb）
bash scripts/build.sh

# 只构建当前架构（示例：x64）
bash scripts/build.sh --arch x64

# 复用已有 runtime/，只重装壳依赖并打包
bash scripts/build.sh --skip-runtime

# 跳过 Electron 壳依赖安装（直接使用已有 node_modules）
bash scripts/build.sh --skip-app --targets AppImage

# 指定产物类型
bash scripts/build.sh --arch arm64 --targets AppImage,deb
```

构建完成后：

```bash
ls -lh dist/
cat dist/RELEASE.json
(cd dist && sha256sum -c SHA256SUMS)
```

## 4. 顶层脚本参数

`scripts/build.sh` 的实际参数（`bash scripts/build.sh --help` 可查看摘要）：

| 参数 | 取值 | 默认 | 说明 |
| --- | --- | --- | --- |
| `--arch <a>` | `x64` / `arm64` / `all` | `all` | 目标架构或全部 |
| `--skip-runtime` | 无 | 关 | 跳过运行时构建（要求 `runtime/linux-<arch>` 已存在） |
| `--skip-app` | 无 | 关 | 跳过 Electron 壳依赖安装（要求 `node_modules/` 已存在） |
| `--targets <t>` | 逗号分隔，如 `AppImage,deb` / 追加 `tar.gz` | `AppImage,deb` | 传给打包脚本（tar.gz 可选） |
| `-h`, `--help` | 无 | — | 打印用法 |

可用环境变量覆盖：

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `APP_VERSION` | `0.2.2` | 传给打包脚本（`--app-version`），影响产物名与 `RELEASE.json` |
| `DSH_VERSION` | `0.2.1-rc.5` | 传给运行时与打包脚本（`--dsh-version`） |
| `NODE_VERSION` | `24.22.2` | 传给运行时与打包脚本（`--node-version`），写入 `RELEASE.json` |

示例：

```bash
APP_VERSION=0.2.2 DSH_VERSION=0.2.1-rc.5 bash scripts/build.sh --arch x64
```

## 5. 分步构建

### 5.1 组装运行时

```bash
bash scripts/runtime/build-runtime.sh --arch x64 --dsh-version 0.2.1-rc.5
bash scripts/runtime/build-runtime.sh --arch arm64 --dsh-version 0.2.1-rc.5

# 强制重建并保留容器，便于进入容器排查
bash scripts/runtime/build-runtime.sh --arch arm64 --no-cache --keep-container
```

参数（`bash scripts/runtime/build-runtime.sh --help`）：

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `--arch x64\|arm64`（必填） | — | 目标架构 |
| `--dsh-version VER` | `0.2.1-rc.5` | `@deepseek-ai/dsh` 的 npm 版本 |
| `--node-version VER` | `24.22.2` | 内置 Node.js 运行时版本 |
| `--out DIR` | `runtime/linux-<arch>` | 输出目录（相对仓库根） |
| `--office-skills-version V` | `0.2.2rc2` | PyPI `deepseek-harness-runtime-bin` wheel 版本（提供 office-skills） |
| `--skip-office-skills` | 关 | 不包含 `office-skills/` |
| `--lean` | 关 | 额外裁剪 libreoffice-kit-wasm 资源（office 导出/渲染将不可用） |
| `--skip-selftest` | 关 | 跳过容器内自测（不建议用于发布构建） |
| `--no-cache` | 关 | 强制重新下载输入并重建 builder 镜像 |
| `--keep-container` | 关 | 保留构建容器（调试） |
| `-h`, `--help` | — | 显示帮助 |

产物与证据：

- 运行时：`runtime/linux-<arch>/`（结构见下）；
- 报告：`build/runtime/report-<arch>.txt`（构建 + 自测完整证据）；
- 原始日志：`build/runtime/<arch>-*.log`；
- 退出码为 0 才表示组装与两阶段自测均通过。

> 顶层 `build.sh` 调用运行时脚本时只传 `--arch` 与 `--dsh-version`，其余取默认值。

产出结构（`runtime/linux-<arch>/`）：

```text
runtime/linux-x64/
├── bin/dsh                   # POSIX sh 包装：node node_modules/@deepseek-ai/dsh/lib/bin.js "$@"
├── node/                     # 官方 Node 24 发行目录（bin/node、bin/npm、LICENSE）
├── node_modules/             # dsh 生产依赖（npm install --omit=dev）
├── office-skills/            # 可选：office 技能
├── licenses/                 # 第三方许可证汇总
└── version.json              # {"dsh":"0.2.1-rc.5","node":"24.22.2","arch":"x64","builtAt":"..."}
```

单独验证运行时：

```bash
runtime/linux-x64/bin/dsh --version          # 期望：0.2.1-rc.5

DSH_HOME=/tmp/dshhome runtime/linux-x64/bin/dsh web --no-open --host 127.0.0.1 --port 0
# 日志中应出现：
# dsh web: http://127.0.0.1:<port>/?token=<token>
# 用 curl 验证返回 200：
# curl -sS -o /dev/null -w '%{http_code}\n' -L "http://127.0.0.1:<port>/?token=<token>"
```

验证要点（验收标准 AC1）：

- `bin/dsh --version` 输出 `0.2.1-rc.5`；
- `dsh web` 10 秒内打印带 token 的 URL；
- `curl -L` 返回 `200`；
- 启动日志无 `failed to import` / `ERR_MODULE_NOT_FOUND`；
- 运行时内不含无关平台的预编译二进制（darwin/win 的 node-pty、sharp、koffi、sherpa 等）；
- 总体积目标 ≤ 700 MB/架构（apparent；实测 x64/arm64 约 677–679 MiB / `du` 约 794–797 MB）。

### 5.2 安装 Electron 壳依赖

```bash
npm ci --no-audit --no-fund --cache "$PWD/build/cache/npm"
```

`package.json` 中固定 `electron 45.2.1` 与 `electron-builder 26.18.0`。开发调试：

根 `package.json` 提供的脚本：

| 命令 | 作用 |
| --- | --- |
| `npm start` | 以开发态运行桌面壳（定位 `runtime/linux-<arch>`） |
| `npm run dev` | 开发态 + `--dev`（显示开发者工具菜单与 F12） |
| `npm run smoke` | `electron . --no-sandbox --smoke-test`，快速验证壳 |
| `npm run dist:linux` | 调用 `scripts/package/build-linux.sh`（需自行带 arch 参数） |

联调时可覆盖运行时定位（无需真实 `runtime/`）：

```bash
DSH_LINUX_RUNTIME=/path/to/runtime \
DSH_LINUX_NODE=/path/to/node \
DSH_LINUX_DSH_ENTRY=/path/to/node_modules/@deepseek-ai/dsh/lib/bin.js \
npm start
```

### 5.3 打包

```bash
bash scripts/package/build-linux.sh x64 --targets AppImage,deb,tar.gz
bash scripts/package/build-linux.sh arm64 --targets AppImage,deb,tar.gz

# 只看将执行的 Docker 命令，不做实际构建
bash scripts/package/build-linux.sh x64 --dry-run
```

参数（`bash scripts/package/build-linux.sh --help`）：

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `<x64\|arm64>`（位置参数，必填） | — | 目标架构 |
| `--targets <列表>` | `AppImage,deb,tar.gz` | 逗号分隔的产物类型 |
| `--runtime <目录>` | `runtime/linux-<arch>` | 内置运行时目录（必须含 `bin/dsh`、`node/bin/node`、dsh 包） |
| `--out <目录>` | `dist/` | 交付物输出目录 |
| `--app-version <版本>` | `0.2.2` | 必须与根 `package.json` 的 `version` 一致 |
| `--dsh-version <版本>` | `0.2.1-rc.5` | 写入报告/元数据 |
| `--node-version <版本>` | `24.22.2` | 写入报告/元数据 |
| `--image <镜像>` | `node:24-bookworm` | 容器基础镜像 |
| `--project-dir <目录>` | 仓库根 | 替代项目目录（仅流水线自测） |
| `--keep-container` | 关 | 保留构建容器（调试） |
| `--dry-run` | 关 | 只打印 Docker 命令 |
| `-h`, `--help` | — | 显示帮助 |

打包流程：

1. 宿主侧校验项目、`runtime/linux-<arch>`、`app/`、`package.json` 版本一致性；
2. 在容器内（`--platform linux/amd64` 或 `linux/arm64`）执行 `scripts/package/in-container.sh`，
   由 electron-builder 26.18.0 产出 AppImage/deb/tar.gz；
3. 通过 `packaging/after-pack.cjs` 钩子把 `runtime/linux-<arch>` 完整复制到应用 `resources/runtime`（`app.asar` 仅含壳；electron-builder 的 extraResources 会跳过根级 node_modules）；
4. deb 的 `postinst` 设置 `chrome-sandbox` 4755，提供 `/usr/bin/deepseek-harness` → `/opt/DeepSeek-Harness/deepseek-harness` 符号链接，声明运行依赖与 `Recommends: bubblewrap, fonts-noto-cjk`；
5. 规范化产物命名，生成 `dist/SHA256SUMS` 与 `dist/RELEASE.json`；
6. 证据写入 `build/package/report-<arch>-<时间戳>.txt` 与 `build/package/build-<arch>-<时间戳>.log`；
7. 成功时最后一行输出 `PKG_OK arch=<arch> artifacts=<n>`。

> 容器内实际执行 `scripts/package/in-container.sh`：安装最小构建依赖 → 复制项目并安装 Electron → electron-builder → 规范化产物 → 结构校验（deb 包名/架构/chrome-sandbox/可执行文件）→ 生成 `SHA256SUMS` 与 `RELEASE.json`。`release-metadata.mjs` 会合并另一架构已有的 `RELEASE.json` 条目，因此可跨架构分两次构建后得到完整元数据。

## 6. 产物与命名

| 文件 | 架构 | 说明 |
| --- | --- | --- |
| `DeepSeek-Harness-Linux-0.2.2-x86_64.AppImage` | x64 | 免安装 |
| `DeepSeek-Harness-Linux-0.2.2-amd64.deb` | x64 | Debian/Ubuntu |
| `DeepSeek-Harness-Linux-0.2.2-arm64.AppImage` | arm64 | 免安装 |
| `DeepSeek-Harness-Linux-0.2.2-arm64.deb` | arm64 | Debian/Ubuntu |
| `SHA256SUMS` | — | 校验和（`sha256sum -c` 可复算） |
| `RELEASE.json` | — | 版本、内置组件版本、构建时间、各文件大小 |

> 正式发布为上面 **4 个安装包**（2 架构 × AppImage/deb），**不含 tar.gz**。tar.gz 仍可由脚本按需构建（`--targets tar.gz`），命名见下方规则。

命名规则（与 `scripts/package/build-linux.sh` 一致）：

- AppImage：`<ver>` 位置为应用版本，架构为 `x86_64` / `arm64`；
- deb：包名 `deepseek-harness-linux`，文件名架构按 Debian 命名（`amd64` / `arm64`）；
- tar.gz（可选，自建）：小写 `deepseek-harness-linux-<ver>-<arch>.tar.gz`。

> 最终文件名以 `dist/` 实际产物与该次构建的 `RELEASE.json` 为准。

实测体积（最终发布物）：

| 产物 | arm64 | x64 |
| --- | --- | --- |
| AppImage | 270,334,588 B（≈258 MiB） | 268,661,926 B（≈256 MiB） |
| deb | 224,029,176 B（≈214 MiB） | 229,335,180 B（≈219 MiB） |
| 安装后磁盘占用 | 约 0.9–1.1 GB（arm64 deb Installed-Size ≈ 982 MB） | 同量级 |
| 运行时（解压后） | ≈ 797 MB（`du`；apparent ≈ 679 MiB） | ≈ 794 MB（`du`；apparent ≈ 677 MiB） |

> tar.gz（可选自建）参考体积：x64 ≈ 288 MB。单架构目标为运行时 apparent ≤ 700 MB、AppImage ≤ 450 MB，实际交付满足。精确字节数/校验和以 `RELEASE.json` 与 `SHA256SUMS` 为准。

## 7. Docker 与双架构

### 7.1 镜像

| 用途 | 镜像 | 平台参数 |
| --- | --- | --- |
| 运行时组装 | `node:24-bookworm` | x64: `--platform linux/amd64`；arm64: `--platform linux/arm64` |
| 打包 | electron-builder 官方/自建 Ubuntu 镜像 | 同上 |
| 验证 | `ubuntu:24.04` + `xvfb` | 目标架构 |

构建基线为 Debian 12（glibc 2.36），兼容 glibc ≥ 2.28 的目标系统。

### 7.2 架构注意事项

- **x64**：Apple Silicon 上通过 Rosetta 运行 amd64 容器，首次拉镜像与 npm 安装较慢，属正常现象。
- **arm64**：Apple Silicon / arm64 Linux 原生速度。
- **不要混用架构**：`runtime/linux-x64` 只能打进 x64 包；打包脚本会按 `<arch>` 取值。
- **容器名**：开发/CI 中请使用自己的前缀（如 `dsh-rt-`、`dsh-pkg-`），并避免删除他人容器。

### 7.3 缓存

- 顶层：`build/cache/npm`
- Electron：`build/cache/electron`
- Docker 层缓存由 Docker 自身管理

## 8. 构建后验证

> 仓库提供 `scripts/test/verify-linux.sh`（QA 维护）在容器中自动验证；若脚本不可用，可按下面的手动流程执行。

### 8.1 AppImage

```bash
# 无 FUSE 时推荐提取运行模式（应用自动降级沙箱）
APPIMAGE_EXTRACT_AND_RUN=1 xvfb-run -a ./dist/DeepSeek-Harness-Linux-0.2.2-x86_64.AppImage --smoke-test
# 期望输出包含：SMOKE_OK <url>

# 或手动解包（运行时必须加 --no-sandbox）
./dist/DeepSeek-Harness-Linux-0.2.2-x86_64.AppImage --appimage-extract
xvfb-run -a ./squashfs-root/deepseek-harness --no-sandbox --smoke-test

xvfb-run -a ./squashfs-root/deepseek-harness --no-sandbox --screenshot=/tmp/dsh.png
# 期望输出包含：SCREENSHOT_OK /tmp/dsh.png，且 PNG 非空
```

容器内验证建议设置（均为桌面壳支持的环境变量）：

| 变量 | 作用 |
| --- | --- |
| `DSH_LINUX_CONTAINER=1` | 追加 `--disable-dev-shm-usage`（容器 `/dev/shm` 过小） |
| `DSH_LINUX_DISABLE_GPU=1` | 禁用硬件加速（无 GPU 环境） |
| `DSH_LINUX_SCREENSHOT_DELAY_MS=6000` | 截图前额外等待（仅取景调试；默认加载完成后 2 秒） |
| `DSH_LINUX_HOME=/tmp/dsh-home` | 隔离测试数据目录 |

示例：

```bash
DSH_LINUX_CONTAINER=1 DSH_LINUX_DISABLE_GPU=1 DSH_LINUX_HOME=/tmp/dsh-home \
  xvfb-run -a ./squashfs-root/deepseek-harness --no-sandbox --smoke-test
```

### 8.2 deb

```bash
docker run --rm -it --platform linux/amd64 \
  -v "$PWD/dist:/dist:ro" ubuntu:24.04 bash
# 容器内：
apt-get update
apt-get install -y /dist/DeepSeek-Harness-Linux-0.2.2-amd64.deb
which deepseek-harness
apt-get install -y xvfb
xvfb-run -a deepseek-harness --smoke-test
```

### 8.3 验收检查（对应架构文档 AC）

- [ ] 运行时：两个架构的 `bin/dsh --version` = `0.2.1-rc.5`，web 启动打印 token URL，`curl -L` 200
- [ ] 桌面：AppImage 与 deb 均可启动，`--smoke-test` 输出 `SMOKE_OK`，`--screenshot` 产出非空 PNG
- [ ] 安装：干净 `ubuntu:24.04` 中 `dpkg -i` + `apt-get -f install` 成功，`/usr/bin/deepseek-harness` 存在
- [ ] 单实例：二次启动聚焦已有窗口
- [ ] 退出后无残留 `dsh`/Electron 子进程
- [ ] `dist/SHA256SUMS` 可复算，`RELEASE.json` 完整

## 9. 常见构建问题

| 问题 | 原因 | 处理 |
| --- | --- | --- |
| `docker is required` | 未安装 Docker | 安装并启动 Docker |
| 拉取 `node:24-bookworm` 超时 | 网络/镜像源 | 配置 Docker registry mirror 或代理 |
| x64 构建极慢 | Rosetta 模拟 | 属正常现象；可只构建 arm64 验证流程 |
| npm `EPERM` / `EACCES` | 宿主 npm 缓存权限异常 | 使用脚本内置缓存 `build/cache/npm`；或 `npm --cache /tmp/npm-cache` |
| 运行时含 darwin/win 二进制 | 可选依赖未剔除 | 检查 `build-runtime.sh` / `prune-runtime.sh` 的清理步骤，保留本架构版本 |
| office-skills 构建被跳过 | PyPI wheel 下载失败（网络/镜像） | 查看 `build/runtime/<arch>-*.log`；可先用 `--skip-office-skills` 构建，office 技能为可选 |
| 运行时自测失败 | dsh web 未打印 token / 依赖缺失 | 查看 `build/runtime/report-<arch>.txt`；用 `--keep-container` 进容器排查 |
| 运行时明显超过 800 MB | office 资源/多平台二进制未剔除 | 使用 `--lean` 或检查 `prune-runtime.sh` 的裁剪统计 |
| `bin/dsh --version` 报 `ERR_MODULE_NOT_FOUND` | 生产依赖缺失/被裁掉 | 重新执行运行时脚本；检查 `npm install --omit=dev` 日志 |
| AppImage 打包报缺少图标 | `assets/icon.png` 缺失 | 确认 1024×1024 PNG 存在 |
| `--smoke-test` 超时 | 无显示环境 | 使用 `xvfb-run` |
| 产物名架构不对 | `--arch` 与 runtime 目录不匹配 | 确认 `runtime/linux-<arch>` 已按目标架构构建 |
| 打包脚本提示缺少 `in-container.sh` | 打包流水线未落地完整 | 等待/补齐 `scripts/package/in-container.sh`；可先用 `--dry-run` 检查命令 |
| 版本不一致：`package.json version=…` | 根 package.json 版本与 `--app-version` 不符 | 修改 package.json 或显式传 `--app-version` |

> 时间盒建议：单个阶段超过 10 分钟无进展时，先只构建单架构（`--arch x64` 或 `arm64`）排除并行因素，并检查 Docker 资源与网络。

## 10. 发布清单

发布前逐项确认：

- [ ] `bash scripts/build.sh` 在干净环境可复现
- [ ] `dist/` 内包含 4 个安装包（AppImage×2、deb×2）+ `SHA256SUMS` + `RELEASE.json`（tar.gz 为可选项）
- [ ] `RELEASE.json` 中 `dshVersion=0.2.1-rc.5`、`nodeVersion=24.22.2`、`electronVersion=45.2.1`
- [ ] `docs/assets/screenshot.png` 为真实运行截图（非伪造）
- [ ] README/INSTALL/BUILD/FAQ 中的命令与脚本实际参数一致
- [ ] `NOTICE.md` 非官方声明完整
- [ ] 无 `runtime/`、`node_modules/`、`dist/` 等大文件被提交进 git
