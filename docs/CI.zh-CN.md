# CI 与自动化（CI · 发布 · 上游跟随）

> 面向维护者与贡献者，说明本仓库的自动化链路：版本如何管理、如何跟随上游 `@deepseek-ai/dsh`、如何在 GitHub Actions 上构建并发布双架构安装包。
>
> 普通用户请阅读 [README](../README.md)、[安装说明](INSTALL.zh-CN.md)；维护者的发布检查清单见 [维护者手册](MAINTAINING.zh-CN.md)；本地构建见 [构建说明](BUILD.zh-CN.md)。

---

## 1. 总览

| Workflow | 触发方式 | 权限 | 作用 |
| --- | --- | --- | --- |
| `.github/workflows/ci.yml` | push 到 `main`、Pull Request、手动 | `contents: read` | 轻量静态检查（shell / Node / YAML / 版本一致性 / 文档链接），**不做全量构建** |
| `.github/workflows/release.yml` | 手动 `workflow_dispatch`（输入 `tag`、`prerelease`） | `contents: write` | 在原生 x64 / arm64 runner 上构建两架构安装包，合并元数据并创建/更新 GitHub Release |
| `.github/workflows/upstream-watch.yml` | 每日定时（03:17 UTC）+ 手动 | `contents: write`、`actions: write` | 检查 npm 上游版本；有新版本则自动升级版本号、提交推送、打 tag 并触发发布 |

三个 workflow 都**不使用任何 secrets**：发布与触发使用 GitHub 自动提供的 `GITHUB_TOKEN`（`${{ github.token }}`），因此 fork PR 只能得到只读权限，不会泄露凭据。

所有用到的 action 固定为以下四个（major 版本，不使用第三方 action，不使用 `@main`）：

- `actions/checkout@v4`
- `actions/setup-node@v4`
- `actions/upload-artifact@v4`
- `actions/download-artifact@v4`

---

## 2. 版本唯一来源：`versions.json`

[`versions.json`](../versions.json) 是**唯一版本源**，仓库中的构建脚本、CI、发布流水线都从这里读取版本：

| 字段 | 含义 | 更新方式 |
| --- | --- | --- |
| `appVersion` | 本项目应用版本（如 `0.2.1`） | 每次发布 patch +1（自动巡检会做）；也可手动修改 |
| `dshVersion` | 内置上游 `@deepseek-ai/dsh` 版本 | 跟随 npm `dist-tags.latest`，由更新脚本写入 |
| `nodeVersion` | 内置 Node.js 版本（官方 linux tar.xz） | 手动升级，需要完整回归（见第 9 节） |
| `electronVersion` | Electron 桌面壳版本 | 手动升级，需与根 `package.json` 的 `devDependencies` 同步 |
| `electronBuilderVersion` | electron-builder 版本 | 手动升级，需与根 `package.json` 同步 |

约定：

- **不要**在脚本或 workflow 里写死版本号（workflow 中不出现具体版本字符串）。
- 根 [`package.json`](../package.json) 的 `version` 必须等于 `versions.json.appVersion`，`devDependencies.electron` / `devDependencies["electron-builder"]` 必须等于对应字段——`ci.yml` 与 `release.yml` 都会校验，不一致直接失败。
- 文档（README、README.en、`docs/*.md`）中的版本字符串由 `update-dsh.sh --apply` 机械同步；**CHANGELOG.md 属于历史记录，不参与替换**。

---

## 3. 构建脚本如何取版本

[`scripts/build.sh`](../scripts/build.sh) 的取值优先级：**同名环境变量 > `versions.json`**。

- `APP_VERSION`、`DSH_VERSION`、`NODE_VERSION`、`ELECTRON_VERSION`、`BUILDER_VERSION` 环境变量可覆盖（用于临时构建/回放历史版本）。
- 两者都缺失时报错退出，并提示检查 `versions.json`。
- 最终 `dist/SHA256SUMS` 与 `dist/RELEASE.json` 由 [`scripts/package/release-metadata.mjs`](../scripts/package/release-metadata.mjs) 以本脚本解析出的版本重写；脚本还会检查 [`scripts/package/build-linux.sh`](../scripts/package/build-linux.sh) 内部的 electron / electron-builder 默认值，不一致时打印 WARN（升级这两个依赖时请同步该文件，见第 9 节）。

