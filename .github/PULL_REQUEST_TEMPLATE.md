## 变更说明

<!-- 这个 PR 做了什么？为什么需要？关联的 issue：Closes #123 -->

## 变更类型

- [ ] 修复缺陷（fix）
- [ ] 新功能（feat）
- [ ] 重构 / 性能（refactor / perf）
- [ ] 文档（docs）
- [ ] 构建 / 打包（build）
- [ ] CI / 发布流程（ci）
- [ ] 其他（chore / test）

## 影响范围

- [ ] Electron 桌面壳（`app/`）
- [ ] 运行时（`scripts/runtime/`）
- [ ] 打包（`packaging/`、`scripts/package/`）
- [ ] 文档 / 截图（`README*`、`docs/`）
- [ ] CI / 发布（`.github/`、`scripts/update-dsh.*`）
- [ ] CLI 安装脚本（`scripts/install-cli.sh`）
- [ ] 仓库元数据（`package.json`、`versions.json` 等）

## 验证方式

<!-- 贴出关键命令与输出（可截取摘要），例如：
bash -n scripts/build.sh
node --check app/main.mjs
bash scripts/test/verify-linux.sh --arch x64 --mode shell
-->

```text

```

- [ ] 已在本地/容器中实际运行验证（不是仅阅读代码）
- [ ] 如涉及 UI，已附截图（不含 API Key / 个人信息）

## 检查清单

- [ ] 只改动与本次变更相关的文件，没有提交 `runtime/`、`dist/`、`build/`、`node_modules/`
- [ ] 没有提交密钥、token、个人路径（`/home/<name>`、`/Users/<name>`、`/Volumes/...`）
- [ ] 用户可见的行为变化已同步更新 `README.md` / `README.en.md` / 相关 `docs/*.zh-CN.md`
- [ ] 已在 [CHANGELOG.md](https://github.com/pengchengwanli2024/deepseek-harness-linux/blob/main/CHANGELOG.md) 的 `Unreleased` 中添加条目（如适用）
- [ ] 文档中的命令与参数在仓库脚本中真实存在（未臆造 flag）
- [ ] 安全相关内容没有在公开 PR 中披露（见 [SECURITY.md](https://github.com/pengchengwanli2024/deepseek-harness-linux/blob/main/SECURITY.md)）
- [ ] 提交信息符合 [Conventional Commits](https://www.conventionalcommits.org/zh-hans/)（见 [CONTRIBUTING.md](https://github.com/pengchengwanli2024/deepseek-harness-linux/blob/main/CONTRIBUTING.md)）
- [ ] 贡献以 [MIT](https://github.com/pengchengwanli2024/deepseek-harness-linux/blob/main/LICENSE) 许可证发布

## 备注

<!-- 已知限制、后续工作、需要维护者决策的事项 -->
