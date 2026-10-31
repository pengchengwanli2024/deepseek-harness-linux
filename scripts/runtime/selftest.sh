#!/usr/bin/env bash
# selftest.sh <runtime-dir> [label]
# Verifies a dsh Linux runtime tree (assembled in-container, or exported+mounted read-only).
set -uo pipefail
RT=${1:?usage: selftest.sh <runtime-dir> [label]}
LABEL=${2:-runtime}
ARCH=${ARCH:-$(uname -m)}
DSH_HOME_DIR="/tmp/dshhome-$LABEL"
WEBLOG=/tmp/web.log
CJ=/tmp/cookies.txt
PAGE=/tmp/page.html
FAILS=0
ok()   { printf 'PASS  %s\n' "$*"; }
bad()  { printf 'FAIL  %s\n' "$*"; FAILS=$((FAILS+1)); }
note() { printf '      %s\n' "$*"; }
sec()  { printf '\n--- %s ---\n' "$*"; }

sec "environment"
echo "date:      $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "uname:     $(uname -m) $(uname -s) $(uname -r)"
echo "runtime:   $RT"
echo "label:     $LABEL"
echo "network:   $(ip route 2>/dev/null | head -3 | tr '\n' ' ' || echo 'none')"

sec "structure"
for p in bin/dsh node/bin/node node/bin/npm node/lib/node_modules/npm/package.json \
         node/LICENSE node_modules/@deepseek-ai/dsh/lib/bin.js \
         node_modules/@deepseek-ai/dsh/LICENSE licenses version.json; do
  if [ -e "$RT/$p" ]; then ok "exists $p"; else bad "missing $p"; fi
done
if [ -x "$RT/bin/dsh" ]; then ok "bin/dsh is executable"; else bad "bin/dsh is not executable"; fi
if [ -d "$RT/office-skills" ]; then
  ok "office-skills present ($(find "$RT/office-skills" -name SKILL.md | wc -l) SKILL.md)"
else
  note "office-skills absent (optional component)"
fi

sec "versions"
V=$(DSH_HOME="$DSH_HOME_DIR" "$RT/bin/dsh" --version 2>&1 || true)
echo "bin/dsh --version          => $V"
case "$V" in
  *0.2.1-rc.5*) ok "dsh version is 0.2.1-rc.5" ;;
  *) bad "unexpected dsh version: $V" ;;
esac
NV=$("$RT/node/bin/node" -v 2>&1 || true)
echo "node/bin/node -v           => $NV"
case "$NV" in
  v24.*) ok "node version $NV" ;;
  *) bad "unexpected node version: $NV" ;;
esac
NPMV=$(PATH="$RT/node/bin:$PATH" "$RT/node/bin/npm" --version 2>&1 || true)
echo "node/bin/npm --version     => $NPMV"
[ -n "$NPMV" ] && ok "bundled npm runs" || bad "bundled npm failed"
ln -sfn "$RT/bin/dsh" /usr/local/bin/dsh-selftest
V2=$(DSH_HOME="$DSH_HOME_DIR" dsh-selftest --version 2>&1 || true)
echo "PATH symlink dsh --version => $V2"
[ "$V2" = "$V" ] && ok "launcher works via PATH symlink" || bad "launcher broken via symlink"

sec "native modules"
cat > /tmp/native-test.js <<'JS'
const RT = process.argv[2];
function t(name, fn) {
  try { console.log('PASS  native module ' + name + ' (' + fn() + ')'); }
  catch (e) { console.log('FAIL  native module ' + name + ': ' + e.message); }
}
t('node-pty', () => {
  const pty = require(RT + '/node_modules/node-pty');
  const p = pty.spawn('/bin/echo', ['ok'], { cols: 80, rows: 24 });
  const pid = p.pid; p.kill();
  return 'spawn pid=' + pid;
});
t('koffi', () => {
  const k = require(RT + '/node_modules/koffi');
  return 'version=' + k.version;
});
t('sharp', () => {
  const s = require(RT + '/node_modules/sharp');
  return 'libvips=' + s.versions.vips;
});
t('sherpa-onnx-node', () => {
  const s = require(RT + '/node_modules/sherpa-onnx-node');
  return 'exports=' + Object.keys(s).length;
});
t('@vscode/ripgrep', () => {
  const fs = require('fs');
  const rg = require(RT + '/node_modules/@vscode/ripgrep');
  if (!rg.rgPath || !fs.existsSync(rg.rgPath)) throw new Error('rgPath missing: ' + rg.rgPath);
  return 'rg=' + rg.rgPath;
});
JS
NATIVE_OUT=$("$RT/node/bin/node" /tmp/native-test.js "$RT" 2>&1 || true)
echo "$NATIVE_OUT"
if printf '%s\n' "$NATIVE_OUT" | grep -q '^FAIL'; then
  bad "one or more native modules failed to load"
