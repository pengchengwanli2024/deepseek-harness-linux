# Changelog

本项目的所有重要变更都会记录在此文件。

格式基于 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

> 本项目是**非官方**社区构建，与 DeepSeek（深度求索）无隶属关系。应用版本（`appVersion`）
> 与内置上游 dsh 版本（`dshVersion`）相互独立，版本信息以 [`versions.json`](versions.json) 为准。

## [Unreleased]

## [0.2.2] - 2026-11-02

首个公开版本：基于官方 `@deepseek-ai/dsh@0.2.1-rc.5` 的 Linux 桌面封装。

### Fixed

- **deb 普通用户启动崩溃**：安装目录由 `/opt/DeepSeek Harness/` 改为无空格的 `/opt/DeepSeek-Harness/`，修复 Electron SUID sandbox helper 在含空格路径下 `execvp` 失败（普通用户启动即崩溃，AppImage 因使用 `--no-sandbox` 不受影响）。0.2.1 的 deb 可通过 `deepseek-harness --no-sandbox` 临时绕过。

### Added

- **桌面应用（Electron 45.2.1）**：独立窗口、启动画面、单实例（重复启动聚焦已有窗口）、窗口尺寸/位置记忆、中英文菜单（按系统区域选择）、外链使用系统浏览器打开、刷新/缩放/全屏快捷键、关于对话框。
- **进程托管**：随窗口启动/退出内置 `dsh web` 服务；服务异常退出时弹窗提示并可一键重启；退出时终止整个进程组，无残留进程。
- **内置离线运行时**：Node.js 24.22.2 + `@deepseek-ai/dsh@0.2.1-rc.5` 生产依赖，无需系统预装 Node.js；同时提供 x86_64 与 arm64 两个架构。
- **安装包**：AppImage（x86_64 / arm64）与 deb（amd64 / arm64），附带 `SHA256SUMS` 与 `RELEASE.json`；deb 安装脚本设置 `chrome-sandbox` 4755 并创建 `/usr/bin/deepseek-harness` 符号链接。
- **CLI 安装脚本**：`scripts/install-cli.sh` 在无桌面/服务器环境安装 `dsh-linux` 与 `dsh-web` 启动器（支持复用系统 Node、`--uninstall`）。
- **应用内更新（AppImage）**：集成 electron-updater 6.8.11，启动后静默检查 GitHub Releases，菜单「帮助 → 检查更新…」可手动检查；提供 `DSH_LINUX_DISABLE_UPDATER=1` 关闭开关。deb 版本引导用户手动下载新包。
- **自动化链路**：`versions.json` 作为版本唯一来源；`scripts/update-dsh.sh` 检查/跟随上游 dsh 版本；GitHub Actions 提供 CI 检查、双架构发布与每日上游巡检，详见 [docs/CI.zh-CN.md](docs/CI.zh-CN.md)。
- **文档**：中文主文档 `README.md`、英文简版 `README.en.md`，以及安装、构建、FAQ、架构、CI、维护者手册。
- **社区文件**：贡献指南、行为准则（Contributor Covenant 2.1）、安全策略、Issue/PR 模板、Dependabot 配置、`.editorconfig`、`.gitattributes`。
- **验证工具**：`scripts/test/verify-linux.sh` 在干净容器中验证运行时、桌面壳、AppImage、deb 与校验清单，并产出真实截图。

### Security

- 本地服务仅监听 `127.0.0.1`，使用一次性 token URL 访问；窗口启用 `contextIsolation`、关闭 `nodeIntegration`，并限制导航到本地 origin。
- AppImage 受机制限制无法保留 setuid 沙箱，以 `--no-sandbox` 运行；deb 版本保留 setuid 沙箱。权衡说明见 README 与 FAQ。
- 日志可能存在提示词与本地路径，反馈前需脱敏；安全报告请使用 [SECURITY.md](SECURITY.md) 中的私下渠道。

### Known limitations

- 非官方构建；功能一致性以官方 CLI / Web UI 为准，官方 Windows/macOS 桌面专属能力不保证一致。
- 应用内自动更新仅支持 AppImage；deb 需手动下载新包。无托盘，关闭窗口即退出应用。
- 不内置 Python / Office 运行时；需要系统 LibreOffice 的功能按官方行为。

[Unreleased]: https://github.com/pengchengwanli2024/deepseek-harness-linux/compare/v0.2.2...HEAD
[0.2.2]: https://github.com/pengchengwanli2024/deepseek-harness-linux/releases/tag/v0.2.2
