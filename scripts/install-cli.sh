#!/usr/bin/env bash
# DeepSeek Harness (Linux) — CLI installer for desktops and headless servers.
#
# Installs an isolated Node.js runtime (unless a compatible system Node exists)
# and @deepseek-ai/dsh, then provides:
#   dsh-linux   -> the dsh CLI (web/headless/tui/plugin ...)
#   dsh-web     -> dsh web launcher (opens the browser by default)
#
# Usage:
#   bash scripts/install-cli.sh [--prefix DIR] [--version VER] [--system-node] [--uninstall]
# Defaults: prefix=$HOME/.local, version=0.2.1-rc.5
set -euo pipefail

PREFIX="$HOME/.local"
DSH_VERSION="0.2.1-rc.5"
APP_NAME="deepseek-harness"
USE_SYSTEM_NODE=0
UNINSTALL=0
NODE_VERSION="${NODE_VERSION:-24.22.2}"

while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) PREFIX="${2:?}"; shift 2 ;;
    --prefix=*) PREFIX="${1#*=}"; shift ;;
    --version) DSH_VERSION="${2:?}"; shift 2 ;;
    --version=*) DSH_VERSION="${1#*=}"; shift ;;
    --system-node) USE_SYSTEM_NODE=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

PREFIX="${PREFIX/#\~/$HOME}"
APP_DIR="$PREFIX/lib/$APP_NAME"
BIN_DIR="$PREFIX/bin"
DESKTOP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/$APP_NAME"

die() { echo "error: $*" >&2; exit 1; }
info() { printf '==> %s\n' "$*"; }

if [ "$UNINSTALL" -eq 1 ]; then
  info "Removing $APP_NAME from $PREFIX"
  rm -rf "$APP_DIR"
  rm -f "$BIN_DIR/dsh-linux" "$BIN_DIR/dsh-web"
  rm -f "$DESKTOP_DIR/dsh-web.desktop"
  echo "Removed. User data kept at: $CONFIG_DIR"
  exit 0
fi

ARCH_RAW="$(uname -m)"
case "$ARCH_RAW" in
  x86_64|amd64) NODE_ARCH="x64" ;;
  aarch64|arm64) NODE_ARCH="arm64" ;;
  *) die "unsupported CPU architecture: $ARCH_RAW" ;;
esac
[ "$(uname -s)" = "Linux" ] || die "this installer targets Linux"

mkdir -p "$APP_DIR" "$BIN_DIR" "$DESKTOP_DIR"

need_download_node=1
NODE_BIN=""
if [ "$USE_SYSTEM_NODE" -eq 1 ]; then
  NODE_BIN="$(command -v node || true)"
  [ -n "$NODE_BIN" ] || die "--system-node was given but node was not found in PATH"
  need_download_node=0
elif command -v node >/dev/null 2>&1; then
  sys_major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
  sys_minor="$(node -p 'process.versions.node.split(".")[1]' 2>/dev/null || echo 0)"
  if [ "$sys_major" -ge 24 ] || { [ "$sys_major" -eq 22 ] && [ "$sys_minor" -ge 19 ]; }; then
    NODE_BIN="$(command -v node)"
    need_download_node=0
    info "Using system Node.js $(node --version) at $NODE_BIN"
  else
    info "System Node.js $(node --version 2>/dev/null || echo unknown) is too old; downloading Node.js $NODE_VERSION"
  fi
fi

if [ "$need_download_node" -eq 1 ]; then
  info "Installing Node.js v$NODE_VERSION ($NODE_ARCH) into $APP_DIR/node"
  TARBALL="node-v$NODE_VERSION-linux-$NODE_ARCH.tar.xz"
  URL="https://nodejs.org/dist/v$NODE_VERSION/$TARBALL"
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 2 -o "$TMP/$TARBALL" "$URL"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$TMP/$TARBALL" "$URL"
  else
    die "curl or wget is required to download Node.js"
  fi
  rm -rf "$APP_DIR/node"
  mkdir -p "$APP_DIR/node"
  tar -xJf "$TMP/$TARBALL" -C "$APP_DIR/node" --strip-components=1
  NODE_BIN="$APP_DIR/node/bin/node"
  [ -x "$NODE_BIN" ] || die "Node.js extraction failed"
  info "Node.js $("$NODE_BIN" --version) installed"
