#!/usr/bin/env bash
# DeepSeek Harness (Linux) — 在干净 ubuntu:24.04 容器中验证 deb / AppImage 交付物
#
# 用法:
#   scripts/package/verify-linux-packages.sh <x64|arm64> [--targets appimage,deb]
#       [--dist <目录>] [--image ubuntu:24.04] [--app-version 0.2.1]
#
# 需要 Docker；容器内用 xvfb 运行 Electron 的 --smoke-test / --screenshot（无需真实显示器）。
# 证据（日志、截图）写入 build/package/evidence/，宿主总日志写入 build/package/verify-<arch>-<ts>.log。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ARCH=""
TARGETS="appimage,deb"
DIST="$ROOT_DIR/dist"
IMAGE="ubuntu:24.04"
APP_VERSION="0.2.1"
EVIDENCE_DIR="$ROOT_DIR/build/package/evidence"

die() { printf 'verify-linux-packages.sh: ERROR: %s\n' "$*" >&2; exit 1; }
note() { printf 'verify-linux-packages.sh: %s\n' "$*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    x64|arm64) ARCH="$1"; shift ;;
    --targets) TARGETS="$2"; shift 2 ;;
    --targets=*) TARGETS="${1#*=}"; shift ;;
    --dist) DIST="$2"; shift 2 ;;
    --dist=*) DIST="${1#*=}"; shift ;;
    --image) IMAGE="$2"; shift 2 ;;
    --image=*) IMAGE="${1#*=}"; shift ;;
    --app-version) APP_VERSION="$2"; shift 2 ;;
    --app-version=*) APP_VERSION="${1#*=}"; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ -n "$ARCH" ] || die "missing <x64|arm64>"
case "$ARCH" in
  x64) DOCKER_PLATFORM="linux/amd64"; ARTIFACT_ARCH="x86_64"; DEB_ARCH="amd64" ;;
  arm64) DOCKER_PLATFORM="linux/arm64"; ARTIFACT_ARCH="arm64"; DEB_ARCH="arm64" ;;
  *) die "unsupported arch: $ARCH" ;;
esac
DIST="$(cd "$DIST" 2>/dev/null && pwd)" || die "dist dir not found: $DIST"
case "$DIST" in
  "$ROOT_DIR"/*) DIST_IN="/work/${DIST#$ROOT_DIR/}" ;;
  *) DIST_IN="/dist" ;;
esac
mkdir -p "$EVIDENCE_DIR"

DEB_NAME="DeepSeek-Harness-Linux-${APP_VERSION}-${DEB_ARCH}.deb"
APPIMAGE_NAME="DeepSeek-Harness-Linux-${APP_VERSION}-${ARTIFACT_ARCH}.AppImage"

IMAGE_TAG="$(printf '%s' "$IMAGE" | tr '/:.' '---')"
TS="$(date +%Y%m%d-%H%M%S)"
LOG="$ROOT_DIR/build/package/verify-${ARCH}-${IMAGE_TAG}-${TS}.log"
CONTAINER_NAME="dsh-qa-pkg-${ARCH}-$(date +%s)-$$"
cleanup() { docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT INT TERM

note "arch=$ARCH platform=$DOCKER_PLATFORM image=$IMAGE targets=$TARGETS"
note "dist=$DIST"
note "log=$LOG"
note "evidence=$EVIDENCE_DIR"

set +e
docker run --rm --name "$CONTAINER_NAME" --platform "$DOCKER_PLATFORM" \
  -v "$ROOT_DIR:/work" \
  -v "$DIST:/dist:ro" \
  -e DSH_VERIFY_ARCH="$ARCH" \
  -e DSH_VERIFY_TAG="${ARCH}-${IMAGE_TAG}" \
  -e DSH_VERIFY_TARGETS="$TARGETS" \
  -e DSH_VERIFY_DEB="$DEB_NAME" \
  -e DSH_VERIFY_APPIMAGE="$APPIMAGE_NAME" \
  -e DSH_VERIFY_DIST="$DIST_IN" \
  -e DSH_VERIFY_EVIDENCE="/work/build/package/evidence" \
  "$IMAGE" bash /work/scripts/package/verify-in-container.sh 2>&1 | tee "$LOG"
STATUS="${PIPESTATUS[0]}"
set -e
[ "$STATUS" -eq 0 ] || die "验证失败（exit=${STATUS}），详见 $LOG"
echo "VERIFY_OK arch=$ARCH targets=$TARGETS"
