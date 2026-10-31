#!/usr/bin/env node
'use strict';
// DeepSeek Harness (Linux) — 自动更新元数据校验（electron-updater / GitHub Releases）
//
// 由 scripts/package/in-container.sh 在构建时调用，也可在宿主机手动复跑。
//
// 用法:
//   node scripts/package/verify-update-metadata.cjs \
//     --yml build/output/latest-linux-arm64.yml \
//     --out build/output --version 0.2.1 \
//     --appimage DeepSeek-Harness-Linux-0.2.1-arm64.AppImage \
//     [--deb DeepSeek-Harness-Linux-0.2.1-arm64.deb] \
//     [--node-modules /build/project/node_modules]
//
// 校验项:
//   1. yml 可解析，version 与 --version 一致；
//   2. files[].url 必须与本次构建产出的最终发布资产名完全一致（electron-updater 按该名字
//      在 GitHub Release 资产中查找文件，改名即 404）；
//   3. 每个条目的 size / sha512 与磁盘上的实际文件一致（sha512 为 base64）；
//   4. AppImage 条目必须带内嵌 blockMapSize（electron-builder 把 blockmap 追加在 AppImage 尾部，
//      不单独生成 .blockmap；differential download 依赖该字段）；
//   5. 顶层 path（electron-updater 1.x/2.15 兼容字段）必须指向 files[] 中的某个资产。
//
// 退出码: 0 = 通过；1 = 校验失败；2 = 用法/依赖错误。
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');

function usage() {
  const lines = [
    'verify-update-metadata.cjs — validate latest-linux*.yml against release artifacts',
    '',
    'Usage:',
    '  node scripts/package/verify-update-metadata.cjs --yml <file> --out <dir> --version <ver>',
    '    --appimage <file-name> [--deb <file-name>] [--node-modules <dir>]',
    '',
    'Exit codes: 0 ok, 1 validation failure, 2 usage/dependency error',
  ];
  console.log(lines.join('\n'));
}

function die(message, code) {
  console.error('[update-metadata] ERROR: ' + message);
  process.exit(code || 1);
}

function parseArgs(argv) {
  const out = { yml: null, out: null, version: null, appimage: null, deb: null, nodeModules: null };
  const args = argv.slice(2);
  for (let i = 0; i < args.length; i += 1) {
    const arg = args[i];
    const next = () => {
      i += 1;
      if (i >= args.length) die('missing value for ' + arg, 2);
      return args[i];
    };
    if (arg === '--yml') out.yml = next();
    else if (arg === '--out') out.out = next();
    else if (arg === '--version') out.version = next();
    else if (arg === '--appimage') out.appimage = next();
    else if (arg === '--deb') out.deb = next();
    else if (arg === '--node-modules') out.nodeModules = next();
    else if (arg === '-h' || arg === '--help') { usage(); process.exit(0); }
    else die('unknown argument: ' + arg, 2);
  }
  if (!out.yml) die('--yml is required', 2);
  if (!out.out) die('--out is required', 2);
  if (!out.version) die('--version is required', 2);
  return out;
}

function loadYaml(nodeModules) {
  const candidates = [];
  if (nodeModules) candidates.push(path.join(nodeModules, 'js-yaml'));
  candidates.push('js-yaml');
  for (const candidate of candidates) {
    try {
      return require(candidate);
    } catch (err) {
      /* try next */
    }
  }
  die('cannot load js-yaml (pass --node-modules <dir containing js-yaml>)', 2);
}

function sha512Base64(file) {
  return crypto.createHash('sha512').update(fs.readFileSync(file)).digest('base64');
}

function main() {
  const opts = parseArgs(process.argv);
  const yaml = loadYaml(opts.nodeModules);
  if (!fs.existsSync(opts.yml)) die('update metadata not found: ' + opts.yml);
  let doc;
  try {
    doc = yaml.load(fs.readFileSync(opts.yml, 'utf8'));
  } catch (err) {
    die('cannot parse ' + opts.yml + ': ' + (err && err.message ? err.message : err));
  }
  if (!doc || typeof doc !== 'object') die('empty update metadata: ' + opts.yml);
  if (doc.version !== opts.version) {
    die('version mismatch: yml=' + doc.version + ' expected=' + opts.version);
  }
  const files = Array.isArray(doc.files) ? doc.files : [];
  if (files.length === 0) die('files[] is empty in ' + path.basename(opts.yml));

  const expected = new Map();
  for (const name of [opts.appimage, opts.deb]) {
    if (!name) continue;
    const file = path.join(opts.out, name);
    if (fs.existsSync(file)) expected.set(name, file);
  }
  if (expected.size === 0) die('no AppImage/deb artifact found in ' + opts.out);

  let appImageEntry = null;
  for (const entry of files) {
    if (!entry || typeof entry.url !== 'string') die('files[] entry without url');
    const target = expected.get(entry.url);
    if (!target) {
      die('files[].url=' + entry.url + ' does not match this build\'s artifacts ('
        + Array.from(expected.keys()).join(', ') + ')');
    }
    const stat = fs.statSync(target);
    if (entry.size != null && entry.size !== stat.size) {
      die(entry.url + ': size=' + entry.size + ' but file is ' + stat.size + ' bytes');
    }
    const digest = sha512Base64(target);
    if (entry.sha512 !== digest) {
      die(entry.url + ': sha512 in yml does not match the file (yml='
        + String(entry.sha512).slice(0, 16) + '..., file=' + digest.slice(0, 16) + '...)');
    }
    if (entry.url.endsWith('.AppImage')) {
      appImageEntry = entry;
      if (!(entry.blockMapSize > 0)) {
        die(entry.url + ': missing embedded blockMapSize (AppImage blockmap must be appended)');
      }
    }
  }
  // electron-updater 只使用 AppImage 条目；deb 条目若存在则已在上方校验 sha512/size，
  // 若 electron-builder 未把 deb 写入通道文件也不影响自动更新（仍要求 AppImage 必须在列）。
  const urls = new Set(files.map((entry) => entry.url));
  if (opts.appimage && fs.existsSync(path.join(opts.out, opts.appimage)) && !urls.has(opts.appimage)) {
    die('AppImage artifact ' + opts.appimage + ' is not listed in files[]');
  }
  if (doc.path != null && !urls.has(doc.path)) {
    die('path=' + doc.path + ' is not one of files[]');
  }
  if (doc.stagingPercentage != null || doc.minimumSystemVersion != null) {
    console.error('[update-metadata] note: stagingPercentage/minimumSystemVersion present');
  }

  const summary = files.map((entry) => entry.url).join(', ');
  console.log('[update-metadata] OK ' + path.basename(opts.yml)
    + ': version=' + doc.version
    + ' files=[' + summary + ']'
    + ' appImageBlockMapSize=' + (appImageEntry ? appImageEntry.blockMapSize : '-')
    + ' releaseDate=' + (doc.releaseDate || '-'));
}

main();
