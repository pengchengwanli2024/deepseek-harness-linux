'use strict';
// DeepSeek Harness (Linux) — electron-builder afterPack 钩子
//
// 为什么需要它：
//   electron-builder 的 extraResources/extraFiles 文件过滤器会无条件跳过 **根级**
//   node_modules（app-builder-lib/out/util/filter.js: `if (relative === "node_modules") return false`），
//   而运行时契约要求 resources/runtime/node_modules/ 必须完整随包分发（dsh 的生产依赖都在里面）。
//   因此这里在 appOutDir 生成后、各 target（AppImage/deb/tar.gz）打包前，用 fs.cp 原样复制
//   整个运行时目录到 resources/runtime，保留权限位与符号链接。
//
// 输入：环境变量 DSH_PKG_RUNTIME（由 scripts/package/in-container.sh 注入，指向 runtime/linux-<arch>）。
// 输出：<appOutDir>/resources/runtime/**。
const fs = require('node:fs');
const fsp = require('node:fs/promises');
const path = require('node:path');

function dirSizeBytes(dir) {
  let total = 0;
  const stack = [dir];
  while (stack.length > 0) {
    const current = stack.pop();
    let entries;
    try {
      entries = fs.readdirSync(current, { withFileTypes: true });
    } catch {
      continue;
    }
    for (const entry of entries) {
      const full = path.join(current, entry.name);
      if (entry.isDirectory()) {
        stack.push(full);
      } else if (entry.isFile()) {
        try {
          total += fs.statSync(full).size;
        } catch {
          /* ignore */
        }
      }
    }
  }
  return total;
}

module.exports = async function afterPack(context) {
  const runtimeSrc = process.env.DSH_PKG_RUNTIME;
  if (!runtimeSrc) {
    throw new Error('afterPack: DSH_PKG_RUNTIME is not set');
  }
  if (!fs.existsSync(runtimeSrc)) {
    throw new Error('afterPack: runtime directory not found: ' + runtimeSrc);
  }

  const resourcesDir = context.electronPlatformName === 'darwin'
    ? path.join(context.appOutDir, context.packager.appInfo.productFilename + '.app', 'Contents', 'Resources')
    : path.join(context.appOutDir, 'resources');
  const dest = path.join(resourcesDir, 'runtime');

  console.log('[afterPack] copying runtime ' + runtimeSrc + ' -> ' + dest);
  await fsp.rm(dest, { recursive: true, force: true });
  await fsp.mkdir(path.dirname(dest), { recursive: true });
  await fsp.cp(runtimeSrc, dest, {
    recursive: true,
    force: true,
    preserveTimestamps: true,
    verbatimSymlinks: true,
  });

  const required = [
    'bin/dsh',
    'node/bin/node',
    'node_modules/@deepseek-ai/dsh/lib/bin.js',
    'node_modules/@deepseek-ai/dsh/package.json',
    'version.json',
  ];
  for (const rel of required) {
    const file = path.join(dest, rel);
    if (!fs.existsSync(file)) {
      throw new Error('afterPack: runtime copied but missing required file: ' + rel);
    }
  }
  for (const exec of ['bin/dsh', 'node/bin/node']) {
    fs.chmodSync(path.join(dest, exec), 0o755);
  }

  const size = dirSizeBytes(dest);
  const srcSize = dirSizeBytes(runtimeSrc);
  if (srcSize > 0 && size < srcSize * 0.95) {
    throw new Error(
      'afterPack: runtime copy incomplete (' + size + ' bytes copied vs ' + srcSize + ' bytes source)',
    );
  }
  console.log(
    '[afterPack] runtime ok: ' + (size / 1048576).toFixed(1) + ' MiB, files=',
    fs.readdirSync(path.join(dest, 'node_modules')).length + ' node_modules entries',
  );
};
