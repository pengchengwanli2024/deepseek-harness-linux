#!/usr/bin/env bash
# DeepSeek Harness (Linux) — top-level build orchestrator.
# Usage: scripts/build.sh [--arch x64|arm64|all] [--skip-runtime] [--skip-app] [--targets AppImage,deb]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

ARCHES="all"
SKIP_RUNTIME=0
SKIP_APP=0
TARGETS="AppImage,deb"
# 版本来自 versions.json（唯一版本源）；同名环境变量可覆盖（CI/临时构建用）。
APP_VERSION="${APP_VERSION:-}"
DSH_VERSION="${DSH_VERSION:-}"
NODE_VERSION="${NODE_VERSION:-}"
ELECTRON_VERSION="${ELECTRON_VERSION:-}"
BUILDER_VERSION="${BUILDER_VERSION:-}"
VERSIONS_FILE="$ROOT/versions.json"

while [ $# -gt 0 ]; do
  case "$1" in
    --arch) ARCHES="${2:?}"; shift 2 ;;
    --arch=*) ARCHES="${1#*=}"; shift ;;
    --skip-runtime) SKIP_RUNTIME=1; shift ;;
    --skip-app) SKIP_APP=1; shift ;;
    --targets) TARGETS="${2:?}"; shift 2 ;;
    --targets=*) TARGETS="${1#*=}"; shift ;;
    -h|--help) sed -n '2,4p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

case "$ARCHES" in
  all) ARCH_LIST="x64 arm64" ;;
  x64|arm64) ARCH_LIST="$ARCHES" ;;
  *) echo "unsupported --arch: $ARCHES (x64|arm64|all)" >&2; exit 2 ;;
esac

# ---- 版本解析：环境变量优先，其次 versions.json ----------------------------
read_versions_key() {
  # read_versions_key <key>：从 versions.json 读取字符串字段；失败时输出空串
  local key="$1" value=""
  if [ -f "$VERSIONS_FILE" ] && command -v node >/dev/null 2>&1; then
    value="$(node -e '
      try {
        const fs = require("fs");
        const v = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
        const x = v[process.argv[2]];
        process.stdout.write(typeof x === "string" ? x : "");
      } catch (err) { process.exit(0); }
    ' "$VERSIONS_FILE" "$key" 2>/dev/null || true)"
  fi
  printf '%s' "$value"
}

[ -n "$APP_VERSION" ] || APP_VERSION="$(read_versions_key appVersion)"
[ -n "$DSH_VERSION" ] || DSH_VERSION="$(read_versions_key dshVersion)"
[ -n "$NODE_VERSION" ] || NODE_VERSION="$(read_versions_key nodeVersion)"
[ -n "$ELECTRON_VERSION" ] || ELECTRON_VERSION="$(read_versions_key electronVersion)"
[ -n "$BUILDER_VERSION" ] || BUILDER_VERSION="$(read_versions_key electronBuilderVersion)"

missing=""
for pair in "APP_VERSION:$APP_VERSION" "DSH_VERSION:$DSH_VERSION" "NODE_VERSION:$NODE_VERSION" \
            "ELECTRON_VERSION:$ELECTRON_VERSION" "BUILDER_VERSION:$BUILDER_VERSION"; do
  name="${pair%%:*}"
  value="${pair#*:}"
  [ -n "$value" ] || missing="$missing $name"
done
if [ -n "$missing" ]; then
  echo "build.sh: ERROR: 缺少版本取值:$missing" >&2
  echo "  请确认 versions.json 存在且包含 appVersion/dshVersion/nodeVersion/electronVersion/electronBuilderVersion，" >&2
  echo "  或显式设置对应环境变量（APP_VERSION/DSH_VERSION/NODE_VERSION/ELECTRON_VERSION/BUILDER_VERSION）。" >&2
  exit 1
fi

# 打包脚本 scripts/package/build-linux.sh 内部对 electron/electron-builder 仍有默认值，
# 升级这两个依赖时需同步修改该文件，否则容器内日志会显示旧版本（RELEASE.json 最终由本脚本以 versions.json 为准重写）。
PACKAGE_SCRIPT="scripts/package/build-linux.sh"
if [ -f "$PACKAGE_SCRIPT" ]; then
  pkg_electron="$(sed -n 's/^ELECTRON_VERSION="\([^"]*\)".*/\1/p' "$PACKAGE_SCRIPT" | head -n 1)"
  pkg_builder="$(sed -n 's/^BUILDER_VERSION="\([^"]*\)".*/\1/p' "$PACKAGE_SCRIPT" | head -n 1)"
  [ -z "$pkg_electron" ] || [ "$pkg_electron" = "$ELECTRON_VERSION" ] || \
    echo "build.sh: WARN: $PACKAGE_SCRIPT 内部默认 electron=${pkg_electron}，versions.json 为 ${ELECTRON_VERSION}（升级时请同步该文件）" >&2
  [ -z "$pkg_builder" ] || [ "$pkg_builder" = "$BUILDER_VERSION" ] || \
    echo "build.sh: WARN: $PACKAGE_SCRIPT 内部默认 electron-builder=${pkg_builder}，versions.json 为 ${BUILDER_VERSION}（升级时请同步该文件）" >&2
fi

command -v docker >/dev/null || { echo "docker is required" >&2; exit 1; }
mkdir -p build/cache dist

echo "==> DSH Linux build"
echo "    version=$APP_VERSION  dsh=$DSH_VERSION  node=$NODE_VERSION  electron=$ELECTRON_VERSION  builder=$BUILDER_VERSION"
echo "    arches=[$ARCH_LIST]  targets=$TARGETS  versions=$VERSIONS_FILE"
echo

if [ "$SKIP_RUNTIME" -eq 0 ]; then
  for arch in $ARCH_LIST; do
    echo "==> [runtime] linux-$arch"
    bash scripts/runtime/build-runtime.sh --arch "$arch" --dsh-version "$DSH_VERSION" --node-version "$NODE_VERSION"
    echo
  done
else
  echo "==> [runtime] skipped"
fi

if [ "$SKIP_APP" -eq 0 ]; then
  echo "==> [app] installing Electron shell dependencies"
  if [ -f package-lock.json ]; then
    npm ci --no-audit --no-fund --cache "$ROOT/build/cache/npm" >/dev/null
  else
    npm install --no-audit --no-fund --cache "$ROOT/build/cache/npm" >/dev/null
  fi
  echo "    node_modules/ ready"
  echo
else
  echo "==> [app] skipped"
fi

for arch in $ARCH_LIST; do
  echo "==> [package] linux-$arch -> $TARGETS"
  bash scripts/package/build-linux.sh "$arch" --targets "$TARGETS" --app-version "$APP_VERSION" --dsh-version "$DSH_VERSION" --node-version "$NODE_VERSION"
  echo
done

echo "==> [manifest] writing dist/SHA256SUMS and dist/RELEASE.json"
COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
if git status --porcelain --untracked-files=no 2>/dev/null | grep -q .; then DIRTY=true; else DIRTY=false; fi
# 每个架构各跑一次：release-metadata.mjs 会保留另一架构的既有条目（跨架构合并）。
for arch in $ARCH_LIST; do
  node scripts/package/release-metadata.mjs --dist dist --arch "$arch" --version "$APP_VERSION" \
    --dsh-version "$DSH_VERSION" --node-version "$NODE_VERSION" --electron-version "$ELECTRON_VERSION" \
    --builder-version "$BUILDER_VERSION" --commit "$COMMIT" --dirty "$DIRTY"
done
echo
echo "==> Done. Artifacts in $ROOT/dist"
ls -lh dist | sed 's/^/    /'
