#!/usr/bin/env bash
# runtime-inner.sh — runs INSIDE the builder container.
# Assembles /out/runtime for one architecture from /cache inputs.
set -euo pipefail

: "${ARCH:?}" "${NODE_VERSION:?}" "${NODE_ARCH:?}" "${DSH_VERSION:?}"
LEAN=${LEAN:-0}
SKIP_OFFICE=${SKIP_OFFICE:-0}
OUT=/out/runtime
STAGE=/stage

log() { printf '[inner] %s\n' "$*"; }

case "$ARCH" in
  arm64) WHEEL_ARCH=aarch64 ;;
  x64)   WHEEL_ARCH=x86_64 ;;
  *) echo "unsupported ARCH $ARCH" >&2; exit 2 ;;
esac

rm -rf "$OUT" "$STAGE"
mkdir -p "$OUT" "$STAGE"

# ---------------------------------------------------------------- 1. Node ---
TARBALL="/cache/node/node-v${NODE_VERSION}-linux-${NODE_ARCH}.tar.xz"
[ -f "$TARBALL" ] || { echo "missing node tarball: $TARBALL" >&2; exit 2; }
log "extracting $(basename "$TARBALL")"
tar -xJf "$TARBALL" -C /tmp
SRC="/tmp/node-v${NODE_VERSION}-linux-${NODE_ARCH}"
mkdir -p "$OUT/node"
cp -a "$SRC/bin" "$OUT/node/bin"
cp -a "$SRC/lib" "$OUT/node/lib"
cp -a "$SRC/LICENSE" "$OUT/node/LICENSE"
rm -rf "$OUT/node/include" "$OUT/node/share"
rm -rf "$OUT/node/lib/node_modules/npm/docs" "$OUT/node/lib/node_modules/npm/man"
printf 'v%s\n' "$NODE_VERSION" > "$OUT/node/VERSION"
log "node: $("$OUT/node/bin/node" -v)"
# ------------------------------------------------------- 2. dsh npm install ---
export PATH="$OUT/node/bin:$PATH"
export npm_config_cache=/root/.npm
cat > "$STAGE/package.json" <<EOF
{
  "name": "dsh-linux-runtime",
  "version": "0.0.0",
  "private": true,
  "description": "Offline runtime assembly for DeepSeek Harness (Linux)",
  "dependencies": {
    "@deepseek-ai/dsh": "$DSH_VERSION"
  }
}
EOF
cd "$STAGE"
log "npm $(npm --version): npm install --omit=dev @deepseek-ai/dsh@$DSH_VERSION"
npm install --omit=dev --no-audit --no-fund --no-progress --loglevel=info 2>&1 | tee /tmp/npm-install.log
[ -f "$STAGE/node_modules/@deepseek-ai/dsh/lib/bin.js" ] || {
  echo "dsh entry missing after install; package tree:" >&2
  ls -la "$STAGE/node_modules/@deepseek-ai" >&2 || true
  exit 3
}
mv "$STAGE/node_modules" "$OUT/node_modules"
cp "$STAGE/package-lock.json" /out/package-lock.json

# npm 11 blocks lifecycle scripts (allowScripts). @deepseek-ai/dsh-subprocess-local
# only chmods node-pty's prebuilt spawn-helper (a no-op on Linux, which ships no
# spawn-helper), but replicate it so the runtime matches a script-enabled install.
if [ -d "$OUT/node_modules/node-pty" ]; then
  find "$OUT/node_modules/node-pty" -type f -name 'spawn-helper' -exec chmod 755 {} + 2>/dev/null || true
fi
log "dsh installed: $(node -p "require('$OUT/node_modules/@deepseek-ai/dsh/package.json').version")"

# --------------------------------------------------------------- 3. prune ---
log "pruning"
LEAN="$LEAN" bash /scripts/prune-runtime.sh "$OUT" "$ARCH" /out/prune-stats.txt || {
  echo "prune failed" >&2; exit 4
}

