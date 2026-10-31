#!/usr/bin/env bash
# ============================================================================
# DeepSeek Harness (Linux) — QA verification driver (Docker-based, reproducible)
# ============================================================================
# Independent acceptance verification for the unofficial Linux desktop build.
# Everything runs in fresh Docker containers; the host only orchestrates.
#
# Usage:
#   scripts/test/verify-linux.sh [options]
#
# Options:
#   --arch x64|arm64|all         Architecture(s) to verify (default: all)
#   --mode LIST                  Comma list of: runtime,shell,appimage,deb,checksums
#                                (default: all of them)
#   --dist DIR                   Deliverables directory (default: <repo>/dist)
#   --runtime DIR                Runtime dir override (default: runtime/linux-<arch>)
#   --appimage FILE              Verify this AppImage only (arch inferred from name)
#   --deb FILE                   Verify this .deb only (arch inferred from name)
#   --screenshot-delay MS        Wait before capture inside the app (default: 2000;
#                                raise it to ~6000 to hide transient toasts)
#   --appimage-structural         AppImage: structural checks only (no runtime exec);
#                                use when the host cannot execute the target runtime
#   env DSH_QA_UBUNTU_MIRROR=URL   optional apt mirror for the clean-container deb test
#   --deb-image IMAGE             image for the deb install test (default ubuntu:24.04);
#                                use a dependency-preinstalled image when the QA network
#                                cannot reach the distro archive
#                                (rewrites ports.ubuntu.com/archive.ubuntu.com)
#                                use when the host cannot execute the target runtime
#   --publish-screenshot         Copy the best real screenshot to
#                                build/qa/screenshot.png and docs/assets/screenshot.png
#   --strict                     Missing artifacts/runtime are FAIL (default: SKIP)
#   --keep                       Keep containers after the run (debug)
#   --no-image-build             Do not build the QA GUI images (must already exist)
#   --timeout SEC                Per-test timeout inside containers (default: 180)
#   -h | --help                  Show this help
#
# Phases:
#   runtime    AC1: bin/dsh --version, token URL, 303 + Set-Cookie, curl -L 200,
#              no import errors, no leftover dsh process.
#   shell      AC2/AC4 pre-package: app source + runtime in xvfb container,
#              --smoke-test, --screenshot, process cleanup, single instance focus.
#   appimage   AC2/AC4: --appimage-extract, layout assertions, smoke, screenshot,
#              cleanup, single instance focus, desktop entry.
#   deb        AC3: clean ubuntu:24.04, dpkg -i + apt-get -f install, file/perm
#              assertions, smoke + screenshot.
#   checksums  AC6: SHA256SUMS recomputation, RELEASE.json fields vs real files,
#              contract artifact names.
#
# Exit code: 0 = all executed tests PASS; 1 = at least one FAIL.
# Evidence:  build/qa/verify-<UTC timestamp>/ (per-phase logs + screenshots + summary)
#
# Notes:
#   * Containers are named dsh-qa-<phase>-<arch>-<ts> and removed on exit.
#   * Inside containers Electron runs as root, so --no-sandbox is passed/auto-added.
#   * dsh web's first request to the token URL answers 303 + Set-Cookie; curl needs
#     a cookie jar (-c/-b). The desktop shell handles this automatically.
# ============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 1

ARCH_ARG="all"
MODE_ARG="all"
DIST_DIR="$ROOT/dist"
RUNTIME_OVERRIDE=""
APPIMAGE_OVERRIDE=""
DEB_OVERRIDE=""
PUBLISH_SCREENSHOT=0
STRICT=0
KEEP=0
NO_IMAGE_BUILD=0
TEST_TIMEOUT=180
SHOT_DELAY=2000
APPIMAGE_STRUCTURAL=0
DEB_IMAGE="ubuntu:24.04"

usage() { sed -n '4,50p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0; }

while [ $# -gt 0 ]; do
  case "$1" in
    --arch) ARCH_ARG="${2:?}"; shift 2 ;;
    --arch=*) ARCH_ARG="${1#*=}"; shift ;;
    --mode) MODE_ARG="${2:?}"; shift 2 ;;
    --mode=*) MODE_ARG="${1#*=}"; shift ;;
    --dist) DIST_DIR="${2:?}"; shift 2 ;;
    --dist=*) DIST_DIR="${1#*=}"; shift ;;
    --runtime) RUNTIME_OVERRIDE="${2:?}"; shift 2 ;;
    --runtime=*) RUNTIME_OVERRIDE="${1#*=}"; shift ;;
    --appimage) APPIMAGE_OVERRIDE="${2:?}"; shift 2 ;;
    --appimage=*) APPIMAGE_OVERRIDE="${1#*=}"; shift ;;
    --deb) DEB_OVERRIDE="${2:?}"; shift 2 ;;
    --deb=*) DEB_OVERRIDE="${1#*=}"; shift ;;
    --publish-screenshot) PUBLISH_SCREENSHOT=1; shift ;;
    --strict) STRICT=1; shift ;;
    --keep) KEEP=1; shift ;;
    --no-image-build) NO_IMAGE_BUILD=1; shift ;;
    --timeout) TEST_TIMEOUT="${2:?}"; shift 2 ;;
    --timeout=*) TEST_TIMEOUT="${1#*=}"; shift ;;
    --screenshot-delay) SHOT_DELAY="${2:?}"; shift 2 ;;
    --screenshot-delay=*) SHOT_DELAY="${1#*=}"; shift ;;
    --appimage-structural) APPIMAGE_STRUCTURAL=1; shift ;;
    --deb-image) DEB_IMAGE="${2:?}"; shift 2 ;;
    --deb-image=*) DEB_IMAGE="${1#*=}"; shift ;;
    -h|--help) usage ;;
    *) echo "verify-linux.sh: unknown argument: $1 (see --help)" >&2; exit 2 ;;
  esac
done

