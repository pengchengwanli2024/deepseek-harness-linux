// app/preload.cjs — 沙箱化 preload
// 架构契约 §5.2：contextIsolation=true / nodeIntegration=false / sandbox=true，
// 仅通过 contextBridge 暴露只读的 { platform, version, isPackaged }。
'use strict';

const { contextBridge } = require('electron');

function readAdditionalArg(name) {
  try {
    const prefix = '--' + name + '=';
    const list = Array.isArray(process.argv) ? process.argv : [];
    const hit = list.find((item) => typeof item === 'string' && item.startsWith(prefix));
    return hit ? hit.slice(prefix.length) : null;
  } catch {
    return null;
  }
}

const version = readAdditionalArg('dsh-app-version') || process.env.DSH_APP_VERSION || '0.2.1';
const isPackaged = readAdditionalArg('dsh-is-packaged') === '1' || process.env.DSH_IS_PACKAGED === '1';

contextBridge.exposeInMainWorld(
  'dshDesktop',
  Object.freeze({
    platform: process.platform,
    version,
    isPackaged,
  }),
);
