# 维护者手册（Maintaining · 发布 / 上游跟随 / 安全响应）

> 面向仓库维护者。普通用户请阅读 [README](../README.md)、[INSTALL](INSTALL.zh-CN.md) 与 [FAQ](FAQ.zh-CN.md)。
>
> 自动化链路（CI、发布、上游巡检）的完整说明见 [docs/CI.zh-CN.md](CI.zh-CN.md)；本手册只描述维护者的操作流程与检查清单。

## 1. 仓库与维护者职责

- 仓库：<https://github.com/pengchengwanli2024/deepseek-harness-linux>
- 发布形态：GitHub Releases，含 AppImage / deb（x86_64、arm64）、`SHA256SUMS`、`RELEASE.json`，以及 electron-updater 需要的 `latest-linux*.yml` 与 `*.blockmap`。
- 维护者需要具备：仓库 Admin（分支保护、Actions）、Releases 管理、Security Advisories 权限。
- 建议在仓库 **Settings** 中开启：
  - `main` 分支保护（要求 CI 通过、禁止强推）；
  - Dependabot alerts / security updates（配置见 `.github/dependabot.yml`）；
  - Private vulnerability reporting（供 [SECURITY.md](../SECURITY.md) 使用）；
  - Secret scanning（GitHub 公开仓库默认开启）。
- **对外沟通一律注明“非官方社区构建”**，与 DeepSeek 无隶属关系（见 [NOTICE.md](../NOTICE.md)）。

## 2. 版本模型

| 字段 | 含义 | 规则 |
| --- | --- | --- |
| `appVersion` | 本项目应用版本（如 `0.2.2`） | 每次发布 patch +1；仅在本项目有独立变更时调整 |
| `dshVersion` | 内置上游 `@deepseek-ai/dsh` 版本 | 跟随 npm `dist-tags.latest`，由自动巡检/手动升级更新 |
| `nodeVersion` | 内置 Node.js（官方 linux tar.xz） | 固定大版本，升级需完整回归 |
| `electronVersion` | Electron 桌面壳 | 固定版本；升级需重跑 shell/打包/验收 |
| `electronBuilderVersion` | electron-builder | 固定版本；升级需重跑打包流水线 |

[`versions.json`](../versions.json) 是版本信息的唯一来源；`scripts/build.sh` 与 CI 从它读取版本（环境变量仍可覆盖）。**不要**在多个文件里手工散落版本号——会破坏自动升级脚本 `scripts/update-dsh.sh` 的替换逻辑。

兼容性基线：glibc ≥ 2.28（Node 24 官方二进制要求）；构建基线 Debian 12 / `node:24-bookworm`。

## 3. 发布前检查清单

在打 tag 之前逐项确认（可在本地或发布 PR 中勾选）：

- [ ] `main` 的 CI（`ci.yml`）为绿色。
- [ ] `bash scripts/update-dsh.sh --check` 输出 `UP_TO_DATE`（若输出 `NEW <ver>`，先决定是本次发布跟随上游，还是按原计划发布）。
- [ ] `bash scripts/build.sh --arch all` 成功完成两架构运行时与安装包构建。
- [ ] `bash scripts/test/verify-linux.sh --arch all --strict --publish-screenshot` 全部 PASS（`--publish-screenshot` 会用真实运行截图更新 `docs/assets/screenshot.png`）。
- [ ] 文档与脚本一致：README / INSTALL / BUILD / FAQ 中的命令与参数可直接运行；版本号一致（`grep -rn '0\.2\.1' README.md docs/` 应只剩当前版本）。
- [ ] [CHANGELOG.md](../CHANGELOG.md) 的 `Unreleased` 条目已归档到新的版本小节，日期正确。
- [ ] `dist/SHA256SUMS` 可复算（`cd dist && sha256sum -c SHA256SUMS`），`dist/RELEASE.json` 的版本/大小/commit 与实际文件一致。
- [ ] `docs/assets/screenshot.png` 来自真实运行，且不含 API Key、个人路径、敏感会话内容。
- [ ] [NOTICE.md](../NOTICE.md) 的非官方声明与商标说明仍在 README 顶部显著位置。
- [ ] **x86_64 真机复核**：x64 AppImage 在真实 x86_64 Linux 机器上启动一次（Apple Silicon + Rosetta、模拟容器不能替代；历史上 x64 AppImage 的外层运行时无法在 Rosetta 下执行）。
- [ ] arm64 产物在原生 arm64 机器/容器中启动一次（CJK 字体、沙箱行为）。