else
  ok "all native modules load"
fi
sec "dsh web startup"
rm -rf "$DSH_HOME_DIR" /tmp/dsh-home-home
mkdir -p "$DSH_HOME_DIR" /tmp/dsh-home-home
rm -f "$WEBLOG" "$CJ" "$PAGE"
(
  cd /tmp
  DSH_HOME="$DSH_HOME_DIR" HOME=/tmp/dsh-home-home \
    setsid "$RT/bin/dsh" web --no-open --host 127.0.0.1 --port 0 > "$WEBLOG" 2>&1 &
  echo $! > /tmp/web.pid
)
START=$(date +%s)
URL=""
i=0
while [ $i -lt 60 ]; do
  URL=$(grep -oE 'https?://(127\.0\.0\.1|localhost):[0-9]+/\?token=[A-Za-z0-9_-]+' "$WEBLOG" 2>/dev/null | head -1 || true)
  [ -n "$URL" ] && break
  sleep 0.5
  i=$((i+1))
done
ELAPSED=$(( $(date +%s) - START ))
if [ -n "$URL" ]; then
  ok "token URL printed after ${ELAPSED}s: $URL"
  [ "$ELAPSED" -le 10 ] && ok "startup within 10s" || note "startup took ${ELAPSED}s (>10s, headroom for emulated builds)"
else
  bad "no token URL within 30s"
  echo "--- web log ---"; cat "$WEBLOG" 2>/dev/null || true
fi

if [ -n "$URL" ]; then
  CODE_SIZE=$(curl -sS -L -c "$CJ" -b "$CJ" -o "$PAGE" -w '%{http_code} %{size_download}' "$URL" 2>&1 || echo "curl_error")
  echo "curl -L (cookie jar) => $CODE_SIZE"
  CODE=${CODE_SIZE%% *}
  SIZE=${CODE_SIZE##* }
  if [ "$CODE" = 200 ]; then ok "GET token URL returns 200"; else bad "GET token URL returns $CODE"; fi
  case "$SIZE" in
    ''|*[!0-9]*) bad "page size not numeric: $SIZE" ;;
    *) if [ "$SIZE" -gt 5000 ]; then ok "page size ${SIZE} bytes"; else bad "page too small: $SIZE"; fi ;;
  esac
  if grep -qi '<title>DeepSeek Harness</title>' "$PAGE"; then
    ok "page contains <title>DeepSeek Harness</title>"
  else
    bad "page title not found"
    head -c 200 "$PAGE" 2>/dev/null; echo
  fi
  ROOT_URL=$(printf '%s' "$URL" | sed 's/?.*//')
  CODE2=$(curl -sS -o /dev/null -w '%{http_code}' -b "$CJ" "$ROOT_URL" 2>/dev/null || true)
  if [ "$CODE2" = 200 ]; then ok "cookie-authenticated re-request returns 200"; else note "re-request without token => $CODE2"; fi
fi

sec "web log error scan"
if grep -Ei 'failed to import|ERR_MODULE_NOT_FOUND|Cannot find module|Cannot find package|failed to load plugin|plugin load error|SyntaxError' "$WEBLOG" > /tmp/import-errors.txt 2>/dev/null; then
  bad "import/plugin errors found in /tmp/web.log"
  head -20 /tmp/import-errors.txt
else
  ok "no import/plugin errors in /tmp/web.log"
fi
echo "web log ($(wc -l < "$WEBLOG" 2>/dev/null || echo 0) lines):"
head -40 "$WEBLOG" 2>/dev/null || true

PID=$(cat /tmp/web.pid 2>/dev/null || true)
if [ -n "$PID" ]; then
  kill -TERM -"$PID" 2>/dev/null || kill -TERM "$PID" 2>/dev/null || true
  sleep 1
  kill -KILL -"$PID" 2>/dev/null || true
fi
sleep 1
LEFTOVER=$(pgrep -af "$RT/node/bin/node .*lib/bin.js" 2>/dev/null | head -5 || true)
if [ -z "$LEFTOVER" ]; then
  ok "no leftover dsh process after shutdown"