CI 中发布流水线会显式清空这些环境变量，保证 tag 对应提交里的 `versions.json` 说了算。

---

## 4. 更新脚本：`scripts/update-dsh.sh`

入口包装脚本为 [`scripts/update-dsh.sh`](../scripts/update-dsh.sh)，真正逻辑在 [`scripts/update-dsh.mjs`](../scripts/update-dsh.mjs)（Node.js ≥ 18，只用标准库，无 npm 依赖）。

### 4.1 检查

```bash
bash scripts/update-dsh.sh --check
# 输出（stdout 仅一行）：
#   UP_TO_DATE            -> 已是最新，退出码 0
#   NEW 0.2.2-rc.1        -> 发现新版本，退出码 10
```

- 数据源：npm registry 的 `dist-tags.latest`（默认 `https://registry.npmjs.org`，可用 `--registry` 或 `UPDATE_DSH_REGISTRY` 覆盖）。
- 细节（当前版本、上游版本、registry）输出到 stderr，不污染 stdout。
- **不联网或 registry 不可用时优雅失败**：stderr 给出原因，退出码 `2`，不会抛异常栈。
- 上游 latest 低于当前固定版本时视为 `UP_TO_DATE`（拒绝自动降级），并在 stderr 告警。

CI 解析用 `--json`（stdout 单行 JSON）：

```bash
bash scripts/update-dsh.sh --check --json
# {"status":"new","action":"check","current":"0.2.1-rc.5","latest":"0.2.2-rc.1",
#  "nextAppVersion":"0.2.2","exitCode":10,...}
```

`status` 取值：`up_to_date` / `new` / `downgrade` / `error`。

### 4.2 升级

```bash
# 升级到 npm latest（写文件，不会 commit）
bash scripts/update-dsh.sh --apply

# 只看会改哪些文件
bash scripts/update-dsh.sh --apply --dry-run

# 离线/回放演练：指定“上游版本”
bash scripts/update-dsh.sh --apply --dsh-version 0.2.2-rc.1 --dry-run
```

`--apply` 做的事：

1. `versions.json`：`dshVersion` 更新为上游版本，`appVersion` patch +1（可用 `--app-version` 显式指定）。
2. 根 `package.json`：`version` 同步为新 `appVersion`。
3. `README.md`、`README.en.md`、`docs/**/*.md`：把旧版本字符串替换为新值（app / dsh / node 三类；先替换更长的 dsh 版本，避免 `0.2.1` 误伤 `0.2.1-rc.5`；`0.2.10`、`10.2.1`、`0.2.1-rc.4` 等相似串不会被误改）。
4. 写入后自校验（重新读取文件确认值正确）；失败返回退出码 `2`，不会留下“半更新”状态。

它**不会**：git commit / push、打 tag、改 CHANGELOG、改 `.github/` 或脚本里的版本。这些由巡检流水线或维护者完成。

### 4.3 退出码与常用参数

| 退出码 | 含义 |
| --- | --- |
| `0` | 已是最新 / `--apply` 成功 / 无需变更 |
| `10` | `--check` 发现新版本（shell 中需显式处理，避免被 `set -e` 当成失败） |
| `2` | 错误：网络不可用、版本格式非法、本地版本不一致、拒绝降级等 |

| 参数 | 说明 |
| --- | --- |
| `--check` / `--apply` | 动作（默认 `--check`） |
| `--json` | stdout 单行 JSON，适配 CI |
| `--dry-run` | `--apply` 只打印变更，不写文件 |
| `--root <目录>` | 仓库根目录（默认脚本上级目录；测试用） |
| `--registry <url>` | npm registry |
| `--dsh-version <ver>` | 跳过网络，直接指定“上游版本”（离线演练） |
| `--app-version <ver>` | 显式指定新 appVersion（默认 patch +1） |
| `--timeout <ms>` | registry 查询超时（默认 20000） |
| `--allow-downgrade` | 允许降级（默认拒绝） |

---

## 5. 自动跟随上游链路（`upstream-watch.yml`）

