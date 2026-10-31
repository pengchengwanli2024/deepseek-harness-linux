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

`scripts/package/build-linux.sh` 还会注入 **发布资产名**，用于 electron-builder 的
`artifactName`（必须与 GitHub Release 资产名完全一致，否则 electron-updater 404）：

| 变量 | 含义 |
| --- | --- |
| `DSH_ARTIFACT_APPIMAGE` | 最终 AppImage 名，如 `DeepSeek-Harness-Linux-0.2.1-arm64.AppImage` |
| `DSH_ARTIFACT_DEB` | 最终 deb 名，如 `DeepSeek-Harness-Linux-0.2.1-amd64.deb` |

## 产物命名（dist/）

- `DeepSeek-Harness-Linux-0.2.1-x86_64.AppImage` / `...-arm64.AppImage`
- `DeepSeek-Harness-Linux-0.2.1-amd64.deb` / `...-arm64.deb`
- `latest-linux.yml`（x64）/ `latest-linux-arm64.yml`（arm64）：**自动更新通道文件**
- `SHA256SUMS`、`RELEASE.json`
- `deepseek-harness-linux-0.2.1-<arch>.tar.gz`：便携 tar.gz **可选**（默认发布集为 AppImage + deb，tar.gz 可按需用 `--targets tar.gz` 生成）

electron-builder 直接产出最终发布名（`appImage.artifactName` / `deb.artifactName` 由
`DSH_ARTIFACT_*` 渲染），`scripts/package/in-container.sh` 负责校验、复制到 dist/ 并
生成校验和/元数据。

## 应用内自动更新（electron-updater 6.8.11）

`electron-builder.yml` 的 `publish` 固定为 GitHub Releases
（`pengchengwanli2024/deepseek-harness-linux`，`releaseType: release`）。即使构建时用
`--publish never`（不上传），electron-builder 仍会生成：

1. `resources/app-update.yml`（打进 AppImage/deb 内，运行时 electron-updater 读取
   `provider/owner/repo/releaseType/updaterCacheDirName`）；
2. **通道文件**：x64 → `latest-linux.yml`，arm64 → `latest-linux-arm64.yml`
   （electron-updater 的 `Provider.getChannelFilePrefix()` 对 linux 追加 `-<arch>`，x64 除外）；
3. **内嵌 blockmap**：AppImage 的 blockmap（gzip/zstd 压缩的 v2 blockmap + 4 字节长度）
   追加在 AppImage 文件尾部，因此 `files[]` 里是 `blockMapSize` 而不是独立 `.blockmap` 文件
   （differential download 依赖它）。若某目标另生成独立 `.blockmap`，流水线会按
   `<发布资产名>.blockmap` 一并交付。

`scripts/package/in-container.sh` 会用 `scripts/package/verify-update-metadata.cjs` 校验：
`files[].url` 等于最终发布名、`sha512`（base64）/ `size` 与实际文件一致、AppImage 条目含
`blockMapSize`、顶层兼容字段 `path` 指向已列资产；任一不符即构建失败。

**发布要求（GitHub Release 资产）**：`latest-linux.yml`、`latest-linux-arm64.yml` 以及
（若有）`*.blockmap` 必须随安装包一起上传。electron-updater 的 GitHub provider 先从
`releases.atom` 找最新 tag，再请求
`https://github.com/<owner>/<repo>/releases/download/<tag>/<channel>.yml`，缺失即 404。
CI 的 `release.yml` 已覆盖这些资产。

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
- **自动更新的前提**：仅 AppImage 走应用内更新（`process.env.APPIMAGE` 存在）；deb
  安装版没有该环境变量，应用会提示用户到 GitHub Releases 手动下载。AppImage 的
  `--no-sandbox` 与自动更新互相独立（更新只替换 AppImage 文件，不改变启动参数）。
- **同时构建 AppImage+deb 时**：deb 目标也会把自身条目写进同一个通道文件
  （`files[]` 两条），electron-updater 会按扩展名选 `.AppImage`，不影响更新；
  `path/sha512` 顶层兼容字段仍指向 AppImage。

## 手工复现（容器内）

```bash
docker run --rm --platform linux/arm64 -v "$PWD:/work" -v "$PWD/build/cache:/cache" \
  -e DSH_PKG_ROOT=/work \
  -e DSH_PKG_OUTPUT=/tmp/out -e DSH_PKG_BUILD_RESOURCES=/work/assets \
  -e DSH_PKG_ICON=/work/assets/icon.png -e DSH_PKG_RUNTIME=/work/runtime/linux-arm64 \
  node:24-bookworm bash -c 'npm i --ignore-scripts && npx electron-builder --linux AppImage --arm64'
```

> 正常流程请使用 `scripts/package/build-linux.sh <x64|arm64>`，不要手工拼装产物。
