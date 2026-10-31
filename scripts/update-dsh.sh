#!/usr/bin/env bash
# scripts/update-dsh.sh — 跟随上游 @deepseek-ai/dsh 版本的入口包装
#
# 实际逻辑在 scripts/update-dsh.mjs（Node >= 18，只用标准库）。
# 退出码：0=已是最新/成功  10=发现新版本  2=错误
#
# 用法:
#   scripts/update-dsh.sh --check
#   scripts/update-dsh.sh --check --json
#   scripts/update-dsh.sh --apply
#   scripts/update-dsh.sh --apply --dsh-version 0.2.2-rc.1   # 离线演练
#
# 完整参数见 scripts/update-dsh.mjs --help 或 docs/CI.zh-CN.md。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/update-dsh.mjs"

if ! command -v node >/dev/null 2>&1; then
  echo "update-dsh.sh: ERROR: 未找到 node（需要 Node.js >= 18）；也可在 Docker 中运行 scripts/update-dsh.mjs" >&2
  exit 2
fi

if [ ! -f "$SCRIPT" ]; then
  echo "update-dsh.sh: ERROR: 缺少 $SCRIPT（仓库结构异常）" >&2
  exit 2
fi

# exec 保留 Node 的退出码（10 = 发现新版本），不要在这里包一层判断。
exec node "$SCRIPT" "$@"