case "$DIST_DIR" in
  /*) ;;
  *) DIST_DIR="$ROOT/$DIST_DIR" ;;
esac
if [ -d "$DIST_DIR" ]; then DIST_DIR="$(cd "$DIST_DIR" && pwd)"; fi

case "$ARCH_ARG" in
  x64|arm64) ARCH_LIST="$ARCH_ARG" ;;
  all) ARCH_LIST="x64 arm64" ;;
  *) echo "verify-linux.sh: invalid --arch: $ARCH_ARG (x64|arm64|all)" >&2; exit 2 ;;
esac

case "$MODE_ARG" in
  all) MODES="runtime shell appimage deb checksums" ;;
  *) MODES="$(printf '%s' "$MODE_ARG" | tr ',' ' ')" ;;
esac
for m in $MODES; do
  case "$m" in runtime|shell|appimage|deb|checksums) ;; *)
    echo "verify-linux.sh: invalid --mode entry: $m" >&2; exit 2 ;;
  esac
done

HOST_ARCH="x64"
case "$(uname -m)" in
  arm64|aarch64) HOST_ARCH="arm64" ;;
  x86_64|amd64) HOST_ARCH="x64" ;;
esac

TS="$(date -u +%Y%m%d-%H%M%S)"
EVID="$ROOT/build/qa/verify-$TS"
mkdir -p "$EVID/screenshots"
SUMMARY="$EVID/summary.txt"
: > "$SUMMARY"

PASS=0
FAIL=0
SKIP=0
FAILURES=""
CONTAINERS=""
LOG="$SUMMARY"
CURRENT_PHASE="startup"
PUBLISH_SRC=""
RT_IN=""
RT_EXTRA=()

say() { printf '%s\n' "$*"; printf '%s\n' "$*" >> "$LOG"; }
pass() { PASS=$((PASS + 1)); say "PASS  $*"; }
fail() { FAIL=$((FAIL + 1)); FAILURES="$FAILURES$CURRENT_PHASE: $*"$'\n'; say "FAIL  $*"; }
skip() { SKIP=$((SKIP + 1)); say "SKIP  $*"; }
die() { say "FATAL $*"; exit 1; }

begin_phase() { CURRENT_PHASE="$1"; LOG="$EVID/$1.log"; : > "$LOG"; say "=== phase: $CURRENT_PHASE ==="; }
end_phase() { LOG="$SUMMARY"; }

container_name() {
  printf 'dsh-qa-%s-%s-%s-%s' "$1" "$2" "$$" "$(date +%s)"
}

docker_start() {
  # docker_start <name> <platform> <image> [extra docker run args...]
  local name="$1" platform="$2" image="$3"
  shift 3
  if ! docker run -d --name "$name" --platform "$platform" "$@" "$image" sleep infinity >>"$LOG" 2>&1; then
    return 1
  fi
  CONTAINERS="$CONTAINERS $name"
  return 0
}

ctr() { docker exec "$1" bash -lc "$2"; }

cleanup() {
  if [ "$KEEP" = "1" ]; then
    [ -n "$CONTAINERS" ] && what="keeping containers:$CONTAINERS"
    [ -n "$CONTAINERS" ] && say "$what"
    return
  fi
  local c
  for c in $CONTAINERS; do
    docker rm -f "$c" >/dev/null 2>&1 || true
  done
}
trap cleanup EXIT INT TERM

# ---- preflight -------------------------------------------------------------
command -v docker >/dev/null 2>&1 || { echo "verify-linux.sh: docker is required" >&2; exit 1; }
docker info >/dev/null 2>&1 || { echo "verify-linux.sh: docker daemon is not available" >&2; exit 1; }

say "DeepSeek Harness (Linux) — independent verification"
say "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
say "host: $(uname -srm) | host-arch=$HOST_ARCH"
say "docker: $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo unknown)"
say "repo: $ROOT"
say "arch: $ARCH_LIST | modes: $(printf '%s' "$MODES" | tr ' ' ',')"
say "dist: $DIST_DIR"
say "evidence: $EVID"
say ""

# ---- helpers ---------------------------------------------------------------
arch_platform() {
  case "$1" in arm64) echo "linux/arm64" ;; x64) echo "linux/amd64" ;; esac
}
arch_deb_arch() {
  case "$1" in arm64) echo "arm64" ;; x64) echo "amd64" ;; esac
}

find_artifact() {
  # find_artifact <arch> <appimage|deb>
  local arch="$1" kind="$2" pat f
  if [ -n "$APPIMAGE_OVERRIDE" ] && [ "$kind" = "appimage" ]; then
    [ -f "$APPIMAGE_OVERRIDE" ] && printf '%s\n' "$APPIMAGE_OVERRIDE" && return 0
    return 1
  fi
  if [ -n "$DEB_OVERRIDE" ] && [ "$kind" = "deb" ]; then
    [ -f "$DEB_OVERRIDE" ] && printf '%s\n' "$DEB_OVERRIDE" && return 0
    return 1
  fi
  case "$arch:$kind" in
    x64:appimage) pat='*x86_64*.AppImage' ;;
    arm64:appimage) pat='*arm64*.AppImage' ;;
    x64:deb) pat='*amd64*.deb' ;;
    arm64:deb) pat='*arm64*.deb' ;;
    *) return 1 ;;
  esac
  f="$(ls -1 "$DIST_DIR"/$pat 2>/dev/null | head -n 1 || true)"
  [ -n "$f" ] && printf '%s\n' "$f" && return 0
  return 1
}

runtime_dir_for() {
  if [ -n "$RUNTIME_OVERRIDE" ]; then
    printf '%s\n' "$RUNTIME_OVERRIDE"
  else
    printf '%s\n' "$ROOT/runtime/linux-$1"
  fi
}

resolve_runtime_mount() {
  # Sets RT_IN (container path) and RT_EXTRA (extra -v args if outside the repo).
  local rt="$1"
  RT_EXTRA=()
  case "$rt" in
    "$ROOT"/*) RT_IN="/workspace/${rt#$ROOT/}" ;;
    *) RT_IN="/opt/rt"; RT_EXTRA=(-v "$rt:/opt/rt:ro") ;;
  esac
}

# ---- images ----------------------------------------------------------------
dockerfile_node24_gui() {
  cat <<'DOCKERFILE'
FROM node:24-bookworm
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl file xz-utils xvfb xauth imagemagick dbus-x11 \
    libnss3 libatk1.0-0 libatk-bridge2.0-0 libcups2 libdrm2 libxkbcommon0 \
    libxcomposite1 libxdamage1 libxfixes3 libxrandr2 libgbm1 libasound2 \
    libpango-1.0-0 libcairo2 libx11-xcb1 libxcb1 libxss1 libxtst6 libatspi2.0-0 \
    libgtk-3-0 fonts-noto-cjk fonts-liberation \
  && rm -rf /var/lib/apt/lists/*
DOCKERFILE
}

dockerfile_ubuntu_gui() {
  cat <<'DOCKERFILE'
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl file xz-utils xvfb xauth imagemagick dbus-x11 \
    libnss3 libatk1.0-0t64 libatk-bridge2.0-0t64 libcups2t64 libdrm2 libxkbcommon0 \
    libxcomposite1 libxdamage1 libxfixes3 libxrandr2 libgbm1 libasound2t64 \
    libpango-1.0-0 libcairo2 libx11-xcb1 libxcb1 libxss1 libxtst6 libatspi2.0-0t64 \
    libgtk-3-0t64 fonts-noto-cjk fonts-liberation \
  && rm -rf /var/lib/apt/lists/*
DOCKERFILE
}

ensure_image() {
  # ensure_image <kind:node24|ubuntu> <arch>
  local kind="$1" arch="$2" image platform df
  platform="$(arch_platform "$arch")"
  if [ "$kind" = "node24" ]; then
    image="dsh-qa-gui:node24-$arch"
    df="$EVID/Dockerfile.node24-$arch"
    dockerfile_node24_gui > "$df"
  else
    image="dsh-qa-gui:ubuntu2404-$arch"
    df="$EVID/Dockerfile.ubuntu2404-$arch"
    dockerfile_ubuntu_gui > "$df"
  fi
  if docker image inspect "$image" >/dev/null 2>&1; then
    return 0
  fi
  if [ "$NO_IMAGE_BUILD" = "1" ]; then
    say "image $image missing and --no-image-build given"
    return 1
  fi
  say "building image $image (platform $platform) — first run only"
  docker build --platform "$platform" -t "$image" -f "$df" "$EVID" >>"$LOG" 2>&1 || {
    say "image build failed: $image (see $LOG)"
    return 1
  }
  return 0
}

png_check() {
  # png_check <container> <path-in-container> ; prints identify line on success
  docker exec "$1" bash -lc "
    f='$2'
    [ -f \"\$f\" ] || { echo 'PNG_MISSING'; exit 1; }
    sig=\$(od -An -tx1 -N8 \"\$f\" | tr -d ' \n')
    [ \"\$sig\" = '89504e470d0a1a0a' ] || { echo \"PNG_BAD_SIGNATURE \$sig\"; exit 1; }
    s=\$(stat -c%s \"\$f\")
    [ \"\$s\" -gt 10000 ] || { echo \"PNG_TOO_SMALL \$s\"; exit 1; }
    identify \"\$f\" >/dev/null 2>&1 || { echo 'PNG_UNREADABLE'; exit 1; }
    identify \"\$f\" | head -n 1
  " 2>&1
}

# ============================================================================
# Phase: runtime (AC1)
# ============================================================================
phase_runtime() {
  local arch="$1" rt image name platform out rc
  begin_phase "runtime-$arch"
  rt="$(runtime_dir_for "$arch")"
  if [ ! -x "$rt/bin/dsh" ] || [ ! -x "$rt/node/bin/node" ]; then
    if [ "$STRICT" = "1" ]; then fail "runtime-$arch: runtime missing/incomplete: $rt"; else skip "runtime-$arch: runtime missing: $rt"; fi
    end_phase; return
  fi
  ensure_image ubuntu "$arch" || { fail "runtime-$arch: GUI image unavailable"; end_phase; return; }
  platform="$(arch_platform "$arch")"
  image="dsh-qa-gui:ubuntu2404-$arch"
  resolve_runtime_mount "$rt"
  name="$(container_name runtime "$arch")"
  if [ "${#RT_EXTRA[@]}" -gt 0 ]; then
    docker_start "$name" "$platform" "$image" -v "$ROOT:/workspace" "${RT_EXTRA[@]}" >/dev/null || { fail "runtime-$arch: container start failed"; end_phase; return; }
  else
    docker_start "$name" "$platform" "$image" -v "$ROOT:/workspace" >/dev/null || { fail "runtime-$arch: container start failed"; end_phase; return; }
  fi
  out="$(ctr "$name" "
    set -o pipefail
    RT='$RT_IN'
    echo '--- version'
    V=\$(\$RT/bin/dsh --version 2>&1); echo \"version=\$V\"
    if [ \"\$V\" = '0.2.1-rc.5' ]; then echo 'ASSERT version PASS'; else echo 'ASSERT version FAIL'; fi
    echo '--- node'
    \$RT/node/bin/node -v 2>&1
    echo '--- web'
    rm -rf /tmp/dsh-home /tmp/dsh-web.log /tmp/cj /tmp/h1 /tmp/page.html
    DSH_HOME=/tmp/dsh-home nohup \$RT/bin/dsh web --no-open --host 127.0.0.1 --port 0 > /tmp/dsh-web.log 2>&1 &
    WEBPID=\$!
    URL=''
    for i in \$(seq 1 30); do
      URL=\$(grep -oE 'http://127\\.0\\.0\\.1:[0-9]+/\\?token=[A-Za-z0-9_-]+' /tmp/dsh-web.log | head -1)
      [ -n \"\$URL\" ] && break
      sleep 1
    done
    if [ -z \"\$URL\" ]; then echo 'ASSERT token-url FAIL'; tail -30 /tmp/dsh-web.log; exit 1; fi
    echo \"ASSERT token-url PASS \$URL\"
    echo '--- first request without cookie jar (no -L)'
    C1=\$(curl -sS -o /dev/null -D /tmp/h1 -w '%{http_code}' \"\$URL\" || echo curl-error)
    SC=\$(grep -ci '^set-cookie:' /tmp/h1 || true)
    echo \"first_code=\$C1 set_cookie_lines=\$SC\"
    case \"\$C1\" in
      303) echo 'ASSERT first-303 PASS' ;;
      200) echo 'ASSERT first-303 SKIP' ;;
      *) echo 'ASSERT first-303 FAIL' ;;
    esac
    if [ \"\$SC\" -ge 1 ]; then echo 'ASSERT set-cookie PASS'; else echo 'ASSERT set-cookie FAIL'; fi
    echo '--- curl -L with cookie jar'
    C2=\$(curl -sS -L -c /tmp/cj -b /tmp/cj -o /tmp/page.html -w '%{http_code}' \"\$URL\" || echo curl-error)
    SZ=\$(stat -c%s /tmp/page.html 2>/dev/null || echo 0)
    echo \"follow_code=\$C2 bytes=\$SZ\"
    if [ \"\$C2\" = '200' ]; then echo 'ASSERT curl-200 PASS'; else echo 'ASSERT curl-200 FAIL'; fi
    if [ \"\$SZ\" -gt 1000 ]; then echo 'ASSERT page-body PASS'; else echo 'ASSERT page-body FAIL'; fi
    echo '--- import errors'
    if grep -iE 'failed to import|ERR_MODULE_NOT_FOUND|Cannot find module' /tmp/dsh-web.log; then
      echo 'ASSERT no-import-errors FAIL'
    else
      echo 'ASSERT no-import-errors PASS'
    fi
    echo '--- cleanup'
    kill \$WEBPID 2>/dev/null || true
    sleep 2
    PIDS=\$(ps -eo pid,args | grep -F 'lib/bin.js' | grep -v grep | awk '{print \$1}')
    if [ -n \"\$PIDS\" ]; then kill \$PIDS 2>/dev/null || true; fi
    sleep 1
    LEFT=\$(ps -eo pid,args | grep -F 'lib/bin.js' | grep -v grep || true)
    if [ -n \"\$LEFT\" ]; then echo 'ASSERT no-leftover FAIL'; echo \"\$LEFT\"; else echo 'ASSERT no-leftover PASS'; fi
  " 2>&1)"
  rc=$?
  say "$out"
  local a
  for a in version token-url first-303 set-cookie curl-200 page-body no-import-errors no-leftover; do
    if printf '%s\n' "$out" | grep -q "ASSERT $a PASS"; then pass "runtime-$arch: $a"; fi
    if printf '%s\n' "$out" | grep -q "ASSERT $a FAIL"; then fail "runtime-$arch: $a"; fi
  done
  [ "$rc" -eq 0 ] || say "runtime-$arch: phase command exit=$rc"
  end_phase
}

# ============================================================================
# Phase: shell (app source + real runtime, AC2/AC4 pre-package)
# ============================================================================
phase_shell() {
  local arch="$1" rt image name platform ebin out rc pnginfo
  begin_phase "shell-$arch"
  rt="$(runtime_dir_for "$arch")"
  if [ ! -x "$rt/bin/dsh" ] || [ ! -x "$rt/node/bin/node" ]; then
    if [ "$STRICT" = "1" ]; then fail "shell-$arch: runtime missing/incomplete: $rt"; else skip "shell-$arch: runtime missing: $rt"; fi
    end_phase; return
  fi
  ensure_image node24 "$arch" || { fail "shell-$arch: node24 GUI image unavailable"; end_phase; return; }
  platform="$(arch_platform "$arch")"
  image="dsh-qa-gui:node24-$arch"
  ebin="/opt/qa-electron/node_modules/electron/dist/electron"
  mkdir -p "$ROOT/build/cache/qa/electron-$arch" "$ROOT/build/cache/qa/npm-$arch"
  resolve_runtime_mount "$rt"
  name="$(container_name shell "$arch")"
  local mounts=(-v "$ROOT:/workspace" -v "$ROOT/build/cache/qa/electron-$arch:/opt/qa-electron" -v "$ROOT/build/cache/qa/npm-$arch:/root/.npm" -v "$EVID:/out")
  if [ "${#RT_EXTRA[@]}" -gt 0 ]; then
    docker_start "$name" "$platform" "$image" "${mounts[@]}" "${RT_EXTRA[@]}" >/dev/null || { fail "shell-$arch: container start failed"; end_phase; return; }
  else
    docker_start "$name" "$platform" "$image" "${mounts[@]}" >/dev/null || { fail "shell-$arch: container start failed"; end_phase; return; }
  fi

  say "installing electron 45.2.1 in container (cached in build/cache/qa/electron-$arch)"
  if ! ctr "$name" "
    set -e
    cd /opt/qa-electron
    [ -f package.json ] || npm init -y >/dev/null 2>&1
    if [ ! -x node_modules/electron/dist/electron ]; then
      npm install electron@45.2.1 --no-audit --no-fund --loglevel=error
      # npm 11 does not run dependency lifecycle scripts here; run electron's
      # postinstall (binary download) explicitly when dist/ is still missing.
      if [ ! -x node_modules/electron/dist/electron ]; then
        ( cd node_modules/electron && node install.js )
      fi
    fi
    node_modules/electron/dist/electron --version --no-sandbox 2>&1 | tail -1
  " >>"$LOG" 2>&1; then
    fail "shell-$arch: electron install failed (see $LOG)"; end_phase; return
  fi
  if ! ctr "$name" "[ -x '$ebin' ]"; then fail "shell-$arch: electron binary missing"; end_phase; return; fi
  local envs="export DSH_LINUX_RUNTIME='$RT_IN' DSH_LINUX_DISABLE_GPU=1 DSH_LINUX_CONTAINER=1 DSH_LINUX_SCREENSHOT_DELAY_MS='$SHOT_DELAY' DSH_LINUX_HOME=/tmp/qa-home; mkdir -p /tmp/qa-home; rm -rf /root/.config/deepseek-harness/logs;"

  say "--- shell smoke test"
  out="$(ctr "$name" "
    set -o pipefail
    $envs
    cd /workspace
    timeout $TEST_TIMEOUT xvfb-run -a '$ebin' /workspace --no-sandbox --dsh-home=/tmp/qa-home --smoke-test > /tmp/smoke.log 2>&1
    RC=\$?
    echo \"exit=\$RC\"
    grep -E 'SMOKE_OK|SMOKE_FAIL' /tmp/smoke.log || tail -20 /tmp/smoke.log
    echo '--- leftover dsh'
    ps -eo pid,args | grep -F 'lib/bin.js' | grep -v grep || echo NO_LEFT_DSH
  " 2>&1)"
  say "$out"
  if printf '%s\n' "$out" | grep -q 'SMOKE_OK'; then pass "shell-$arch: smoke-test"; else fail "shell-$arch: smoke-test"; fi
  if printf '%s\n' "$out" | grep -q 'exit=0'; then pass "shell-$arch: smoke exit 0"; else fail "shell-$arch: smoke exit 0"; fi
  if printf '%s\n' "$out" | grep -q 'NO_LEFT_DSH'; then pass "shell-$arch: no leftover dsh process"; else fail "shell-$arch: no leftover dsh process"; fi

  say "--- shell screenshot"
  out="$(ctr "$name" "
    set -o pipefail
    $envs
    cd /workspace
    timeout $((TEST_TIMEOUT + 60)) xvfb-run -a '$ebin' /workspace --no-sandbox --dsh-home=/tmp/qa-home --screenshot=/out/screenshots/shell-$arch.png > /tmp/shot.log 2>&1
    RC=\$?
    echo \"exit=\$RC\"
    grep -E 'SCREENSHOT_OK|SCREENSHOT_FAIL' /tmp/shot.log || tail -20 /tmp/shot.log
    ps -eo pid,args | grep -F 'lib/bin.js' | grep -v grep || echo NO_LEFT_DSH
  " 2>&1)"
  say "$out"
  if printf '%s\n' "$out" | grep -q 'SCREENSHOT_OK'; then pass "shell-$arch: screenshot"; else fail "shell-$arch: screenshot"; fi
  pnginfo="$(png_check "$name" "/out/screenshots/shell-$arch.png")"
  if printf '%s\n' "$pnginfo" | grep -qE 'PNG [0-9]+x[0-9]+'; then pass "shell-$arch: png non-empty ($(printf '%s' "$pnginfo" | tail -1))"; else fail "shell-$arch: png check: $pnginfo"; fi
  if printf '%s\n' "$out" | grep -q 'NO_LEFT_DSH'; then pass "shell-$arch: no leftover dsh after screenshot"; else fail "shell-$arch: no leftover dsh after screenshot"; fi
  if [ -z "$PUBLISH_SRC" ] && [ -f "$EVID/screenshots/shell-$arch.png" ]; then PUBLISH_SRC="$EVID/screenshots/shell-$arch.png"; fi

  say "--- shell single instance"
  out="$(ctr "$name" "
    set -o pipefail
    $envs
    cd /workspace
    rm -f /tmp/first.log /tmp/second.log
    RM=/root/.config/deepseek-harness/logs/server.log
    rm -rf /root/.config/deepseek-harness/logs
    Xvfb :99 -screen 0 1280x800x24 >/tmp/xvfb.log 2>&1 &
    XVFB=\$!
    sleep 1
    export DISPLAY=:99
    nohup '$ebin' /workspace --no-sandbox --dsh-home=/tmp/qa-home > /tmp/first.log 2>&1 &
    APP_PID=\$!
    READY=0
    for i in \$(seq 1 45); do
      if grep -q 'server ready' \"\$RM\" 2>/dev/null; then READY=1; break; fi
      sleep 1
    done
    if [ \"\$READY\" = '1' ]; then echo 'ASSERT first-ready PASS'; else echo 'ASSERT first-ready FAIL'; fi
    timeout 90 '$ebin' /workspace --no-sandbox --dsh-home=/tmp/qa-home --smoke-test > /tmp/second.log 2>&1
    echo \"second_exit=\$?\"
    if grep -q 'another instance is already running' /tmp/second.log; then echo 'ASSERT second-blocked PASS'; else echo 'ASSERT second-blocked FAIL'; tail -20 /tmp/second.log; fi
    if grep -q 'second instance detected, focusing main window' \"\$RM\" 2>/dev/null; then echo 'ASSERT focus-log PASS'; else echo 'ASSERT focus-log FAIL'; fi
    echo \"killing first app pid: \$APP_PID (xvfb \$XVFB)\"
    kill \$APP_PID 2>/dev/null || true
    sleep 8
    kill \$XVFB 2>/dev/null || true
    LEFT=\$(ps -eo pid,args | grep -F 'lib/bin.js' | grep -v grep || true)
    if [ -n \"\$LEFT\" ]; then echo 'ASSERT no-leftover-after-kill FAIL'; echo \"\$LEFT\"; else echo 'ASSERT no-leftover-after-kill PASS'; fi
  " 2>&1)"
  say "$out"
  local a
  for a in first-ready second-blocked focus-log no-leftover-after-kill; do
    if printf '%s\n' "$out" | grep -q "ASSERT $a PASS"; then pass "shell-$arch: single-instance/$a"; fi
    if printf '%s\n' "$out" | grep -q "ASSERT $a FAIL"; then fail "shell-$arch: single-instance/$a"; fi
  done
  end_phase
}

# Structural-only AppImage verification (used when the host cannot execute the
# AppImage runtime, e.g. arm64 host with amd64 Rosetta emulation and a static-pie
# x64 runtime that this emulation layer refuses to load).
phase_appimage_structural() {
  local arch="$1" name="$2" appimage="$3" out rc pnginfo machine
  case "$arch" in
    x64) machine="x86-64" ;;
    arm64) machine="aarch64" ;;
  esac
  say "structural-only mode (runtime execution not possible in this environment)"
  out="$(ctr "$name" "
    set -o pipefail
    chmod +x /opt/pkg.AppImage
    INFO=\$(file -b /opt/pkg.AppImage)
    echo \"file=\$INFO\"
    SIZE=\$(stat -c%s /opt/pkg.AppImage); echo \"size=\$SIZE\"
    if [ \"\$SIZE\" -gt 104857600 ]; then echo \"ASSERT image-size PASS\"; else echo \"ASSERT image-size FAIL\"; fi
    if printf %s \"\$INFO\" | grep -q \"$machine\"; then echo \"ASSERT image-elf PASS\"; else echo \"ASSERT image-elf FAIL\"; fi
    OFF=""
    for CAND in \$(grep -abo hsqs /opt/pkg.AppImage | cut -d: -f1); do
      BS=\$(od -An -tu4 -j \$((CAND+12)) -N4 /opt/pkg.AppImage | tr -d ' ')
      MAJ=\$(od -An -tu2 -j \$((CAND+28)) -N2 /opt/pkg.AppImage | tr -d ' ')
      MIN=\$(od -An -tu2 -j \$((CAND+30)) -N2 /opt/pkg.AppImage | tr -d ' ')
      if [ \"\$BS\" = '131072' ] && [ \"\$MAJ\" = '4' ] && [ \"\$MIN\" = '0' ]; then OFF=\$CAND; break; fi
    done
    echo \"squashfs_offset=\$OFF\"
    if [ -n \"\$OFF\" ]; then echo \"ASSERT squashfs-payload PASS\"; else echo \"ASSERT squashfs-payload FAIL\"; fi
    if [ -n \"\$OFF\" ]; then dd if=/opt/pkg.AppImage of=/tmp/runtime bs=1 count=\$OFF status=none; RINFO=\$(file -b /tmp/runtime); echo \"runtime_elf=\$RINFO\"; fi
    if [ -n \"\$RINFO\" ] && printf %s \"\$RINFO\" | grep -q \"$machine\"; then echo \"ASSERT runtime-elf PASS\"; else echo \"ASSERT runtime-elf FAIL\"; fi
    $MIRROR_SETUP
    if ! command -v unsquashfs >/dev/null 2>&1; then
      timeout 60 apt-get update -qq >/dev/null 2>&1 || true
      DEBIAN_FRONTEND=noninteractive timeout 120 apt-get install -y -qq --no-install-recommends squashfs-tools >/dev/null 2>&1 || true
    fi
    if command -v unsquashfs >/dev/null 2>&1 && [ -n \"\$OFF\" ]; then
      unsquashfs -o \"\$OFF\" -l /opt/pkg.AppImage > /tmp/sq.list 2>/dev/null; echo \"payload_entries=\$(wc -l < /tmp/sq.list)\"
      if grep -q \"resources/runtime/node_modules/@deepseek-ai/dsh/lib/bin.js\" /tmp/sq.list; then echo \"ASSERT payload-dsh PASS\"; else echo \"ASSERT payload-dsh FAIL\"; fi
      if grep -qE \"resources/runtime/node/bin/node\$\" /tmp/sq.list; then echo \"ASSERT payload-node PASS\"; else echo \"ASSERT payload-node FAIL\"; fi
      if grep -qE \"resources/app.asar\$\" /tmp/sq.list; then echo \"ASSERT payload-asar PASS\"; else echo \"ASSERT payload-asar FAIL\"; fi
      if grep -qE \"resources/runtime/version.json\$\" /tmp/sq.list; then echo \"ASSERT payload-version PASS\"; else echo \"ASSERT payload-version FAIL\"; fi
    else
      echo \"ASSERT payload-dsh SKIP\"; echo \"ASSERT payload-node SKIP\"; echo \"ASSERT payload-asar SKIP\"; echo \"ASSERT payload-version SKIP\"
    fi
    echo \"ASSERT runtime-run SKIP\"
  " 2>&1)"
  rc=$?
  say "$out"
  local a
  for a in image-size image-elf squashfs-payload runtime-elf payload-dsh payload-node payload-asar payload-version; do
    if printf '%s\n' "$out" | grep -q "ASSERT $a PASS"; then pass "appimage-$arch: $a (structural)"; fi
    if printf '%s\n' "$out" | grep -q "ASSERT $a FAIL"; then fail "appimage-$arch: $a (structural)"; fi
    if printf '%s\n' "$out" | grep -q "ASSERT $a SKIP"; then skip "appimage-$arch: $a (unsquashfs unavailable)"; fi
  done
  skip "appimage-$arch: smoke/screenshot/single-instance (host cannot execute static-pie AppImage runtime; needs native $arch)"
  [ "$rc" -eq 0 ] || say "appimage-$arch: structural command exit=$rc"
}
# ============================================================================
# Phase: appimage (AC2/AC4)
# ============================================================================
phase_appimage() {
  local arch="$1" appimage image name platform out rc pnginfo
  begin_phase "appimage-$arch"
  if ! appimage="$(find_artifact "$arch" appimage)"; then
    if [ "$STRICT" = "1" ]; then fail "appimage-$arch: AppImage not found in $DIST_DIR"; else skip "appimage-$arch: AppImage not found in $DIST_DIR"; fi
    end_phase; return
  fi
  ensure_image ubuntu "$arch" || { fail "appimage-$arch: GUI image unavailable"; end_phase; return; }
  platform="$(arch_platform "$arch")"
  image="dsh-qa-gui:ubuntu2404-$arch"
  name="$(container_name appimage "$arch")"
  docker_start "$name" "$platform" "$image" -v "$EVID:/out" >/dev/null || { fail "appimage-$arch: container start failed"; end_phase; return; }
  if ! docker cp "$appimage" "$name:/opt/pkg.AppImage" >>"$LOG" 2>&1; then
    fail "appimage-$arch: docker cp failed"; end_phase; return
  fi
  say "artifact: $appimage ($(ls -lh "$appimage" 2>/dev/null | awk '{print $5}'))"
  if [ "$APPIMAGE_STRUCTURAL" = "1" ]; then
    phase_appimage_structural "$arch" "$name" "$appimage"
    end_phase; return
  fi
  out="$(ctr "$name" "
    set -o pipefail
    chmod +x /opt/pkg.AppImage
    rm -rf /opt/extract; mkdir -p /opt/extract
    cd /opt/extract
    /opt/pkg.AppImage --appimage-extract >/tmp/extract.log 2>&1 || { echo 'ASSERT extract FAIL'; tail -20 /tmp/extract.log; exit 1; }
    SQ=/opt/extract/squashfs-root
    if [ -x \"\$SQ/deepseek-harness\" ]; then echo 'ASSERT binary PASS'; else echo 'ASSERT binary FAIL'; fi
    if [ -f \"\$SQ/resources/app.asar\" ]; then echo 'ASSERT asar PASS'; else echo 'ASSERT asar FAIL'; fi
    if [ -x \"\$SQ/resources/runtime/bin/dsh\" ]; then echo 'ASSERT runtime-wrapper PASS'; else echo 'ASSERT runtime-wrapper FAIL'; fi
    if [ -x \"\$SQ/resources/runtime/node/bin/node\" ]; then echo 'ASSERT runtime-node PASS'; else echo 'ASSERT runtime-node FAIL'; fi
    if [ -f \"\$SQ/resources/runtime/node_modules/@deepseek-ai/dsh/lib/bin.js\" ]; then echo 'ASSERT dsh-entry PASS'; else echo 'ASSERT dsh-entry FAIL'; fi
    if [ -f \"\$SQ/resources/runtime/version.json\" ]; then echo 'ASSERT runtime-version PASS'; else echo 'ASSERT runtime-version FAIL'; fi
    if grep -q '\"arch\"[[:space:]]*:[[:space:]]*\"$arch\"' \"\$SQ/resources/runtime/version.json\" 2>/dev/null; then echo 'ASSERT runtime-arch PASS'; else echo 'ASSERT runtime-arch FAIL'; fi
    DESK=\$(ls \"\$SQ\"/*.desktop 2>/dev/null | head -1)
    if [ -n \"\$DESK\" ]; then
      echo 'ASSERT desktop-entry PASS'
      if grep -qE '^Name=DeepSeek Harness' \"\$DESK\"; then echo 'ASSERT desktop-name PASS'; else echo 'ASSERT desktop-name FAIL'; fi
      if grep -qE '^Exec=' \"\$DESK\"; then echo 'ASSERT desktop-exec PASS'; else echo 'ASSERT desktop-exec FAIL'; fi
    else
      echo 'ASSERT desktop-entry FAIL'
    fi
    echo '--- version'
    DSH_LINUX_HOME=/tmp/qa-home \"\$SQ/deepseek-harness\" --no-sandbox --version >/tmp/ver.log 2>&1
    echo \"version_exit=\$?\"
    head -3 /tmp/ver.log
    echo '--- smoke'
    export DSH_LINUX_DISABLE_GPU=1 DSH_LINUX_CONTAINER=1 DSH_LINUX_SCREENSHOT_DELAY_MS=$SHOT_DELAY DSH_LINUX_HOME=/tmp/qa-home
    rm -rf /tmp/qa-home; mkdir -p /tmp/qa-home
    cd \"\$SQ\"
    timeout $TEST_TIMEOUT xvfb-run -a ./deepseek-harness --no-sandbox --smoke-test > /tmp/smoke.log 2>&1
    echo \"smoke_exit=\$?\"
    grep -E 'SMOKE_OK|SMOKE_FAIL' /tmp/smoke.log || tail -20 /tmp/smoke.log
    ps -eo pid,args | grep -F 'lib/bin.js' | grep -v grep || echo NO_LEFT_DSH
    echo '--- screenshot'
    timeout $((TEST_TIMEOUT + 60)) xvfb-run -a ./deepseek-harness --no-sandbox --dsh-home=/tmp/qa-home --screenshot=/out/screenshots/appimage-$arch.png > /tmp/shot.log 2>&1
    echo \"shot_exit=\$?\"
    grep -E 'SCREENSHOT_OK|SCREENSHOT_FAIL' /tmp/shot.log || tail -20 /tmp/shot.log
    ps -eo pid,args | grep -F 'lib/bin.js' | grep -v grep || echo NO_LEFT_DSH
  " 2>&1)"
  rc=$?
  say "$out"
  local a
  for a in extract binary asar runtime-wrapper runtime-node dsh-entry runtime-version runtime-arch desktop-entry desktop-name desktop-exec; do
    if printf '%s\n' "$out" | grep -q "ASSERT $a PASS"; then pass "appimage-$arch: $a"; fi
    if printf '%s\n' "$out" | grep -q "ASSERT $a FAIL"; then fail "appimage-$arch: $a"; fi
  done
  if printf '%s\n' "$out" | grep -q 'SMOKE_OK'; then pass "appimage-$arch: smoke-test"; else fail "appimage-$arch: smoke-test"; fi
  if printf '%s\n' "$out" | grep -q 'SCREENSHOT_OK'; then pass "appimage-$arch: screenshot"; else fail "appimage-$arch: screenshot"; fi
  pnginfo="$(png_check "$name" "/out/screenshots/appimage-$arch.png")"
  if printf '%s\n' "$pnginfo" | grep -qE 'PNG [0-9]+x[0-9]+'; then pass "appimage-$arch: png non-empty ($(printf '%s' "$pnginfo" | tail -1))"; else fail "appimage-$arch: png check: $pnginfo"; fi
  if printf '%s\n' "$out" | grep -q 'NO_LEFT_DSH'; then pass "appimage-$arch: no leftover dsh process"; else fail "appimage-$arch: no leftover dsh process"; fi

  say "--- appimage single instance"
  out="$(ctr "$name" "
    set -o pipefail
    export DSH_LINUX_DISABLE_GPU=1 DSH_LINUX_CONTAINER=1 DSH_LINUX_SCREENSHOT_DELAY_MS=$SHOT_DELAY DSH_LINUX_HOME=/tmp/qa-home
    SQ=/opt/extract/squashfs-root
    RM=/root/.config/deepseek-harness/logs/server.log
    rm -rf /root/.config/deepseek-harness/logs /tmp/first.log /tmp/second.log; mkdir -p /tmp/qa-home
    cd \"\$SQ\"
    Xvfb :99 -screen 0 1280x800x24 >/tmp/xvfb.log 2>&1 &
    XVFB=\$!
    sleep 1
    export DISPLAY=:99
    nohup ./deepseek-harness --no-sandbox --dsh-home=/tmp/qa-home > /tmp/first.log 2>&1 &
    APP_PID=\$!
    READY=0
    for i in \$(seq 1 45); do
      if grep -q 'server ready' \"\$RM\" 2>/dev/null; then READY=1; break; fi
      sleep 1
    done
    if [ \"\$READY\" = '1' ]; then echo 'ASSERT first-ready PASS'; else echo 'ASSERT first-ready FAIL'; fi
    timeout 90 ./deepseek-harness --no-sandbox --dsh-home=/tmp/qa-home --smoke-test > /tmp/second.log 2>&1
    echo \"second_exit=\$?\"
    if grep -q 'another instance is already running' /tmp/second.log; then echo 'ASSERT second-blocked PASS'; else echo 'ASSERT second-blocked FAIL'; tail -20 /tmp/second.log; fi
    if grep -q 'second instance detected, focusing main window' \"\$RM\" 2>/dev/null; then echo 'ASSERT focus-log PASS'; else echo 'ASSERT focus-log FAIL'; fi
    echo \"killing first app pid: \$APP_PID (xvfb \$XVFB)\"
    kill \$APP_PID 2>/dev/null || true
    sleep 8
    kill \$XVFB 2>/dev/null || true
    LEFT=\$(ps -eo pid,args | grep -F 'lib/bin.js' | grep -v grep || true)
    if [ -n \"\$LEFT\" ]; then echo 'ASSERT no-leftover-after-kill FAIL'; echo \"\$LEFT\"; else echo 'ASSERT no-leftover-after-kill PASS'; fi
  " 2>&1)"
  say "$out"
  local a2
  for a2 in first-ready second-blocked focus-log no-leftover-after-kill; do
    if printf '%s\n' "$out" | grep -q "ASSERT $a2 PASS"; then pass "appimage-$arch: single-instance/$a2"; fi
    if printf '%s\n' "$out" | grep -q "ASSERT $a2 FAIL"; then fail "appimage-$arch: single-instance/$a2"; fi
  done
  if [ -f "$EVID/screenshots/appimage-$arch.png" ] && [ "$arch" = "$HOST_ARCH" ]; then PUBLISH_SRC="$EVID/screenshots/appimage-$arch.png"; fi
  if [ -f "$EVID/screenshots/appimage-$arch.png" ] && [ -z "$PUBLISH_SRC" ]; then PUBLISH_SRC="$EVID/screenshots/appimage-$arch.png"; fi
  end_phase
}

# ============================================================================
# Phase: deb (AC3)
# ============================================================================
phase_deb() {
  local arch="$1" deb name platform out rc pnginfo debarch mirror
  local MIRROR_SETUP=""
  if [ -n "${DSH_QA_UBUNTU_MIRROR:-}" ]; then
    mirror="$DSH_QA_UBUNTU_MIRROR"
    if [ "$arch" = "x64" ]; then
      mirror="$(printf '%s' "$mirror" | sed 's#/ubuntu-ports#/ubuntu#g')"
    fi
    MIRROR_SETUP="sed -i \"s#http://ports.ubuntu.com/ubuntu-ports#$mirror#g; s#http://archive.ubuntu.com/ubuntu#$mirror#g\" /etc/apt/sources.list.d/ubuntu.sources 2>/dev/null || true; sed -i \"s#http://ports.ubuntu.com/ubuntu-ports#$mirror#g\" /etc/apt/sources.list 2>/dev/null || true;"
  fi
  begin_phase "deb-$arch"
  if ! deb="$(find_artifact "$arch" deb)"; then
    if [ "$STRICT" = "1" ]; then fail "deb-$arch: deb not found in $DIST_DIR"; else skip "deb-$arch: deb not found in $DIST_DIR"; fi
    end_phase; return
  fi
  debarch="$(arch_deb_arch "$arch")"
  platform="$(arch_platform "$arch")"
  name="$(container_name deb "$arch")"
  docker_start "$name" "$platform" "$DEB_IMAGE" -v "$EVID:/out" >/dev/null || { fail "deb-$arch: container start failed"; end_phase; return; }
  if ! docker cp "$deb" "$name:/opt/pkg.deb" >>"$LOG" 2>&1; then
    fail "deb-$arch: docker cp failed"; end_phase; return
  fi
  say "artifact: $deb ($(ls -lh "$deb" 2>/dev/null | awk '{print $5}'))"
  out="$(ctr "$name" "
    set +e
    $MIRROR_SETUP
    export DEBIAN_FRONTEND=noninteractive
    echo '--- dpkg -i (missing deps expected on a clean image)'
    dpkg -i /opt/pkg.deb > /tmp/dpkg1.log 2>&1
    echo \"dpkg_initial_exit=\$?\"
    grep -E 'dependency problems|not installed' /tmp/dpkg1.log | head -5
    echo '--- apt-get update + -f install'
    timeout 240 apt-get -o Acquire::Retries=5 update -qq > /tmp/apt-update.log 2>&1; echo \"update_exit=\$?\"
    APT_OK=0
    for i in 1 2 3 4 5 6; do
      timeout 480 apt-get -o Acquire::Retries=5 -o Acquire::http::MaxParallel=1 -f install -y -qq > /tmp/apt-fix.log 2>&1
      RC=\$?
      echo \"apt_fix_attempt=\$i rc=\$RC\"
      if [ \$RC -eq 0 ]; then APT_OK=1; break; fi
      timeout 480 apt-get -o Acquire::Retries=5 -o Acquire::http::MaxParallel=1 -f install -y -qq --fix-missing >> /tmp/apt-fix.log 2>&1
      RC2=\$?
      echo \"apt_fix_missing_attempt=\$i rc=\$RC2\"
      if [ \$RC2 -eq 0 ]; then APT_OK=1; break; fi
      sleep 3
    done
    if [ \$APT_OK -eq 1 ]; then echo \"apt_fix_exit=0\"; else echo \"apt_fix_exit=1\"; fi
    tail -3 /tmp/apt-fix.log
    echo '--- installed state'
    if dpkg -s deepseek-harness-linux 2>/dev/null | grep -q 'Status: install ok installed'; then echo 'ASSERT installed PASS'; else echo 'ASSERT installed FAIL'; dpkg -s deepseek-harness-linux 2>&1 | head -5; fi
    V=\$(dpkg-query -W -f='\${Version}' deepseek-harness-linux 2>/dev/null); echo \"version=\$V\"
    if [ \"\$V\" = '0.2.1' ]; then echo 'ASSERT version PASS'; else echo 'ASSERT version FAIL'; fi
    A=\$(dpkg-query -W -f='\${Architecture}' deepseek-harness-linux 2>/dev/null); echo \"arch=\$A\"
    if [ \"\$A\" = '$debarch' ]; then echo 'ASSERT arch PASS'; else echo 'ASSERT arch FAIL'; fi
    echo '--- ALSA dependency resolution (t64-first check)'
    if dpkg -l libasound2t64 2>/dev/null | grep -q '^ii  libasound2t64'; then echo 'ASSERT alsa-t64 PASS'; else echo 'ASSERT alsa-t64 FAIL'; dpkg -l | grep -E 'libasound' | head -5; fi
    if dpkg -l 2>/dev/null | grep -q 'liboss4'; then echo 'ASSERT alsa-no-oss4 FAIL'; dpkg -l | grep liboss4; else echo 'ASSERT alsa-no-oss4 PASS'; fi
    ASOUND_TARGET=\$(readlink -f /usr/lib/*-linux-gnu/libasound.so.2 2>/dev/null | head -1); echo \"asound_target=\$ASOUND_TARGET\"
    case \"\$ASOUND_TARGET\" in
      */libasound.so.2.0.0) echo 'ASSERT alsa-real-lib PASS' ;;
      *) echo 'ASSERT alsa-real-lib FAIL' ;;
    esac
    echo '--- executable'
    if [ -x /usr/bin/deepseek-harness ]; then echo 'ASSERT bin PASS'; else echo 'ASSERT bin FAIL'; fi
    readlink -f /usr/bin/deepseek-harness 2>/dev/null
    echo '--- dependencies'
    dpkg-query -W -f='\${Depends}\n\${Recommends}\n' deepseek-harness-linux 2>/dev/null | tr ',' '\n' | sed 's/^ *//' | grep -E 'libgtk-3-0|libnss3|libgbm1|libasound2|libatspi2.0-0|libxss1|libxtst6|xdg-utils|bubblewrap|fonts-noto-cjk' | sort -u
    echo '--- chrome-sandbox'
    SB=\$(dpkg -L deepseek-harness-linux 2>/dev/null | grep '/chrome-sandbox$' | head -1)
    echo \"sandbox=\$SB\"
    if [ -n \"\$SB\" ]; then
      PERM=\$(stat -c '%a %U:%G' \"\$SB\"); echo \"sandbox_perm=\$PERM\"
      case \"\$PERM\" in
        '4755 root:root') echo 'ASSERT sandbox-setuid PASS' ;;
        *) echo 'ASSERT sandbox-setuid FAIL' ;;
      esac
    else
      echo 'ASSERT sandbox-setuid FAIL'
    fi
    echo '--- desktop entry / icon'
    DT=\$(ls /usr/share/applications/*.desktop 2>/dev/null | grep -i deepseek | head -1)
    echo \"desktop=\$DT\"
    if [ -n \"\$DT\" ]; then
      echo 'ASSERT desktop PASS'
      grep -E '^Name=|^Exec=' \"\$DT\"
      if grep -qE '^Exec=' \"\$DT\"; then echo 'ASSERT desktop-exec PASS'; else echo 'ASSERT desktop-exec FAIL'; fi
    else
      echo 'ASSERT desktop FAIL'
    fi
    ICONS=\$(dpkg -L deepseek-harness-linux 2>/dev/null | grep -E '/icons/.*\\.png$' | head -3)
    if [ -n \"\$ICONS\" ]; then echo 'ASSERT icon PASS'; echo \"\$ICONS\"; else echo 'ASSERT icon FAIL'; fi
    echo '--- install xvfb + imagemagick (test tooling)'
    XVFB_OK=0
    if command -v xvfb-run >/dev/null 2>&1 && command -v identify >/dev/null 2>&1; then
      XVFB_OK=1; echo 'xvfb_attempt=0 rc=0 (preinstalled)'
    fi
    for i in 1 2 3 4; do
      if [ \$XVFB_OK -eq 1 ]; then break; fi
      timeout 300 apt-get -o Acquire::Retries=5 -o Acquire::http::MaxParallel=1 install -y -qq --no-install-recommends xvfb imagemagick > /tmp/apt-xvfb.log 2>&1
      XRC=\$?
      echo \"xvfb_attempt=\$i rc=\$XRC\"
      if [ \$XRC -eq 0 ]; then XVFB_OK=1; break; fi
      sleep 3
    done
    if [ \$XVFB_OK -eq 1 ]; then echo \"xvfb_exit=0\"; else echo \"xvfb_exit=1\"; fi
    echo '--- smoke from installed deb'
    export DSH_LINUX_DISABLE_GPU=1 DSH_LINUX_CONTAINER=1 DSH_LINUX_SCREENSHOT_DELAY_MS=$SHOT_DELAY DSH_LINUX_HOME=/tmp/qa-home
    rm -rf /tmp/qa-home; mkdir -p /tmp/qa-home
    timeout $TEST_TIMEOUT xvfb-run -a deepseek-harness --no-sandbox --smoke-test > /tmp/smoke.log 2>&1
    echo \"smoke_exit=\$?\"
    grep -E 'SMOKE_OK|SMOKE_FAIL' /tmp/smoke.log || tail -20 /tmp/smoke.log
    ps -eo pid,args | grep -F 'lib/bin.js' | grep -v grep || echo NO_LEFT_DSH
    echo '--- screenshot from installed deb'
    timeout $((TEST_TIMEOUT + 60)) xvfb-run -a deepseek-harness --no-sandbox --dsh-home=/tmp/qa-home --screenshot=/out/screenshots/deb-$arch.png > /tmp/shot.log 2>&1
    echo \"shot_exit=\$?\"
    grep -E 'SCREENSHOT_OK|SCREENSHOT_FAIL' /tmp/shot.log || tail -20 /tmp/shot.log
    ps -eo pid,args | grep -F 'lib/bin.js' | grep -v grep || echo NO_LEFT_DSH
  " 2>&1)"
  rc=$?
  say "$out"
  local a
  for a in installed version arch alsa-t64 alsa-no-oss4 alsa-real-lib bin sandbox-setuid desktop desktop-exec icon; do
    if printf '%s\n' "$out" | grep -q "ASSERT $a PASS"; then pass "deb-$arch: $a"; fi
    if printf '%s\n' "$out" | grep -q "ASSERT $a FAIL"; then fail "deb-$arch: $a"; fi
  done
  if printf '%s\n' "$out" | grep -q 'SMOKE_OK'; then pass "deb-$arch: smoke-test"; else fail "deb-$arch: smoke-test"; fi
  if printf '%s\n' "$out" | grep -q 'SCREENSHOT_OK'; then pass "deb-$arch: screenshot"; else fail "deb-$arch: screenshot"; fi
  pnginfo="$(png_check "$name" "/out/screenshots/deb-$arch.png")"
  if printf '%s\n' "$pnginfo" | grep -qE 'PNG [0-9]+x[0-9]+'; then pass "deb-$arch: png non-empty ($(printf '%s' "$pnginfo" | tail -1))"; else fail "deb-$arch: png check: $pnginfo"; fi
  if printf '%s\n' "$out" | grep -q 'NO_LEFT_DSH'; then pass "deb-$arch: no leftover dsh process"; else fail "deb-$arch: no leftover dsh process"; fi
  if [ -f "$EVID/screenshots/deb-$arch.png" ] && [ -z "$PUBLISH_SRC" ] && [ "$arch" = "$HOST_ARCH" ]; then PUBLISH_SRC="$EVID/screenshots/deb-$arch.png"; fi
  end_phase
}

# ============================================================================
# Phase: checksums (AC6)
# ============================================================================
phase_checksums() {
  begin_phase "checksums"
  if ! ls -1 "$DIST_DIR"/*.AppImage >/dev/null 2>&1 && ! ls -1 "$DIST_DIR"/*.deb >/dev/null 2>&1; then
    if [ "$STRICT" = "1" ]; then fail "checksums: no artifacts in $DIST_DIR"; else skip "checksums: no artifacts in $DIST_DIR"; fi
    end_phase; return
  fi
  local checkjs="$EVID/check-release.mjs"
  cat > "$checkjs" <<'CHECKJS'
import { createHash } from 'node:crypto';
import { createReadStream, readdirSync, readFileSync, statSync, existsSync } from 'node:fs';
import { join } from 'node:path';

const dist = process.argv[2];
let pass = 0;
let fail = 0;
const ok = (id, msg) => { pass += 1; console.log('PASS ' + id + ': ' + msg); };
const bad = (id, msg) => { fail += 1; console.log('FAIL ' + id + ': ' + msg); };

const ART = /^(DeepSeek-Harness-Linux-.*\.(AppImage|deb)|deepseek-harness-linux-.*\.tar\.gz)$/;
const files = readdirSync(dist).filter((f) => ART.test(f)).sort();
if (files.length === 0) bad('artifacts', 'no deliverables found in ' + dist);
else ok('artifacts', files.length + ' deliverable(s): ' + files.join(', '));

const archs = new Set(files.map((f) => (/(x86_64|amd64)/.test(f) ? 'x86_64' : /arm64/.test(f) ? 'arm64' : 'unknown')));
ok('arches', 'present: ' + [...archs].sort().join(', '));

const contract = [
  ['x86_64', 'DeepSeek-Harness-Linux-0.2.1-x86_64.AppImage', 'DeepSeek-Harness-Linux-0.2.1-amd64.deb'],
  ['arm64', 'DeepSeek-Harness-Linux-0.2.1-arm64.AppImage', 'DeepSeek-Harness-Linux-0.2.1-arm64.deb'],
];
for (const [arch, ai, deb] of contract) {
  if (!archs.has(arch)) { console.log('SKIP contract-' + arch + ': architecture not present'); continue; }
  if (existsSync(join(dist, ai))) ok('contract-' + arch + '-appimage', ai);
  else bad('contract-' + arch + '-appimage', 'missing ' + ai);
  if (existsSync(join(dist, deb))) ok('contract-' + arch + '-deb', deb);
  else bad('contract-' + arch + '-deb', 'missing ' + deb);
}

const sha = (file) => new Promise((resolve, reject) => {
  const h = createHash('sha256');
  createReadStream(file).on('data', (c) => h.update(c)).on('error', reject).on('end', () => resolve(h.digest('hex')));
});

const sumsPath = join(dist, 'SHA256SUMS');
if (!existsSync(sumsPath)) bad('sha256sums', 'SHA256SUMS missing');
else {
  const lines = readFileSync(sumsPath, 'utf8').trim().split('\n').filter(Boolean);
  const listed = new Map();
  for (const line of lines) {
    const m = /^([0-9a-f]{64})  (.+)$/.exec(line);
    if (!m) { bad('sha256sums-format', 'bad line: ' + line.slice(0, 80)); continue; }
    listed.set(m[2], m[1]);
  }
  const missing = files.filter((f) => !listed.has(f));
  const extra = [...listed.keys()].filter((f) => !existsSync(join(dist, f)));
  if (missing.length) bad('sha256sums-coverage', 'not listed: ' + missing.join(', '));
  else ok('sha256sums-coverage', 'all ' + files.length + ' deliverable(s) listed');
  if (extra.length) bad('sha256sums-extra', 'listed but missing: ' + extra.join(', '));
  else ok('sha256sums-extra', 'no stale entries');
  for (const f of files) {
    if (!listed.has(f)) continue;
    const real = await sha(join(dist, f));
    if (real === listed.get(f)) ok('sha256sums-' + f, 'hash matches');
    else bad('sha256sums-' + f, 'hash mismatch (recomputed ' + real.slice(0, 16) + '...)');
  }
}

const relPath = join(dist, 'RELEASE.json');
if (!existsSync(relPath)) bad('release-json', 'RELEASE.json missing');
else {
  let rel = null;
  try { rel = JSON.parse(readFileSync(relPath, 'utf8')); ok('release-json', 'valid JSON'); }
  catch (e) { bad('release-json', 'invalid JSON: ' + e.message); }
  if (rel) {
    const expect = { version: '0.2.1', dshVersion: '0.2.1-rc.5', nodeVersion: '24.22.2', electronVersion: '45.2.1' };
    for (const k of Object.keys(expect)) {
      const want = expect[k];
      if (rel[k] === want) ok('release-' + k, k + '=' + want);
      else bad('release-' + k, k + '=' + JSON.stringify(rel[k]) + ', expected ' + want);
    }
    if (rel.unofficial === true) ok('release-unofficial', 'unofficial=true');
    else bad('release-unofficial', 'unofficial flag missing/false');
    const sizes = new Map();
    if (Array.isArray(rel.artifacts)) for (const a of rel.artifacts) sizes.set(a.name, a.size);
    else if (rel.files && typeof rel.files === 'object') for (const n of Object.keys(rel.files)) sizes.set(n, rel.files[n]);
    if (sizes.size === 0) bad('release-sizes', 'no artifact size information (artifacts[]/files{})');
    else {
      let badSizes = 0;
      for (const f of files) {
        if (!sizes.has(f)) { bad('release-size-' + f, 'not described in RELEASE.json'); badSizes += 1; continue; }
        const real = statSync(join(dist, f)).size;
        if (sizes.get(f) === real) ok('release-size-' + f, real + ' bytes');
        else { bad('release-size-' + f, 'size ' + sizes.get(f) + ' != actual ' + real); badSizes += 1; }
      }
      if (badSizes === 0) ok('release-sizes', 'all sizes match actual files');
    }
    if (Array.isArray(rel.artifacts)) {
      let shaBad = 0;
      for (const a of rel.artifacts) {
        if (!a.sha256 || !existsSync(join(dist, a.name))) continue;
        const real = await sha(join(dist, a.name));
        if (real !== a.sha256) { bad('release-sha-' + a.name, 'sha256 mismatch'); shaBad += 1; }
      }
      if (shaBad === 0) ok('release-sha256', 'artifact sha256 values match');
    }
  }
}
console.log('check-release: PASS=' + pass + ' FAIL=' + fail);
process.exit(fail ? 1 : 0);
CHECKJS

  local image="node:24-bookworm"
  if ! docker image inspect "$image" >/dev/null 2>&1; then
    say "pulling $image for checksum validation"
    docker pull -q "$image" >>"$LOG" 2>&1 || { fail "checksums: cannot obtain $image"; end_phase; return; }
  fi
  local out rc npass nfail tally
  out="$(docker run --rm --platform "$(arch_platform "$HOST_ARCH")" -v "$DIST_DIR:/dist:ro" -v "$checkjs:/check.mjs:ro" "$image" node /check.mjs /dist 2>&1)"
  rc=$?
  say "$out"
  tally="$(printf '%s\n' "$out" | grep -oE 'check-release: PASS=[0-9]+ FAIL=[0-9]+' | tail -1)"
  npass="$(printf '%s' "$tally" | sed -n 's/.*PASS=\([0-9]*\).*/\1/p')"
  nfail="$(printf '%s' "$tally" | sed -n 's/.*FAIL=\([0-9]*\).*/\1/p')"
  npass="${npass:-0}"
  nfail="${nfail:-0}"
  PASS=$((PASS + npass))
  if [ "$nfail" -gt 0 ]; then
    FAIL=$((FAIL + nfail))
    printf '%s\n' "$out" | grep '^FAIL ' >> "$SUMMARY"
    FAILURES="$FAILURES$CURRENT_PHASE: $nfail checksum/metadata check(s) failed"$'\n'
  fi
  [ "$rc" -eq 0 ] || say "checksums: node checker exit=$rc"
  end_phase
}

