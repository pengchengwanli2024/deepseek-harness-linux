# packaging/ — 打包配置与模板

本目录是 Linux 交付物（AppImage / deb / tar.gz）的 electron-builder 配置与 deb 维护脚本模板。

## 文件

| 文件 | 用途 |
| --- | --- |
| `electron-builder.yml` | electron-builder 26.18.0 配置模板（路径用 `${env.DSH_PKG_*}` 注入；`toolsets.appimage: "1.0.3"` 静态 runtime） |
| `after-pack.cjs` | afterPack 钩子：把完整 runtime（含 node_modules）复制到 `resources/runtime` |
| `deb/postinst` | deb 安装后脚本：chrome-sandbox 4755 + desktop/mime 数据库刷新 |
| `deb/postrm` | deb 卸载后脚本（afterRemove） |
| `deb/prerm` | 卸载前脚本模板（electron-builder 不直接使用，供降级/手工组装参考） |
| `deepseek-harness.desktop` | 桌面文件模板（参考用；electron-builder 会按同一字段生成） |

## 环境变量（由 `scripts/package/in-container.sh` 注入）

| 变量 | 含义 |
| --- | --- |
| `DSH_PKG_OUTPUT` | electron-builder 输出目录 |
| `DSH_PKG_BUILD_RESOURCES` | buildResources 目录（仓库 `assets/`） |
| `DSH_PKG_ICON` | 应用图标 `assets/icon.png`（1024×1024） |
| `DSH_PKG_RUNTIME` | 内置运行时 `runtime/linux-<arch>`（由 afterPack 复制到 `resources/runtime`） |
| `DSH_PKG_ROOT` | 仓库根目录（引用 deb 模板） |

## 产物命名（dist/）

- `DeepSeek-Harness-Linux-0.2.1-x86_64.AppImage` / `...-arm64.AppImage`
- `DeepSeek-Harness-Linux-0.2.1-amd64.deb` / `...-arm64.deb`
- `SHA256SUMS`、`RELEASE.json`
- `deepseek-harness-linux-0.2.1-<arch>.tar.gz`：便携 tar.gz **可选**（默认发布集为 AppImage + deb，tar.gz 可按需用 `--targets tar.gz` 生成）

electron-builder 先产出 `deepseek-harness-0.2.1-<x64|arm64>.{AppImage,deb,tar.gz}`，
再由 `scripts/package/in-container.sh` 规范化为上述交付名并生成校验和/元数据。

## 已知限制 / 构建注意

- **runtime 不能走 extraResources**：electron-builder 的文件过滤器会无条件跳过根级
  `node_modules`（`app-builder-lib/out/util/filter.js`），因此改用 `after-pack.cjs` 用
  `fs.cp` 原样复制整个 `runtime/linux-<arch>` 到 `resources/runtime`，并断言
  `bin/dsh`、`node/bin/node`、`node_modules/@deepseek-ai/dsh/lib/bin.js` 存在。
- **AppImage runtime 必须用静态工具集**：legacy `appimage-12.0.1` 的 inner runtime 依赖
  未版本化 `libz.so`（需要 zlib1g-dev），已在 `toolsets.appimage: "1.0.3"` 中改为
  静态 runtime；验证脚本会在无 `zlib1g-dev` 的 ubuntu:24.04 中直接执行 AppImage 本体。
- **x64 AppImage 在 Apple Silicon/Rosetta 下无法执行 outer runtime**
  （x86_64 静态 runtime 返回 `Exec format error`，与产物无关）：流水线会自动降级为
  `hsqs + s_major==4` 定位 squashfs superblock 后用 `unsquashfs` 校验 payload；
  真实 x86_64 机器上的启动冒烟需在发布前复核。
- **deb 安装入口**：electron-builder 只安装到 `/opt/DeepSeek Harness/`，`postinst`
  额外创建 `/usr/bin/deepseek-harness` 符号链接（`postrm` 删除），并给
  `chrome-sandbox` 设 4755。

## 手工复现（容器内）

```bash
docker run --rm --platform linux/arm64 -v "$PWD:/work" -v "$PWD/build/cache:/cache" \
  -e DSH_PKG_ROOT=/work \
  -e DSH_PKG_OUTPUT=/tmp/out -e DSH_PKG_BUILD_RESOURCES=/work/assets \
  -e DSH_PKG_ICON=/work/assets/icon.png -e DSH_PKG_RUNTIME=/work/runtime/linux-arm64 \
  node:24-bookworm bash -c 'npm i --ignore-scripts && npx electron-builder --linux AppImage --arm64'
```

> 正常流程请使用 `scripts/package/build-linux.sh <x64|arm64>`，不要手工拼装产物。
