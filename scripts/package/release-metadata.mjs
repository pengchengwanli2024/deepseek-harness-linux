#!/usr/bin/env node
// DeepSeek Harness (Linux) — 生成 dist/SHA256SUMS 与 dist/RELEASE.json
//
// 用法（容器内或宿主机均可，需要 Node >= 18）:
//   node scripts/package/release-metadata.mjs --dist dist --arch arm64 --artifact-arch arm64 \
//     --version 0.2.1 --dsh-version 0.2.1-rc.5 --node-version 24.22.2 \
//     --electron-version 45.2.1 --builder-version 26.18.0 \
//     --commit abc1234 --dirty false --built-at 2026-01-01T00:00:00Z
//
// 设计: 每次只构建一个架构，脚本会合并 RELEASE.json 中另一架构的既有条目，
//       并对 dist/ 中所有交付文件重新计算 SHA-256（可复算）。
import { createHash } from 'node:crypto';
import { createReadStream, readdirSync, readFileSync, statSync, writeFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';

const ARTIFACT_RE = /^(DeepSeek-Harness-Linux-.*\.(AppImage|deb)|deepseek-harness-linux-.*\.tar\.gz)$/;

function parseArgs(argv) {
  const defaults = {
    dist: 'dist',
    arch: null,
    artifactArch: null,
    version: '0.2.1',
    dshVersion: '0.2.1-rc.5',
    nodeVersion: '24.22.2',
    electronVersion: '45.2.1',
    builderVersion: '26.18.0',
    commit: 'unknown',
    dirty: 'false',
    builtAt: null,
    product: 'DeepSeek Harness (Linux)',
  };
  const out = { ...defaults };
  const argvRest = argv.slice(2);
  for (let i = 0; i < argvRest.length; i += 1) {
    const arg = argvRest[i];
    if (!arg.startsWith('--')) throw new Error('unexpected argument: ' + arg);
    const eq = arg.indexOf('=');
    let key;
    let value;
    if (eq > 0) {
      key = arg.slice(2, eq);
      value = arg.slice(eq + 1);
    } else {
      key = arg.slice(2);
      if (i + 1 >= argvRest.length || argvRest[i + 1].startsWith('--')) {
        throw new Error('missing value for --' + key);
      }
      i += 1;
      value = argvRest[i];
    }
    if (key === 'dist') out.dist = value;
    else if (key === 'arch') out.arch = value;
    else if (key === 'artifact-arch') out.artifactArch = value;
    else if (key === 'version') out.version = value;
    else if (key === 'dsh-version') out.dshVersion = value;
    else if (key === 'node-version') out.nodeVersion = value;
    else if (key === 'electron-version') out.electronVersion = value;
    else if (key === 'builder-version') out.builderVersion = value;
    else if (key === 'commit') out.commit = value;
    else if (key === 'dirty') out.dirty = value;
    else if (key === 'built-at') out.builtAt = value;
    else if (key === 'product') out.product = value;
    else throw new Error('unknown option: --' + key);
  }
  if (!out.arch) throw new Error('--arch is required (x64 or arm64)');
  return out;
}

function sha256(file) {
  return new Promise((resolve, reject) => {
    const hash = createHash('sha256');
    createReadStream(file)
      .on('data', (chunk) => hash.update(chunk))
      .on('error', reject)
      .on('end', () => resolve(hash.digest('hex')));
  });
}

function detectArch(name) {
  if (/(x86_64|amd64)/.test(name)) return 'x86_64';
  if (/arm64/.test(name)) return 'arm64';
  return 'unknown';
}

function detectKind(name) {
  if (name.endsWith('.AppImage')) return 'AppImage';
  if (name.endsWith('.deb')) return 'deb';
  if (name.endsWith('.tar.gz')) return 'tar.gz';
  return 'unknown';
}

async function main() {
  const opts = parseArgs(process.argv);
  const dist = opts.dist;
  if (!existsSync(dist)) throw new Error(`dist directory not found: ${dist}`);
  const buildArch = opts.arch;
  const archMap = { x64: 'x86_64', amd64: 'x86_64', arm64: 'arm64' };
  const artifactArch = opts.artifactArch ?? archMap[buildArch] ?? detectArch(`x-${buildArch}`);

  const files = readdirSync(dist)
    .filter((name) => ARTIFACT_RE.test(name))
    .sort();

  const artifacts = [];
  for (const name of files) {
    const file = join(dist, name);
    const st = statSync(file);
    artifacts.push({
      name,
      arch: detectArch(name),
      kind: detectKind(name),
      size: st.size,
      sha256: await sha256(file),
    });
  }

  const sums = artifacts
    .map((a) => `${a.sha256}  ${a.name}`)
    .sort()
    .join('\n');
  writeFileSync(join(dist, 'SHA256SUMS'), sums + '\n');

  const releasePath = join(dist, 'RELEASE.json');
  let previous = null;
  if (existsSync(releasePath)) {
    try {
      previous = JSON.parse(readFileSync(releasePath, 'utf8'));
    } catch {
      previous = null;
    }
  }
  const keep = (previous?.artifacts ?? []).filter((a) => a.arch !== artifactArch);
  // 去重：同名产物以当前 dist 扫描结果为准，避免跨架构合并时重复累积。
  const byName = new Map();
  for (const artifact of [...keep, ...artifacts]) byName.set(artifact.name, artifact);
  const merged = [...byName.values()].sort((a, b) => a.name.localeCompare(b.name));

  const release = {
    product: opts.product,
    project: 'dsh-linux',
    unofficial: true,
    license: 'MIT',
    version: opts.version,
    dshVersion: opts.dshVersion,
    nodeVersion: opts.nodeVersion,
    electronVersion: opts.electronVersion,
    electronBuilderVersion: opts.builderVersion,
    commit: opts.commit,
    commitDirty: opts.dirty === 'true' || opts.dirty === '1',
    builtAt: opts.builtAt ?? new Date().toISOString(),
    architectures: [...new Set(merged.map((a) => a.arch))].sort(),
    artifacts: merged,
  };
  writeFileSync(releasePath, JSON.stringify(release, null, 2) + '\n');

  console.log(`SHA256SUMS: ${artifacts.length} artifact(s), RELEASE.json updated`);
  for (const a of artifacts) console.log(`  ${a.sha256}  ${a.name}  ${a.size} bytes`);
}

main().catch((err) => {
  console.error(`release-metadata.mjs: ${err.message}`);
  process.exit(1);
});