# ------------------------------------------------------- 4. office-skills ---
OFFICE_VER=""
if [ "$SKIP_OFFICE" != 1 ]; then
  WHL=$(ls /cache/pypi/*manylinux*_"$WHEEL_ARCH".whl 2>/dev/null | head -1 || true)
  if [ -n "$WHL" ] && [ -f "$WHL" ]; then
    OFFICE_VER=$(basename "$WHL" | sed -E 's/^deepseek_harness_runtime_bin-([^-]+)-.*/\1/')
    log "office-skills from $(basename "$WHL") (version $OFFICE_VER)"
    rm -rf /tmp/whl && mkdir -p /tmp/whl
    unzip -q "$WHL" -d /tmp/whl
    SKILLS=$(find /tmp/whl -type d -name office-skills -path '*runtime*' | head -1)
    if [ -n "$SKILLS" ] && [ -d "$SKILLS" ]; then
      cp -a "$SKILLS" "$OUT/office-skills"
      log "office-skills: $(find "$OUT/office-skills" -name SKILL.md | wc -l) SKILL.md, $(du -sh "$OUT/office-skills" | cut -f1)"
    else
      log "WARN: office-skills not found inside wheel"
    fi
    rm -rf /tmp/whl
  else
    log "WARN: no wheel for $WHEEL_ARCH in /cache/pypi, skipping office-skills"
  fi
else
  log "office-skills skipped (--skip-office-skills)"
fi
# ----------------------------------------------------------- 5. bin/dsh -----
mkdir -p "$OUT/bin"
cat > "$OUT/bin/dsh" <<'LAUNCHER'
#!/bin/sh
# dsh launcher — offline Linux runtime wrapper.
# Resolves symlinks so it works from PATH symlinks and any cwd.
set -eu
self=$0
while [ -h "$self" ]; do
  dir=$(cd -P "$(dirname "$self")" >/dev/null 2>&1 && pwd)
  link=$(readlink "$self")
  case $link in
    /*) self=$link ;;
    *) self=$dir/$link ;;
  esac
done
root=$(cd -P "$(dirname "$self")/.." >/dev/null 2>&1 && pwd)
exec "$root/node/bin/node" "$root/node_modules/@deepseek-ai/dsh/lib/bin.js" "$@"
LAUNCHER
chmod 755 "$OUT/bin/dsh"
[ -x "$OUT/bin/dsh" ] || { echo "bin/dsh not executable" >&2; exit 5; }

# ---------------------------------------------------------- 6. licenses -----
mkdir -p "$OUT/licenses"
cp "$OUT/node/LICENSE" "$OUT/licenses/Node.js-LICENSE"
if [ -f "$OUT/node/lib/node_modules/npm/LICENSE" ]; then
  cp "$OUT/node/lib/node_modules/npm/LICENSE" "$OUT/licenses/npm-LICENSE"
fi
if [ -f "$OUT/node_modules/@deepseek-ai/dsh/LICENSE" ]; then
  cp "$OUT/node_modules/@deepseek-ai/dsh/LICENSE" "$OUT/licenses/dsh-LICENSE"
fi
if [ -n "$OFFICE_VER" ]; then
  WHL_PATH="/cache/pypi/deepseek_harness_runtime_bin-$OFFICE_VER-py3-none-manylinux_2_28_$WHEEL_ARCH.whl"
  if [ -f "$WHL_PATH" ]; then
    rm -rf /tmp/whl-lic && mkdir -p /tmp/whl-lic
    unzip -q -j "$WHL_PATH" '*dist-info*' -d /tmp/whl-lic >/dev/null 2>&1 || true
    for f in /tmp/whl-lic/LICENSE* /tmp/whl-lic/NOTICE* /tmp/whl-lic/METADATA; do
      if [ -f "$f" ]; then cp "$f" "$OUT/licenses/office-skills-$(basename "$f")"; fi
    done
    rm -rf /tmp/whl-lic
  fi
fi
# third-party inventory (name@version + license) from the shipped tree
node <<'JS'
const fs = require('fs');
const path = require('path');
const root = '/out/runtime/node_modules';
const pkgs = new Map();
function scanDir(dir) {
  let entries;
  try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch (e) { return; }
  for (const e of entries) {
    if (!e.isDirectory() && !e.isSymbolicLink()) continue;
    if (e.name === '.bin' || e.name === '.cache' || e.name === 'node_modules') continue;
    const p = path.join(dir, e.name);
    if (e.name.startsWith('@')) { scanDir(p); continue; }
    try {
      const meta = JSON.parse(fs.readFileSync(path.join(p, 'package.json'), 'utf8'));
      const lic = typeof meta.license === 'string' ? meta.license
        : (meta.license && meta.license.type) ? meta.license.type : 'UNKNOWN';
      pkgs.set(meta.name + '@' + meta.version, lic);
    } catch (e) { /* not a package dir */ }
  }
}
scanDir(root);
const names = Array.from(pkgs.keys()).sort();
const lines = [
  '# Third-party components bundled in this runtime',
  '',
  'This unofficial Linux runtime redistributes the following npm packages',
  'unmodified as installed from the npm registry. Full license texts and',
  'package metadata are retained inside node_modules/<pkg>/.',
  '',
  '| package | license |',
  '| --- | --- |',
];
for (const n of names) lines.push('| ' + n + ' | ' + pkgs.get(n) + ' |');
lines.push('', 'Total packages: ' + names.length, '');
fs.writeFileSync('/out/runtime/licenses/THIRD-PARTY.md', lines.join('\n'));
console.log('[inner] third-party inventory: ' + names.length + ' packages');
JS
# --------------------------------------------------------- 7. version.json ---
BUILT_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
NODE_FULL=$(node -v | sed 's/^v//')
NPM_VER=$(npm --version)
RT_BYTES=$(du -sb "$OUT" | cut -f1)
NM_BYTES=$(du -sb "$OUT/node_modules" | cut -f1)
NODE_BYTES=$(du -sb "$OUT/node" | cut -f1)
PKG_COUNT=$(find "$OUT/node_modules" -mindepth 2 -maxdepth 3 -name package.json -type f | wc -l)
DSH_VER=$(node -p "require('$OUT/node_modules/@deepseek-ai/dsh/package.json').version")
if [ -n "$OFFICE_VER" ]; then
  OFFICE_JSON="{\"version\":\"$OFFICE_VER\",\"source\":\"PyPI deepseek-harness-runtime-bin\"}"
