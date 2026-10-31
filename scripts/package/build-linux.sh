#!/usr/bin/env bash
# DeepSeek Harness (Linux) — Linux 打包入口（AppImage / deb / tar.gz）
#
# 用法:
#   scripts/package/build-linux.sh <x64|arm64> [options]
#
# 选项:
#   --targets <列表>       逗号分隔，可选 AppImage,deb,tar.gz（默认三者全打）
#   --runtime <目录>       运行时目录（默认 <repo>/runtime/linux-<arch>）
#   --out <目录>           交付物输出目录（默认 <repo>/dist）
#   --app-version <版本>   期望的应用版本（默认 0.2.1，必须与根 package.json version 一致）
#   --dsh-version <版本>   内置 dsh 版本（默认 0.2.1-rc.5，写入 RELEASE.json）
#   --node-version <版本>  内置 Node 版本（默认 24.22.2，写入 RELEASE.json）
#   --image <镜像>         Docker 基础镜像（默认 node:24-bookworm）
#   --project-dir <目录>   项目根（默认本仓库；仅流水线自测时指向替代项目）
#   --keep-container       保留构建容器（调试用）
#   --dry-run              只打印将执行的命令
#   -h | --help            显示帮助
#
# 说明:
#   * 所有打包都在 Linux 容器内完成（arm64 → --platform linux/arm64，x64 → linux/amd64），
#     宿主只负责编排与最终校验，不在 macOS 上手工拼装。
#   * 构建缓存放在 build/cache/（npm、electron、electron-builder toolset），可重复执行。
#   * 产物落到 <out>/，并生成 SHA256SUMS 与 RELEASE.json（可跨架构多次构建合并）。
#   * 证据（构建日志、报告）放到 build/package/。
#
# 产物命名（<ver>=<app-version>）:
#   DeepSeek-Harness-Linux-<ver>-x86_64.AppImage   / ...-arm64.AppImage
#   DeepSeek-Harness-Linux-<ver>-amd64.deb        / ...-arm64.deb
#   deepseek-harness-linux-<ver>-x86_64.tar.gz    / ...-arm64.tar.gz
#
# 成功时最后一行输出: PKG_OK arch=<arch> artifacts=<n>
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

ARCH=""
TARGETS="AppImage,deb,tar.gz"
APP_VERSION="0.2.1"
DSH_VERSION="0.2.1-rc.5"
NODE_VERSION="24.22.2"
ELECTRON_VERSION="45.2.1"
BUILDER_VERSION="26.18.0"
DOCKER_IMAGE="node:24-bookworm"
KEEP_CONTAINER=0
DRY_RUN=0
PROJECT_DIR="${DSH_PKG_PROJECT_DIR:-$ROOT_DIR}"
RUNTIME_DIR=""
OUT_DIR="${DSH_PKG_OUT_DIR:-$ROOT_DIR/dist}"
EVIDENCE_DIR="${DSH_PKG_EVIDENCE_DIR:-$ROOT_DIR/build/package}"
CACHE_DIR="$ROOT_DIR/build/cache"

usage() { sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# {0,1}//'; }

die() { printf 'build-linux.sh: ERROR: %s\n' "$*" >&2; exit 1; }
note() { printf 'build-linux.sh: %s\n' "$*"; }
need_file() { [ -f "$1" ] || die "missing file: $1"; }
need_dir() { [ -d "$1" ] || die "missing directory: $1"; }

while [ $# -gt 0 ]; do
  case "$1" in
    x64|arm64) ARCH="$1"; shift ;;
    --targets) TARGETS="$2"; shift 2 ;;
    --targets=*) TARGETS="${1#*=}"; shift ;;
    --runtime) RUNTIME_DIR="$2"; shift 2 ;;
    --runtime=*) RUNTIME_DIR="${1#*=}"; shift ;;
    --out) OUT_DIR="$2"; shift 2 ;;
    --out=*) OUT_DIR="${1#*=}"; shift ;;
    --app-version) APP_VERSION="$2"; shift 2 ;;
    --app-version=*) APP_VERSION="${1#*=}"; shift ;;
    --dsh-version) DSH_VERSION="$2"; shift 2 ;;
    --dsh-version=*) DSH_VERSION="${1#*=}"; shift ;;
    --node-version) NODE_VERSION="$2"; shift 2 ;;
    --node-version=*) NODE_VERSION="${1#*=}"; shift ;;
    --image) DOCKER_IMAGE="$2"; shift 2 ;;
    --image=*) DOCKER_IMAGE="${1#*=}"; shift ;;
    --project-dir) PROJECT_DIR="$2"; shift 2 ;;
    --project-dir=*) PROJECT_DIR="${1#*=}"; shift ;;
    --keep-container) KEEP_CONTAINER=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