每日 03:17 UTC（北京时间 11:17）或手动触发，执行：

1. `node scripts/update-dsh.mjs --check --json` 比较 npm `dist-tags.latest` 与 `versions.json.dshVersion`。
2. **无新版本**：写 job summary 后结束。
3. **有新版本**：
   1. `--apply --dsh-version <latest>` 更新 `versions.json`、`package.json` 与文档；
   2. git commit（作者 `github-actions[bot]`）→ push `main`（失败会 rebase 重试 3 次）；
   3. 创建并推送 annotated tag `v<appVersion>`（与 `versions.json` 强一致；tag 已存在则报错停止，避免覆盖已发布版本）；
   4. `gh workflow run release.yml --ref main -f tag=v<appVersion> -f prerelease=false` 触发发布；
   5. 轮询确认 release workflow 已启动，并在 summary 中给出运行链接。
4. registry 不可用（退出码 `2`）：job 以 **warning** 结束，不创建任何提交，等下次计划任务重试。

### 为什么必须用 `workflow_dispatch` 触发发布？

GitHub 的防递归机制规定：使用 `GITHUB_TOKEN` 推送的 commit/tag **不会触发**其它 workflow。因此巡检推送 tag 后，`release.yml` 不会自动运行，必须显式 dispatch。这也是 `upstream-watch.yml` 需要 `actions: write` 权限的原因（dispatch 属于 Actions 写操作）。

### 注意事项

- 若 `main` 开启分支保护（要求 PR / 状态检查），`GITHUB_TOKEN` 的直推会被拒绝。此时请：允许 `github-actions[bot]` 绕过保护，或改为“巡检只提 PR、人工合并后手动触发发布”。
- 巡检提交由 `GITHUB_TOKEN` 推送，**不会触发 `ci.yml`**。因此自动发布链路依赖 `release.yml` 自身的校验（版本一致性、产物校验）兜底；重要发布仍建议人工看一眼 commit。
- `--apply` 只做机械替换；上游若有破坏性变更，需要人工检查 diff 并完整跑验收（见 [维护者手册](MAINTAINING.zh-CN.md)）。

---

## 6. 手动发布（`release.yml`）

### 6.1 触发

```bash
# 推荐：tag 已在 main 上创建并推送后触发
gh workflow run release.yml --ref main -f tag=v0.2.2 -f prerelease=false
```

| input | 必填 | 说明 |
| --- | --- | --- |
| `tag` | 否 | 要构建并发布的 tag（如 `v0.2.2`）。留空则使用 `v<versions.json appVersion>`。必须与 tag 对应提交里的 `versions.json.appVersion` 一致，且 tag 必须已存在 |
| `prerelease` | 否 | 是否标记为 pre-release（默认 `false`） |

### 6.2 三个阶段

| Job | Runner | 说明 |
| --- | --- | --- |
| `prepare` | `ubuntu-24.04` | 读取 `versions.json` 与 `package.json` 并交叉校验；计算 tag、校验 tag 已存在；把版本写入 job outputs |
| `build`（matrix） | x64: `ubuntu-24.04`；arm64: `ubuntu-24.04-arm` | 每个 job **只构建本机架构**（原生 runner，无 QEMU）；内部由 `scripts/build.sh` 调用 Docker 完成运行时与打包；产物上传为 artifact `dist-x64` / `dist-arm64` |
| `release` | `ubuntu-24.04` | 下载两份 artifact 合并到 `dist/`，重算 `SHA256SUMS` / `RELEASE.json`，用 `gh release create`（或已存在时 `gh release upload --clobber`）发布 |

`build` job 的关键步骤：

1. checkout 指定 tag（`fetch-depth: 1`，干净工作区）。
2. `actions/setup-node@v4`（Node 24，仅用于编排；真正的 Node 运行时由构建脚本下载）。
3. 检查 Docker 可用、清理磁盘（托管 runner 空间有限）。
4. 校验 checkout 出的 `versions.json` 与 `prepare` 的输出一致（防止 tag 与版本错配）。
5. `bash scripts/build.sh --arch <arch> --targets AppImage,deb`（内部 Docker 构建运行时 + Electron 壳 + AppImage/deb）。
6. 校验产物存在且体积合理（AppImage、deb 均 > 100 MiB），校验 `RELEASE.json` 的架构字段。
7. 上传整个 `dist/`（含更新元数据文件，若构建产生）。

