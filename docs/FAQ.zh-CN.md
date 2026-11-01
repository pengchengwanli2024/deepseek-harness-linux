# 常见问题（FAQ · DeepSeek Harness Linux）

> 适用版本：应用 0.2.2，内置 dsh 0.2.1-rc.5。安装步骤见 [INSTALL.zh-CN.md](INSTALL.zh-CN.md)，构建问题见 [BUILD.zh-CN.md](BUILD.zh-CN.md)。

## 目录

1. [AppImage 无法启动（FUSE 相关）](#1-appimage-无法启动fuse-相关)
2. [AppImage 启动后白屏或闪退](#2-appimage-启动后白屏或闪退)
3. [AppImage 为什么要禁用沙箱](#3-appimage-为什么要禁用沙箱)
4. [Wayland 下黑屏或窗口异常](#4-wayland-下黑屏或窗口异常)
5. [bubblewrap 缺失有什么影响](#5-bubblewrap-缺失有什么影响)
6. [中文显示成方块](#6-中文显示成方块)
7. [端口被占用或服务启动失败](#7-端口被占用或服务启动失败)
8. [无法创建默认工作区](#8-无法创建默认工作区--提示-unable-to-create-default-workspace)
9. [公司代理下模型请求失败怎么办](#9-公司代理下模型请求失败怎么办)
10. [模型报错与 API Key 无效](#10-模型报错与-api-key-无效)
11. [日志位置与反馈问题](#11-日志位置与反馈问题)
12. [单实例与进程行为](#12-单实例与进程行为)
13. [数据备份、迁移与恢复](#13-数据备份迁移与恢复)
14. [其他常见问题](#14-其他常见问题)

---

## 1. AppImage 无法启动（FUSE 相关）

**现象**：双击无反应；终端运行报 `dlopen(): error loading libfuse.so.2` 或 `AppImages require FUSE to run`。

**原因**：AppImage 需要 FUSE 2 来挂载自身，很多新发行版默认只装 FUSE 3。

**解决**：

```bash
# Debian 12 / Ubuntu 22.04
sudo apt install libfuse2
# Ubuntu 24.04+（只有 t64 变体，没有 libfuse2）
sudo apt install libfuse2t64
# Fedora
sudo dnf install fuse-libs
# Arch
sudo pacman -S fuse2
```

不装 FUSE 也能用——**推荐**使用提取运行模式（非 root 也可，应用会自动处理沙箱降级）：

```bash
APPIMAGE_EXTRACT_AND_RUN=1 ./DeepSeek-Harness-Linux-0.2.2-x86_64.AppImage
```

或者手动解包后运行（需显式加 `--no-sandbox`）：

```bash
./DeepSeek-Harness-Linux-0.2.2-x86_64.AppImage --appimage-extract
./squashfs-root/deepseek-harness --no-sandbox
```

其他排查：

- 确认有执行权限：`chmod +x <file>.AppImage`；
- 某些系统把 `/tmp` 挂载为 `noexec`，AppImage 挂载点无法执行。可用 `APPIMAGE_EXTRACT_AND_RUN=1`、手动 `--appimage-extract`（运行时加 `--no-sandbox`），或设置 `TMPDIR` 到可执行目录；
- 通过 `cd` 到文件所在目录后用 `./文件名` 运行，避免相对路径问题。

## 2. AppImage 启动后白屏或闪退

**排查顺序**：

1. 在终端前台运行，观察 stderr：

   ```bash
   ./DeepSeek-Harness-Linux-0.2.2-x86_64.AppImage
   ```

2. 查看服务日志：

   ```bash
   tail -n 100 ~/.config/deepseek-harness/logs/server.log
   ```

3. 缺少系统库（常见于精简发行版）：

   ```bash
   sudo apt install libgtk-3-0 libnss3 libgbm1 libasound2 libatspi2.0-0 libxss1 libxtst6 xdg-utils
   ```

4. 如果是 `The SUID sandbox helper binary was found, but is not configured correctly`，说明 Electron 沙箱不可用。AppImage 会自动加 `--no-sandbox`；若仍失败，手动指定：

   ```bash
   ./DeepSeek-Harness-Linux-0.2.2-x86_64.AppImage --no-sandbox
   ```

5. 尝试禁用 GPU（虚拟机/远程桌面/老显卡常见）：

   ```bash
   ./DeepSeek-Harness-Linux-0.2.2-x86_64.AppImage --disable-gpu
   # 或使用应用内置开关：
   DSH_LINUX_DISABLE_GPU=1 deepseek-harness
   ```

## 3. AppImage 为什么要禁用沙箱

**背景**：Chromium 的多进程沙箱依赖 `chrome-sandbox` 这个 setuid 辅助程序（属主 root、权限 4755）。deb 安装包可以设置该权限，而 **AppImage 的 squashfs 镜像无法保留 setuid**，因此 Electron 会拒绝启动。应用检测到 AppImage 环境（`APPIMAGE`）或 root 运行时会自动追加 `--no-sandbox`。

**这意味着什么（权衡）**：

- 失去的是 **Chromium 渲染进程的 OS 级沙箱**；
- 但应用自身的安全设计仍然生效：`contextIsolation: true`、`nodeIntegration: false`、preload 只暴露极窄接口；窗口只加载本机 `127.0.0.1` 的服务，禁止导航到外部站点；外链交给系统浏览器；
- dsh 服务只监听 `127.0.0.1`，并用一次性 token 建立访问，不对局域网暴露；
- 风险主要在于：渲染进程若被恶意页面内容攻破，隔离强度弱于 deb 版。

**建议**：

- 以 AppImage（含 `APPIMAGE_EXTRACT_AND_RUN=1`）运行时会自动降级；**手动解包**运行则需显式加 `--no-sandbox`；
- 需要手动强制时：`DSH_LINUX_NO_SANDBOX=1 deepseek-harness`（或直接传 Electron 的 `--no-sandbox`）；
- 处理敏感代码或长期使用 → 安装 **deb**（保留 setuid 沙箱）；
- 不要以 root 身份运行应用；
- 只在受信任的工作区中使用（dsh 能执行命令、读写文件）。

## 4. Wayland 下黑屏或窗口异常

默认走 **XWayland**，多数发行版开箱即用。若出现黑屏、输入法异常、缩放错乱：

```bash
# 1) 显式使用 X11/XWayland
GDK_BACKEND=x11 deepseek-harness

# 2) 或尝试原生 Wayland（Electron 45 支持，但个别合成器仍有问题）
deepseek-harness --ozone-platform=wayland

# 3) 或临时切到 X11 登录会话（登录界面选择 "Ubuntu on Xorg" 等）
```

若黑屏但进程仍在，可尝试：

```bash
deepseek-harness --disable-gpu
```

> 远程桌面（RDP/VNC）或虚拟机中建议加 `--disable-gpu` 并使用 X11。

## 5. bubblewrap 缺失有什么影响

dsh 的受限命令执行（`dsh-bash-sandbox`）使用 **bubblewrap（bwrap）** 提供文件访问隔离。系统未安装时：

- 命令沙箱无法实施受限模式，相关能力会降级或报 `SANDBOX_UNAVAILABLE`；
- 普通对话、文件读写等仍可工作，但执行命令时的隔离保障变弱。

安装：

```bash
sudo apt install bubblewrap
bwrap --version
```

> Ubuntu 23.10+ 默认限制非特权用户命名空间，bwrap 可能因此失败。若确认需要，可评估后调整：
> `sudo sysctl kernel.apparmor_restrict_unprivileged_userns=0`（这会降低系统级隔离，请自行权衡）。
> deb 包把 `bubblewrap` 声明为 **Recommends**，默认会随包安装。

## 6. 中文显示成方块

缺少中文字体：

```bash
sudo apt install fonts-noto-cjk
fc-cache -fv
# 验证
fc-list :lang=zh | head
```

deb 包的 `Recommends: fonts-noto-cjk` 通常会自动装上；AppImage 用户需手动安装。

如果界面语言不是中文，检查：

```bash
echo $LANG
export LANG=zh_CN.UTF-8
```

> 应用菜单语言根据系统区域自动选择（zh* → 中文，其余英文）。

## 7. 端口被占用或服务启动失败

应用默认用 `--port 0` 让系统分配空闲端口，因此正常情况不会冲突。只有你手动指定 `--port` 时才可能被占用：

```bash
# 查看端口占用
ss -ltnp | grep 8080
# 或
lsof -i :8080
```

处理：

- 去掉 `--port` 让系统分配；
- 或换一个端口：`deepseek-harness --port 8081`；
- 若有上次异常退出的残留 dsh 进程：`ps aux | grep -i dsh` 后终止；
- 仍然启动失败时看日志：`~/.config/deepseek-harness/logs/server.log`。

## 8. 无法创建默认工作区 / 提示 “Unable to create default workspace”

**原因**：首次使用时 dsh 会尝试在系统 **Documents** 目录下创建默认工作区 `~/Documents/deepseek-harness`。在容器、精简系统或未启用 `Documents` 目录的环境里，这一步可能失败。

**解决**：

- 在界面中通过 **「选择工作区目录」** 手动选择一个存在的目录（推荐，最稳妥）；
- 或先用文件管理器创建 `~/Documents` 目录后再启动；
- 确认当前用户对目标目录有读写权限；不要用 root 运行桌面应用。

> 这是工作区初始化问题，不影响应用本身启动。

## 9. 公司代理下模型请求失败怎么办

dsh 支持标准代理环境变量：`http_proxy`、`https_proxy`、`all_proxy`、`no_proxy`（**小写优先**，大写兜底）。回环地址始终直连。

**方式一：启动前导出**

```bash
export https_proxy=http://proxy.corp.example:8080
export http_proxy=http://proxy.corp.example:8080
export no_proxy=127.0.0.1,localhost
deepseek-harness
```

**方式二：写入 `$DSH_HOME/.env`**（桌面版默认 `~/.config/deepseek-harness/dsh-home/.env`）

```bash
cat >> ~/.config/deepseek-harness/dsh-home/.env <<'EOF'
https_proxy=http://proxy.corp.example:8080
http_proxy=http://proxy.corp.example:8080
no_proxy=127.0.0.1,localhost
EOF
```

修改后**重启应用**生效。

**方式三：走私有网关**（不经过代理，直接把请求指向内网服务）

```bash
export DEEPSEEK_BASE_URL=https://llm-gateway.corp.example/v1
deepseek-harness
```

验证网络连通性：

```bash
curl -sS -o /dev/null -w '%{http_code}\n' https://api.deepseek.com --max-time 10
```

> 说明：Electron 窗口自身使用系统代理；而 dsh 子进程（模型/搜索/MCP 请求）使用上述环境变量。两者都要通。

## 10. 模型报错与 API Key 无效

**先确认 Key 本身可用**：

```bash
curl -sS https://api.deepseek.com/models \
  -H "Authorization: Bearer $DEEPSEEK_API_KEY" | head -c 300
```

| 现象 | 可能原因 | 处理 |
| --- | --- | --- |
| `401` / 认证失败 | Key 错误、过期、含空格或换行 | 到 **设置 → 模型** 重新填写（只写保存，不会回显） |
| `402` / 余额不足 | 账户额度用尽 | 充值或换 Key |
| `403` / 区域限制 | 当前网络出口不被允许 | 换网络/代理，或使用私有网关 |
| `404` / 模型不存在 | 模型名在该端点不可用 | 在模型选择器中换模型；自定义端点时确认 `DEEPSEEK_BASE_URL` |
| 请求超时 | 网络/代理不通 | 按上一节检查代理 |
| 界面显示 “API key missing” | 未保存或环境变量未生效 | 保存后重启；确认启动环境里有 `DEEPSEEK_API_KEY` |

**优先级提醒**：已保存的凭据优先于环境变量。如果你在界面里保存过旧 Key，仅改环境变量不会覆盖它——请在 **设置 → 模型** 中更新，或清空该 provider 的凭据。

**检查内置版本**：

```bash
deepseek-harness --version        # 输出应用版本行 + Electron/Chromium/Node 版本
~/.local/bin/dsh-linux --version  # CLI 方式：0.2.1-rc.5
```

> 桌面版 `--version` 是多行输出（应用版本、Electron、Chromium、Node），不是单独一个版本号。

## 11. 日志位置与反馈问题

| 场景 | 位置 |
| --- | --- |
| 桌面版服务日志 | `~/.config/deepseek-harness/logs/server.log` |
| 桌面版配置/数据 | `~/.config/deepseek-harness/` |
| CLI（systemd） | `journalctl --user -u dsh-web -f` |
| CLI（前台运行） | 终端输出 |

实时查看：

```bash
tail -f ~/.config/deepseek-harness/logs/server.log
```

日志超过 5 MB 会轮转为 `server.log.1`（单文件上限约 5 MB）。应用菜单 **文件 → 打开日志目录** 可直接打开日志所在目录；**帮助 → 关于** 会显示数据目录、运行时路径与组件版本。

反馈问题时请附上：

```bash
uname -a
ldd --version | head -1
deepseek-harness --version
# 日志最后 100 行（注意先脱敏 API Key）
tail -n 100 ~/.config/deepseek-harness/logs/server.log
```

> **不要**把 API Key、会话内容或含敏感信息的项目文件贴进 issue。

## 12. 单实例与进程行为

- 应用使用单实例锁：重复启动会**聚焦已有窗口**，不会开第二个服务；
- 关闭主窗口即退出应用（`window-all-closed` → 退出），并停止 dsh 服务（进程组整体终止，5 秒超时后强杀）；
- **没有托盘图标**，也没有“关闭后最小化到后台”的行为；
- 退出后如仍怀疑有残留：

  ```bash
  ps aux | grep -E 'deepseek-harness|dsh web' | grep -v grep
  ```

  正常情况下不应有输出。异常残留可手动结束对应进程。

- 服务崩溃时会弹出对话框，可选择“重启服务 / 打开日志 / 退出”。

## 13. 数据备份、迁移与恢复

**需要备份的內容**：

| 内容 | 路径 | 说明 |
| --- | --- | --- |
| Harness 数据 | `~/.config/deepseek-harness/` | 配置、会话、工作区索引、凭据（`.credentials.yaml` 含 API Key） |
| 工作区文件 | 你选择的项目目录（默认 `~/Documents/deepseek-harness`） | 代码/文档本身，需单独备份 |
| CLI 安装 | `~/.local/lib/deepseek-harness/` | 可重装，不必备份 |

**备份**（先退出应用）：

```bash
tar -czf dsh-backup-$(date +%Y%m%d).tar.gz \
  -C "$HOME" .config/deepseek-harness
```

> 备份包包含 API Key，请妥善保管（建议 `chmod 600`）。`dsh-home/.credentials.yaml` 与 `.env` 也要一并备份/保护。

**恢复 / 迁移到新机器**：

```bash
# 1) 先安装同架构的新版本
# 2) 退出应用，恢复数据
tar -xzf dsh-backup-20250101.tar.gz -C "$HOME"
# 3) 启动应用
```

**改用其他数据目录**（例如放到加密盘）：

```bash
deepseek-harness --dsh-home /mnt/secure/dsh-home
# 或
DSH_LINUX_HOME=/mnt/secure/dsh-home deepseek-harness
```

**彻底重置**（不可恢复）：

```bash
rm -rf ~/.config/deepseek-harness
```

## 14. 其他常见问题

**问：可以以 root 运行吗？**
不建议。root 下 Electron 必须 `--no-sandbox`，且 dsh 会以 root 权限执行命令，风险极高。请用普通用户运行。

**问：HiDPI 缩放不合适？**
可用环境变量或参数调整：

```bash
GDK_SCALE=2 deepseek-harness
# 或
deepseek-harness --force-device-scale-factor=1.25
```

**问：快捷键有哪些？**

| 快捷键 | 功能 |
| --- | --- |
| `Ctrl+R` | 重新加载界面 |
| `Ctrl+Shift+R` | 强制重新加载（忽略缓存） |
| `Ctrl++` / `Ctrl+-` / `Ctrl+0` | 放大 / 缩小 / 重置缩放 |
| `F11` | 全屏切换 |
| `Ctrl+Q` | 退出应用 |
| `F12` | 开发者工具（仅开发模式 `--dev` 或未打包时可用） |

**问：CLI 安装后命令找不到？**

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
which dsh-linux dsh-web
```

**问：能同时运行多个实例/多套数据吗？**
同一用户默认单实例。需要并行时，用不同的数据目录启动 CLI 版本：

```bash
DSH_HOME=/tmp/dsh-a dsh-web --port 8081 --no-open
DSH_HOME=/tmp/dsh-b dsh-web --port 8082 --no-open
```

**问：如何更新？**
AppImage 支持应用内自动更新（启动后静默检查，或菜单“帮助 → 检查更新…”；也可用 `--updater-check` 手动检查），更新来自 GitHub Releases。deb 安装版需手动下载新包覆盖安装；用户数据（`~/.config/deepseek-harness/`）会保留。可用 `DSH_LINUX_DISABLE_UPDATER=1` 禁用自动检查。详见 [INSTALL 第 10 节](INSTALL.zh-CN.md#10-升级与卸载) 与 [README §7](../README.md#7-更新机制升级与卸载)。

**问：0.2.1 的 deb 安装后一启动就崩溃？**
0.2.1 的 deb 把应用装在含空格的 `/opt/DeepSeek Harness/`，Electron 的 SUID sandbox helper 在含空格路径下 `execvp` 失败，普通用户启动即崩溃。**升级到 0.2.2+**（安装目录改为 `/opt/DeepSeek-Harness/`）即可修复；临时也可运行 `deepseek-harness --no-sandbox` 启动（会降低 Chromium 沙箱强度）。AppImage 不受此问题影响。

**问：支持哪些架构？**
x86_64 与 arm64。用 `uname -m` 确认后下载对应产物。