[ -n "$ARCH" ] || { usage >&2; die "missing <x64|arm64> argument"; }
case "$ARCH" in
  x64)   DOCKER_PLATFORM="linux/amd64"; ARTIFACT_ARCH="x86_64"; DEB_ARCH="amd64" ;;
  arm64) DOCKER_PLATFORM="linux/arm64"; ARTIFACT_ARCH="arm64";  DEB_ARCH="arm64" ;;
  *) die "unsupported arch: $ARCH (expected x64 or arm64)" ;;
esac

IFS=',' read -r -a TARGET_ARR <<EOF
$TARGETS
EOF
[ "${#TARGET_ARR[@]}" -gt 0 ] || die "--targets is empty"
for t in "${TARGET_ARR[@]}"; do
  case "$t" in AppImage|deb|tar.gz|"") ;; *) die "unsupported target: $t (expected AppImage,deb,tar.gz)" ;; esac
done

[ -n "$RUNTIME_DIR" ] || RUNTIME_DIR="$ROOT_DIR/runtime/linux-$ARCH"

# 统一成绝对路径（脚本可在任意 cwd 下调用；runtime/out/project 都必须在仓库内）
PROJECT_DIR="$(cd "$PROJECT_DIR" 2>/dev/null && pwd)" || die "project dir not found: $PROJECT_DIR"
RUNTIME_DIR="$(cd "$RUNTIME_DIR" 2>/dev/null && pwd)" || die "runtime dir not found: $RUNTIME_DIR"
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)" || die "cannot create out dir: $OUT_DIR"

APPIMAGE_NAME="DeepSeek-Harness-Linux-${APP_VERSION}-${ARTIFACT_ARCH}.AppImage"
DEB_NAME="DeepSeek-Harness-Linux-${APP_VERSION}-${DEB_ARCH}.deb"
TARBALL_NAME="deepseek-harness-linux-${APP_VERSION}-${ARTIFACT_ARCH}.tar.gz"

# ---- 输入校验 ---------------------------------------------------------------
[ "$DRY_RUN" = "1" ] || {
  need_dir "$PROJECT_DIR"
  need_file "$PROJECT_DIR/package.json"
  need_dir "$PROJECT_DIR/app"
  need_dir "$RUNTIME_DIR"
  need_file "$RUNTIME_DIR/bin/dsh"
  need_file "$RUNTIME_DIR/node/bin/node"
  need_file "$RUNTIME_DIR/node_modules/@deepseek-ai/dsh/package.json"
}

PKG_JSON="$PROJECT_DIR/package.json"
grep -Eq '"electron"[[:space:]]*:[[:space:]]*"' "$PKG_JSON" 2>/dev/null || die "package.json 缺少 electron devDependency"
grep -Eq '"electron-builder"[[:space:]]*:[[:space:]]*"' "$PKG_JSON" 2>/dev/null || die "package.json 缺少 electron-builder devDependency"
if ! grep -Eq '"electron"[[:space:]]*:[[:space:]]*"45\.2\.1"' "$PKG_JSON"; then
  note "WARN: 根 package.json 的 electron 版本不是 45.2.1（架构契约要求 45.2.1）"
fi
if ! grep -Eq '"electron-builder"[[:space:]]*:[[:space:]]*"26\.18\.0"' "$PKG_JSON"; then
  note "WARN: 根 package.json 的 electron-builder 版本不是 26.18.0（架构契约要求 26.18.0）"
fi
PKG_VERSION="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$PKG_JSON" | head -n 1)"
[ "$PKG_VERSION" = "$APP_VERSION" ] || die "根 package.json version=${PKG_VERSION}，期望 ${APP_VERSION}（或显式传 --app-version=${PKG_VERSION}）"
MAIN_REL="$(sed -n 's/.*"main"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$PKG_JSON" | head -n 1)"
[ -n "$MAIN_REL" ] || die "package.json 缺少 main 字段"
need_file "$PROJECT_DIR/$MAIN_REL"