`release` job 的关键步骤：

1. `actions/download-artifact@v4` 用 `pattern: dist-*`、`merge-multiple: true` 合并；
2. 校验 4 个安装包齐全（两种架构 × AppImage/deb）；
3. 每个架构各跑一次 `scripts/package/release-metadata.mjs` 合并 `SHA256SUMS` 与 `RELEASE.json`（脚本会保留另一架构条目，并对 `dist/` 全部可交付文件重算 SHA-256）；
4. `sha256sum -c SHA256SUMS` 自检；校验 `RELEASE.json.architectures` 恰为 `arm64,x86_64`、版本字段正确、引用的产物都存在；
5. 发布：`gh release create "$TAG" <assets> --title ... --generate-notes [--prerelease]`；若该 Release 已存在（重跑），改为 `gh release upload --clobber` + `gh release edit`，保证幂等（非 pre-release 的 Latest 标记由 GitHub 自动维护，不强制改写历史 Release 的标记）。

### 6.3 上传的发布产物

| 文件 | 说明 |
| --- | --- |
| `DeepSeek-Harness-Linux-<ver>-x86_64.AppImage` / `-arm64.AppImage` | 免安装包 |
| `DeepSeek-Harness-Linux-<ver>-amd64.deb` / `-arm64.deb` | Debian/Ubuntu 安装包 |
| `SHA256SUMS` | 全部可交付文件的 SHA-256（`sha256sum -c` 可复算） |
| `RELEASE.json` | 版本、架构、构建时间、commit、每个产物的大小与 SHA-256 |
| `latest-linux.yml` / `latest-linux-arm64.yml` | electron-updater 检查更新用（若构建产生；由打包任务维护） |
| `*.blockmap` | 增量下载块映射（若构建产生） |

上传集合使用 glob 收集：`DeepSeek-Harness-Linux-*`、`SHA256SUMS`、`RELEASE.json`、`*.blockmap`、`latest-linux*.yml`。**若更新元数据文件缺失，AppImage 的应用内更新会失效**，发布前请确认它们已上传。

### 6.4 发布后校验

```bash
# 下载发布产物后校验
sha256sum -c SHA256SUMS --ignore-missing
```

并确认 Release 页面包含：标签名 `v<appVersion>`、4 个安装包、`SHA256SUMS`、`RELEASE.json`，以及（如需应用内更新）`latest-linux*.yml` 与 `*.blockmap`。

---

## 7. 持续集成（`ci.yml`）

Push 到 `main`、PR、手动触发时运行，目标 **< 5 分钟**，**不在 PR 上做全量构建**。检查项：

| 步骤 | 内容 |
| --- | --- |
| Shell 语法 | 对仓库内全部 `*.sh` 执行 `bash -n` |
| ShellCheck | `shellcheck -S warning -x`（runner 未预装时自动 `apt-get install`） |
| Node 语法 | 对 `*.mjs` / `*.cjs` / `*.js` 执行 `node --check` |
| Workflow YAML | Ruby/Psych 解析 `.github/workflows/*.yml`（无 PyYAML 依赖） |
| Workflow 约束 | action 仅允许上表四个固定版本、禁止 `secrets.*`、必须有 `on:` / `jobs:` / `permissions:`；`release.yml` 必须含 `contents: write`，巡检必须含 `actions: write` |
| 版本一致性 | `versions.json` 字段完整且格式合法；`package.json.version`、`electron`、`electron-builder` 与之一致 |
| 更新脚本离线自测 | `--check`（相同版本 → `UP_TO_DATE`；更高版本 → `NEW` 且退出码 10）；在临时 fixture 上演练 `--apply`（不触碰仓库） |
| 文档链接 | 扫描 Markdown 相对链接，目标文件必须存在 |
| 脚本冒烟 | `scripts/build.sh --help`、`scripts/update-dsh.sh --help` 正常输出 |

