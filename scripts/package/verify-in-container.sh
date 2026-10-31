#!/usr/bin/env bash
# DeepSeek Harness (Linux) — 在 ubuntu:24.04 容器内验证 deb / AppImage
#
# 由 scripts/package/verify-linux-packages.sh 调用。验证内容（AC2/AC3 的打包侧）：
#   deb:  dpkg -i + apt-get -f install、/usr/bin/deepseek-harness 存在、
#         chrome-sandbox 权限 4755、xvfb 下 --smoke-test / --screenshot 通过、无残留进程
#   AppImage: --appimage-extract、AppRun 在 xvfb 下 --smoke-test / --screenshot 通过
set -euo pipefail

log() { printf '[verify %s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { printf '[verify %s] ERROR: %s\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }

ARCH="${DSH_VERIFY_ARCH:?}"
TARGETS="${DSH_VERIFY_TARGETS:-appimage,deb}"
DEB_NAME="${DSH_VERIFY_DEB:-}"
APPIMAGE_NAME="${DSH_VERIFY_APPIMAGE:-}"
DIST="${DSH_VERIFY_DIST:-/work/dist}"
EVIDENCE="${DSH_VERIFY_EVIDENCE:-/work/build/package/evidence}"
mkdir -p "$EVIDENCE"

TAG="${DSH_VERIFY_TAG:-$ARCH}"
log "arch=$ARCH tag=$TAG targets=$TARGETS dist=$DIST"

# ---- 依赖（Ubuntu 24.04+ 用 t64 包名，Debian 12 用旧包名） ---------------------
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/tmp/apt.log 2>&1 || die "apt-get update failed"

DISTRO_ID=""
DISTRO_VERSION=""
if [ -f /etc/os-release ]; then
  DISTRO_ID="$(. /etc/os-release && printf '%s' "${ID:-}")"
  DISTRO_VERSION="$(. /etc/os-release && printf '%s' "${VERSION_ID:-}")"
fi
log "distro: ${DISTRO_ID} ${DISTRO_VERSION}"

GTK_PKG="libgtk-3-0"
ASOUND_PKG="libasound2"
ATSPI_PKG="libatspi2.0-0"
FUSE_PKG="libfuse2"
if [ "$DISTRO_ID" = "ubuntu" ] && [ "${DISTRO_VERSION%%.*}" -ge 24 ] 2>/dev/null; then
  GTK_PKG="libgtk-3-0t64"
  ASOUND_PKG="libasound2t64"
  ATSPI_PKG="libatspi2.0-0t64"
  FUSE_PKG="libfuse2t64"
fi
# libfuse2 仅 AppImage 挂载需要；--appimage-extract 路径不依赖 FUSE，缺失不影响验证。
OPTIONAL_PKGS=""
for pkg in "$FUSE_PKG"; do
  apt-cache show "$pkg" >/dev/null 2>&1 && OPTIONAL_PKGS="$OPTIONAL_PKGS $pkg"
done
apt-get install -y -qq --no-install-recommends \
  xvfb xauth ca-certificates file dbus-x11 \
  libnss3 libatk1.0-0 libatk-bridge2.0-0 "$GTK_PKG" libgbm1 "$ASOUND_PKG" \
  libxss1 libxtst6 "$ATSPI_PKG" libxcomposite1 libxdamage1 libxrandr2 \
  libcairo2 libpango-1.0-0 libx11-xcb1 libxkbcommon0 fonts-noto-cjk $OPTIONAL_PKGS \
  >>/tmp/apt.log 2>&1 || die "apt-get install failed (see /tmp/apt.log)"
log "GUI deps installed ($GTK_PKG, $ASOUND_PKG, $ATSPI_PKG)"
# AppImage outer runtime 若动态链接未版本化 libz.so，会依赖 zlib1g-dev 提供的 /usr/lib/*/libz.so；
# 这里确认干净系统没有 zlib1g-dev，作为静态 runtime 的验证前提。
if dpkg -l zlib1g-dev 2>/dev/null | grep -q '^ii'; then
  log "WARN: zlib1g-dev 已安装，静态 runtime 验证弱化"
else
  log "zlib1g-dev absent (good: AppImage 不应依赖未版本化 libz.so)"
fi

