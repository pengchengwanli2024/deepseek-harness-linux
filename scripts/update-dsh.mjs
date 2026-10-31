#!/usr/bin/env node
// scripts/update-dsh.mjs — 跟随上游 @deepseek-ai/dsh 版本（离线可用、可被 CI 调用）
//
// versions.json 是唯一版本源：
//   appVersion / dshVersion / nodeVersion / electronVersion / electronBuilderVersion
//
// 用法:
//   node scripts/update-dsh.mjs --check [--json]
//   node scripts/update-dsh.mjs --apply [--json] [--dry-run]
//
// 退出码:
//   0   已是最新（或 --apply 成功 / 无需变更）
//   10  发现上游新版本（--check）
//   2   错误（registry 不可用、版本格式非法、写入后校验失败等）
//
// 选项:
//   --check              只检查（默认动作）
//   --apply              写回 versions.json / package.json / 文档中的版本字符串
//   --json               stdout 输出单行 JSON（CI 解析用），细节日志走 stderr
//   --root <目录>        仓库根目录（默认：本脚本的上级目录）
//   --registry <url>     npm registry（默认 $UPDATE_DSH_REGISTRY 或 https://registry.npmjs.org）
//   --dsh-version <ver>  直接指定“上游最新版本”，跳过网络查询（离线/测试用）
//   --app-version <ver>  --apply 时显式指定新 appVersion（默认 patch+1，如 0.2.1 -> 0.2.2）
//   --timeout <ms>       registry 查询超时（默认 20000）
//   --allow-downgrade    允许上游 latest 低于当前固定版本时降级（默认拒绝）
//   --dry-run            --apply 只列出将变更的文件，不写入
//   -h | --help          显示帮助
//
// 示例:
//   scripts/update-dsh.sh --check                 # UP_TO_DATE / NEW <ver>
//   scripts/update-dsh.sh --apply                 # 升级并同步文档
//   scripts/update-dsh.sh --check --json          # CI 解析
//   node scripts/update-dsh.mjs --apply --dsh-version 0.2.2-rc.1   # 离线演练

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const DEFAULT_ROOT = path.resolve(SCRIPT_DIR, '..');
const PKG_NAME = '@deepseek-ai/dsh';
const DEFAULT_REGISTRY = process.env.UPDATE_DSH_REGISTRY || 'https://registry.npmjs.org';
const EXIT_OK = 0;
const EXIT_NEW = 10;
const EXIT_ERROR = 2;

// 版本字符串替换范围（README 与 docs 下的 Markdown；CHANGELOG 属于历史记录，不替换）
const DOC_FILES = ['README.md', 'README.en.md'];
const DOC_DIRS = ['docs'];
const DOC_SKIP_DIRS = new Set(['assets', 'node_modules', '.git']);

const USAGE = `用法:
  node scripts/update-dsh.mjs --check [--json]
  node scripts/update-dsh.mjs --apply [--json] [--dry-run]

选项:
  --check              只检查（默认动作），输出 UP_TO_DATE 或 NEW <version>，退出码 0/10
  --apply              升级 versions.json + package.json + README/docs 版本字符串
  --json               stdout 输出单行 JSON（CI 用）
  --root <目录>        仓库根目录（默认：本脚本上级目录）
  --registry <url>     npm registry（默认 \$UPDATE_DSH_REGISTRY 或 https://registry.npmjs.org）
  --dsh-version <ver>  直接指定上游最新版本，跳过网络查询（离线/测试用）
  --app-version <ver>  --apply 时显式指定新 appVersion（默认 patch+1）
  --timeout <ms>       registry 查询超时（默认 20000）
  --allow-downgrade    允许降级（默认拒绝）
  --dry-run            --apply 只打印将变更的文件，不写入
  -h | --help          显示本帮助

退出码: 0=已是最新/成功  10=发现新版本  2=错误`;

