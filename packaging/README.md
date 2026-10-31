# packaging/ — 打包配置与模板

本目录是 Linux 交付物（AppImage / deb / tar.gz）的 electron-builder 配置与 deb 维护脚本模板。

## 文件

| 文件 | 用途 |
| --- | --- |
| `electron-builder.yml` | electron-builder 26.18.0 配置模板（路径用 `${env.DSH_PKG_*}` 注入） |
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
| `DSH_PKG_RUNTIME` | 内置运行时 `runtime/linux-<arch>` → `resources/runtime` |
| `DSH_PKG_ROOT` | 仓库根目录（引用 deb 模板） |

## 产物命名（dist/）

- `DeepSeek-Harness-Linux-0.2.1-x86_64.AppImage` / `...-arm64.AppImage`
- `DeepSeek-Harness-Linux-0.2.1-amd64.deb` / `...-arm64.deb`
- `deepseek-harness-linux-0.2.1-x86_64.tar.gz` / `...-arm64.tar.gz`
- `SHA256SUMS`、`RELEASE.json`

electron-builder 先产出 `deepseek-harness-0.2.1-<x64|arm64>.{AppImage,deb,tar.gz}`，
再由 `scripts/package/in-container.sh` 规范化为上述交付名并生成校验和/元数据。

## 手工复现（容器内）

```bash
docker run --rm --platform linux/arm64 -v "$PWD:/work" -v "$PWD/build/cache:/cache" \
  -e DSH_PKG_ROOT=/work \
  -e DSH_PKG_OUTPUT=/tmp/out -e DSH_PKG_BUILD_RESOURCES=/work/assets \
  -e DSH_PKG_ICON=/work/assets/icon.png -e DSH_PKG_RUNTIME=/work/runtime/linux-arm64 \
  node:24-bookworm bash -c 'npm i --ignore-scripts && npx electron-builder --linux AppImage --arm64'
```

> 正常流程请使用 `scripts/package/build-linux.sh <x64|arm64>`，不要手工拼装产物。
