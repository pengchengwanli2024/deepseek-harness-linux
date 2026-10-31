#!/usr/bin/env bash
# prune-runtime.sh <runtime-dir> <arch> [stats-file]
#
# Remove files that are useless for a Linux/<arch> runtime:
#   * source maps
#   * package-root README / CHANGELOG markdown (SKILL.md & assets are preserved)
#   * docs / test / tests / __tests__ / examples / benchmarks / coverage dirs
#     (paths under assets/, skills/ and templates/ are preserved)
#   * non-<arch> native prebuilds (node-pty prebuilds, sherpa-onnx-*, koffi,
#     sharp, ripgrep, libreoffice-kit) and other platforms' counterparts
#   * Windows / macOS binaries (*.exe *.dll *.pdb *.lib *.exp *.dylib)
#
# Idempotent. Safe to run twice.
set -uo pipefail

RT=${1:?usage: prune-runtime.sh <runtime-dir> <arch> [stats-file]}
ARCH=${2:?usage: prune-runtime.sh <runtime-dir> <arch> [stats-file]}
STATS=${3:-/dev/stdout}
NM="$RT/node_modules"
LEAN=${LEAN:-0}

case "$ARCH" in
  arm64) OTHER_ARCH="x64" ;;
  x64)   OTHER_ARCH="arm64" ;;
  *) echo "[prune] unsupported arch: $ARCH" >&2; exit 2 ;;
esac

[ -d "$NM" ] || { echo "[prune] node_modules not found under $RT" >&2; exit 2; }

bytes() { du -sb "$1" 2>/dev/null | cut -f1; }
count() { find "$1" -mindepth 1 2>/dev/null | wc -l | tr -d ' '; }

BEFORE=$(bytes "$NM")
N_BEFORE=$(count "$NM")

exec 3>>"$STATS"
log() { printf '[prune] %s\n' "$*"; printf '%s\n' "$*" >&3; }

log "arch=$ARCH lean=$LEAN node_modules_before=${BEFORE}B files_before=$N_BEFORE"

removed=0
step() {
  local label="$1"
  shift
  local b a delta
  b=$(bytes "$NM")
  "$@"
  a=$(bytes "$NM")
  delta=$(( b - a ))
  removed=$(( removed + delta ))
  log "$label: removed $(( delta / 1024 )) KiB"
}
noop() { :; }

# 1. source maps ------------------------------------------------------------
source_maps() {
  find "$NM" -name '*.map' -type f -delete
}
step "source maps (*.map)" source_maps

# 2. package-root README/CHANGELOG -----------------------------------------
package_root_md() {
  find "$NM" -mindepth 2 -maxdepth 3 -type f \
    \( -iname 'README*.md' -o -iname 'CHANGELOG*.md' -o -iname 'HISTORY*.md' -o -iname 'CONTRIBUTING*.md' \) \
    -delete
}
step "package-root markdown" package_root_md

# 3. docs / tests / examples ----------------------------------------------
doc_test_dirs() {
  find "$NM" -type d \
    \( -name docs -o -name test -o -name tests -o -name __tests__ -o -name examples \
       -o -name benchmarks -o -name coverage \) \
    -not -path '*/assets/*' -not -path '*/skills/*' -not -path '*/templates/*' \
    -prune -exec rm -rf {} +
}
step "docs/test/examples dirs" doc_test_dirs