# ============================================================================
# main
# ============================================================================
RUN_CHECKSUMS=0
ARCH_MODES=""
for mode in $MODES; do
  if [ "$mode" = "checksums" ]; then
    RUN_CHECKSUMS=1
  else
    ARCH_MODES="$ARCH_MODES $mode"
  fi
done

for arch in $ARCH_LIST; do
  for mode in $ARCH_MODES; do
    case "$mode" in
      runtime) phase_runtime "$arch" ;;
      shell) phase_shell "$arch" ;;
      appimage) phase_appimage "$arch" ;;
      deb) phase_deb "$arch" ;;
    esac
  done
done
[ "$RUN_CHECKSUMS" = "1" ] && phase_checksums

# ---- publish screenshot ----------------------------------------------------
if [ "$PUBLISH_SCREENSHOT" = "1" ]; then
  LOG="$SUMMARY"
  if [ -n "$PUBLISH_SRC" ] && [ -f "$PUBLISH_SRC" ]; then
    cp -f "$PUBLISH_SRC" "$ROOT/build/qa/screenshot.png"
    mkdir -p "$ROOT/docs/assets"
    cp -f "$PUBLISH_SRC" "$ROOT/docs/assets/screenshot.png"
    pass "screenshot published: $PUBLISH_SRC -> build/qa/screenshot.png, docs/assets/screenshot.png"
  else
    skip "screenshot publish: no real screenshot captured"
  fi
fi

# ---- summary ---------------------------------------------------------------
LOG="$SUMMARY"
say ""
say "==================================================================="
say "RESULT: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
if [ "$FAIL" -gt 0 ]; then
  say "failures:"
  printf '%s' "$FAILURES" | sed 's/^/  - /'
  say "evidence: $EVID"
  exit 1
fi
say "all executed checks passed"
say "evidence: $EVID"
exit 0