// ---------------------------------------------------------------------------
// 参数
// ---------------------------------------------------------------------------
function parseArgs(argv) {
  const opts = {
    action: 'check',
    json: false,
    dryRun: false,
    allowDowngrade: false,
    root: null,
    registry: DEFAULT_REGISTRY,
    timeoutMs: 20_000,
    dshVersion: null,
    appVersion: null,
    help: false,
  };
  const needValue = (flag, value) => {
    if (value === undefined || value === '' || value.startsWith('--')) {
      throw new Error(`${flag} 需要参数值`);
    }
    return value;
  };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--check') opts.action = 'check';
    else if (arg === '--apply') opts.action = 'apply';
    else if (arg === '--json') opts.json = true;
    else if (arg === '--dry-run') opts.dryRun = true;
    else if (arg === '--allow-downgrade') opts.allowDowngrade = true;
    else if (arg === '-h' || arg === '--help') opts.help = true;
    else if (arg === '--root') { opts.root = needValue('--root', argv[++i]); }
    else if (arg.startsWith('--root=')) opts.root = needValue('--root=', arg.slice('--root='.length));
    else if (arg === '--registry') { opts.registry = needValue('--registry', argv[++i]); }
    else if (arg.startsWith('--registry=')) opts.registry = needValue('--registry=', arg.slice('--registry='.length));
    else if (arg === '--dsh-version') { opts.dshVersion = needValue('--dsh-version', argv[++i]); }
    else if (arg.startsWith('--dsh-version=')) opts.dshVersion = needValue('--dsh-version=', arg.slice('--dsh-version='.length));
    else if (arg === '--app-version') { opts.appVersion = needValue('--app-version', argv[++i]); }
    else if (arg.startsWith('--app-version=')) opts.appVersion = needValue('--app-version=', arg.slice('--app-version='.length));
    else if (arg === '--timeout') { opts.timeoutMs = Number(needValue('--timeout', argv[++i])); }
    else if (arg.startsWith('--timeout=')) opts.timeoutMs = Number(needValue('--timeout=', arg.slice('--timeout='.length)));
    else throw new Error(`未知参数: ${arg}（--help 查看用法）`);
  }
  if (!Number.isFinite(opts.timeoutMs) || opts.timeoutMs <= 0) throw new Error('--timeout 必须为正整数毫秒');
  if (opts.dshVersion !== null && !/^[0-9A-Za-z][0-9A-Za-z.+_-]*$/.test(opts.dshVersion)) {
    throw new Error(`--dsh-version 格式非法: ${opts.dshVersion}`);
  }
  return opts;
}

// ---------------------------------------------------------------------------
// 工具函数
// ---------------------------------------------------------------------------
function info(message) {
  process.stderr.write(message + '\n');
}

function readJson(file, label) {
  let text;
  try {
    text = fs.readFileSync(file, 'utf8');
  } catch (err) {
    throw new Error(`无法读取 ${label}: ${file}: ${err.message}`);
  }
  try {
    return JSON.parse(text);
  } catch (err) {
    throw new Error(`${label} 不是合法 JSON: ${file}: ${err.message}`);
  }
}

function writeJson(file, value) {
  fs.writeFileSync(file, JSON.stringify(value, null, 2) + '\n', 'utf8');
}

function assertSemverCoarse(value, label) {
  if (typeof value !== 'string' || !/^\d+\.\d+\.\d+([-+][0-9A-Za-z.-]+)?$/.test(value)) {
    throw new Error(`${label} 不是合法版本号: ${JSON.stringify(value)}`);
  }
}

function resolveRoot(opts) {
  const root = path.resolve(opts.root || DEFAULT_ROOT);
  if (!fs.existsSync(path.join(root, 'versions.json'))) {
    throw new Error(`在 ${root} 下找不到 versions.json（可用 --root 指定仓库根目录）`);
  }
  return root;
}

