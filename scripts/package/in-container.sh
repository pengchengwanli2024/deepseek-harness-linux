#!/usr/bin/env bash
# DeepSeek Harness (Linux) — 在 Linux 构建容器内执行打包流水线
#
# 由 scripts/package/build-linux.sh 通过 docker run 调用，不要在宿主机直接运行。
# 步骤：安装最小构建依赖 → 复制项目并 npm install → electron-builder → 规范化产物 →
#       结构校验 → 生成 dist/SHA256SUMS 与 dist/RELEASE.json。
set -euo pipefail

log() { printf '[package %s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { printf '[package %s] ERROR: %s\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }

ARCH="${DSH_ARCH:?DSH_ARCH missing}"
TARGETS="${DSH_TARGETS:-AppImage,deb,tar.gz}"
APP_VERSION="${DSH_APP_VERSION:?DSH_APP_VERSION missing}"
DSH_VERSION="${DSH_DSH_VERSION:?}"
NODE_VERSION="${DSH_NODE_VERSION:?}"
ELECTRON_VERSION="${DSH_ELECTRON_VERSION:?}"
BUILDER_VERSION="${DSH_BUILDER_VERSION:?}"
PROJECT_SRC="${DSH_PROJECT_SRC:-/work}"
RUNTIME_SRC="${DSH_RUNTIME_SRC:?DSH_RUNTIME_SRC missing}"
OUTPUT="${DSH_OUTPUT_DIR:-/build/output}"
DIST_DIR="${DSH_DIST_DIR:-/work/dist}"
PKG_ROOT="${DSH_PKG_ROOT:-/work}"
CONFIG="$PKG_ROOT/packaging/electron-builder.yml"
STAGE="/build/project"
CACHE="${DSH_CACHE_DIR:-/cache}"
COMMIT="${DSH_COMMIT:-unknown}"
COMMIT_DIRTY="${DSH_COMMIT_DIRTY:-false}"
BUILT_AT="${DSH_BUILT_AT:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"

export ELECTRON_BUILDER_CACHE="${ELECTRON_BUILDER_CACHE:-$CACHE/electron-builder}"
export ELECTRON_CACHE="${ELECTRON_CACHE:-$CACHE/electron}"
export npm_config_cache="${npm_config_cache:-$CACHE/npm}"
export npm_config_update_notifier=false
export CI=true

# electron-builder 的 ${env.X} 宏只在部分字段展开（artifactName/directories 等），
# afterInstall 等脚本路径不会展开，因此这里把配置渲染成带真实绝对路径的 effective config。
export DSH_PKG_ROOT="$PKG_ROOT"
export DSH_PKG_OUTPUT="$OUTPUT"
export DSH_PKG_BUILD_RESOURCES="$PKG_ROOT/assets"
export DSH_PKG_ICON="$PKG_ROOT/assets/icon.png"
export DSH_PKG_RUNTIME="$RUNTIME_SRC"
EFFECTIVE_CONFIG="/build/electron-builder.effective.yml"

case "$ARCH" in
  x64)   EB_ARCH="--x64";   DEB_EXPECT_ARCH="amd64" ;;
  arm64) EB_ARCH="--arm64"; DEB_EXPECT_ARCH="arm64" ;;
  *) die "unsupported arch: $ARCH" ;;
esac

[ -d "$RUNTIME_SRC/bin" ] || die "runtime missing: $RUNTIME_SRC/bin"
[ -f "$RUNTIME_SRC/bin/dsh" ] || die "runtime missing bin/dsh: $RUNTIME_SRC"
[ -f "$RUNTIME_SRC/node/bin/node" ] || die "runtime missing node/bin/node: $RUNTIME_SRC"
[ -f "$RUNTIME_SRC/node_modules/@deepseek-ai/dsh/package.json" ] || die "runtime missing dsh node_modules"
[ -d "$PROJECT_SRC/app" ] || die "project missing app/: $PROJECT_SRC"
[ -f "$CONFIG" ] || die "electron-builder config missing: $CONFIG"

log "arch=$ARCH targets=$TARGETS app=$APP_VERSION dsh=$DSH_VERSION electron=$ELECTRON_VERSION"
log "runtime=$RUNTIME_SRC ($(du -sh "$RUNTIME_SRC" | awk '{print $1}'))"
log "electron-builder cache: $ELECTRON_BUILDER_CACHE"