else
  bad "leftover dsh processes"
  echo "$LEFTOVER"
  pkill -f "$RT/bin/dsh" 2>/dev/null || true
  pkill -f "$RT/node/bin/node .*lib/bin.js" 2>/dev/null || true
fi

sec "pruning checks"
if [ -d "$RT/node_modules/node-pty/prebuilds" ]; then
  echo "node-pty prebuilds: $(ls "$RT/node_modules/node-pty/prebuilds" | tr '\n' ' ')"
  if [ "$(ls "$RT/node_modules/node-pty/prebuilds")" = "linux-$ARCH" ]; then
    ok "node-pty prebuilds contain only linux-$ARCH"
  else
    bad "node-pty prebuilds contain foreign platforms"
  fi
fi
for pat in '*.exe' '*.dll' '*.pdb' '*.dylib'; do
  N=$(find "$RT/node_modules" -name "$pat" -type f 2>/dev/null | wc -l)
  if [ "$N" = 0 ]; then ok "no $pat files"; else bad "$N $pat files remain"; fi
done
# sherpa-onnx-node / koffi / sharp are JS wrapper packages with no platform
# suffix (native payload lives in *-linux-<arch> siblings). Two dsh packages are
# pure-JS Windows support code loaded conditionally at runtime and are kept on
# purpose: @deepseek-ai/dsh-win32-process, @deepseek-ai/dsh-sandbox-windows-acl.
if [ "$ARCH" = "arm64" ]; then OTHER_ARCH="x64"; else OTHER_ARCH="arm64"; fi
FOREIGN=$(find "$RT/node_modules" -maxdepth 3 -type d 2>/dev/null \
  | grep -E '(darwin|win32|windows|android|freebsd|linuxmusl)' \
  | grep -vE '/@deepseek-ai/dsh-(win32-process|sandbox-windows-acl)(/|$)' || true)
OTHERARCH=$(find "$RT/node_modules" -maxdepth 3 -type d -name "*-linux-$OTHER_ARCH*" 2>/dev/null || true)
if [ -z "$FOREIGN" ] && [ -z "$OTHERARCH" ]; then
  ok "no foreign-platform dirs (darwin/win32/linux-$OTHER_ARCH/...)"
else
  bad "foreign platform dirs remain"
  printf '%s\n%s\n' "$FOREIGN" "$OTHERARCH" | sed '/^$/d' | head -20
fi
note "kept by design (pure JS, conditional): dsh-win32-process, dsh-sandbox-windows-acl"
FOREIGN_NATIVE=$(find "$RT/node_modules" -type f \( -name '*.node' -o -name '*.so' -o -name '*.dylib' -o -name '*.dll' \) 2>/dev/null \
  | grep -E '(darwin|win32|windows|android|freebsd|linuxmusl|linux-'$OTHER_ARCH')' || true)
if [ -z "$FOREIGN_NATIVE" ]; then
  ok "no native binaries for foreign platforms"
else
  bad "foreign native binaries remain"
  printf '%s\n' "$FOREIGN_NATIVE" | head -10
fi
if [ -f "$RT/node_modules/@deepseek-ai/dsh-skill-office/assets/office/SKILL.md" ]; then
  ok "office SKILL.md assets preserved"
else
  note "office SKILL.md assets not found at expected path"
fi
echo "native .node binaries:"
find "$RT/node_modules" -name '*.node' -printf '%10s %p\n' 2>/dev/null | sort -rn | head -8
sec "sizes"
for d in "$RT" "$RT/node_modules" "$RT/node" "$RT/office-skills" "$RT/licenses"; do
  if [ -e "$d" ]; then
    printf '%-28s apparent=%-8s allocated=%s\n' "$(basename "$d")" \
      "$(du -sh --apparent-size "$d" 2>/dev/null | cut -f1)" \
      "$(du -sh "$d" 2>/dev/null | cut -f1)"
  fi
done
echo "files: $(find "$RT" | wc -l)"
echo "top 12 packages (apparent):"
du -s --apparent-size "$RT/node_modules"/* "$RT/node_modules"/@*/* 2>/dev/null | sort -rn | head -12 | awk '{printf "%9.1f MiB  %s\n", $1/1024, $2}'

sec "version.json"
cat "$RT/version.json" 2>/dev/null || bad "version.json unreadable"

echo
if [ "$FAILS" -eq 0 ]; then
  printf 'SELFTEST RESULT: PASS (0 failures)\n'
  exit 0
fi
printf 'SELFTEST RESULT: FAIL (%s failures)\n' "$FAILS"
exit 1