function readVersions(root) {
  const file = path.join(root, 'versions.json');
  const versions = readJson(file, 'versions.json');
  for (const key of ['appVersion', 'dshVersion', 'nodeVersion', 'electronVersion', 'electronBuilderVersion']) {
    if (typeof versions[key] !== 'string' || versions[key] === '') {
      throw new Error(`versions.json 缺少字符串字段 ${key}`);
    }
  }
  assertSemverCoarse(versions.appVersion, 'versions.json appVersion');
  return versions;
}

function bumpPatch(appVersion) {
  const m = /^(\d+)\.(\d+)\.(\d+)$/.exec(appVersion);
  if (!m) throw new Error(`appVersion 必须为 X.Y.Z（当前: ${appVersion}）`);
  return `${m[1]}.${m[2]}.${Number(m[3]) + 1}`;
}

function parseSemver(version) {
  const m = /^v?(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$/.exec(version);
  if (!m) {
    throw new Error(`无法解析版本号: ${version}`);
  }
  return {
    major: Number(m[1]),
    minor: Number(m[2]),
    patch: Number(m[3]),
    prerelease: m[4] ? m[4].split('.') : [],
  };
}

function comparePrerelease(a, b) {
  if (a.length === 0 && b.length === 0) return 0;
  if (a.length === 0) return 1;
  if (b.length === 0) return -1;
  const length = Math.max(a.length, b.length);
  for (let i = 0; i < length; i += 1) {
    const x = a[i];
    const y = b[i];
    if (x === undefined) return -1;
    if (y === undefined) return 1;
    const xn = /^\d+$/.test(x);
    const yn = /^\d+$/.test(y);
    if (xn && yn) {
      const diff = Number(x) - Number(y);
      if (diff !== 0) return diff > 0 ? 1 : -1;
    } else if (xn !== yn) {
      return xn ? -1 : 1;
    } else if (x !== y) {
      return x > y ? 1 : -1;
    }
  }
  return 0;
}

/** 语义化版本比较：<0 表示 a<b，0 相等，>0 表示 a>b */
function compareVersions(a, b) {
  const x = parseSemver(a);
  const y = parseSemver(b);
  for (const key of ['major', 'minor', 'patch']) {
    if (x[key] !== y[key]) return x[key] > y[key] ? 1 : -1;
  }
  return comparePrerelease(x.prerelease, y.prerelease);
}

// ---------------------------------------------------------------------------
// 上游注册表
// ---------------------------------------------------------------------------
async function fetchLatestDsh(registry, timeoutMs) {
  const registryBase = String(registry || DEFAULT_REGISTRY).replace(/\/+$/, '');
  const url = `${registryBase}/${PKG_NAME.replace('/', '%2F')}`;
  let res;
  try {
    res = await fetch(url, {
      headers: { accept: 'application/vnd.npm.install-v1+json' },
      signal: AbortSignal.timeout(timeoutMs),
    });
  } catch (err) {
    throw new Error(`无法访问 npm registry ${registryBase}（${err.message}）；离线环境可用 --dsh-version 跳过网络查询`);
  }
  if (!res.ok) {
    throw new Error(`npm registry 返回 HTTP ${res.status} ${res.statusText}（${url}）`);
  }
  let body;
  try {
    body = await res.json();
  } catch (err) {
    throw new Error(`npm registry 响应不是合法 JSON: ${err.message}`);
  }
  const latest = body && body['dist-tags'] && body['dist-tags'].latest;
  if (typeof latest !== 'string' || latest === '') {
    throw new Error(`npm registry 响应缺少 dist-tags.latest（${PKG_NAME}）`);
  }
  return latest;
}

async function resolveLatest(opts) {
  if (opts.dshVersion) {
    info(`# 使用 --dsh-version 指定的上游版本: ${opts.dshVersion}（跳过网络查询）`);
    return { latest: opts.dshVersion, source: 'cli' };
  }
  const latest = await fetchLatestDsh(opts.registry, opts.timeoutMs);
  return { latest, source: opts.registry };
}

// ---------------------------------------------------------------------------
// 本地一致性检查（只告警，不阻断 check）
// ---------------------------------------------------------------------------
function warnLocalConsistency(root, versions) {
  const pkgPath = path.join(root, 'package.json');
  if (!fs.existsSync(pkgPath)) {
    info('# WARN: 缺少 package.json，跳过本地一致性检查');
    return;
  }
  let pkg;
  try {
    pkg = readJson(pkgPath, 'package.json');
  } catch (err) {
    info(`# WARN: ${err.message}`);
    return;
  }
  if (pkg.version !== versions.appVersion) {
    info(`# WARN: package.json version=${JSON.stringify(pkg.version)} 与 versions.json appVersion=${versions.appVersion} 不一致（--apply 会同步）`);
  }
  const dev = pkg.devDependencies || {};
  if (dev.electron && dev.electron !== versions.electronVersion) {
    info(`# WARN: package.json electron=${dev.electron} 与 versions.json electronVersion=${versions.electronVersion} 不一致`);
  }
  if (dev['electron-builder'] && dev['electron-builder'] !== versions.electronBuilderVersion) {
    info(`# WARN: package.json electron-builder=${dev['electron-builder']} 与 versions.json electronBuilderVersion=${versions.electronBuilderVersion} 不一致`);
  }
}

// ---------------------------------------------------------------------------
// 文档版本替换
// ---------------------------------------------------------------------------
function escapeRegExp(text) {
  return text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function buildReplacementPlan(oldVersions, newVersions) {
  const plan = [];
  const push = (from, to, kind) => {
    if (from && to && from !== to) plan.push({ from, to, kind });
  };
  // 顺序很重要：先替换更长的 dsh 版本（0.2.1-rc.5），再替换 app 版本（0.2.1），
  // 避免 app 版本成为 dsh 版本的前缀时误替换。node 版本与二者不重叠。
  push(oldVersions.dshVersion, newVersions.dshVersion, 'dshVersion');
  push(oldVersions.appVersion, newVersions.appVersion, 'appVersion');
  push(oldVersions.nodeVersion, newVersions.nodeVersion, 'nodeVersion');
  return plan;
}

function buildReplacementRegex(plan) {
  if (plan.length === 0) return null;
  const alternatives = plan.map((item) => {
    // app 版本后面若紧跟 -rc/-alpha/-beta 等预发布后缀，说明它属于其他版本号，不替换。
    const guard = item.kind === 'appVersion' ? '(?!-(?:rc|alpha|beta|next)\\b)' : '';
    return `(?:${escapeRegExp(item.from)})${guard}`;
  });
  // 前后只要求不是数字/点，允许 v0.2.1、-0.2.1-x86_64 这类上下文。
  return new RegExp(`(?<![\\d.])(?:${alternatives.join('|')})(?!\\d)`, 'g');
}

function collectDocFiles(root) {
  const files = [];
  for (const rel of DOC_FILES) {
    const abs = path.join(root, rel);
    if (fs.existsSync(abs) && fs.statSync(abs).isFile()) files.push(abs);
  }
  const walk = (dir) => {
    if (!fs.existsSync(dir)) return;
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      if (entry.name.startsWith('.')) continue;
      const abs = path.join(dir, entry.name);
      if (entry.isDirectory()) {
        if (!DOC_SKIP_DIRS.has(entry.name)) walk(abs);
      } else if (entry.isFile() && entry.name.endsWith('.md')) {
        files.push(abs);
      }
    }
  };
  for (const rel of DOC_DIRS) walk(path.join(root, rel));
  return [...new Set(files)];
}

function replaceVersionsInDocs(root, plan, dryRun) {
  const regex = buildReplacementRegex(plan);
  if (!regex) return [];
  const changed = [];
  for (const file of collectDocFiles(root)) {
    let text;
    try {
      text = fs.readFileSync(file, 'utf8');
    } catch (err) {
      info(`# WARN: 跳过无法读取的文档 ${file}: ${err.message}`);
      continue;
    }
    const next = text.replace(regex, (match) => {
      const hit = plan.find((item) => item.from === match);
      return hit ? hit.to : match;
    });
    if (next !== text) {
      if (!dryRun) fs.writeFileSync(file, next, 'utf8');
      changed.push(path.relative(root, file));
      info(`# ${dryRun ? 'would update' : 'updated'} ${path.relative(root, file)}`);
    }
  }
  return changed;
}

// ---------------------------------------------------------------------------
// 动作：--check
// ---------------------------------------------------------------------------
async function runCheck(opts) {
  const root = resolveRoot(opts);
  const versions = readVersions(root);
  warnLocalConsistency(root, versions);
  const { latest, source } = await resolveLatest(opts);
  const current = versions.dshVersion;
  let cmp;
  try {
    cmp = compareVersions(latest, current);
  } catch (err) {
    throw new Error(`版本号无法比较（latest=${latest}, current=${current}）: ${err.message}`);
  }
  let status;
  if (latest === current) status = 'up_to_date';
  else if (cmp > 0) status = 'new';
  else status = 'downgrade';
  const exitCode = status === 'new' ? EXIT_NEW : EXIT_OK;
  const nextAppVersion = status === 'new' ? (opts.appVersion || bumpPatch(versions.appVersion)) : null;
  info(`# current=${current} latest=${latest} registry=${source}`);
  if (status === 'downgrade') {
    info(`# WARN: registry latest (${latest}) 低于当前固定版本 (${current})，保持锁定版本`);
  }
  if (opts.json) {
    process.stdout.write(JSON.stringify({
      status,
      action: 'check',
      current,
      latest,
      appVersion: versions.appVersion,
      dshVersion: versions.dshVersion,
      nextAppVersion,
      source,
      exitCode,
    }) + '\n');
  } else if (status === 'new') {
    process.stdout.write(`NEW ${latest}\n`);
  } else {
    process.stdout.write('UP_TO_DATE\n');
  }
  return exitCode;
}

// ---------------------------------------------------------------------------
// 动作：--apply
// ---------------------------------------------------------------------------
async function runApply(opts) {
  const root = resolveRoot(opts);
  const versions = readVersions(root);
  const { latest, source } = await resolveLatest(opts);
  const current = versions.dshVersion;
  const changedFiles = [];

  const versionsPath = path.join(root, 'versions.json');
  const pkgPath = path.join(root, 'package.json');
  const pkg = fs.existsSync(pkgPath) ? readJson(pkgPath, 'package.json') : null;

  // 已是最新：只做幂等同步（package.json version 与 versions.json 对齐）
  if (latest === current) {
    if (pkg && pkg.version !== versions.appVersion) {
      pkg.version = versions.appVersion;
      if (!opts.dryRun) writeJson(pkgPath, pkg);
      changedFiles.push('package.json');
      info(`# ${opts.dryRun ? 'would sync' : 'synced'} package.json version -> ${versions.appVersion}`);
    }
    if (opts.json) {
      process.stdout.write(JSON.stringify({
        status: 'up_to_date',
        action: 'apply',
        current,
        latest,
        appVersion: versions.appVersion,
        dshVersion: versions.dshVersion,
        source,
        changedFiles,
        exitCode: EXIT_OK,
      }) + '\n');
    } else if (changedFiles.length > 0) {
      process.stdout.write(`APPLIED appVersion=${versions.appVersion} dshVersion=${versions.dshVersion}\n`);
    } else {
      process.stdout.write('UP_TO_DATE\n');
    }
    return EXIT_OK;
  }

  let cmp;
  try {
    cmp = compareVersions(latest, current);
  } catch (err) {
    throw new Error(`版本号无法比较（latest=${latest}, current=${current}）: ${err.message}`);
  }
  if (cmp < 0 && !opts.allowDowngrade) {
    throw new Error(`拒绝降级：上游 latest=${latest} 低于当前固定版本 ${current}（确需降级请加 --allow-downgrade）`);
  }

  const newAppVersion = opts.appVersion || bumpPatch(versions.appVersion);
  if (!/^\d+\.\d+\.\d+$/.test(newAppVersion)) {
    throw new Error(`新 appVersion 必须为 X.Y.Z: ${newAppVersion}`);
  }
  if (pkg && pkg.version === newAppVersion && latest === current) {
    throw new Error('版本未发生变化，无需 apply');
  }

  const newVersions = { ...versions, appVersion: newAppVersion, dshVersion: latest };
  const plan = buildReplacementPlan(versions, newVersions);

  if (!opts.dryRun) {
    writeJson(versionsPath, newVersions);
  }
  changedFiles.push('versions.json');
  info(`# versions.json -> appVersion=${newAppVersion} dshVersion=${latest}`);

  if (pkg) {
    const nextPkg = { ...pkg, version: newAppVersion };
    if (!opts.dryRun) writeJson(pkgPath, nextPkg);
    changedFiles.push('package.json');
    info(`# package.json version -> ${newAppVersion}`);
  }

  const docFiles = replaceVersionsInDocs(root, plan, opts.dryRun);
  changedFiles.push(...docFiles);

  if (!opts.dryRun) {
    // 写入后校验，避免半更新状态进入发布流程
    const written = readVersions(root);
    if (written.dshVersion !== latest || written.appVersion !== newAppVersion) {
      throw new Error('写入后校验失败：versions.json 内容与预期不一致');
    }
    if (pkg) {
      const writtenPkg = readJson(pkgPath, 'package.json');
      if (writtenPkg.version !== newAppVersion) {
        throw new Error(`写入后校验失败：package.json version=${writtenPkg.version}，期望 ${newAppVersion}`);
      }
    }
  }

  const result = {
    status: 'applied',
    action: 'apply',
    previous: { appVersion: versions.appVersion, dshVersion: current },
    appVersion: newAppVersion,
    dshVersion: latest,
    source,
    changedFiles,
    exitCode: EXIT_OK,
  };
  if (opts.json) {
    process.stdout.write(JSON.stringify(result) + '\n');
  } else if (opts.dryRun) {
    process.stdout.write(`WOULD_APPLY appVersion=${newAppVersion} dshVersion=${latest}\n`);
  } else {
    process.stdout.write(`APPLIED appVersion=${newAppVersion} dshVersion=${latest}\n`);
  }
  info(`# changed ${changedFiles.length} file(s): ${changedFiles.join(', ')}`);
  return EXIT_OK;
}

// ---------------------------------------------------------------------------
// 错误输出
// ---------------------------------------------------------------------------
function reportError(opts, err) {
  const message = err && err.message ? err.message : String(err);
  if (opts && opts.json) {
    process.stdout.write(JSON.stringify({
      status: 'error',
      action: opts.action,
      error: message,
      exitCode: EXIT_ERROR,
    }) + '\n');
  }
  process.stderr.write(`update-dsh.mjs: ERROR: ${message}\n`);
  return EXIT_ERROR;
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------
async function main(argv) {
  const opts = parseArgs(argv);
  if (opts.help) {
    process.stdout.write(USAGE + '\n');
    return EXIT_OK;
  }
  try {
    return opts.action === 'apply' ? await runApply(opts) : await runCheck(opts);
  } catch (err) {
    return reportError(opts, err);
  }
}

main(process.argv.slice(2)).then((code) => {
  process.exitCode = code;
}).catch((err) => {
  process.stderr.write(`update-dsh.mjs: ERROR: ${err && err.message ? err.message : String(err)}\n`);
  process.exitCode = EXIT_ERROR;
});