else
  OFFICE_JSON="null"
fi
cat > "$OUT/version.json" <<EOF
{
  "dsh": "$DSH_VER",
  "node": "$NODE_FULL",
  "npm": "$NPM_VER",
  "arch": "$ARCH",
  "platform": "linux",
  "builtAt": "$BUILT_AT",
  "builder": "node:24-bookworm (Debian 12, glibc 2.36)",
  "nodeDistribution": "node-v$NODE_VERSION-linux-$NODE_ARCH.tar.xz (nodejs.org, sha256 verified)",
  "officeSkills": $OFFICE_JSON,
  "pruned": "safe (maps, package docs/tests, non-arch binaries); lean=$LEAN",
  "packageCount": $PKG_COUNT,
  "sizeBytes": {
    "runtime": $RT_BYTES,
    "nodeModules": $NM_BYTES,
    "node": $NODE_BYTES
  }
}
EOF
node -e "JSON.parse(require('fs').readFileSync('$OUT/version.json','utf8')); console.log('[inner] version.json valid')"
# ---------------------------------------------------------- 8. stats file ----
{
  echo "== runtime stats (assembled) =="
  echo "arch=$ARCH node=$NODE_FULL npm=$NPM_VER dsh=$DSH_VER officeSkills=${OFFICE_VER:-none}"
  echo "runtime:      $(du -sh "$OUT" | cut -f1) (apparent $(du -sh --apparent-size "$OUT" | cut -f1))"
  echo "node_modules: $(du -sh "$OUT/node_modules" | cut -f1) (apparent $(du -sh --apparent-size "$OUT/node_modules" | cut -f1))"
  echo "node:         $(du -sh "$OUT/node" | cut -f1)"
  echo "office-skills: $(du -sh "$OUT/office-skills" 2>/dev/null | cut -f1 || echo 0)"
  echo "licenses:     $(du -sh "$OUT/licenses" | cut -f1)"
  echo "files:        $(find "$OUT" | wc -l)"
  echo
  echo "== top 20 largest packages (apparent) =="
  du -s --apparent-size "$OUT/node_modules"/* "$OUT/node_modules"/@*/* 2>/dev/null | sort -rn | head -20 | awk '{printf "%9.1f MiB  %s\n", $1/1024, $2}'
  echo
  echo "== prune stats =="
  cat /out/prune-stats.txt 2>/dev/null || true
} | tee /out/stats.txt

log "assembly complete: $OUT"