# ---- 1. 构建依赖 -------------------------------------------------------------
if ! command -v fakeroot >/dev/null 2>&1 || ! command -v xz >/dev/null 2>&1; then
  log "installing build dependencies (apt)"
  apt-get update -qq >/tmp/apt.log 2>&1 || die "apt-get update failed (see /tmp/apt.log)"
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
    ca-certificates curl xz-utils file fakeroot >>/tmp/apt.log 2>&1 || die "apt-get install failed (see /tmp/apt.log)"
fi
log "build deps ok: fakeroot=$(command -v fakeroot || echo missing) xz=$(command -v xz || echo missing)"

# ---- 2. 准备项目（copy 到容器本地盘，避免大目录走 bind mount） -----------------
rm -rf "$STAGE" "$OUTPUT"
mkdir -p "$STAGE" "$OUTPUT"
cp -a "$PROJECT_SRC/package.json" "$STAGE/package.json"
[ -f "$PROJECT_SRC/package-lock.json" ] && cp -a "$PROJECT_SRC/package-lock.json" "$STAGE/package-lock.json"
cp -a "$PROJECT_SRC/app" "$STAGE/app"
for extra in assets packaging; do
  [ -e "$PROJECT_SRC/$extra" ] && cp -a "$PROJECT_SRC/$extra" "$STAGE/$extra"
done
log "project staged: $(ls -A "$STAGE" | tr '\n' ' ')"

log "npm install (ignore-scripts; electron 二进制由 electron-builder 按需下载)"
if [ -f "$STAGE/package-lock.json" ]; then
  ( cd "$STAGE" && npm ci --ignore-scripts --no-audit --no-fund --loglevel=warn ) || die "npm ci failed"
else
  ( cd "$STAGE" && npm install --ignore-scripts --no-audit --no-fund --loglevel=warn ) || die "npm install failed"
fi
[ -x "$STAGE/node_modules/.bin/electron-builder" ] || die "electron-builder binary missing after npm install"
EB_INSTALLED="$("$STAGE/node_modules/.bin/electron-builder" --version 2>/dev/null | tail -n 1)"
log "electron-builder installed: $EB_INSTALLED (expected $BUILDER_VERSION)"
log "electron devDependency: $(sed -n 's/.*"electron"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$STAGE/package.json" | head -n 1)"

# ---- 3. electron-builder ----------------------------------------------------
node - "$CONFIG" "$EFFECTIVE_CONFIG" <<'NODE_RENDER' || die "config render failed"
const fs = require('fs');
const [src, dst] = process.argv.slice(2);
let text = fs.readFileSync(src, 'utf8');
text = text.replace(/\$\{env\.([A-Z0-9_]+)\}/g, (m, name) => {
  const value = process.env[name];
  if (value == null || value === '') throw new Error('missing env for config macro: ' + name);
  return value;
});
fs.writeFileSync(dst, text);
NODE_RENDER
log "effective electron-builder config: $EFFECTIVE_CONFIG"

TARGET_ARGS="$(printf '%s' "$TARGETS" | tr ',' ' ')"
log "electron-builder --linux $TARGET_ARGS $EB_ARCH --projectDir $STAGE"
(
  cd "$STAGE"
  # shellcheck disable=SC2086
  ./node_modules/.bin/electron-builder --linux $TARGET_ARGS $EB_ARCH \
    --projectDir "$STAGE" --config "$EFFECTIVE_CONFIG" --publish never
) || die "electron-builder failed"

log "electron-builder output:"
ls -la "$OUTPUT" || true