fi

NODE_DIR="$(dirname "$NODE_BIN")"
case ":$PATH:" in
  *":$NODE_DIR:"*) ;;
  *) PATH="$NODE_DIR:$PATH" ;;
esac
export PATH
NPM_BIN="$(command -v npm || true)"
[ -n "$NPM_BIN" ] || die "npm not found (expected next to $NODE_BIN)"

info "Installing @deepseek-ai/dsh@$DSH_VERSION (production deps)"
NPM_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/dsh-linux/npm"
mkdir -p "$NPM_CACHE" "$APP_DIR"
if [ ! -f "$APP_DIR/package.json" ]; then
  ( cd "$APP_DIR" && "$NPM_BIN" init -y >/dev/null )
fi
( cd "$APP_DIR" && "$NPM_BIN" install "@deepseek-ai/dsh@$DSH_VERSION" --omit=dev --no-audit --no-fund --cache "$NPM_CACHE" )

DSH_ENTRY="$APP_DIR/node_modules/@deepseek-ai/dsh/lib/bin.js"
[ -f "$DSH_ENTRY" ] || die "dsh entry not found after install: $DSH_ENTRY"

cat > "$BIN_DIR/dsh-linux" <<'WRAPPER'
#!/usr/bin/env bash
set -euo pipefail
SELF="$(readlink -f "$0")"
APP_DIR="$(cd "$(dirname "$SELF")/../lib/deepseek-harness" && pwd)"
export DSH_HOME="${DSH_HOME:-$HOME/.config/deepseek-harness/dsh-home}"
mkdir -p "$DSH_HOME"
if [ -x "$APP_DIR/node/bin/node" ]; then
  NODE_BIN="$APP_DIR/node/bin/node"
else
  NODE_BIN="$(command -v node)"
fi
exec "$NODE_BIN" "$APP_DIR/node_modules/@deepseek-ai/dsh/lib/bin.js" "$@"
WRAPPER
chmod +x "$BIN_DIR/dsh-linux"

cat > "$BIN_DIR/dsh-web" <<'WRAPPER'
#!/usr/bin/env bash
set -euo pipefail
SELF="$(readlink -f "$0")"
APP_DIR="$(cd "$(dirname "$SELF")/../lib/deepseek-harness" && pwd)"
export DSH_HOME="${DSH_HOME:-$HOME/.config/deepseek-harness/dsh-home}"
mkdir -p "$DSH_HOME"
if [ -x "$APP_DIR/node/bin/node" ]; then
  NODE_BIN="$APP_DIR/node/bin/node"
else
  NODE_BIN="$(command -v node)"
fi
exec "$NODE_BIN" "$APP_DIR/node_modules/@deepseek-ai/dsh/lib/bin.js" web "$@"
WRAPPER
chmod +x "$BIN_DIR/dsh-web"

cat > "$DESKTOP_DIR/dsh-web.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=DeepSeek Harness (Web UI)
Comment=Start the DSH Web UI and open it in the browser
Exec=$BIN_DIR/dsh-web
Terminal=true
Icon=utilities-terminal
Categories=Development;Utility;
DESKTOP

info "Installed:"
echo "    $BIN_DIR/dsh-linux   (CLI: web/headless/tui/plugin ...)"
echo "    $BIN_DIR/dsh-web     (starts the Web UI; add --no-open for headless servers)"
echo
echo "Add $BIN_DIR to PATH if needed, then run: dsh-web"
echo "User data (DSH_HOME) defaults to: $CONFIG_DIR/dsh-home"