**已知排除**：`shellcheck -e SC2066,SC2318` 用于屏蔽 [`scripts/package/verify-in-container.sh`](../scripts/package/verify-in-container.sh) 的历史遗留问题；修复该脚本后请移除排除项。

PR 阶段的 workflow 事件来自 fork 时只有只读权限，不会执行发布/推送类操作。

---

## 8. 如何修改版本

### 8.1 跟随上游 dsh（推荐，自动）

无需手动操作：每日巡检会自动完成（见第 5 节）。本地可先演练：

```bash
bash scripts/update-dsh.sh --check          # UP_TO_DATE / NEW <ver>
bash scripts/update-dsh.sh --apply --dry-run
```

### 8.2 手动升级 dsh / 发布

1. `bash scripts/update-dsh.sh --check` 确认上游版本；
2. `bash scripts/update-dsh.sh --apply`（或显式 `--dsh-version`）；
3. 检查 `git diff`（版本号、文档、`package.json`）；
4. 按 [维护者手册](MAINTAINING.zh-CN.md) 的发布前检查清单验收；
5. 提交 → 打 tag `v<appVersion>` → 推送 → 触发发布（第 6 节）。

### 8.3 手动 bump appVersion（不跟随上游）

`--apply` 在 dsh 版本未变时只做幂等同步，不会 bump `appVersion`；需要独立发版时请直接编辑 [`versions.json`](../versions.json) 的 `appVersion`、根 [`package.json`](../package.json) 的 `version`，并按需同步文档，然后走发布流程。

### 8.4 升级 Node / Electron / electron-builder（需完整回归）

1. 修改 `versions.json` 对应字段；
2. 同步根 `package.json` 的 `devDependencies`（electron、electron-builder）并更新 `package-lock.json`；
3. **electron / electron-builder**：同步 [`scripts/package/build-linux.sh`](../scripts/package/build-linux.sh) 顶部的 `ELECTRON_VERSION` / `BUILDER_VERSION` 默认值（`build.sh` 会 WARN 提示不一致），并重跑打包与容器验收；
4. **Node**：确认官方 `linux-x64` / `linux-arm64` tar.xz 存在且校验和匹配（运行时构建脚本自动下载并校验），重跑两架构运行时自测；
5. 重新生成两架构安装包并做安装/启动验收；
6. 如涉及 electron-updater 元数据或 `publish` 配置变化，确认 `latest-linux*.yml` / `*.blockmap` 仍正确生成。

> 原则：版本号只写在 `versions.json` + `package.json`（以及上文提到的打包脚本默认值）中，workflow 与 CI 不写死版本。

---

## 9. 本地复现 CI 检查

```bash
# shell 语法
git ls-files '*.sh' | xargs -n1 bash -n

# ShellCheck（与 CI 相同的排除项）
git ls-files '*.sh' | xargs shellcheck -S warning -x -e SC2066,SC2318

# Node 语法
git ls-files '*.mjs' '*.cjs' '*.js' | xargs -n1 node --check

# workflow YAML（无 PyYAML 时用 Ruby/Psych）
ruby -ryaml -e 'Dir.glob(".github/workflows/*.yml").each { |f| YAML.load_file(f); puts "OK " + f }'

# 版本一致性 + 更新脚本离线自测
node scripts/update-dsh.mjs --check --dsh-version "$(node -p "require('./versions.json').dshVersion")"
node scripts/update-dsh.mjs --apply --root /tmp/fixture --dsh-version 0.2.2-rc.1 --dry-run
```

---

## 10. 权限与安全

| Workflow | `permissions` | 为什么 |
| --- | --- | --- |
| `ci.yml` | `contents: read` | 只读代码做静态检查 |
| `release.yml` | `contents: write`（job 级：prepare/build 只读，release 写） | 创建/更新 Release、上传资产 |
| `upstream-watch.yml` | `contents: write` + `actions: write` | 推送版本提交与 tag、dispatch 发布 workflow |