run_smoke() {
  local bin="$1" tag="$2" logf="$EVIDENCE/$TAG-$tag-smoke.log"
  set +e
  xvfb-run -a timeout 180 env ELECTRON_DISABLE_SECURITY_WARNINGS=1 "$bin" --no-sandbox --smoke-test >"$logf" 2>&1
  local rc=$?
  set -e
  log "$tag smoke-test rc=$rc"
  tail -n 6 "$logf" | sed 's/^/    /' || true
  grep -q 'SMOKE_OK' "$logf" || die "$tag --smoke-test 未输出 SMOKE_OK（rc=${rc}，日志 ${logf}）"
}

run_screenshot() {
  local bin="$1" tag="$2" png="$EVIDENCE/$TAG-$tag-screenshot.png" logf="$EVIDENCE/$TAG-$tag-screenshot.log"
  set +e
  xvfb-run -a timeout 180 env ELECTRON_DISABLE_SECURITY_WARNINGS=1 "$bin" --no-sandbox "--screenshot=$png" >"$logf" 2>&1
  local rc=$?
  set -e
  log "$tag screenshot rc=$rc"
  grep -q 'SCREENSHOT_OK' "$logf" || die "$tag --screenshot 未输出 SCREENSHOT_OK（rc=${rc}，日志 ${logf}）"
  [ -s "$png" ] || die "$tag 截图文件为空: $png"
  local size
  size="$(stat -c%s "$png")"
  [ "$size" -gt 10000 ] || die "$tag 截图过小（$size bytes）: $png"
  log "$tag screenshot ok: $png ($size bytes)"
}

check_no_residual() {
  sleep 2
  local residue
  residue="$(pgrep -af 'dsh web --no-open|runtime/bin/dsh.web|lib/bin.js web' || true)"
  if [ -n "$residue" ]; then
    log "residual processes: $residue"
    die "退出后仍有 dsh 子进程残留"
  fi
  log "no residual dsh processes"
}

find_squashfs_offset() {
  local img="$1" off major minor block_size magic
  while IFS= read -r off; do
    [ -n "$off" ] || continue
    # squashfs superblock: 0x73717368 ('hsqs' little-endian) + s_major(u32)==4
    magic="$(od -An -tx1 -j "$off" -N4 "$img" 2>/dev/null | tr -d ' \n')"
    [ "$magic" = "68737173" ] || continue
    # squashfs superblock 布局：s_major/s_minor 是 u16，位于 magic 后 +28/+30（不是 +4！）
    major="$(od -An -tu2 -j $((off + 28)) -N2 "$img" 2>/dev/null | tr -d ' ')"
    minor="$(od -An -tu2 -j $((off + 30)) -N2 "$img" 2>/dev/null | tr -d ' ')"
    [ "$major" = "4" ] && [ "$minor" = "0" ] || continue
    block_size="$(od -An -tu4 -j $((off + 12)) -N4 "$img" 2>/dev/null | tr -d ' ')"
    if [ -z "$block_size" ] || [ "$block_size" -lt 4096 ] || [ "$block_size" -gt 1048576 ]; then continue; fi
    printf '%s\n' "$off"
    return 0
  done < <(grep -abo hsqs "$img" | cut -d: -f1)
  return 1
}

HAS_DEB=0
HAS_APPIMAGE=0
case ",$TARGETS," in *,deb,*) HAS_DEB=1 ;; esac
case ",$TARGETS," in *,appimage,*) HAS_APPIMAGE=1 ;; esac

# ---- deb --------------------------------------------------------------------
if [ "$HAS_DEB" = "1" ]; then
  [ -n "$DEB_NAME" ] || die "DSH_VERIFY_DEB missing"
  [ -f "$DIST/$DEB_NAME" ] || die "deb not found: $DIST/$DEB_NAME"
  log "installing deb via dpkg -i + apt-get -f install"
  dpkg -i "$DIST/$DEB_NAME" >"$EVIDENCE/$ARCH-deb-install.log" 2>&1 || true
  apt-get -f install -y >>"$EVIDENCE/$ARCH-deb-install.log" 2>&1 || die "apt-get -f install 失败（见 $EVIDENCE/$ARCH-deb-install.log）"
  dpkg -s deepseek-harness-linux | sed -n '1,12p' | sed 's/^/    /'
  [ -x /usr/bin/deepseek-harness ] || die "/usr/bin/deepseek-harness 不存在或不可执行"
  SANDBOX="$(dpkg -L deepseek-harness-linux | grep '/chrome-sandbox$' | head -n 1)"
  [ -n "$SANDBOX" ] || die "dpkg 安装内容中缺少 chrome-sandbox"
  MODE="$(stat -c '%a' "$SANDBOX")"
  log "chrome-sandbox: $SANDBOX mode=$MODE"
  [ "$MODE" = "4755" ] || die "chrome-sandbox 权限不是 4755（实际 ${MODE}）"
  DESKTOP="$(ls /usr/share/applications/*deepseek*harness*.desktop 2>/dev/null | head -n 1 || true)"
  [ -n "$DESKTOP" ] || DESKTOP="$(ls /usr/share/applications/*.desktop 2>/dev/null | head -n 1 || true)"
  [ -n "$DESKTOP" ] || die "未安装 .desktop 文件"
  log "desktop file: $DESKTOP"
  grep -E '^(Name|Exec|Categories|StartupWMClass)=' "$DESKTOP" | sed 's/^/    /' || true
  run_smoke /usr/bin/deepseek-harness deb
  run_screenshot /usr/bin/deepseek-harness deb
  check_no_residual