# 4. node-pty: keep only prebuilds/linux-<arch> ----------------------------
pty_prebuilds() {
  local d="$NM/node-pty/prebuilds"
  [ -d "$d" ] || return 0
  local keep="linux-$ARCH"
  local tmp; tmp=$(mktemp -d)
  for p in "$d"/*; do
    [ -e "$p" ] || continue
    if [ "$(basename "$p")" = "$keep" ]; then cp -a "$p" "$tmp/"; fi
  done
  rm -rf "$d"
  mkdir -p "$d"
  cp -a "$tmp/." "$d/" 2>/dev/null || true
  rm -rf "$tmp"
}
step "node-pty non-linux prebuilds" pty_prebuilds

# 5. other platform packages (targeted, never wildcard package names) ------
platform_pkgs() {
  local nm="$NM" dir base
  # node_modules/<name> and node_modules/@scope/<name>
  for dir in "$nm"/* "$nm"/@*/*; do
    [ -d "$dir" ] || continue
    base=$(basename "$dir")
    case "$base" in
      sherpa-onnx-*)
        case "$base" in sherpa-onnx-linux-"$ARCH"|sherpa-onnx-node) ;; *) [ -d "$dir" ] && rm -rf "$dir" ;; esac ;;
      koffi-*)
        # @koromix/koffi-<platform>-<arch>
        case "$base" in koffi-linux-"$ARCH") ;; *) [ -d "$dir" ] && rm -rf "$dir" ;; esac ;;
      sharp-libvips-*|sharp-*)
        case "$base" in *linux-$ARCH*) ;; *) [ -d "$dir" ] && rm -rf "$dir" ;; esac ;;
      ripgrep-*)
        case "$base" in ripgrep-linux-"$ARCH") ;; *) [ -d "$dir" ] && rm -rf "$dir" ;; esac ;;
      libreoffice-kit-*)
        case "$base" in *linux-$ARCH*|libreoffice-kit-wasm) ;; *) [ -d "$dir" ] && rm -rf "$dir" ;; esac ;;
    esac
    # drop non-arch ~linux-<other>~ prebuilds dirs that live inside packages
    if [ -d "$dir/prebuilds" ]; then
      for p in "$dir"/prebuilds/*; do
        [ -e "$p" ] || continue
        case "$(basename "$p")" in
          *linux-$ARCH*) ;;
          *) rm -rf "$p" ;;
        esac
      done
    fi
  done
  # koffi musl binary next to the glibc one inside @koromix/koffi-<arch>
  [ -d "$nm/@koromix/koffi-linux-$ARCH" ] && rm -rf "$nm/@koromix/koffi-linux-$ARCH"/musl_*
  # remove the *other* arch's tirpc/pty copies under node-pty prebuilds (defensive)
  [ -d "$nm/node-pty/prebuilds/linux-$OTHER_ARCH" ] && rm -rf "$nm/node-pty/prebuilds/linux-$OTHER_ARCH"
  return 0
}
step "other-platform native packages" platform_pkgs

# 6. Windows / macOS binaries ---------------------------------------------
win_mac_bins() {
  find "$NM" -type f \( -iname '*.exe' -o -iname '*.dll' -o -iname '*.pdb' \
    -o -iname '*.lib' -o -iname '*.exp' -o -iname '*.dylib' \) -delete
}
step "windows/macos binaries" win_mac_bins

# 7. optional lean mode: drop office wasm (office export/render degrade) --
if [ "$LEAN" = 1 ]; then
  lean_office() {
    rm -rf "$NM/@deepseek-ai/libreoffice-kit-wasm/assets" 2>/dev/null || true
    find "$NM/@deepseek-ai/libreoffice-kit-wasm" -maxdepth 1 -type f -name '*.wasm' -delete 2>/dev/null || true
  }
  step "lean: libreoffice-kit-wasm assets" lean_office
fi

AFTER=$(bytes "$NM")
N_AFTER=$(count "$NM")
log "node_modules_after=${AFTER}B files_after=$N_AFTER"
log "total_removed_$(( (BEFORE - AFTER) / 1048576 ))MiB ($(( BEFORE - AFTER ))B), files_removed=$(( N_BEFORE - N_AFTER ))"
exec 3>&-
printf '[prune] done: %s -> %s bytes (%s MiB removed)\n' "$BEFORE" "$AFTER" "$(( (BEFORE - AFTER) / 1048576 ))" >&2
exit 0