if [ -f "$RUNTIME_DIR/version.json" ]; then
  grep -Eq "\"arch\"[[:space:]]*:[[:space:]]*\"$ARCH\"" "$RUNTIME_DIR/version.json" 2>/dev/null || note "WARN: runtime/version.json 的 arch 字段与 $ARCH 不一致（继续）"
  grep -q "$DSH_VERSION" "$RUNTIME_DIR/version.json" 2>/dev/null || note "WARN: runtime/version.json 未标注 dsh ${DSH_VERSION}（继续）"
else
  note "WARN: $RUNTIME_DIR/version.json 不存在（继续）"
fi

command -v docker >/dev/null 2>&1 || die "docker not found"

mkdir -p "$OUT_DIR" "$EVIDENCE_DIR" "$CACHE_DIR/electron-builder" "$CACHE_DIR/npm"

TS="$(date +%Y%m%d-%H%M%S)"
LOG="$EVIDENCE_DIR/build-${ARCH}-${TS}.log"
REPORT="$EVIDENCE_DIR/report-${ARCH}-${TS}.txt"
CONTAINER_NAME="dsh-pkg-${ARCH}-$(date +%s)-$$"
START_EPOCH="$(date +%s)"
BUILT_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
COMMIT="$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
DIRTY="false"
if ! git -C "$ROOT_DIR" diff --quiet 2>/dev/null; then DIRTY="true"; fi