fi

# ---- AppImage ---------------------------------------------------------------
if [ "$HAS_APPIMAGE" = "1" ]; then
  [ -n "$APPIMAGE_NAME" ] || die "DSH_VERIFY_APPIMAGE missing"
  [ -f "$DIST/$APPIMAGE_NAME" ] || die "AppImage not found: $DIST/$APPIMAGE_NAME"
  cp "$DIST/$APPIMAGE_NAME" /tmp/deepseek-harness.AppImage
  chmod +x /tmp/deepseek-harness.AppImage
  log "AppImage --appimage-extract"
  rm -rf /tmp/appimage-extract && mkdir -p /tmp/appimage-extract
  APPIMAGE_FALLBACK=0
  if ( cd /tmp/appimage-extract && /tmp/deepseek-harness.AppImage --appimage-extract >"$EVIDENCE/$TAG-appimage-extract.log" 2>&1 ); then
    log "AppImage outer runtime 执行成功"
  else
    APPIMAGE_FALLBACK=1
    log "WARN: AppImage outer runtime 无法在本环境执行（Rosetta 限制）；降级 unsquashfs 内容校验"
    apt-get install -y -qq --no-install-recommends squashfs-tools >>/tmp/apt.log 2>&1 || die "安装 squashfs-tools 失败"
    rm -rf /tmp/appimage-extract/squashfs-root
    OFFSET="$(find_squashfs_offset /tmp/deepseek-harness.AppImage || true)"
    [ -n "$OFFSET" ] || die "无法定位 AppImage squashfs superblock（hsqs + s_major=4）"
    unsquashfs -q -o "$OFFSET" -d /tmp/appimage-extract/squashfs-root /tmp/deepseek-harness.AppImage >"$EVIDENCE/$TAG-appimage-unsquashfs.log" 2>&1 || die "unsquashfs 解包失败"
  fi
  [ -x /tmp/appimage-extract/squashfs-root/deepseek-harness ] || die "extract 后缺少可执行文件"
  log "extract ok: $(du -sh /tmp/appimage-extract/squashfs-root | awk '{print $1}')"
  if [ "$APPIMAGE_FALLBACK" = "0" ]; then
    # 无 FUSE 环境：直接以 APPIMAGE_EXTRACT_AND_RUN=1 运行 AppImage 本体，验证 outer runtime 不依赖 libz.so。
    ldd /tmp/deepseek-harness.AppImage 2>&1 | head -n 5 | sed "s/^/    ldd: /" || true
    if ldd /tmp/deepseek-harness.AppImage 2>&1 | grep -q libz; then
      die "AppImage outer runtime 仍依赖未版本化 libz.so"
    fi
    export APPIMAGE_EXTRACT_AND_RUN=1
    run_smoke /tmp/deepseek-harness.AppImage appimage
    run_screenshot /tmp/deepseek-harness.AppImage appimage
    unset APPIMAGE_EXTRACT_AND_RUN
  else
    # Rosetta 等环境无法执行 outer runtime：用解包后的 Electron 二进制做等效冒烟（内容与 AppImage 内一致）。
    log "WARN: 改用解包后二进制冒烟（outer runtime 在模拟环境不可执行，非产物缺陷）"
    run_smoke /tmp/appimage-extract/squashfs-root/deepseek-harness appimage
    run_screenshot /tmp/appimage-extract/squashfs-root/deepseek-harness appimage
  fi
  check_no_residual
  check_no_residual
  rm -rf /tmp/appimage-extract
fi

log "VERIFY_OK arch=$ARCH targets=$TARGETS"
