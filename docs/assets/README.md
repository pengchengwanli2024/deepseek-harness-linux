# docs/assets

本目录存放文档引用的图片资源。

## 文件

| 文件 | 状态 | 说明 |
| --- | --- | --- |
| `screenshot.png` | **已提供（Lead/QA 真实运行产出）** | README 主截图，1280×775 PNG；来自应用 `--screenshot` 真实运行 |

## screenshot.png 要求

- 内容：DeepSeek Harness (Linux) 主窗口，加载完成后的真实界面（建议包含会话列表/欢迎页与输入框）。
- 尺寸：建议 1280×800 或 2×（2560×1600）以适配 HiDPI；PNG 格式。
- 来源：在 Linux 容器或真实桌面中运行应用后截取，例如：

  ```bash
  # 应用内置的自动化截图钩子（测试用）
  xvfb-run -a deepseek-harness --screenshot=docs/assets/screenshot.png
  # 期望输出：SCREENSHOT_OK docs/assets/screenshot.png
  ```

- 命名与路径固定为 `docs/assets/screenshot.png`，README 与 README.en.md 已按该路径引用；替换文件即可，无需改文档。
- 不要在截图中暴露 API Key、个人路径、会话内容等敏感信息。

## 状态说明

当前 `screenshot.png` 已由 Lead/QA 提供（真实运行截图）。如后续更换，保持文件名与路径不变即可，README 无需修改。
