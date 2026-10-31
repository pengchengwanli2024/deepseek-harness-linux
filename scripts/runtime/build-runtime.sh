#!/usr/bin/env bash
# build-runtime.sh — build the offline Linux runtime for DeepSeek Harness (unofficial).
#
# Assembles runtime/linux-<arch>/ per docs/ARCHITECTURE.md §4 by running the
# assembly inside a Docker container based on node:24-bookworm:
#   x64   -> --platform linux/amd64  (works on Apple Silicon via Rosetta)
#   arm64 -> --platform linux/arm64
#
# Usage:
#   scripts/runtime/build-runtime.sh --arch arm64
#   scripts/runtime/build-runtime.sh --arch x64 --out runtime/linux-x64
#
# Options:
#   --arch x64|arm64           target architecture (required)
#   --dsh-version VERSION      npm version of @deepseek-ai/dsh (default 0.2.1-rc.5)
#   --node-version VERSION     Node.js runtime version (default 24.22.2)
#   --out DIR                  output directory, relative to the repo root
#                              (default: runtime/linux-<arch>)
#   --office-skills-version V  version of PyPI deepseek-harness-runtime-bin
#                              (default 0.2.1rc2)
#   --skip-office-skills       do not add office-skills/
#   --lean                     extra size cut: drop libreoffice-kit-wasm assets
#                              (office export/render will not work)
#   --skip-selftest            skip the in-container self tests
#   --no-cache                 re-download inputs and rebuild the builder image
#   --keep-container           keep the builder container (debugging)
#   -h | --help
#
# Artifacts:
#   <out>/bin/dsh, node/, node_modules/, office-skills/, licenses/, version.json
#   build/runtime/report-<arch>.txt        full build + self-test evidence
#   build/runtime/<arch>-*.log             raw logs
#
# Exit code 0 only if the assembly and both self-test phases pass.
set -euo pipefail

SELF_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SELF_DIR/../.." && pwd)
CACHE_DIR="$REPO_ROOT/build/cache"
REPORT_DIR="$REPO_ROOT/build/runtime"

DSH_VERSION="0.2.1-rc.5"
NODE_VERSION="24.22.2"
OFFICE_VERSION="0.2.1rc2"
ARCH=""
OUT_ARG=""
LEAN=0
SKIP_OFFICE=0
SKIP_SELFTEST=0
NO_CACHE=0
KEEP_CONTAINER=0

log()  { printf '\033[1;34m[build-runtime]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[build-runtime][warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[build-runtime][error]\033[0m %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,40p' "$0"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --arch) ARCH="${2:-}"; shift 2 ;;
    --arch=*) ARCH="${1#*=}"; shift ;;
    --dsh-version) DSH_VERSION="${2:-}"; shift 2 ;;
    --dsh-version=*) DSH_VERSION="${1#*=}"; shift ;;
    --node-version) NODE_VERSION="${2:-}"; shift 2 ;;
    --node-version=*) NODE_VERSION="${1#*=}"; shift ;;
    --out) OUT_ARG="${2:-}"; shift 2 ;;
    --out=*) OUT_ARG="${1#*=}"; shift ;;
    --office-skills-version) OFFICE_VERSION="${2:-}"; shift 2 ;;
    --office-skills-version=*) OFFICE_VERSION="${1#*=}"; shift ;;
    --lean) LEAN=1; shift ;;
    --skip-office-skills) SKIP_OFFICE=1; shift ;;
    --skip-selftest) SKIP_SELFTEST=1; shift ;;
    --no-cache) NO_CACHE=1; shift ;;
    --keep-container) KEEP_CONTAINER=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done

[ -n "$ARCH" ] || { usage >&2; die "--arch is required"; }

case "$ARCH" in
  x64)   DOCKER_PLATFORM="linux/amd64"; NODE_ARCH="x64";   WHEEL_ARCH="x86_64"  ;;
  arm64) DOCKER_PLATFORM="linux/arm64"; NODE_ARCH="arm64"; WHEEL_ARCH="aarch64" ;;
  *) die "unsupported --arch '$ARCH' (use x64 or arm64)" ;;
esac