## 4. 手动发布流程

自动发布由 `.github/workflows/release.yml` 完成（细节见 [docs/CI.zh-CN.md](CI.zh-CN.md)）。维护者手动发布的步骤如下：

1. **准备版本**：更新 `versions.json` 与 `CHANGELOG.md`；如需跟随上游，执行
   `bash scripts/update-dsh.sh --apply`（会同步 `versions.json`、根 `package.json` 与文档中的版本字符串）。
2. **本地构建与验收**：按第 3 节清单执行 `scripts/build.sh` 与 `scripts/test/verify-linux.sh`。
3. **提交与打 tag**：提交信息建议 `chore(release): <appVersion>`；打 annotated tag `v<appVersion>`（与 `versions.json` 一致）。
4. **推送**：`git push origin main --follow-tags`。推送 tag 后由发布流水线（或维护者手动触发 `release.yml`）构建并在 Releases 上传产物。
5. **校验 Release**：确认 x86_64 / arm64 的 AppImage、deb、`SHA256SUMS`、`RELEASE.json`、`latest-linux*.yml`、`*.blockmap` 均已上传；下载其中一个包校验 SHA-256。
6. **发布说明**：使用 CHANGELOG 对应小节；开头必须包含“非官方社区构建”声明与升级/卸载指引；安全修复注明受影响版本。
7. **公告**（可选）：在仓库 Discussions/Issue 中发布一条更新说明；不要宣称与 DeepSeek 官方有关联。

> 发布流水线由 CI 驱动时，`GITHUB_TOKEN` 推送的 tag 不会触发另一个 workflow；自动巡检使用 `workflow_dispatch` 触发发布，具体 token/权限见 [docs/CI.zh-CN.md](CI.zh-CN.md)。

## 5. 自动跟随上游 dsh

- 每日定时（以及手动 `workflow_dispatch`）运行上游巡检：`scripts/update-dsh.sh --check` 比较 npm `dist-tags.latest` 与 `versions.json`。
- 发现新版本时，巡检流水线会：`--apply` 更新版本 → 提交并推送 `main` → 创建 tag `v<appVersion>` → 触发发布流水线。
- 本地演练（不会写文件）：

  ```bash
  # 只看是否有新版本（0=已最新，10=有新版本，2=错误）
  bash scripts/update-dsh.sh --check

  # CI 友好的单行 JSON
  bash scripts/update-dsh.sh --check --json

  # 预览 --apply 会修改哪些文件
  bash scripts/update-dsh.sh --apply --dry-run

  # 无网络时指定版本做演练
  bash scripts/update-dsh.sh --apply --dsh-version 0.2.2-rc.1 --dry-run
  ```

- `--apply` 只做机械替换（版本号、`versions.json`、文档字符串）；**上游若有破坏性变更，仍需人工检查 diff 并完整跑验收**。上游新版本若无法通过验收，应修复后手动发布，必要时保持旧 `dshVersion`。
- 巡检/发布失败排查：见 [docs/CI.zh-CN.md](CI.zh-CN.md) 的故障排查小节。

## 6. 应用内更新（AppImage）

- AppImage 构建启用 electron-updater，更新源为 GitHub Releases（`publish` 配置在 `packaging/electron-builder.yml`）；发布时必须同时上传 `latest-linux.yml` / `latest-linux-arm64.yml`（如适用）与 `*.blockmap`，否则客户端检测更新会失败。
- deb 不启用应用内更新：在 README/FAQ 中引导用户从 Releases 下载新包重新安装（用户数据保留）。
- 修改更新逻辑后，务必验证：`app.asar` 内含 `electron-updater`，且 `latest-linux.yml` 的 `path` / `sha512` / `size` 指向正确的 AppImage。
- `--smoke-test` / `--screenshot` / `DSH_LINUX_DISABLE_UPDATER=1` 下必须禁用更新检查，避免测试环境联网。

