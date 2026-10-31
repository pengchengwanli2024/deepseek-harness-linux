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
APP_VERSION="${APP_VERSION:-0.2.1}"
DSH_VERSION="${DSH_VERSION:-0.2.1-rc.5}"
NODE_VERSION="${NODE_VERSION:-24.22.2}"

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

command -v docker >/dev/null || { echo "docker is required" >&2; exit 1; }
mkdir -p build/cache dist

echo "==> DSH Linux build"
echo "    version=$APP_VERSION  dsh=$DSH_VERSION  arches=[$ARCH_LIST]  targets=$TARGETS"
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
if git diff --quiet 2>/dev/null; then DIRTY=false; else DIRTY=true; fi
node scripts/package/release-metadata.mjs --dist dist --arch x64 --version "$APP_VERSION" \
  --dsh-version "$DSH_VERSION" --node-version "$NODE_VERSION" --electron-version 45.2.1 \
  --builder-version 26.18.0 --commit "$COMMIT" --dirty "$DIRTY"
echo
echo "==> Done. Artifacts in $ROOT/dist"
ls -lh dist | sed 's/^/    /'