# 容器内路径映射（仓库根挂到 /work，runtime/out 必须位于仓库内，避免空格路径进入容器）
PROJECT_IN="/work"
case "$PROJECT_DIR" in
  "$ROOT_DIR"/*) PROJECT_IN="/work/${PROJECT_DIR#$ROOT_DIR/}" ;;
  "$ROOT_DIR") PROJECT_IN="/work" ;;
  *) die "--project-dir 必须位于仓库目录内（当前: ${PROJECT_DIR}）" ;;
esac
RUNTIME_IN="/work/runtime/linux-$ARCH"
case "$RUNTIME_DIR" in
  "$ROOT_DIR"/*) RUNTIME_IN="/work/${RUNTIME_DIR#$ROOT_DIR/}" ;;
  *) die "--runtime 必须位于仓库目录内（当前: ${RUNTIME_DIR}；runtime/ 已是架构契约位置）" ;;
esac
OUT_IN="/work"
case "$OUT_DIR" in
  "$ROOT_DIR"/*) OUT_IN="/work/${OUT_DIR#$ROOT_DIR/}" ;;
  *) die "--out 必须位于仓库目录内（当前: ${OUT_DIR}）" ;;
esac
need_file "$ROOT_DIR/assets/icon.png"

cleanup() {
  if [ "$KEEP_CONTAINER" != "1" ]; then
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  else
    note "container kept: $CONTAINER_NAME"
  fi
}
trap cleanup EXIT INT TERM

DOCKER_RUN=(
  run --rm --name "$CONTAINER_NAME" --platform "$DOCKER_PLATFORM"
  -v "$ROOT_DIR:/work"
  -v "$CACHE_DIR:/cache"
  -e DSH_ARCH="$ARCH"
  -e DSH_TARGETS="$TARGETS"
  -e DSH_APP_VERSION="$APP_VERSION"
  -e DSH_DSH_VERSION="$DSH_VERSION"
  -e DSH_NODE_VERSION="$NODE_VERSION"
  -e DSH_ELECTRON_VERSION="$ELECTRON_VERSION"
  -e DSH_BUILDER_VERSION="$BUILDER_VERSION"
  -e DSH_PROJECT_SRC="$PROJECT_IN"
  -e DSH_RUNTIME_SRC="$RUNTIME_IN"
  -e DSH_OUTPUT_DIR="/build/output"
  -e DSH_DIST_DIR="$OUT_IN"
  -e DSH_PKG_ROOT="/work"
  -e DSH_ARTIFACT_ARCH="$ARTIFACT_ARCH"
  -e DSH_ARTIFACT_APPIMAGE="$APPIMAGE_NAME"
  -e DSH_ARTIFACT_DEB="$DEB_NAME"
  -e DSH_ARTIFACT_TARBALL="$TARBALL_NAME"
  -e DSH_COMMIT="$COMMIT"
  -e DSH_COMMIT_DIRTY="$DIRTY"
  -e DSH_BUILT_AT="$BUILT_AT"
  # 容器内以 root 复制到 bind mount 的 dist/ 需归还宿主用户，
  # 否则宿主侧 build.sh 的 manifest 步骤无法覆盖 SHA256SUMS/RELEASE.json。
  -e HOST_UID="$(id -u)"
  -e HOST_GID="$(id -g)"
)

note "arch=$ARCH platform=$DOCKER_PLATFORM image=$DOCKER_IMAGE targets=$TARGETS"
note "runtime=$RUNTIME_DIR (du -sh: $(du -sh "$RUNTIME_DIR" 2>/dev/null | awk '{print $1}'))"
note "project=$PROJECT_DIR"
note "output=$OUT_DIR"
note "log=$LOG"

if [ "$DRY_RUN" = "1" ]; then
  printf 'build-linux.sh: docker'
  printf ' %q' "${DOCKER_RUN[@]}"
  printf ' %q' "$DOCKER_IMAGE" "bash" "/work/scripts/package/in-container.sh"
  printf '\n'
  exit 0
fi

set +e
docker "${DOCKER_RUN[@]}" "$DOCKER_IMAGE" bash /work/scripts/package/in-container.sh 2>&1 | tee "$LOG"
STATUS="${PIPESTATUS[0]}"
set -e
END_EPOCH="$(date +%s)"
DURATION="$((END_EPOCH - START_EPOCH))"
[ "$STATUS" -eq 0 ] || die "容器内打包失败（exit=${STATUS}），详见 $LOG"

# ---- 产物校验（宿主侧） -----------------------------------------------------
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}';
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}
size_of() { if stat -f%z "$1" >/dev/null 2>&1; then stat -f%z "$1"; else stat -c%s "$1"; fi; }

ARTIFACTS=""
N=0
add_artifact() {
  f="$OUT_DIR/$1"
  [ -f "$f" ] || return 0
  N=$((N + 1))
  ARTIFACTS="${ARTIFACTS}${1} $(( $(size_of "$f") / 1048576 ))MB $(sha256_of "$f")
"
}
# 自动更新通道文件（electron-updater 按架构选择 latest-linux.yml / latest-linux-arm64.yml）
case "$ARCH" in
  arm64) CHANNEL_YML="latest-linux-arm64.yml" ;;
  *)     CHANNEL_YML="latest-linux.yml" ;;
esac
add_artifact "$CHANNEL_YML"

add_artifact "$APPIMAGE_NAME"
add_artifact "$DEB_NAME"
add_artifact "$TARBALL_NAME"
if [ -f "$OUT_DIR/$APPIMAGE_NAME" ] && [ ! -f "$OUT_DIR/$CHANNEL_YML" ]; then
  die "构建产出 AppImage 但缺少自动更新通道文件 $CHANNEL_YML（检查 packaging/electron-builder.yml 的 publish 配置）"
fi
[ "$N" -ge 1 ] || die "构建结束但未找到任何产物（检查 $OUT_DIR 与 ${LOG}）"

{
  echo "# DeepSeek Harness (Linux) — packaging report"
  echo "arch: $ARCH"
  echo "platform: $DOCKER_PLATFORM"
  echo "docker-image: $DOCKER_IMAGE"
  echo "app-version: $APP_VERSION"
  echo "dsh-version: $DSH_VERSION"
  echo "node-version: $NODE_VERSION"
  echo "electron-version: $ELECTRON_VERSION"
  echo "electron-builder-version: $BUILDER_VERSION"
  echo "commit: $COMMIT (dirty=$DIRTY)"
  echo "built-at: $BUILT_AT"
  echo "duration-seconds: $DURATION"
  echo "runtime-dir: $RUNTIME_DIR"
  echo "runtime-size: $(du -sh "$RUNTIME_DIR" 2>/dev/null | awk '{print $1}')"
  echo "project-dir: $PROJECT_DIR"
  echo "output-dir: $OUT_DIR"
  echo "log: $LOG"
  echo ""
  echo "## artifacts"
  printf '%s' "$ARTIFACTS"
  echo ""
  echo "## container log (tail -n 80)"
  tail -n 80 "$LOG" 2>/dev/null || true
} > "$REPORT"

note "report: $REPORT"
printf '%s' "$ARTIFACTS" | while read -r name size hash; do
  [ -n "$name" ] && note "  $name  $size  sha256=$hash"
done
note "duration: ${DURATION}s"
echo "PKG_OK arch=$ARCH artifacts=$N"
