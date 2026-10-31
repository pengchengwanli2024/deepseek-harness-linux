# 安全策略 / Security Policy

本项目是社区维护的 **非官方** DeepSeek Harness Linux 桌面封装。我们重视安全问题，并会尽力快速响应。

## 支持版本

| 版本 | 是否接收安全修复 |
| --- | --- |
| 最新 Release（`0.2.x`） | ✅ 支持 |
| 更早版本 / 自行构建的旧包 | ❌ 不支持，请先升级到最新发布 |

桌面壳版本与内置 dsh 版本是两个独立版本：请同时说明应用版本（`deepseek-harness --version`）与内置 dsh 版本（`dsh web --version` 或关于对话框）。

## 私下报告漏洞

**不要**在公开 issue、PR 或讨论区披露漏洞细节、复现步骤、API Key 或 token。

请使用 GitHub 的 **Security Advisories** 私下报告：

- <https://github.com/pengchengwanli2024/deepseek-harness-linux/security/advisories/new>
- 或仓库 **Security → Report a vulnerability** 页面

报告时请尽量包含：

1. 受影响版本（应用 / dsh / Node / Electron）与安装方式（AppImage、deb、CLI、源码）；
2. 发行版与架构（如 Ubuntu 24.04 arm64）、桌面环境（X11/Wayland）；
3. 影响与攻击前提（本地用户？恶意工作区？恶意网页？）；
4. 最小复现步骤或 PoC（**请脱敏** API Key、token、个人路径与会话内容）；
5. 你期望的修复方式或缓解建议（可选）。

我们会在可能的情况下于 **7 天内**确认收到，并在修复发布后于 Release Notes / [CHANGELOG.md](CHANGELOG.md) 中致谢（除非你要求匿名）。

## 不在本项目范围内

以下问题属于上游或第三方，请向对应项目报告；我们会在确认后转达或在文档中说明：

- **上游 `@deepseek-ai/dsh` / DeepSeek Harness** 的模型、Web UI、插件、MCP、沙箱实现等：<https://github.com/deepseek-ai/deepseek-harness>
- **Node.js** 安全公告：<https://nodejs.org/en/security>
- **Electron / Chromium** 安全公告：<https://www.electronjs.org/security>
- 模型 API（DeepSeek 官方服务）的账号、计费、密钥泄露问题。
- 用户自行在不受信任的工作区中运行任意命令、或把 API Key 写入共享目录导致的信息泄露。

## 本项目自身的安全设计（供报告参考）

- dsh 服务仅监听 `127.0.0.1` 的随机端口，并使用一次性 token URL 访问；
- 窗口启用 `contextIsolation`、关闭 `nodeIntegration`；外链交由系统浏览器打开；导航限制在本地服务 origin；
- AppImage 无法保留 setuid 沙箱，会以 Electron `--no-sandbox` 运行；deb 安装后 `chrome-sandbox` 为 4755，可用 setuid 沙箱。需要更强隔离请使用 deb；
- 日志写入 `~/.config/deepseek-harness/logs/server.log`，可能包含提示词与本地路径，反馈前请脱敏；
- 本项目不收集遥测；是否启用上游遥测由 `DSH_TELEMETRY_DISABLED` 控制。

## 安全更新发布

安全修复通过 GitHub Releases 发布，并在 [CHANGELOG.md](CHANGELOG.md) 中标注。用户应下载最新安装包（deb 重新安装 / AppImage 替换文件），用户数据保留。

---

## English

- **Supported**: latest release (`0.2.x`). Older builds are not supported.
- **Report privately** via [GitHub Security Advisories](https://github.com/pengchengwanli2024/deepseek-harness-linux/security/advisories/new). Do **not** disclose details, API keys, or tokens in public issues.
- Include app/dsh versions, install method, distro/arch/desktop session, impact, and a redacted PoC.
- We aim to acknowledge within 7 days and credit reporters in release notes unless anonymity is requested.
- Upstream `dsh`/DeepSeek Harness, Node.js, Electron/Chromium, and model API issues should be reported to their respective projects.
- The app binds `dsh` to `127.0.0.1` with a one-time token URL; the AppImage runs Electron with `--no-sandbox` while the deb keeps a setuid sandbox; logs may contain prompts and paths — redact before sharing.