## 7. 安全响应流程

1. **接收**：通过 GitHub Security Advisories（见 [SECURITY.md](../SECURITY.md)）或维护者私信收到报告，**不要**在公开 issue 讨论细节。
2. **确认**：7 天内回复收到；复现并判断影响范围（应用版本 / dsh 版本 / 是否仅本地利用）。
3. **修复**：在私有 fork 或本地修复；安全修复尽量小步，避免与功能改动混合。
4. **发布**：走发布流程，Release Notes 注明“安全修复”、受影响版本与建议动作；必要时为依赖升级单独发布。
5. **公告**：修复发布后发布 GitHub Security Advisory（可申请 CVE），并在 CHANGELOG 中记录；致谢报告者（除非要求匿名）。
6. **不要在修复发布前公开 PoC/细节**；如果漏洞来自上游或第三方（Node/Electron/dsh），同步转达对应项目。

## 8. 回滚与热修复

- **不要删除或移动已发布的 tag**；GitHub Release 可编辑说明或改为 pre-release。
- 若某版本存在严重问题：尽快发布新的 patch 版本（例如 `0.2.2`）并在 Release Notes 说明受影响范围，优于静默删除资产。
- 若 electron-updater 元数据（`latest-linux*.yml`）错误：修复后重新上传，并确认 `sha512`/文件大小与新包一致；必要时临时将该 Release 标记为 pre-release，防止客户端拉到坏包。
- 若 CI 产物损坏：删除该 Release 的资产并重跑发布流水线，保持 tag 与 RELEASE.json 的 commit 对应。

## 9. Issue / PR 与依赖管理

- 使用 issue 模板（`.github/ISSUE_TEMPLATE/`）收集版本、安装方式、发行版、日志；提醒用户脱敏。
- 依赖更新由 Dependabot 每周提案（npm + GitHub Actions）。合并前至少跑 `ci.yml`；涉及 Electron/打包链的更新需完整验收（大版本已被 `dependabot.yml` 忽略，需人工评估）。
- PR 合并前检查：范围单一、含验证证据、文档与 CHANGELOG 同步、无构建产物/密钥/个人路径。
- 对上游功能问题，引导到 <https://github.com/deepseek-ai/deepseek-harness>。

## 10. 常见维护故障

| 现象 | 排查方向 |
| --- | --- |
| CI 中 shellcheck 失败 | 本地 `shellcheck -S warning scripts/*.sh scripts/*/*.sh`；注意 `set -euo pipefail` 与变量引用 |
| 文档链接检查失败 | 相对链接是否指向已提交文件；锚点是否与标题 slug 一致 |
| npm 安装失败 / 缓存损坏 | 清理 `build/cache/npm`，或 `npm_config_cache=/tmp/npm-cache npm ci` |
| arm64 打包慢或 runner 不可用 | 使用原生 arm64 runner 或 `--platform linux/arm64` 的 Docker（QEMU 模拟很慢） |
| x64 AppImage 无法在开发机运行 | Apple Silicon 的 Rosetta 无法执行 x64 AppImage 外层运行时；用真实 x86_64 机器或仅做结构校验 |
| Release 资产缺失 | 确认 release job 汇总了两架构 `dist/`，且 `SHA256SUMS`/`RELEASE.json` 重新生成 |
| 客户端收不到更新 | 检查 `latest-linux*.yml` 是否上传、`path` 与资产名是否一致、Release 是否为 latest（非 pre-release） |
| 上游巡检误报新版本 | 上游可能发布了预发布版；确认为 `dist-tags.latest` 语义后再决定是否跟随 |

## 11. 联系渠道

- 公开问题：GitHub Issues（模板：Bug / Feature）。
- 私下安全报告：GitHub Security Advisories（<https://github.com/pengchengwanli2024/deepseek-harness-linux/security/advisories/new>）。
- 行为准则问题：见 [CODE_OF_CONDUCT.md](../CODE_OF_CONDUCT.md)。
- **不要**在文档或仓库中编造/添加个人邮箱、电话或社交账号；统一使用上述 GitHub 渠道。
