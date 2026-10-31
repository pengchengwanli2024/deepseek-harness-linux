#!/usr/bin/env bash
# DeepSeek Harness (Linux) — top-level build orchestrator.
# Usage: scripts/build.sh [--arch x64|arm64|all] [--skip-runtime] [--skip-app] [--targets AppImage,deb,tar.gz]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

ARCHES="all"
SKIP_RUNTIME=0
SKIP_APP=0
TARGETS="AppImage,deb,tar.gz"
APP_VERSION="${APP_VERSION:-0.2.1}"
DSH_VERSION="${DSH_VERSION:-0.2.1-rc.5}"

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
    bash scripts/runtime/build-runtime.sh --arch "$arch" --dsh-version "$DSH_VERSION"
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
  bash scripts/package/build-linux.sh "$arch" --targets "$TARGETS"
  echo
done

echo "==> [manifest] writing dist/SHA256SUMS and dist/RELEASE.json"
( cd dist && shasum -a 256 * 2>/dev/null | grep -vE 'SHA256SUMS|RELEASE.json' > SHA256SUMS || true )
node -e '
const fs = require("fs");
const path = require("path");
const dist = path.resolve("dist");
const version = process.env.APP_VERSION || "0.2.1";
const dsh = process.env.DSH_VERSION || "0.2.1-rc.5";
const files = fs.readdirSync(dist).filter((f) => !/^(SHA256SUMS|RELEASE.json)$/.test(f));
const sizes = Object.fromEntries(files.map((f) => [f, fs.statSync(path.join(dist, f)).size]));
fs.writeFileSync(path.join(dist, "RELEASE.json"), JSON.stringify({
  product: "DeepSeek Harness (Linux)",
  unofficial: true,
  version,
  dshVersion: dsh,
  nodeVersion: process.env.NODE_VERSION || "24.22.2",
  electronVersion: "45.2.1",
  builtAt: new Date().toISOString(),
  files: sizes,
}, null, 2) + "\n");
console.log("RELEASE.json files:", files.length);
'
echo
echo "==> Done. Artifacts in $ROOT/dist"
ls -lh dist | sed 's/^/    /'