shopt -s nullglob
APPIMAGES=("$OUTPUT"/*.AppImage)
DEBS=("$OUTPUT"/*.deb)
TARBALLS=("$OUTPUT"/*.tar.gz)
shopt -u nullglob

# ---- 4. 产物结构校验（全部通过后才复制到 dist/，避免失败时留下半成品） ------
mkdir -p "$DIST_DIR"
PENDING_SRC=()
PENDING_NAME=()

RUNTIME_SIZE_SRC="$(du -sb "$RUNTIME_SRC" | awk '{print $1}')"
RUNTIME_MIN_SIZE=$((RUNTIME_SIZE_SRC * 95 / 100))
log "runtime source: $((RUNTIME_SIZE_SRC / 1048576))MiB"

# 校验打包后的运行时目录是否完整（dsh 包装脚本、node 二进制、node_modules 依赖）。
assert_runtime_tree() {
  local base="$1" label="$2" actual
  [ -f "$base/bin/dsh" ] || die "$label: 缺少 runtime/bin/dsh"
  [ -x "$base/bin/dsh" ] || die "$label: runtime/bin/dsh 无执行权限"
  [ -f "$base/node/bin/node" ] || die "$label: 缺少 runtime/node/bin/node"
  [ -x "$base/node/bin/node" ] || die "$label: runtime/node/bin/node 无执行权限"
  [ -f "$base/node_modules/@deepseek-ai/dsh/lib/bin.js" ] || die "$label: 缺少 runtime/node_modules/@deepseek-ai/dsh/lib/bin.js"
  [ -f "$base/node_modules/@deepseek-ai/dsh/package.json" ] || die "$label: 缺少 runtime/node_modules/@deepseek-ai/dsh/package.json"
  [ -f "$base/version.json" ] || die "$label: 缺少 runtime/version.json"
  actual="$(du -sb "$base" | awk '{print $1}')"
  [ "$actual" -ge "$RUNTIME_MIN_SIZE" ] || die "$label: runtime 体积异常（$((actual / 1048576))MiB < 下限 $((RUNTIME_MIN_SIZE / 1048576))MiB）"
  log "$label: runtime 完整（$((actual / 1048576))MiB）"
}

queue_artifact() {
  [ -f "$1" ] || return 1
  PENDING_SRC+=("$1")
  PENDING_NAME+=("$2")
  return 0
}

check_asar() {
  local unpacked listing
  unpacked="$(ls -d "$OUTPUT"/linux*-unpacked 2>/dev/null | head -n 1 || true)"
  [ -d "$unpacked" ] || die "unpacked 目录不存在（无法校验 app.asar/runtime 布局）"
  [ -f "$unpacked/resources/app.asar" ] || die "app.asar missing in $unpacked/resources"
  listing="$(node -e '
    const asar = require(process.argv[1]);
    console.log(asar.listPackage(process.argv[2]).join("\n"));
  ' "$STAGE/node_modules/@electron/asar" "$unpacked/resources/app.asar")"
  printf '%s\n' "$listing" | grep -q '/app/main.mjs' || die "app.asar 中缺少 app/main.mjs"
  if printf '%s\n' "$listing" | grep -Eq '^/(runtime|dist|docs)/'; then
    die "app.asar 不应包含 runtime/、dist/ 或 docs/"
  fi
  log "app.asar 仅含壳代码（app/main.mjs 存在，无 runtime/dist/docs）"
  assert_runtime_tree "$unpacked/resources/runtime" "unpacked"
}

if [ "${#APPIMAGES[@]}" -gt 0 ]; then
  AI="${APPIMAGES[0]}"
  log "AppImage: $(file -b "$AI" | cut -c1-120)"
  # 结构校验：--appimage-extract 后必须包含可执行文件与 resources/runtime。
  # 若构建环境无法执行 AppImage 的 outer runtime（例如在 Apple Silicon 的 Rosetta amd64 容器里，
  # x86_64 静态 runtime 会 ENOEXEC），降级为 offset + unsquashfs 直接读取 squashfs 内容，
  # 内容校验等价（仅少了 outer runtime 运行验证）。
  EXTRACT_DIR="/build/appimage-extract"
  rm -rf "$EXTRACT_DIR"; mkdir -p "$EXTRACT_DIR"
  if ( cd "$EXTRACT_DIR" && "$AI" --appimage-extract >/tmp/appimage-extract.log 2>&1 ); then
    log "AppImage outer runtime 执行成功（--appimage-extract）"
  else
    log "WARN: AppImage outer runtime 无法在本环境执行（$(tail -n 2 /tmp/appimage-extract.log | tr '\n' ' ')）；降级 unsquashfs 内容校验"
    if ! command -v unsquashfs >/dev/null 2>&1; then
      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends squashfs-tools >>/tmp/apt.log 2>&1 || die "安装 squashfs-tools 失败"
    fi
    rm -rf "$EXTRACT_DIR/squashfs-root"
    AI_OFFSET="$(grep -abo 'hsqs' "$AI" | head -n 1 | cut -d: -f1)"
    [ -n "$AI_OFFSET" ] || die "无法在 AppImage 中定位 squashfs 魔数 hsqs"
    log "AppImage squashfs offset: $AI_OFFSET"
    unsquashfs -q -o "$AI_OFFSET" -d "$EXTRACT_DIR/squashfs-root" "$AI" >/tmp/unsquashfs.log 2>&1 || die "unsquashfs 解包失败（见 /tmp/unsquashfs.log）"
    log "AppImage runtime exec skipped under amd64 emulation; structure verified via squashfs offset $AI_OFFSET"
  fi
  [ -f "$EXTRACT_DIR/squashfs-root/deepseek-harness" ] || die "AppImage 内缺少 deepseek-harness 可执行文件"
  [ -x "$EXTRACT_DIR/squashfs-root/deepseek-harness" ] || die "AppImage 内 deepseek-harness 无执行权限"
  [ -f "$EXTRACT_DIR/squashfs-root/resources/app.asar" ] || die "AppImage 内缺少 resources/app.asar"
  assert_runtime_tree "$EXTRACT_DIR/squashfs-root/resources/runtime" "AppImage"
  AI_DESKTOP="$(find "$EXTRACT_DIR/squashfs-root" -maxdepth 5 -name '*.desktop' 2>/dev/null | head -n 1 || true)"
  if [ -n "$AI_DESKTOP" ]; then
    grep -q 'Development' "$AI_DESKTOP" && grep -q 'Utility' "$AI_DESKTOP" || log "WARN: AppImage desktop 文件 Categories 与契约不一致"
    log "AppImage desktop entry: ${AI_DESKTOP#$EXTRACT_DIR/squashfs-root/}"
  else
    log "WARN: AppImage 内未找到 .desktop 文件"
  fi
  log "AppImage extract ok: $(du -sh "$EXTRACT_DIR/squashfs-root" | awk '{print $1}')"
  rm -rf "$EXTRACT_DIR"
  queue_artifact "$AI" "${DSH_ARTIFACT_APPIMAGE:-deepseek-harness-${APP_VERSION}-${ARCH}.AppImage}" || die "queue AppImage failed"
fi

if [ "${#DEBS[@]}" -gt 0 ]; then
  DEB="${DEBS[0]}"
  log "deb control:"
  dpkg-deb -f "$DEB" Package Version Architecture Depends Recommends 2>/dev/null | sed 's/^/    /'
  [ "$(dpkg-deb -f "$DEB" Package)" = "deepseek-harness-linux" ] || die "deb 包名错误（期望 deepseek-harness-linux）"
  [ "$(dpkg-deb -f "$DEB" Architecture)" = "$DEB_EXPECT_ARCH" ] || die "deb 架构错误（期望 ${DEB_EXPECT_ARCH}）"
  DEB_LIST="/tmp/deb-list.txt"
  dpkg-deb -c "$DEB" > "$DEB_LIST" 2>/dev/null || die "dpkg-deb -c failed"
  grep -q 'chrome-sandbox$' "$DEB_LIST" || die "deb 内缺少 chrome-sandbox"
  grep -Eq '/(deepseek-harness|DeepSeek Harness)$' "$DEB_LIST" || die "deb 内缺少主可执行文件"
  DESKTOP_LINE="$(grep -E '/usr/share/applications/.*\.desktop$' "$DEB_LIST" | head -n 1 || true)"
  [ -n "$DESKTOP_LINE" ] || die "deb 内缺少 .desktop 文件"
  DEB_ROOT="/tmp/deb-root"
  rm -rf "$DEB_ROOT"; mkdir -p "$DEB_ROOT"
  dpkg-deb -x "$DEB" "$DEB_ROOT" || die "deb 解包失败"
  DEB_APP_DIR="$(find "$DEB_ROOT/opt" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | head -n 1 || true)"
  [ -n "$DEB_APP_DIR" ] || die "deb 内未找到 /opt/<app> 安装目录"
  log "deb install dir: ${DEB_APP_DIR#$DEB_ROOT}"
  assert_runtime_tree "$DEB_APP_DIR/resources/runtime" "deb"
  DESKTOP_FILE="$(find "$DEB_ROOT/usr/share/applications" -name '*.desktop' | head -n 1)"
  [ -n "$DESKTOP_FILE" ] || die "deb 中未找到 .desktop 文件"
  CATEGORIES_LINE="$(grep -E '^Categories=' "$DESKTOP_FILE" | head -n 1 || true)"
  printf '%s' "$CATEGORIES_LINE" | grep -q 'Development' || die "desktop 文件 Categories 缺少 Development（实际: $CATEGORIES_LINE）"
  printf '%s' "$CATEGORIES_LINE" | grep -q 'Utility' || die "desktop 文件 Categories 缺少 Utility（实际: $CATEGORIES_LINE）"
  grep -q '^StartupWMClass=DeepSeek Harness$' "$DESKTOP_FILE" || die "desktop 文件 StartupWMClass 不符合契约"
  log "deb desktop categories: $CATEGORIES_LINE"
  log "deb desktop entry ok: $(basename "$DESKTOP_FILE")"
  rm -rf "$DEB_ROOT"
  CTRL_DIR="/build/deb-control"; rm -rf "$CTRL_DIR"; mkdir -p "$CTRL_DIR"
  dpkg-deb -e "$DEB" "$CTRL_DIR" || die "deb control 提取失败"
  [ -f "$CTRL_DIR/postinst" ] || die "deb 内缺少 postinst"
  grep -q 'chrome-sandbox' "$CTRL_DIR/postinst" || die "postinst 未处理 chrome-sandbox"
  grep -Eq 'chmod[[:space:]]+4755' "$CTRL_DIR/postinst" || die "postinst 未设置 4755"
  grep -q 'usr/bin/deepseek-harness' "$CTRL_DIR/postinst" || die "postinst 未创建 /usr/bin/deepseek-harness 符号链接"
  log "deb postinst/chrome-sandbox ok"
  rm -rf "$CTRL_DIR"
  queue_artifact "$DEB" "${DSH_ARTIFACT_DEB:-deepseek-harness-${APP_VERSION}-${ARCH}.deb}" || die "queue deb failed"
fi

if [ "${#TARBALLS[@]}" -gt 0 ]; then
  TGZ="${TARBALLS[0]}"
  tar -tvzf "$TGZ" > /tmp/tarball-detail.txt 2>/dev/null || die "tar.gz 无法读取"
  grep -Eq 'resources/runtime/bin/dsh$' /tmp/tarball-detail.txt || die "tar.gz 内缺少 resources/runtime/bin/dsh"
  grep -Eq 'resources/runtime/node/bin/node$' /tmp/tarball-detail.txt || die "tar.gz 内缺少 resources/runtime/node/bin/node"
  grep -Eq 'resources/runtime/node_modules/@deepseek-ai/dsh/lib/bin.js$' /tmp/tarball-detail.txt || die "tar.gz 内缺少 dsh lib/bin.js"
  grep -Eq 'resources/app.asar$' /tmp/tarball-detail.txt || die "tar.gz 内缺少 resources/app.asar"
  grep -E 'resources/runtime/bin/dsh$' /tmp/tarball-detail.txt | grep -Eq '^-rwx' || die "tar.gz 内 runtime/bin/dsh 无执行权限"
  TAR_RUNTIME_SIZE="$(awk '/resources\/runtime\// {sum += $3} END {print sum + 0}' /tmp/tarball-detail.txt)"
  [ "$TAR_RUNTIME_SIZE" -ge "$RUNTIME_MIN_SIZE" ] || die "tar.gz 内 runtime 体积异常（$((TAR_RUNTIME_SIZE / 1048576))MiB < 下限 $((RUNTIME_MIN_SIZE / 1048576))MiB）"
  log "tar.gz entries: $(wc -l < /tmp/tarball-detail.txt)  runtime: $((TAR_RUNTIME_SIZE / 1048576))MiB  top: $(head -n 2 /tmp/tarball-detail.txt | awk '{print $NF}' | tr '\n' ' ')"
  queue_artifact "$TGZ" "${DSH_ARTIFACT_TARBALL:-deepseek-harness-linux-${APP_VERSION}-${ARCH}.tar.gz}" || die "queue tar.gz failed"
fi

check_asar "$OUTPUT"

[ "${#PENDING_SRC[@]}" -ge 1 ] || die "没有产出任何可交付文件"

# 所有校验通过后才复制到宿主 dist/，避免失败时留下半成品被误发。
N=0
for i in "${!PENDING_SRC[@]}"; do
  src="${PENDING_SRC[$i]}"
  name="${PENDING_NAME[$i]}"
  cp -f "$src" "$DIST_DIR/$name.tmp"
  size="$(stat -c%s "$DIST_DIR/$name.tmp")"
  [ "$size" -gt 1048576 ] || die "artifact too small: $name ($size bytes)"
  mv -f "$DIST_DIR/$name.tmp" "$DIST_DIR/$name"
  log "dist/$name  $((size / 1048576))MB"
  N=$((N + 1))
done

# ---- 5. SHA256SUMS / RELEASE.json -------------------------------------------
log "generating SHA256SUMS / RELEASE.json"
node "$PKG_ROOT/scripts/package/release-metadata.mjs" \
  --dist "$DIST_DIR" \
  --arch "$ARCH" \
  --artifact-arch "${DSH_ARTIFACT_ARCH:-$ARCH}" \
  --version "$APP_VERSION" \
  --dsh-version "$DSH_VERSION" \
  --node-version "$NODE_VERSION" \
  --electron-version "$ELECTRON_VERSION" \
  --builder-version "$BUILDER_VERSION" \
  --commit "$COMMIT" \
  --dirty "$COMMIT_DIRTY" \
  --built-at "$BUILT_AT" || die "release metadata generation failed"

log "done: $N artifact(s) in $DIST_DIR"