- **不使用 secrets**：全部使用内置 `GITHUB_TOKEN`；CI 中有断言禁止 `secrets.*` 出现在 workflow 中。
- action 版本固定为 `v4`（允许 `v4.x.y` 补丁，不允许 `@main` / `@latest`），CI 会校验；如需升级 action major，请同时更新 `ci.yml` 的允许列表。
- fork PR 的 `GITHUB_TOKEN` 只读，无法推送/发布。
- 建议开启 `main` 分支保护；若导致巡检无法直推，见第 5 节的处理方式。

---

## 11. 故障排查

| 现象 | 原因 / 处理 |
| --- | --- |
| `update-dsh.sh --check` 退出码 `2` | registry 不可用/超时/网络受限。确认能访问 `https://registry.npmjs.org`；离线可用 `--dsh-version` 演练；巡检对此只告警不失败 |
| shell 脚本被 `set -e` 中断 | `--check` 发现新版本时退出码是 **10**，脚本里需显式判断（例如先 `set +e` 再取退出码） |
| 巡检报 “tag 已存在” | `versions.json.appVersion` 与既有 tag 冲突。检查是否有人手动改过版本或上一次发布未推进版本号 |
| 发布报 “tag 不存在” | 先创建并推送 tag：`git tag v<appVersion> && git push origin v<appVersion>`，再 dispatch |
| `prepare` 报 package.json / versions.json 不一致 | 先本地 `bash scripts/update-dsh.sh --apply` 同步（或手动改 `package.json.version`），提交后再发版 |
| `git push` main 被拒绝 | 分支保护/权限；见第 5 节。也可改为由维护者合并巡检分支 |
| `gh workflow run` 失败（403/404） | 缺 `actions: write`，或 `release.yml` 尚未在默认分支上；确认 workflow 已合并到 `main` |
| `ubuntu-24.04-arm` runner 一直 pending | 该 label 不可用/配额不足；确认仓库可见性与 runner 标签 |
| Docker 权限错误 | 托管 runner 已预装 Docker；自托管 runner 需把用户加入 `docker` 组 |
| 构建因磁盘不足失败 | `build` job 已清理部分预装工具，但双架构共享缓存仍可能吃紧；可增大 runner 磁盘或拆分缓存 |
| `npm ci` 失败（宿主缓存损坏） | `build.sh` 使用 `build/cache/npm` 独立缓存；CI 每次全新环境。本地损坏时可删除 `build/cache/npm` 重试 |
| workflow YAML 报错 | 用第 9 节的 Ruby/Psych 命令本地解析；注意缩进与 `on:` / `permissions:` 位置 |
| Release 缺少 `latest-linux*.yml` / `*.blockmap` | 打包任务未生成（electron-builder `publish` 配置 / `--publish never` 行为）或未被收集；检查 `packaging/electron-builder.yml` 与 `dist/` 内容，重新构建后重跑 release |
| Release 重跑后资产重复/旧产物 | release job 使用 `gh release upload --clobber` 幂等覆盖；仍异常时先删除该 Release 的资产再重跑 |
| `SHA256SUMS` 校验失败 | 发布前 `release` job 已执行 `sha256sum -c`；若人工上传/替换了文件，需重新运行 release-metadata 并重传 |
| 巡检提交没有触发 CI | 预期行为：`GITHUB_TOKEN` 推送不触发其它 workflow；发布由 `release.yml` 自身校验兜底 |

---

## 12. 已知限制

- **托管 runner 构建时间较长**：单架构运行时 + 打包通常 20–60 分钟（首次无缓存更慢），因此 `build` job 的超时设为 150 分钟；PR 上不做全量构建。
- **arm64 依赖 `ubuntu-24.04-arm` 原生 runner**（已确认可用）；若不可用只能人工构建。
- **巡检自动提交**依赖 `GITHUB_TOKEN` 对 `main` 的写权限；分支保护策略需相应放行。
- 自动链路只做“机械版本跟随”，**不替代人工验收**；上游破坏性变更、Electron/打包链升级必须人工复核。
- 自动链路**不修改 CHANGELOG.md**（历史条目由人工维护），也不会自动回滚有问题的版本；回滚策略见 [维护者手册](MAINTAINING.zh-CN.md)。
- 若仓库改名/迁移，请同步更新 `release.yml` 文档中的仓库链接（`gh` 默认使用当前仓库上下文，通常无需改 workflow）。
