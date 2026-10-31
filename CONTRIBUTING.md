# 参与贡献 / Contributing

感谢你愿意参与 **DeepSeek Harness (Linux)**！本项目是社区维护的**非官方** Linux 桌面封装，基于官方 npm 包 [`@deepseek-ai/dsh`](https://www.npmjs.com/package/@deepseek-ai/dsh)。我们欢迎缺陷报告、功能建议、文档改进、打包/CI 修复与上游版本跟进。

在参与之前，请先阅读：

- [行为准则 Code of Conduct](CODE_OF_CONDUCT.md)
- [安全策略 Security](SECURITY.md)（安全漏洞**不要**公开提交 issue）
- [常见问题 FAQ](docs/FAQ.zh-CN.md) 与 [安装指南](docs/INSTALL.zh-CN.md)
- [仓库说明 NOTICE](NOTICE.md)（非官方声明与商标说明）

---

## 1. 项目范围

| 属于本项目 | 不属于本项目 |
| --- | --- |
| Electron 桌面壳（`app/`） | 上游 dsh 的模型能力、Web UI、插件、MCP 实现 |
| 离线运行时组装（`scripts/runtime/`） | 模型 API 服务与计费 |
| AppImage / deb 打包（`packaging/`、`scripts/package/`） | 官方 Windows / macOS 桌面版 |
| 安装/构建/FAQ 文档与 CI | 上游桌面端的专有功能 |

如果问题可以在官方 `dsh` CLI / Web UI 中复现（不涉及本项目桌面壳），请向上游反馈：<https://github.com/deepseek-ai/deepseek-harness>。

## 2. 开发环境

| 依赖 | 版本 / 说明 |
| --- | --- |
| Linux 或 macOS 宿主机 | 构建与验证在 Linux 容器内完成，macOS 宿主机可编排（速度较慢） |
| Docker | 用于运行时组装、打包与容器内验证（必需） |
| Node.js | 宿主 ≥ 22（`scripts/build.sh`、`scripts/package/release-metadata.mjs` 使用；仓库按 Node 24 校验） |
| git / bash / curl | 基础工具 |

> **npm 缓存提示**：若宿主 npm 缓存损坏或只读，设置可写缓存目录，例如
> `npm_config_cache="$PWD/build/cache/npm" npm ci`。仓库脚本默认使用 `build/cache/npm`。

克隆与初步构建：

```bash
git clone https://github.com/pengchengwanli2024/deepseek-harness-linux.git
cd deepseek-harness-linux

# 只构建当前架构的运行时 + 安装包（首次构建需要下载 Node/dsh 依赖）
bash scripts/build.sh --arch x64

# 已有 runtime/ 时，只重装壳依赖并重新打包
bash scripts/build.sh --arch x64 --skip-runtime
```

构建参数、分步构建、容器细节与故障排查见 [docs/BUILD.zh-CN.md](docs/BUILD.zh-CN.md)。

## 3. 目录结构与改动位置

```text
app/                  Electron 主进程、preload、启动画面、图标（桌面壳）
assets/               项目图标
docs/                 安装/构建/FAQ/架构/CI/维护文档
packaging/            electron-builder 配置、deb 脚本、after-pack 钩子
scripts/
  build.sh            顶层编排：运行时 → 壳依赖 → 打包 → 校验清单
  runtime/            运行时组装（Node + dsh 生产依赖 + 许可证）
  package/            打包入口、容器内脚本、SHA256SUMS/RELEASE.json 生成
  test/               Docker 化验收（AppImage/deb/smoke/checksums）
  install-cli.sh      无桌面环境的 CLI 安装器
versions.json         版本唯一来源（app / dsh / Node / Electron）*
.github/workflows/    CI、发布、上游巡检流水线*
```

\* 具体文件与命令以仓库当前内容为准；相关说明见 [docs/CI.zh-CN.md](docs/CI.zh-CN.md)。

**请不要提交构建产物**：`runtime/`、`dist/`、`build/`、`node_modules/` 已在 `.gitignore` 中忽略；本地构建结果保留在工作区即可。

## 4. 本地检查（提交前）

至少运行与你改动相关的检查：

```bash
# 1) Shell 脚本语法
for f in scripts/*.sh scripts/*/*.sh; do bash -n "$f" || exit 1; done

# 2) 如安装了 shellcheck（CI 也会跑）
shellcheck -S warning scripts/*.sh scripts/*/*.sh

# 3) Node 语法
node --check app/main.mjs
node --check scripts/package/release-metadata.mjs

# 4) Docker 化验收（按改动范围选择 --mode）
bash scripts/test/verify-linux.sh --arch x64 --mode runtime,shell
```

`scripts/test/verify-linux.sh` 支持 `runtime`、`shell`、`appimage`、`deb`、`checksums` 五个阶段；缺少产物时默认 `SKIP`，加 `--strict` 视为失败。验收证据写入 `build/qa/`。

## 5. 提交与 PR 规范

### 分支

- 从 `main` 切出，命名如 `feat/appimage-auto-update`、`fix/wayland-black-screen`、`docs/faq-proxy`。
- 一个 PR 聚焦一件事；重构与功能改动尽量分开。

### 提交信息（Conventional Commits）

```text
<type>(<scope>): <简短描述>

<可选正文：动机、行为变化、验证方式>
```

常用 `type`：`feat`、`fix`、`docs`、`test`、`build`、`ci`、`chore`、`refactor`；`scope` 可用 `app`、`runtime`、`packaging`、`docs`、`ci` 等。

示例：`fix(app): kill dsh process group on window close`

### PR 要求

- 描述：改了什么、为什么、如何验证（贴关键命令与输出，必要时附截图/日志）。
- 通过 CI：`.github/workflows/ci.yml`（shellcheck / `bash -n` / `node --check` / YAML 解析 / 文档链接检查）。
- 涉及用户可见行为时：同步更新 `README.md`、`README.en.md`、相关 `docs/*.zh-CN.md` 与 [CHANGELOG.md](CHANGELOG.md)。
- 涉及安装包 / 运行时 / 版本号时：说明对应的 `version.json` 与 `RELEASE.json` 校验结果。
- 不要提交：API Key、token、个人路径（`/home/<name>`、`/Users/<name>`、`/Volumes/...`）、`build/`、`dist/`、`runtime/`、`node_modules/`。
- 新增/修改的命令必须在真实脚本中可用，**不要写未实现的参数**；文档与脚本不一致会被 CI 的文档检查或 review 指出。

## 6. 版本与发布策略

- **应用版本（appVersion）**：本项目自身版本，发布时 patch +1（如 `0.2.1` → `0.2.2`）。
- **内置 dsh 版本（dshVersion）**：跟随上游 `@deepseek-ai/dsh` 的 npm latest（当前 `0.2.1-rc.5`）。
- **Node / Electron / electron-builder**：固定版本，变更需单独评估并完整跑一遍验收。
- 版本信息的唯一来源与自动跟随上游的流程见 [docs/CI.zh-CN.md](docs/CI.zh-CN.md)；维护者发布手册见 [docs/MAINTAINING.zh-CN.md](docs/MAINTAINING.zh-CN.md)。
- 发布由维护者执行；贡献者**不需要**改 tag、版本号或发布流水线，除非任务明确要求。
- 用户侧升级方式：下载新版本安装包覆盖安装（AppImage 替换文件；deb 重新安装，用户数据保留）。发布说明会列出校验和。

## 7. 文档贡献

- 中文文档为主，英文为简版（`README.en.md`）。术语保持一致：如“工作区”“会话”“插件”“运行时”。
- 文档中的每条命令都应可在本仓库中直接运行；参数以脚本 `--help` 为准。
- 文档相对链接必须可解析（CI 会检查），图片放在 `docs/assets/`。
- 不要编造联系邮箱、安全渠道或未发布的功能；安全报告渠道以 [SECURITY.md](SECURITY.md) 为准。

## 8. 许可与商标

- 贡献即表示同意以 [MIT](LICENSE) 许可证发布。
- 请勿在仓库中加入官方图标以外的第三方商标素材；本项目与 DeepSeek 无隶属关系，详见 [NOTICE.md](NOTICE.md)。

---

## English summary

- **Unofficial community build**; bugs reproducible in upstream `dsh` should go upstream.
- **Requirements**: Docker, host Node.js ≥ 22, bash/curl. Build with `bash scripts/build.sh --arch x64`; verify with `bash scripts/test/verify-linux.sh --arch x64 --mode runtime,shell`.
- **Do not commit** `runtime/`, `dist/`, `build/`, `node_modules/`, secrets, or absolute personal paths.
- **Commits**: Conventional Commits. One focused change per PR; include test evidence.
- **Docs**: keep `README.md`, `README.en.md`, `docs/*.zh-CN.md` and `CHANGELOG.md` in sync with user-visible behavior; every command must exist in the repository.
- **Versioning**: app version bumps on release; bundled dsh tracks upstream npm latest. See [docs/CI.zh-CN.md](docs/CI.zh-CN.md) and [docs/MAINTAINING.zh-CN.md](docs/MAINTAINING.zh-CN.md).
- **Security**: report privately per [SECURITY.md](SECURITY.md); never open a public issue with vulnerability details or credentials.
- Contributions are licensed under [MIT](LICENSE).