OUT_DIR="${OUT_ARG:-runtime/linux-$ARCH}"
case "$OUT_DIR" in
  /*) : ;;
  *) OUT_DIR="$REPO_ROOT/$OUT_DIR" ;;
esac
OUT_DIR="${OUT_DIR%/}"
[ -n "$OUT_DIR" ] || die "invalid --out"
[ "$OUT_DIR" != "/" ] || die "refusing to use / as output directory"

IMAGE="dsh-rt-builder:node24-bookworm-$ARCH"
CTR="dsh-rt-build-$ARCH"
NPM_VOL="dsh-rt-npm-cache-$ARCH"
NODE_TARBALL_NAME="node-v${NODE_VERSION}-linux-${NODE_ARCH}.tar.xz"
NODE_TARBALL="$CACHE_DIR/node/$NODE_TARBALL_NAME"
SHASUMS="$CACHE_DIR/node/SHASUMS256.txt"
INNER_LOG="$REPORT_DIR/$ARCH-inner.log"
ST_ASSEMBLED_LOG="$REPORT_DIR/$ARCH-selftest-assembled.log"
ST_EXPORTED_LOG="$REPORT_DIR/$ARCH-selftest-exported.log"
REPORT="$REPORT_DIR/report-$ARCH.txt"

mkdir -p "$CACHE_DIR/node" "$CACHE_DIR/pypi" "$REPORT_DIR"

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

cleanup() {
  if [ "$KEEP_CONTAINER" != 1 ] && [ -n "${CTR:-}" ]; then
    docker rm -f "$CTR" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT
trap 'warn "interrupted"; exit 130' INT TERM
command -v docker >/dev/null 2>&1 || die "docker CLI not found"
docker info >/dev/null 2>&1 || die "docker daemon is not reachable"
log "target: $ARCH ($DOCKER_PLATFORM) -> $OUT_DIR"

# ------------------------------------------------------------------ inputs ---
ensure_node_tarball() {
  if [ "$NO_CACHE" = 1 ]; then rm -f "$NODE_TARBALL" "$SHASUMS"; fi
  if [ ! -f "$SHASUMS" ]; then
    log "fetching node SHASUMS256.txt"
    curl -fsSL --retry 3 --max-time 180 -o "$SHASUMS" \
      "https://nodejs.org/dist/v$NODE_VERSION/SHASUMS256.txt" \
      || die "cannot download SHASUMS256.txt for node $NODE_VERSION"
  fi
  EXPECTED=$(awk -v f="$NODE_TARBALL_NAME" '$2==f {print $1}' "$SHASUMS" | head -1)
  [ -n "$EXPECTED" ] || die "no checksum for $NODE_TARBALL_NAME"
  if [ -f "$NODE_TARBALL" ] && [ "$(sha256_of "$NODE_TARBALL")" = "$EXPECTED" ]; then
    log "node tarball cached: $NODE_TARBALL_NAME"
    return 0
  fi
  rm -f "$NODE_TARBALL"
  log "downloading $NODE_TARBALL_NAME"
  curl -fL --retry 3 --max-time 900 -o "$NODE_TARBALL.part" \
    "https://nodejs.org/dist/v$NODE_VERSION/$NODE_TARBALL_NAME" || die "node download failed"
  mv "$NODE_TARBALL.part" "$NODE_TARBALL"
  GOT=$(sha256_of "$NODE_TARBALL")
  [ "$GOT" = "$EXPECTED" ] || die "node tarball checksum mismatch (expected $EXPECTED, got $GOT)"
  log "node tarball sha256 verified"
}

ensure_wheel() {
  [ "$SKIP_OFFICE" = 1 ] && { log "office-skills disabled"; return 0; }
  command -v python3 >/dev/null 2>&1 || {
    warn "python3 not found; cannot resolve PyPI wheel - skipping office-skills"
    SKIP_OFFICE=1
    return 0
  }
  INFO=$(python3 - "$WHEEL_ARCH" "$OFFICE_VERSION" <<'PY'
import json, sys, urllib.request
arch, want = sys.argv[1], sys.argv[2]
with urllib.request.urlopen(
        "https://pypi.org/pypi/deepseek-harness-runtime-bin/json", timeout=120) as r:
    data = json.load(r)
cands = []
for u in data.get("urls", []):
    fn = u.get("filename", "")
    if not fn.startswith("deepseek_harness_runtime_bin-" + want + "-"):
        continue
    if not fn.endswith(".whl"):
        continue
    if "manylinux" not in fn or not fn.endswith("_" + arch + ".whl"):
        continue
    cands.append(u)
if not cands:
    sys.exit("no manylinux wheel for " + arch + " " + want)
cands.sort(key=lambda u: u["filename"])
u = cands[-1]
print(u["digests"]["sha256"], u["url"], u["filename"])
PY
  ) || { warn "PyPI wheel lookup failed - skipping office-skills"; SKIP_OFFICE=1; return 0; }
  WHEEL_SHA=$(printf '%s' "$INFO" | cut -d' ' -f1)
  WHEEL_URL=$(printf '%s' "$INFO" | cut -d' ' -f2)
  WHEEL_NAME=$(printf '%s' "$INFO" | cut -d' ' -f3)
  WHEEL_FILE="$CACHE_DIR/pypi/$WHEEL_NAME"
  if [ "$NO_CACHE" = 1 ]; then rm -f "$WHEEL_FILE"; fi
  if [ -f "$WHEEL_FILE" ] && [ "$(sha256_of "$WHEEL_FILE")" = "$WHEEL_SHA" ]; then
    log "office-skills wheel cached: $WHEEL_NAME"
    return 0
  fi
  rm -f "$WHEEL_FILE"
  log "downloading $WHEEL_NAME"
  curl -fL --retry 3 --max-time 1800 -o "$WHEEL_FILE.part" "$WHEEL_URL" || die "wheel download failed"
  mv "$WHEEL_FILE.part" "$WHEEL_FILE"
  GOT=$(sha256_of "$WHEEL_FILE")
  [ "$GOT" = "$WHEEL_SHA" ] || die "wheel checksum mismatch"
  log "office-skills wheel sha256 verified: $WHEEL_NAME"
}

ensure_image() {
  if [ "$NO_CACHE" = 1 ]; then docker rmi -f "$IMAGE" >/dev/null 2>&1 || true; fi
  if docker image inspect "$IMAGE" >/dev/null 2>&1; then
    log "builder image cached: $IMAGE"
    return 0
  fi
  log "building builder image $IMAGE ($DOCKER_PLATFORM)"
  if docker build --platform "$DOCKER_PLATFORM" -f "$SELF_DIR/Dockerfile.builder" \
       -t "$IMAGE" "$SELF_DIR" >/dev/null 2>&1; then
    log "builder image built (docker build)"
  else
    warn "docker build failed, retrying with buildx"
    docker buildx build --platform "$DOCKER_PLATFORM" --load \
      -f "$SELF_DIR/Dockerfile.builder" -t "$IMAGE" "$SELF_DIR" \
      || die "could not build builder image $IMAGE"
  fi
}

ensure_node_tarball
ensure_wheel
ensure_image

# ------------------------------------------------------------- build phase ---
docker rm -f "$CTR" >/dev/null 2>&1 || true
if [ "$NO_CACHE" = 1 ]; then docker volume rm "$NPM_VOL" >/dev/null 2>&1 || true; fi
docker volume create "$NPM_VOL" >/dev/null
log "starting builder container $CTR"
docker run -d --name "$CTR" --platform "$DOCKER_PLATFORM" \
  -e ARCH="$ARCH" -e NODE_ARCH="$NODE_ARCH" -e NODE_VERSION="$NODE_VERSION" \
  -e DSH_VERSION="$DSH_VERSION" -e LEAN="$LEAN" -e SKIP_OFFICE="$SKIP_OFFICE" \
  -v "$CACHE_DIR:/cache:ro" \
  -v "$SELF_DIR:/scripts:ro" \
  -v "$NPM_VOL:/root/.npm" \
  "$IMAGE" sleep infinity >/dev/null || die "could not start builder container"

set +e
docker exec "$CTR" bash /scripts/runtime-inner.sh 2>&1 | tee "$INNER_LOG"
INNER_RC=${PIPESTATUS[0]}
set -e
if [ "$INNER_RC" -ne 0 ]; then
  warn "in-container assembly failed (rc=$INNER_RC); log: $INNER_LOG"
  exit 1
fi
log "assembly complete"
# ------------------------------------------------------ self-test phase A ----
ST_ASSEMBLED_RC=0
if [ "$SKIP_SELFTEST" = 0 ]; then
  log "self-test A: assembled tree (in-container)"
  set +e
  docker exec "$CTR" bash /scripts/selftest.sh /out/runtime assembled > "$ST_ASSEMBLED_LOG" 2>&1
  ST_ASSEMBLED_RC=$?
  set -e
  docker cp "$CTR:/out/stats.txt" "$REPORT_DIR/$ARCH-stats.txt" >/dev/null 2>&1 || true
  docker cp "$CTR:/out/prune-stats.txt" "$REPORT_DIR/$ARCH-prune-stats.txt" >/dev/null 2>&1 || true
  cat "$ST_ASSEMBLED_LOG"
  if [ "$ST_ASSEMBLED_RC" -eq 0 ]; then
    log "self-test A: PASS"
  else
    warn "self-test A: FAIL (rc=$ST_ASSEMBLED_RC)"
  fi
fi

# ---------------------------------------------------------------- export ----
log "exporting runtime -> $OUT_DIR"
mkdir -p "$OUT_DIR"
find "$OUT_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
docker exec "$CTR" tar -C /out/runtime -cf - . | tar -C "$OUT_DIR" -xf - \
  || die "export failed"
[ -x "$OUT_DIR/bin/dsh" ] || die "exported runtime has no executable bin/dsh"
[ -f "$OUT_DIR/version.json" ] || die "exported runtime has no version.json"
log "export complete"

# ------------------------------------------------------ self-test phase B ----
ST_EXPORTED_RC=0
if [ "$SKIP_SELFTEST" = 0 ]; then
  VCTR="dsh-rt-verify-$ARCH"
  docker rm -f "$VCTR" >/dev/null 2>&1 || true
  log "self-test B: exported artifact mounted read-only, network disabled"
  if docker run -d --name "$VCTR" --platform "$DOCKER_PLATFORM" --network none \
       -e ARCH="$ARCH" -v "$OUT_DIR:/rt:ro" -v "$SELF_DIR:/scripts:ro" \
       "$IMAGE" sleep infinity >/dev/null 2>&1; then
    set +e
    docker exec "$VCTR" bash /scripts/selftest.sh /rt exported > "$ST_EXPORTED_LOG" 2>&1
    ST_EXPORTED_RC=$?
    set -e
    cat "$ST_EXPORTED_LOG"
    docker rm -f "$VCTR" >/dev/null 2>&1 || true
    if [ "$ST_EXPORTED_RC" -eq 0 ]; then
      log "self-test B: PASS"
    else
      warn "self-test B: FAIL (rc=$ST_EXPORTED_RC)"
    fi
  else
    warn "could not start verify container (host bind mount?) - phase B skipped"
    ST_EXPORTED_RC=1
  fi
fi

# ----------------------------------------------------------------- report ---
OVERALL="PASS"
if [ "$SKIP_SELFTEST" = 0 ]; then
  if [ "$ST_ASSEMBLED_RC" -ne 0 ] || [ "$ST_EXPORTED_RC" -ne 0 ]; then OVERALL="FAIL"; fi
else
  OVERALL="BUILT (self-test skipped)"
fi

{
  echo "DSH Linux runtime build report"
  echo "=============================="
  echo "generated:      $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "arch:           $ARCH ($DOCKER_PLATFORM)"
  echo "dsh version:    $DSH_VERSION"
  echo "node version:   $NODE_VERSION ($NODE_ARCH)"
  echo "office-skills:  $( [ "$SKIP_OFFICE" = 1 ] && echo skipped || echo "deepseek-harness-runtime-bin $OFFICE_VERSION" )"
  echo "lean prune:     $LEAN"
  echo "output:         $OUT_DIR"
  echo "builder image:  $IMAGE"
  echo "builder host:   $(uname -s) $(uname -m), docker ${DOCKER_PLATFORM}"
  echo "overall:        $OVERALL"
  echo
  echo "=== phase 1: in-container assembly (tail) ==="
  tail -n 250 "$INNER_LOG" 2>/dev/null || echo "(no log)"
  echo
  echo "=== phase 2: self-test - assembled tree ==="
  cat "$ST_ASSEMBLED_LOG" 2>/dev/null || echo "(skipped)"
  echo
  echo "=== phase 3: self-test - exported artifact (read-only mount, network:none) ==="
  cat "$ST_EXPORTED_LOG" 2>/dev/null || echo "(skipped)"
  echo
  echo "=== phase 4: host-side delivered runtime ==="
  echo "path: $OUT_DIR"
  echo "size: $(du -sh "$OUT_DIR" 2>/dev/null | cut -f1) (allocated)"
  echo "tree:"
  ls -la "$OUT_DIR" 2>/dev/null
  echo
  echo "version.json:"
  cat "$OUT_DIR/version.json" 2>/dev/null
  echo
  echo "sha256 of key files:"
  for f in bin/dsh version.json; do
    [ -f "$OUT_DIR/$f" ] && printf '%s  %s\n' "$(sha256_of "$OUT_DIR/$f")" "$f"
  done
} > "$REPORT"

log "report: $REPORT"
log "runtime: $OUT_DIR ($(du -sh "$OUT_DIR" 2>/dev/null | cut -f1))"
if [ "$OVERALL" = "PASS" ] || [ "$SKIP_SELFTEST" = 1 ]; then
  log "RESULT: $OVERALL"
  exit 0
fi
warn "RESULT: $OVERALL - inspect $REPORT"
exit 1
