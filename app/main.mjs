// app/main.mjs — DeepSeek Harness (Linux) Electron 桌面壳主进程
// 架构契约：docs/ARCHITECTURE.md §5 / §8
//
// 职责：
//  1. 定位并启动内置离线运行时（dsh web），解析带 token 的访问地址；
//  2. splash → 主窗口，单实例、窗口记忆、菜单、安全策略、日志、崩溃恢复；
//  3. 提供 --smoke-test / --screenshot 测试钩子。
//
// 运行时覆盖（联调/排障用）：
//  DSH_LINUX_RUNTIME   运行时根目录（含 bin/dsh 或 node_modules/@deepseek-ai/dsh）
//  DSH_LINUX_NODE      node 可执行文件（配合 DSH_LINUX_DSH_ENTRY 直接 spawn）
//  DSH_LINUX_DSH_ENTRY dsh 入口 JS（lib/bin.js）
//  DSH_LINUX_HOME      DSH_HOME 覆盖（同 --dsh-home）

import { app, BrowserWindow, dialog, Menu, screen, session, shell } from 'electron';
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const APP_NAME = 'deepseek-harness';
const APP_TITLE = 'DeepSeek Harness';
const PROJECT_URL = 'https://github.com/pengchengwanli2024/deepseek-harness-linux';
const MIN_WIDTH = 960;
const MIN_HEIGHT = 640;
const DEFAULT_WIDTH = 1280;
const DEFAULT_HEIGHT = 800;
const SERVER_READY_TIMEOUT_MS = 60_000;
const LOG_MAX_BYTES = 5 * 1024 * 1024;
const KILL_GRACE_MS = 5_000;
// 自动更新（electron-updater）：
//  - 仅打包后的 AppImage（process.env.APPIMAGE）启用；
//  - --smoke-test / --screenshot / DSH_LINUX_DISABLE_UPDATER=1 时禁用；
//  - 启动 8 秒后静默检查，菜单“帮助 → 检查更新…”可手动检查；
//  - deb 安装版没有 APPIMAGE，引导用户去 GitHub Releases 手动下载。
const RELEASES_URL = 'https://github.com/pengchengwanli2024/deepseek-harness-linux/releases/latest';
const UPDATER_STARTUP_DELAY_MS = 8_000;
const UPDATER_DISABLED = process.env.DSH_LINUX_DISABLE_UPDATER === '1';
const UPDATER_FEED_URL = process.env.DSH_LINUX_UPDATE_FEED_URL || '';

app.setName(APP_NAME);

// ---------------------------------------------------------------------------
// 参数解析
// ---------------------------------------------------------------------------
function parseArgs(argv) {
  const out = {
    host: '127.0.0.1',
    port: 0,
    dshHome: null,
    smokeTest: false,
    screenshot: null,
    version: false,
    help: false,
    dev: false,
    updaterCheck: false,
  };
  for (let i = 1; i < argv.length; i += 1) {
    const a = argv[i];
    if (a === '--smoke-test') out.smokeTest = true;
    else if (a === '--updater-check') out.updaterCheck = true;
    else if (a === '--version' || a === '-V') out.version = true;
    else if (a === '--help' || a === '-h') out.help = true;
    else if (a === '--dev') out.dev = true;
    else if (a.startsWith('--dsh-home=')) out.dshHome = a.slice('--dsh-home='.length);
    else if (a === '--dsh-home') out.dshHome = argv[++i] ?? null;
    else if (a.startsWith('--port=')) out.port = Number(a.slice('--port='.length));
    else if (a === '--port') out.port = Number(argv[++i]);
    else if (a.startsWith('--host=')) out.host = a.slice('--host='.length);
    else if (a === '--host') out.host = argv[++i] ?? out.host;
    else if (a.startsWith('--screenshot=')) out.screenshot = a.slice('--screenshot='.length);
    else if (a === '--screenshot') out.screenshot = argv[++i] ?? null;
  }
  if (!Number.isFinite(out.port) || out.port < 0 || out.port > 65535) out.port = 0;
  if (!out.host) out.host = '127.0.0.1';
  return out;
}

const cliArgs = parseArgs(process.argv);
const IS_TEST = cliArgs.smokeTest || Boolean(cliArgs.screenshot);
const isRoot = typeof process.getuid === 'function' && process.getuid() === 0;

// Linux 沙箱：AppImage / root / 容器内无法使用 setuid chrome-sandbox helper
// （deb 安装后由 postinst 设置 4755；AppImage 无法保留 setuid 位）
if (process.env.APPIMAGE || isRoot || process.env.DSH_LINUX_NO_SANDBOX === '1') {
  app.commandLine.appendSwitch('no-sandbox');
}
// 容器/无 GPU 环境下的兼容开关（对桌面用户无副作用）
if (process.env.DSH_LINUX_DISABLE_GPU === '1') app.disableHardwareAcceleration();
if (isRoot || process.env.DSH_LINUX_CONTAINER === '1') {
  app.commandLine.appendSwitch('disable-dev-shm-usage');
}

function appVersion() {
  try {
    return app.getVersion();
  } catch {
    return '0.2.1';
  }
}

const VERSION_TEXT = [
  APP_TITLE + ' (Linux) ' + appVersion(),
  'Electron ' + process.versions.electron + ' / Chromium ' + process.versions.chrome + ' / Node ' + process.versions.node,
].join('\n');

const HELP_TEXT = [
  VERSION_TEXT,
  '',
  '用法: deepseek-harness [选项]',
  '',
  '选项:',
  '  --dsh-home=<目录>   指定 DSH_HOME 数据目录',
  '                      默认: <userData>/dsh-home（可用 DSH_LINUX_HOME 覆盖）',
  '  --host=<ip>         本地服务监听地址（默认 127.0.0.1）',
  '  --port=<n>          本地服务端口（默认 0 = 自动分配空闲端口）',
  '  --version, -V       显示版本信息并退出',
  '  --help, -h          显示本帮助并退出',
  '',
  '测试钩子（仅 CI/验证使用）:',
  '  --smoke-test        服务就绪并加载页面后输出 SMOKE_OK 并退出 0',
  '  --screenshot=<png>  页面加载 2 秒后截图保存并输出 SCREENSHOT_OK',
  '  --updater-check     检查更新并输出 UPDATE_AVAILABLE/UPDATE_NONE/UPDATE_ERROR 后退出',
  '',
  '环境变量:',
  '  DSH_LINUX_RUNTIME / DSH_LINUX_NODE / DSH_LINUX_DSH_ENTRY  运行时覆盖',
  '  DSH_LINUX_HOME      DSH_HOME 覆盖',
  '  DSH_LINUX_DISABLE_GPU=1   禁用硬件加速',
  '  DSH_LINUX_DISABLE_UPDATER=1  禁用应用内自动更新',
  '  DSH_LINUX_UPDATE_FEED_URL=<url>  覆盖更新源（generic provider，调试/镜像用）',
  '',
  '说明: Linux 桌面版为非官方构建，数据保存在 $XDG_CONFIG_HOME/' + APP_NAME + '。',
].join('\n');

if (cliArgs.version || cliArgs.help) {
  try {
    fs.writeSync(1, (cliArgs.version ? VERSION_TEXT : HELP_TEXT) + '\n');
  } catch {
    /* ignore */
  }
  app.exit(0);
}

// ---------------------------------------------------------------------------
// 全局状态
// ---------------------------------------------------------------------------
let mainWindow = null;
let splashWindow = null;
let serverProc = null;
let serverUrl = null;
let serverOrigin = null;
let serverReady = false;
let quitting = false;
let quittingForTest = false;
let startupTimer = null;
let appLogFile = null;
let logsDir = null;
let dshHome = null;
let windowStatePath = null;
let testFinished = false;
let crashDialogOpen = false;
let restarting = false;
let lastServerExit = null;
// 自动更新状态
let autoUpdater = null;
let autoUpdaterLoadError = null;
let updaterEventsBound = false;
let updaterChecking = false;
let updaterDownloading = false;
let updaterDialogOpen = false;
let updaterManualCheck = false;
let updaterStartupTimer = null;

// ---------------------------------------------------------------------------
// 日志（userData/logs/server.log，单文件上限 5MB）
// ---------------------------------------------------------------------------
function rotateLogIfNeeded() {
  try {
    const st = fs.statSync(appLogFile);
    if (st.size > LOG_MAX_BYTES) fs.renameSync(appLogFile, appLogFile + '.1');
  } catch {
    /* 文件不存在或权限问题：忽略 */
  }
}

function logLine(message) {
  const line = '[' + new Date().toISOString() + '] ' + message + '\n';
  try {
    fs.mkdirSync(logsDir, { recursive: true });
    rotateLogIfNeeded();
    fs.appendFileSync(appLogFile, line);
  } catch {
    /* 日志失败不阻断应用 */
  }
}

function logBoth(message) {
  logLine(message);
  try {
    fs.writeSync(1, '[dsh-desktop] ' + message + '\n');
  } catch {
    /* stdout closed */
  }
}

// 测试钩子输出必须同步写入，避免 app.exit() 前管道未 flush 导致断言失败
function emit(text) {
  try {
    fs.writeSync(1, text + '\n');
  } catch {
    /* ignore */
  }
}

function emitErr(text) {
  try {
    fs.writeSync(2, text + '\n');
  } catch {
    /* ignore */
  }
}

// dialog.showMessageBox 在无窗口时必须省略第一个参数
function showMessageBox(options) {
  const win = primaryWindow();
  return win ? dialog.showMessageBox(win, options) : dialog.showMessageBox(options);
}

function stripAnsi(text) {
  // eslint-disable-next-line no-control-regex
  return text.replace(/\u001b\[[0-9;]*[A-Za-z]/g, '');
}

// ---------------------------------------------------------------------------
// 运行时定位 / 启动命令解析
// ---------------------------------------------------------------------------
function runtimeArch() {
  return process.arch === 'arm64' ? 'arm64' : 'x64';
}

function resolveRuntimeDir() {
  if (process.env.DSH_LINUX_RUNTIME) return path.resolve(process.env.DSH_LINUX_RUNTIME);
  if (app.isPackaged) return path.join(process.resourcesPath, 'runtime');
  return path.resolve(__dirname, '..', 'runtime', 'linux-' + runtimeArch());
}

function firstExisting(candidates) {
  for (const c of candidates) {
    try {
      if (c && fs.existsSync(c)) return c;
    } catch {
      /* ignore */
    }
  }
  return null;
}

function resolveLaunch() {
  const runtimeDir = resolveRuntimeDir();
  const envNode = process.env.DSH_LINUX_NODE || null;
  const envEntry = process.env.DSH_LINUX_DSH_ENTRY || null;
  const nodeBin = envNode || firstExisting([
    path.join(runtimeDir, 'node', 'bin', 'node'),
    path.join(runtimeDir, 'bin', 'node'),
    path.join(runtimeDir, 'node', 'node'),
  ]);
  const dshEntry = envEntry || firstExisting([
    path.join(runtimeDir, 'node_modules', '@deepseek-ai', 'dsh', 'lib', 'bin.js'),
    path.join(runtimeDir, 'node_modules', '@deepseek-ai', 'dsh', 'bin', 'dsh.js'),
  ]);
  const wrapper = firstExisting([path.join(runtimeDir, 'bin', 'dsh')]);
  const explicit = Boolean(envNode || envEntry);
  // 显式覆盖或缺少 bin/dsh 包装时，直接 spawn <node> <dshEntry> ...
  const useNodeEntry = explicit || !wrapper;
  if (useNodeEntry) {
    return {
      runtimeDir,
      command: nodeBin,
      prefixArgs: [dshEntry],
      wrapper: null,
      nodeBin,
      dshEntry,
      error: !nodeBin ? '\u672a\u627e\u5230 Node \u53ef\u6267\u884c\u6587\u4ef6\uff08' + runtimeDir + '/node/bin/node\uff09\uff0c\u53ef\u7528 DSH_LINUX_NODE \u6307\u5b9a'
        : !dshEntry ? '\u672a\u627e\u5230 dsh \u5165\u53e3\uff08' + runtimeDir + '/node_modules/@deepseek-ai/dsh/lib/bin.js\uff09\uff0c\u53ef\u7528 DSH_LINUX_DSH_ENTRY \u6307\u5b9a'
        : null,
    };
  }
  return { runtimeDir, command: wrapper, prefixArgs: [], wrapper, nodeBin, dshEntry, error: null };
}

function ensureDir(dir) {
  try {
    fs.mkdirSync(dir, { recursive: true });
  } catch {
    /* ignore */
  }
  return dir;
}

// ---------------------------------------------------------------------------
// 服务进程
// ---------------------------------------------------------------------------
function serverAlive() {
  return Boolean(serverProc && serverProc.exitCode === null && !serverProc.killed);
}

function buildServerEnv(runtimeDir) {
  const env = { ...process.env };
  env.DSH_HOME = dshHome;
  env.HOME = env.HOME || os.homedir();
  env.USER = env.USER || (os.userInfo().username || 'user');
  const nodeBinDir = path.join(runtimeDir, 'node', 'bin');
  env.PATH = fs.existsSync(nodeBinDir) ? nodeBinDir + path.delimiter + (env.PATH || '') : env.PATH || '';
  env.LANG = env.LANG || 'C.UTF-8';
  env.LC_ALL = env.LC_ALL || env.LANG;
  // Electron 会注入这些变量，spawn 外部 Node 时应移除
  delete env.ELECTRON_RUN_AS_NODE;
  delete env.ELECTRON_NO_ATTACH_CONSOLE;
  delete env.ELECTRON_ENABLE_LOGGING;
  return env;
}

function startServer() {
  if (serverAlive()) return;
  serverReady = false;
  serverUrl = null;
  serverOrigin = null;
  lastServerExit = null;

  const launch = resolveLaunch();
  if (launch.error) {
    logBoth('runtime error: ' + launch.error);
    if (IS_TEST) {
      failTest('RUNTIME_NOT_FOUND: ' + launch.error);
    } else {
      showStartupError(launch.error);
    }
    return;
  }

  const dshArgs = ['web', '--no-open', '--host', cliArgs.host, '--port', String(cliArgs.port)];
  const args = launch.prefixArgs.concat(dshArgs);
  const env = buildServerEnv(launch.runtimeDir);
  logBoth('starting: ' + launch.command + ' ' + args.join(' '));
  logBoth('runtime: ' + launch.runtimeDir + ' | DSH_HOME: ' + dshHome);

  let child;
  try {
    child = spawn(launch.command, args, {
      cwd: os.homedir(),
      detached: true, // 独立进程组，退出时整组清理
      stdio: ['ignore', 'pipe', 'pipe'],
      env,
    });
  } catch (err) {
    const msg = '\u65e0\u6cd5\u542f\u52a8\u672c\u5730\u670d\u52a1: ' + String(err && err.message ? err.message : err);
    logBoth(msg);
    if (IS_TEST) failTest('SPAWN_ERROR: ' + msg);
    else showStartupError(msg);
    return;
  }
  serverProc = child;

  const onLine = (line, streamName) => {
    const clean = stripAnsi(line).trimEnd();
    if (!clean) return;
    logLine('[' + streamName + '] ' + clean);
    try {
      fs.writeSync(1, '[dsh] ' + clean + '\n');
    } catch {
      /* ignore */
    }
    if (serverUrl) return;
    const m = clean.match(/https?:\/\/(?:127\.0\.0\.1|localhost):\d+\/?\?token=[A-Za-z0-9_-]+/);
    const generic = m ? m[0] : (clean.match(/https?:\/\/(?:127\.0\.0\.1|localhost):\d+\/\S*token\S*/) || [])[0];
    if (generic) {
      serverUrl = generic.replace(/[)"'>,]+$/, '');
      try {
        serverOrigin = new URL(serverUrl).origin;
      } catch {
        serverOrigin = null;
      }
      logBoth('server ready: ' + serverUrl);
      onServerReady(serverUrl);
    }
  };

  const makeReader = (stream, name) => {
    let buffer = '';
    stream.setEncoding('utf8');
    stream.on('data', (chunk) => {
      buffer += chunk;
      const parts = buffer.split(/\r?\n/);
      buffer = parts.pop() ?? '';
      for (const line of parts) onLine(line, name);
    });
    stream.on('end', () => {
      if (buffer.trim()) onLine(buffer, name);
      buffer = '';
    });
  };
  makeReader(child.stdout, 'stdout');
  makeReader(child.stderr, 'stderr');

  startupTimer = setTimeout(() => {
    if (serverReady) return;
    const msg = '本地服务启动超时（60 秒）：未捕获到带 token 的访问地址。\n日志: ' + appLogFile;
    logBoth(msg);
    if (IS_TEST) {
      failTest('SMOKE_TIMEOUT');
    } else {
      showStartupError(msg);
    }
  }, SERVER_READY_TIMEOUT_MS);
  if (typeof startupTimer.unref === 'function') startupTimer.unref();

  child.on('error', (err) => {
    logBoth('server spawn failed: ' + String(err && err.message ? err.message : err));
    if (IS_TEST) failTest('SERVER_SPAWN_FAILED: ' + String(err && err.message ? err.message : err));
    else showStartupError('本地服务启动失败: ' + String(err && err.message ? err.message : err));
  });

  child.on('exit', (code, signal) => {
    logBoth('server exited: code=' + code + ' signal=' + signal);
    lastServerExit = { code, signal };
    clearTimeout(startupTimer);
    serverProc = null;
    if (quitting || quittingForTest) return;
    if (!serverReady) {
      // 启动阶段就退出
      const msg = '本地服务在启动阶段退出（code=' + code + ', signal=' + signal + '）。\n日志: ' + appLogFile;
      logBoth(msg);
      if (IS_TEST) failTest('SERVER_EXITED_EARLY: ' + msg);
      else showStartupError(msg);
      return;
    }
    if (crashDialogOpen) return;
    crashDialogOpen = true;
    onServerCrash(code, signal);
  });
}

function onServerReady(url) {
  serverReady = true;
  clearTimeout(startupTimer);
  if (mainWindow && !mainWindow.isDestroyed()) {
    mainWindow.loadURL(url).catch((err) => logBoth('loadURL failed: ' + err));
    return;
  }
  createMainWindow(url);
}

function waitServerExit(proc, ms) {
  return new Promise((resolve) => {
    if (!proc || proc.exitCode !== null) {
      resolve(true);
      return;
    }
    let done = false;
    const finish = (v) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      resolve(v);
    };
    const timer = setTimeout(() => finish(false), ms);
    proc.once('exit', () => finish(true));
  });
}

async function killServer() {
  const proc = serverProc;
  if (!proc) return;
  const pid = proc.pid;
  if (!pid || proc.exitCode !== null) {
    serverProc = null;
    return;
  }
  try {
    process.kill(-pid, 'SIGTERM'); // 整个进程组
  } catch {
    try {
      proc.kill('SIGTERM');
    } catch {
      /* ignore */
    }
  }
  const exited = await waitServerExit(proc, KILL_GRACE_MS);
  if (!exited) {
    logBoth('server did not exit in ' + KILL_GRACE_MS + 'ms, SIGKILL process group');
    try {
      process.kill(-pid, 'SIGKILL');
    } catch {
      /* ignore */
    }
    try {
      proc.kill('SIGKILL');
    } catch {
      /* ignore */
    }
    await waitServerExit(proc, 2_000);
  }
  serverProc = null;
}

function killServerSync() {
  const proc = serverProc;
  if (!proc || !proc.pid || proc.exitCode !== null) return;
  try {
    process.kill(-proc.pid, 'SIGKILL');
  } catch {
    try {
      proc.kill('SIGKILL');
    } catch {
      /* ignore */
    }
  }
}

// ---------------------------------------------------------------------------
// 窗口
// ---------------------------------------------------------------------------
function iconPath() {
  const p = path.join(app.getAppPath(), 'app', 'assets', 'icon.png');
  if (fs.existsSync(p)) return p;
  return path.join(__dirname, 'assets', 'icon.png');
}

function loadWindowState() {
  try {
    const raw = fs.readFileSync(windowStatePath, 'utf8');
    const s = JSON.parse(raw);
    if (s && Number.isFinite(s.width) && Number.isFinite(s.height)) {
      const width = Math.min(Math.max(Math.round(s.width), MIN_WIDTH), 100000);
      const height = Math.min(Math.max(Math.round(s.height), MIN_HEIGHT), 100000);
      let x;
      let y;
      if (Number.isFinite(s.x) && Number.isFinite(s.y)) {
        const area = screen.getDisplayMatching({ x: s.x, y: s.y, width, height }).workArea;
        const visible = s.x < area.x + area.width - 120 && s.x + width > area.x + 120 && s.y < area.y + area.height - 80 && s.y + height > area.y;
        if (visible) {
          x = s.x;
          y = s.y;
        }
      }
      return { width, height, x, y, maximized: Boolean(s.maximized) };
    }
  } catch {
    /* 首次启动 */
  }
  return { width: DEFAULT_WIDTH, height: DEFAULT_HEIGHT, x: undefined, y: undefined, maximized: false };
}

function saveWindowState(win) {
  if (!win || win.isDestroyed()) return;
  try {
    const maximized = win.isMaximized();
    const bounds = maximized ? win.getNormalBounds() : win.getBounds();
    const state = { ...bounds, maximized };
    fs.mkdirSync(path.dirname(windowStatePath), { recursive: true });
    fs.writeFileSync(windowStatePath, JSON.stringify(state, null, 2));
  } catch (err) {
    logBoth('save window state failed: ' + err);
  }
}

function attachSecurity(win) {
  const wc = win.webContents;
  wc.setWindowOpenHandler(({ url }) => {
    if (/^https?:\/\//i.test(url)) shell.openExternal(url).catch(() => {});
    return { action: 'deny' };
  });
  const allow = (url) => {
    if (!url) return false;
    if (url === 'about:blank' || url.startsWith('data:') || url.startsWith('devtools:')) return true;
    if (!serverOrigin) return false;
    try {
      return new URL(url).origin === serverOrigin;
    } catch {
      return false;
    }
  };
  wc.on('will-navigate', (event, url) => {
    if (allow(url)) return;
    event.preventDefault();
    if (/^https?:\/\//i.test(url)) shell.openExternal(url).catch(() => {});
  });
  wc.on('will-redirect', (event, url) => {
    if (allow(url)) return;
    event.preventDefault();
    if (/^https?:\/\//i.test(url)) shell.openExternal(url).catch(() => {});
  });
  wc.on('before-input-event', (event, input) => {
    if (input.type !== 'keyDown') return;
    const key = input.key;
    const ctrl = input.control || input.meta;
    if (key === 'F11') {
      event.preventDefault();
      toggleFullScreen();
      return;
    }
    if (key === 'F12' && (!app.isPackaged || cliArgs.dev)) {
      event.preventDefault();
      wc.toggleDevTools();
      return;
    }
    if (!ctrl) return;
    if (key === '=' || key === '+') {
      event.preventDefault();
      zoomBy(0.5);
    } else if (key === '-') {
      event.preventDefault();
      zoomBy(-0.5);
    } else if (key === '0') {
      event.preventDefault();
      wc.setZoomLevel(0);
    } else if (key.toLowerCase() === 'r') {
      event.preventDefault();
      if (input.shift) wc.reloadIgnoringCache();
      else wc.reload();
    } else if (key.toLowerCase() === 'q') {
      event.preventDefault();
      app.quit();
    }
  });
}

function zoomBy(delta) {
  if (!mainWindow || mainWindow.isDestroyed()) return;
  const wc = mainWindow.webContents;
  const next = Math.min(5, Math.max(-5, wc.getZoomLevel() + delta));
  wc.setZoomLevel(next);
}

function toggleFullScreen() {
  if (!mainWindow || mainWindow.isDestroyed()) return;
  mainWindow.setFullScreen(!mainWindow.isFullScreen());
}

function createSplashWindow() {
  splashWindow = new BrowserWindow({
    width: 440,
    height: 300,
    frame: false,
    resizable: false,
    movable: true,
    maximizable: false,
    minimizable: false,
    show: true,
    backgroundColor: '#0f1115',
    icon: iconPath(),
    title: APP_TITLE,
    webPreferences: {
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      spellcheck: false,
    },
  });
  splashWindow.center();
  splashWindow.loadFile(path.join(__dirname, 'splash.html'), {
    query: { version: appVersion() },
  }).catch((err) => logBoth('splash load failed: ' + err));
  splashWindow.on('closed', () => {
    splashWindow = null;
  });
}

function closeSplash() {
  if (splashWindow && !splashWindow.isDestroyed()) {
    splashWindow.close();
  }
  splashWindow = null;
}

function createMainWindow(url) {
  const state = loadWindowState();
  const win = new BrowserWindow({
    width: state.width,
    height: state.height,
    x: state.x,
    y: state.y,
    minWidth: MIN_WIDTH,
    minHeight: MIN_HEIGHT,
    show: false,
    title: APP_TITLE,
    backgroundColor: '#0f1115',
    icon: iconPath(),
    autoHideMenuBar: false,
    webPreferences: {
      preload: path.join(__dirname, 'preload.cjs'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      webSecurity: true,
      allowRunningInsecureContent: false,
      spellcheck: false,
      additionalArguments: [
        '--dsh-app-version=' + appVersion(),
        '--dsh-is-packaged=' + (app.isPackaged ? '1' : '0'),
      ],
    },
  });
  mainWindow = win;
  if (state.maximized) win.maximize();

  attachSecurity(win);

  let saveTimer = null;
  const scheduleSave = () => {
    clearTimeout(saveTimer);
    saveTimer = setTimeout(() => saveWindowState(win), 500);
  };
  win.on('resize', scheduleSave);
  win.on('move', scheduleSave);
  win.on('close', () => saveWindowState(win));
  win.on('closed', () => {
    if (mainWindow === win) mainWindow = null;
  });

  win.once('ready-to-show', () => {
    closeSplash();
    if (!win.isDestroyed()) {
      win.show();
      win.focus();
    }
  });

  win.webContents.on('did-finish-load', () => onPageLoaded(win));
  win.webContents.on('did-fail-load', (_event, errorCode, errorDescription, validatedURL, isMainFrame) => {
    if (!isMainFrame) return;
    logBoth('did-fail-load ' + errorCode + ' ' + errorDescription + ' url=' + validatedURL);
  });
  win.webContents.on('render-process-gone', (_event, details) => {
    logBoth('renderer gone: ' + JSON.stringify(details));
    if (!quitting) onRendererGone(details);
  });

  win.loadURL(url).catch((err) => logBoth('loadURL failed: ' + err));
}

function onPageLoaded(win) {
  if (testFinished || !IS_TEST || !win || win.isDestroyed()) return;
  if (!serverReady || !serverUrl) return;
  const current = win.webContents.getURL();
  if (serverOrigin && !current.startsWith(serverOrigin)) return;
  testFinished = true;
  // 无窗口管理器（xvfb）下 ready-to-show 可能不触发，测试时显式显示以保证可截图
  if (!win.isVisible()) win.show();

  if (cliArgs.screenshot) {
    const target = path.resolve(process.cwd(), cliArgs.screenshot);
    // 契约默认 did-finish-load + 2s；DSH_LINUX_SCREENSHOT_DELAY_MS 仅供截图取景调试
    const envDelay = Number(process.env.DSH_LINUX_SCREENSHOT_DELAY_MS);
    const delayMs = Number.isFinite(envDelay) && envDelay >= 0 ? envDelay : 2_000;
    setTimeout(async () => {
      try {
        const image = await win.webContents.capturePage();
        const png = image.toPNG();
        if (!png || png.length < 1000) throw new Error('captured PNG is empty');
        fs.mkdirSync(path.dirname(target), { recursive: true });
        fs.writeFileSync(target, png);
        emit('SCREENSHOT_OK ' + target + ' bytes=' + png.length);
        logBoth('screenshot saved: ' + target + ' (' + png.length + ' bytes)');
      } catch (err) {
        emitErr('SCREENSHOT_FAIL ' + String(err && err.stack ? err.stack : err));
        logBoth('screenshot failed: ' + err);
        await finishTest(1);
        return;
      }
      if (cliArgs.smokeTest) emit('SMOKE_OK ' + serverUrl);
      await finishTest(0);
    }, delayMs);
    return;
  }

  if (cliArgs.smokeTest) {
    emit('SMOKE_OK ' + serverUrl);
    finishTest(0);
  }
}

async function finishTest(code) {
  quittingForTest = true;
  clearTimeout(startupTimer);
  try {
    await killServer();
  } catch (err) {
    logBoth('killServer during test finish failed: ' + err);
  }
  const win = mainWindow;
  if (win && !win.isDestroyed()) {
    try {
      win.destroy();
    } catch {
      /* ignore */
    }
  }
  if (splashWindow && !splashWindow.isDestroyed()) {
    try {
      splashWindow.destroy();
    } catch {
      /* ignore */
    }
  }
  app.exit(code);
}

function failTest(reason) {
  if (testFinished) return;
  testFinished = true;
  clearTimeout(startupTimer);
  emitErr('SMOKE_FAIL ' + reason);
  logBoth('test failed: ' + reason);
  finishTest(1).catch(() => app.exit(1));
}

// ---------------------------------------------------------------------------
// 错误 / 崩溃对话框
// ---------------------------------------------------------------------------
function primaryWindow() {
  if (mainWindow && !mainWindow.isDestroyed()) return mainWindow;
  return undefined;
}

async function showStartupError(message) {
  if (crashDialogOpen) return;
  crashDialogOpen = true;
  const zh = isZhLocale();
  const buttons = zh ? ['重试', '打开日志', '退出'] : ['Retry', 'Open Logs', 'Quit'];
  const overlay = '本地服务启动失败';
  const openLogs = () => shell.openPath(logsDir).catch(() => {});
  try {
    const { response } = await showMessageBox({
      type: 'error',
      title: APP_TITLE,
      message: zh ? overlay : 'Local service failed to start',
      detail: message + '\n\n' + (zh ? '日志目录: ' : 'Logs: ') + appLogFile,
      buttons,
      defaultId: 0,
      cancelId: 2,
      noLink: true,
    });
    crashDialogOpen = false;
    if (response === 0) restartServer();
    else if (response === 1) openLogs();
    else app.quit();
  } catch (err) {
    crashDialogOpen = false;
    logBoth('startup error dialog failed: ' + err);
    app.quit();
  }
}

async function onServerCrash(code, signal) {
  const zh = isZhLocale();
  const buttons = zh ? ['重启服务', '打开日志', '退出'] : ['Restart', 'Open Logs', 'Quit'];
  logBoth('showing crash dialog (code=' + code + ', signal=' + signal + ')');
  try {
    const { response } = await showMessageBox({
      type: 'error',
      title: APP_TITLE,
      message: zh ? '本地服务已退出' : 'Local service exited',
      detail: (zh ? '退出码: ' : 'Exit code: ') + code + '  signal: ' + signal + '\n'
        + (zh ? '可重启服务恢复使用。日志: ' : 'Restart to recover. Logs: ') + appLogFile,
      buttons,
      defaultId: 0,
      cancelId: 2,
      noLink: true,
    });
    crashDialogOpen = false;
    if (response === 0) restartServer();
    else if (response === 1) shell.openPath(logsDir).catch(() => {});
    else app.quit();
  } catch (err) {
    crashDialogOpen = false;
    logBoth('crash dialog failed: ' + err);
    app.quit();
  }
}

function onRendererGone(details) {
  const zh = isZhLocale();
  const buttons = zh ? ['重新加载', '退出'] : ['Reload', 'Quit'];
  showMessageBox({
    type: 'error',
    title: APP_TITLE,
    message: zh ? '界面渲染进程已崩溃' : 'Renderer process crashed',
    detail: JSON.stringify(details),
    buttons,
    defaultId: 0,
    cancelId: 1,
    noLink: true,
  }).then(({ response }) => {
    if (response === 0) {
      if (mainWindow && !mainWindow.isDestroyed() && serverUrl) mainWindow.loadURL(serverUrl).catch(() => {});
    } else {
      app.quit();
    }
  }).catch(() => app.quit());
}

async function restartServer() {
  if (restarting) return;
  restarting = true;
  try {
    logBoth('restarting local service');
    await killServer();
    serverReady = false;
    serverUrl = null;
    serverOrigin = null;
    if (!splashWindow) createSplashWindow();
    startServer();
  } finally {
    restarting = false;
  }
}

// ---------------------------------------------------------------------------
// 菜单
// ---------------------------------------------------------------------------
function isZhLocale() {
  try {
    return (app.getLocale() || '').toLowerCase().startsWith('zh');
  } catch {
    return true; // 默认中文界面
  }
}

function menuText(zh) {
  return zh
    ? {
        file: '文件', openWorkspace: '打开工作区目录', openLogs: '打开日志目录', quit: '退出',
        edit: '编辑', undo: '撤销', redo: '重做', cut: '剪切', copy: '复制', paste: '粘贴', selectAll: '全选',
        view: '视图', reload: '重新加载', forceReload: '强制重新加载', devTools: '开发者工具',
        zoomIn: '放大', zoomOut: '缩小', resetZoom: '重置缩放', fullscreen: '全屏',
        help: '帮助', projectPage: '项目主页', checkUpdates: '检查更新…', about: '关于 DeepSeek Harness',
      }
    : {
        file: 'File', openWorkspace: 'Open Workspace Folder', openLogs: 'Open Logs Folder', quit: 'Quit',
        edit: 'Edit', undo: 'Undo', redo: 'Redo', cut: 'Cut', copy: 'Copy', paste: 'Paste', selectAll: 'Select All',
        view: 'View', reload: 'Reload', forceReload: 'Force Reload', devTools: 'Developer Tools',
        zoomIn: 'Zoom In', zoomOut: 'Zoom Out', resetZoom: 'Reset Zoom', fullscreen: 'Toggle Full Screen',
        help: 'Help', projectPage: 'Project Homepage', checkUpdates: 'Check for Updates…', about: 'About DeepSeek Harness',
      };
}

function buildMenu() {
  const zh = isZhLocale();
  logBoth('menu language: ' + (zh ? 'zh-CN' : 'en') + ' (app.getLocale=' + app.getLocale() + ')');
  const L = menuText(zh);
  const withWindow = (fn) => () => {
    if (!mainWindow || mainWindow.isDestroyed()) return;
    fn(mainWindow.webContents);
  };
  const template = [
    {
      label: L.file,
      submenu: [
        { label: L.openWorkspace, click: () => shell.openPath(dshHome).catch(() => {}) },
        { label: L.openLogs, click: () => shell.openPath(logsDir).catch(() => {}) },
        { type: 'separator' },
        { label: L.quit, role: 'quit', accelerator: 'CmdOrCtrl+Q' },
      ],
    },
    {
      label: L.edit,
      submenu: [
        { label: L.undo, role: 'undo' },
        { label: L.redo, role: 'redo' },
        { type: 'separator' },
        { label: L.cut, role: 'cut' },
        { label: L.copy, role: 'copy' },
        { label: L.paste, role: 'paste' },
        { label: L.selectAll, role: 'selectAll' },
      ],
    },
    {
      label: L.view,
      submenu: [
        {
          label: L.reload,
          accelerator: 'CmdOrCtrl+R',
          registerAccelerator: false,
          click: withWindow((wc) => wc.reload()),
        },
        {
          label: L.forceReload,
          accelerator: 'CmdOrCtrl+Shift+R',
          registerAccelerator: false,
          click: withWindow((wc) => wc.reloadIgnoringCache()),
        },
        ...(app.isPackaged ? [] : [{
          label: L.devTools,
          accelerator: 'F12',
          registerAccelerator: false,
          click: withWindow((wc) => wc.toggleDevTools()),
        }]),
        { type: 'separator' },
        { label: L.zoomIn, accelerator: 'CmdOrCtrl+=', registerAccelerator: false, click: () => zoomBy(0.5) },
        { label: L.zoomOut, accelerator: 'CmdOrCtrl+-', registerAccelerator: false, click: () => zoomBy(-0.5) },
        { label: L.resetZoom, accelerator: 'CmdOrCtrl+0', registerAccelerator: false, click: () => withWindow((wc) => wc.setZoomLevel(0))() },
        { type: 'separator' },
        { label: L.fullscreen, accelerator: 'F11', registerAccelerator: false, click: toggleFullScreen },
      ],
    },
    {
      label: L.help,
      role: 'help',
      submenu: [
        { label: L.projectPage, click: () => shell.openExternal(PROJECT_URL).catch(() => {}) },
        { label: L.openLogs, click: () => shell.openPath(logsDir).catch(() => {}) },
        { type: 'separator' },
        {
          label: L.checkUpdates,
          click: () => {
            runUpdateCheck(true).catch((err) => logBoth('updater: manual check failed: ' + errText(err)));
          },
        },
        { type: 'separator' },
        { label: L.about, click: showAboutDialog },
      ],
    },
  ];
  Menu.setApplicationMenu(Menu.buildFromTemplate(template));
}

function showAboutDialog() {
  const zh = isZhLocale();
  const launch = resolveLaunch();
  const detail = [
    (zh ? '版本: ' : 'Version: ') + appVersion(),
    'Electron: ' + process.versions.electron,
    'Chromium: ' + process.versions.chrome,
    'Node: ' + process.versions.node,
    (zh ? '运行时: ' : 'Runtime: ') + launch.runtimeDir,
    (zh ? '数据目录: ' : 'User data: ') + app.getPath('userData'),
    '',
    zh ? '非官方 Linux 桌面构建，基于官方 @deepseek-ai/dsh。' : 'Unofficial Linux desktop build based on the official @deepseek-ai/dsh.',
  ].join('\n');
  showMessageBox({
    type: 'info',
    title: APP_TITLE,
    message: APP_TITLE,
    detail,
    buttons: [zh ? '确定' : 'OK'],
    noLink: true,
  }).catch(() => {});
}

// ---------------------------------------------------------------------------
// 应用内自动更新（electron-updater 6.8.11）
// ---------------------------------------------------------------------------
function errText(err) {
  if (!err) return 'unknown error';
  return String(err && err.stack ? err.stack : err && err.message ? err.message : err);
}

function updaterText(zh) {
  return zh
    ? {
        checkUpdates: '检查更新…',
        upToDate: '已是最新版本',
        upToDateDetail: (cur) => '当前版本 ' + cur + ' 已是最新版本。',
        available: (ver) => '发现新版本 ' + ver,
        availableDetail: (cur, ver, notes) => '当前版本：' + cur + '\n最新版本：' + ver + (notes ? '\n\n发行说明：\n' + notes : ''),
        downloadAndInstall: '下载并安装',
        later: '稍后',
        downloaded: (ver) => '更新已下载完成',
        downloadedDetail: (ver) => '新版本 ' + ver + ' 已下载完成。立即重启应用完成安装？\n（选择“稍后”会在下次退出应用时自动安装）',
        restartNow: '立即重启并安装',
        checkFailed: '检查更新失败',
        downloadFailed: '下载更新失败',
        manualOnly: '此安装方式不支持应用内自动更新',
        manualOnlyDetail: (ver) => '当前版本：' + ver + '\n应用内自动更新仅支持 AppImage 格式。\ndeb 安装包请从 GitHub Releases 下载新版本后手动安装：\n' + RELEASES_URL,
        devBuild: '开发模式下不检查更新',
        devBuildDetail: '当前运行的是未打包的源码版本，应用内自动更新仅在打包后的 AppImage 中生效。',
        disabled: '自动更新已禁用',
        disabledDetail: '环境变量 DSH_LINUX_DISABLE_UPDATER=1 已禁用自动更新检查。',
        unavailable: '自动更新组件不可用',
        unavailableDetail: (detail) => '无法加载 electron-updater，应用内自动更新不可用。\n\n' + detail + '\n\n仍可在 GitHub Releases 页面手动下载新版本：\n' + RELEASES_URL,
        openReleases: '打开发布页',
        close: '关闭',
      }
    : {
        checkUpdates: 'Check for Updates…',
        upToDate: 'You are up to date',
        upToDateDetail: (cur) => 'Version ' + cur + ' is the latest version.',
        available: (ver) => 'New version available: ' + ver,
        availableDetail: (cur, ver, notes) => 'Current version: ' + cur + '\nLatest version: ' + ver + (notes ? '\n\nRelease notes:\n' + notes : ''),
        downloadAndInstall: 'Download and Install',
        later: 'Later',
        downloaded: (ver) => 'Update downloaded',
        downloadedDetail: (ver) => 'Version ' + ver + ' has been downloaded. Restart now to install?\n(Choose "Later" to install automatically the next time the app quits.)',
        restartNow: 'Restart and Install',
        checkFailed: 'Update check failed',
        downloadFailed: 'Update download failed',
        manualOnly: 'In-app updates are not supported for this installation',
        manualOnlyDetail: (ver) => 'Current version: ' + ver + '\nIn-app auto-update is only supported for the AppImage build.\nFor the .deb package, download the new version from GitHub Releases: \n' + RELEASES_URL,
        devBuild: 'Update check is disabled in development mode',
        devBuildDetail: 'This is an unpackaged source build; auto-update only works in the packaged AppImage.',
        disabled: 'Auto-update is disabled',
        disabledDetail: 'The environment variable DSH_LINUX_DISABLE_UPDATER=1 disables the update check.',
        unavailable: 'Update component unavailable',
        unavailableDetail: (detail) => 'Failed to load electron-updater; in-app auto-update is unavailable.\n\n' + detail + '\n\nYou can still download the latest version manually from GitHub Releases:\n' + RELEASES_URL,
        openReleases: 'Open Releases',
        close: 'Close',
      };
}

function updaterEnabled() {
  if (UPDATER_DISABLED) return false;
  if (IS_TEST) return false;
  if (!app.isPackaged) return false;
  if (!process.env.APPIMAGE) return false;
  return true;
}

function showReleasesDialog(message, detail) {
  const L = updaterText(isZhLocale());
  return showMessageBox({
    type: 'info',
    title: APP_TITLE,
    message,
    detail,
    buttons: [L.openReleases, L.close],
    defaultId: 0,
    cancelId: 1,
    noLink: true,
  }).then(({ response }) => {
    if (response === 0) shell.openExternal(RELEASES_URL).catch(() => {});
  }).catch((err) => logBoth('updater: dialog failed: ' + errText(err)));
}

function bindUpdaterEvents() {
  if (updaterEventsBound || !autoUpdater) return;
  // --updater-check（测试钩子）自行监听事件，不注册交互式对话框处理器
  if (cliArgs.updaterCheck) return;
  updaterEventsBound = true;
  const u = autoUpdater;
  u.on('checking-for-update', () => logBoth('updater: checking for update'));
  u.on('update-available', (info) => {
    logBoth('updater: update available version=' + (info && info.version));
    onUpdateAvailable(info).catch((err) => logBoth('updater: update-available handler failed: ' + errText(err)));
  });
  u.on('update-not-available', (info) => {
    logBoth('updater: no update available (current=' + appVersion() + ', remote=' + (info && info.version) + ')');
    if (!updaterManualCheck) return;
    updaterManualCheck = false;
    const L = updaterText(isZhLocale());
    showMessageBox({
      type: 'info',
      title: APP_TITLE,
      message: L.upToDate,
      detail: L.upToDateDetail(appVersion()),
      buttons: [L.close],
      noLink: true,
    }).catch(() => {});
  });
  u.on('error', (err) => logBoth('updater: event error: ' + errText(err)));
  u.on('download-progress', (progress) => {
    const percent = progress && Number.isFinite(progress.percent) ? Math.round(progress.percent) : -1;
    if (percent < 0) return;
    if (mainWindow && !mainWindow.isDestroyed()) mainWindow.setProgressBar(Math.min(1, percent / 100));
    if (percent === 100 || percent >= updaterLastProgressLog + 20) {
      updaterLastProgressLog = percent;
      logBoth('updater: download progress ' + percent + '%');
    }
  });
  u.on('update-downloaded', (info) => {
    logBoth('updater: update downloaded version=' + (info && info.version));
    updaterDownloading = false;
    resetUpdaterProgress();
    promptInstallUpdate(info).catch((err) => logBoth('updater: install prompt failed: ' + errText(err)));
  });
}

let updaterLastProgressLog = -1;

function resetUpdaterProgress() {
  if (mainWindow && !mainWindow.isDestroyed()) mainWindow.setProgressBar(-1);
}

function releaseNotesText(info) {
  const notes = info && info.releaseNotes;
  let text = '';
  if (typeof notes === 'string') {
    text = notes;
  } else if (Array.isArray(notes)) {
    text = notes
      .map((n) => (n && (n.version ? n.version + ': ' : '') + (n.note || '')).trim())
      .filter(Boolean)
      .join('\n\n');
  }
  text = String(text).replace(/<[^>]+>/g, '').trim();
  if (!text) return '';
  return text.length > 3000 ? text.slice(0, 3000) + '…' : text;
}

function setupAutoUpdater(candidate, source) {
  autoUpdater = candidate;
  try {
    autoUpdater.logger = {
      info: (m) => logLine('updater: ' + m),
      warn: (m) => logLine('updater WARN: ' + m),
      error: (m) => logLine('updater ERROR: ' + m),
      debug: () => {},
    };
    autoUpdater.autoDownload = false;
    autoUpdater.autoInstallOnAppQuit = true;
    autoUpdater.allowPrerelease = false;
    autoUpdater.allowDowngrade = false;
    if (UPDATER_FEED_URL) {
      autoUpdater.setFeedURL({ provider: 'generic', url: UPDATER_FEED_URL });
      logBoth('updater: feed override -> ' + UPDATER_FEED_URL);
    }
  } catch (err) {
    logBoth('updater: configuration warning: ' + errText(err));
  }
  logBoth('updater: electron-updater loaded via ' + source + ' (current=' + appVersion()
    + ', feed=' + (UPDATER_FEED_URL || 'app-update.yml') + ')');
  bindUpdaterEvents();
  return autoUpdater;
}

// 动态 import 在部分 Electron/asar 组合下会失败，失败时用 createRequire 兜底，
// 两者都失败则降级为“应用内更新不可用”，不影响桌面壳正常启动。
async function loadAutoUpdater() {
  if (autoUpdater) return autoUpdater;
  if (autoUpdaterLoadError) return null;
  const failures = [];
  try {
    const mod = await import('electron-updater');
    const candidate = mod.autoUpdater || (mod.default && mod.default.autoUpdater) || null;
    if (!candidate) throw new Error('模块未导出 autoUpdater');
    return setupAutoUpdater(candidate, 'dynamic import');
  } catch (err) {
    failures.push('import: ' + errText(err));
    logBoth('updater: dynamic import failed, falling back to createRequire: ' + errText(err));
  }
  try {
    const { createRequire } = await import('node:module');
    const require = createRequire(import.meta.url);
    const mod = require('electron-updater');
    const candidate = mod.autoUpdater || (mod.default && mod.default.autoUpdater) || null;
    if (!candidate) throw new Error('模块未导出 autoUpdater');
    return setupAutoUpdater(candidate, 'createRequire');
  } catch (err) {
    failures.push('require: ' + errText(err));
    autoUpdaterLoadError = failures.join(' | ');
    logBoth('updater: electron-updater unavailable: ' + autoUpdaterLoadError);
    return null;
  }
}

async function onUpdateAvailable(info) {
  const version = (info && info.version) || '?';
  updaterManualCheck = false;
  if (updaterDialogOpen) return;
  updaterDialogOpen = true;
  const L = updaterText(isZhLocale());
  let response = 1;
  try {
    const notes = releaseNotesText(info);
    const result = await showMessageBox({
      type: 'info',
      title: APP_TITLE,
      message: L.available(version),
      detail: L.availableDetail(appVersion(), version, notes),
      buttons: [L.downloadAndInstall, L.later],
      defaultId: 0,
      cancelId: 1,
      noLink: true,
    });
    response = result.response;
  } catch (err) {
    logBoth('updater: update-available dialog failed: ' + errText(err));
  } finally {
    updaterDialogOpen = false;
  }
  if (response === 0) await downloadUpdate();
}

async function downloadUpdate() {
  if (!autoUpdater || updaterDownloading) return;
  updaterDownloading = true;
  updaterLastProgressLog = -1;
  logBoth('updater: downloading update');
  try {
    await autoUpdater.downloadUpdate();
  } catch (err) {
    updaterDownloading = false;
    resetUpdaterProgress();
    logBoth('updater: download failed: ' + errText(err));
    const L = updaterText(isZhLocale());
    showReleasesDialog(L.downloadFailed, errText(err) + '\n\n' + RELEASES_URL).catch(() => {});
  }
}

async function promptInstallUpdate(info) {
  const L = updaterText(isZhLocale());
  const version = (info && info.version) || appVersion();
  try {
    const { response } = await showMessageBox({
      type: 'info',
      title: APP_TITLE,
      message: L.downloaded(version),
      detail: L.downloadedDetail(version),
      buttons: [L.restartNow, L.later],
      defaultId: 0,
      cancelId: 1,
      noLink: true,
    });
    if (response === 0) {
      logBoth('updater: quitAndInstall');
      autoUpdater.quitAndInstall(false, true);
    } else {
      logBoth('updater: install deferred (autoInstallOnAppQuit=true)');
    }
  } catch (err) {
    logBoth('updater: install dialog failed: ' + errText(err));
  }
}

async function runUpdateCheck(manual) {
  const L = updaterText(isZhLocale());
  if (UPDATER_DISABLED) {
    if (manual) showReleasesDialog(L.disabled, L.disabledDetail).catch(() => {});
    return;
  }
  if (!app.isPackaged) {
    if (manual) showReleasesDialog(L.devBuild, L.devBuildDetail).catch(() => {});
    return;
  }
  if (!process.env.APPIMAGE) {
    // deb / tar.gz / 手动安装：没有应用内更新通道
    if (manual) showReleasesDialog(L.manualOnly, L.manualOnlyDetail(appVersion())).catch(() => {});
    return;
  }
  if (updaterChecking) {
    logBoth('updater: update check already in progress');
    return;
  }
  const updater = await loadAutoUpdater();
  if (!updater) {
    if (manual) showReleasesDialog(L.unavailable, L.unavailableDetail(autoUpdaterLoadError || 'unknown error')).catch(() => {});
    return;
  }
  updaterChecking = true;
  updaterManualCheck = manual;
  logBoth('updater: checking for updates (manual=' + manual + ')');
  try {
    const info = await updater.checkForUpdates();
    if (info == null) {
      updaterManualCheck = false;
      logBoth('updater: checkForUpdates returned null (updater inactive)');
      if (manual) showReleasesDialog(L.unavailable, L.unavailableDetail('更新检查未启用（APPIMAGE 环境缺失或更新器被禁用）')).catch(() => {});
    }
  } catch (err) {
    updaterManualCheck = false;
    logBoth('updater: update check failed: ' + errText(err));
    if (manual) showReleasesDialog(L.checkFailed, errText(err) + '\n\n' + RELEASES_URL).catch(() => {});
  } finally {
    updaterChecking = false;
  }
}

function scheduleStartupUpdateCheck() {
  if (!updaterEnabled()) {
    const reason = UPDATER_DISABLED
      ? 'DSH_LINUX_DISABLE_UPDATER=1'
      : IS_TEST
        ? 'test mode'
        : !app.isPackaged
          ? 'not packaged'
          : 'no APPIMAGE env (deb / manual install)';
    logBoth('updater: automatic update check disabled (' + reason + ')');
    return;
  }
  updaterStartupTimer = setTimeout(() => {
    updaterStartupTimer = null;
    runUpdateCheck(false).catch((err) => logBoth('updater: startup check failed: ' + errText(err)));
  }, UPDATER_STARTUP_DELAY_MS);
  if (typeof updaterStartupTimer.unref === 'function') updaterStartupTimer.unref();
  logBoth('updater: startup update check scheduled in ' + UPDATER_STARTUP_DELAY_MS / 1000 + 's');
}

// --updater-check 测试钩子：无窗口执行一次检查并输出结果后退出。
async function runUpdaterCheckHook() {
  const feed = UPDATER_FEED_URL || '(app-update.yml)';
  emit('UPDATER_CHECK current=' + appVersion() + ' packaged=' + app.isPackaged
    + ' appimage=' + Boolean(process.env.APPIMAGE) + ' feed=' + feed);
  logBoth('updater-check: requested (feed=' + feed + ')');
  if (!process.env.APPIMAGE) {
    emit('UPDATER_SKIPPED appimage-env-missing');
    app.exit(0);
    return;
  }
  const updater = await loadAutoUpdater();
  if (!updater) {
    emitErr('UPDATE_ERROR ' + (autoUpdaterLoadError || 'electron-updater unavailable'));
    app.exit(1);
    return;
  }
  const result = await new Promise((resolve) => {
    let done = false;
    const finish = (r) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      resolve(r);
    };
    const timer = setTimeout(() => finish({ kind: 'error', detail: 'timeout waiting for updater event' }), 45_000);
    updater.once('update-available', (info) => finish({ kind: 'available', version: info && info.version }));
    updater.once('update-not-available', (info) => finish({ kind: 'none', version: info && info.version }));
    updater.once('error', (err) => finish({ kind: 'error', detail: errText(err) }));
    Promise.resolve()
      .then(() => updater.checkForUpdates())
      .then((info) => {
        if (info == null) finish({ kind: 'inactive', detail: 'checkForUpdates returned null' });
      })
      .catch((err) => finish({ kind: 'error', detail: errText(err) }));
  });
  if (result.kind === 'available') {
    emit('UPDATE_AVAILABLE ' + result.version);
    logBoth('updater-check: UPDATE_AVAILABLE ' + result.version);
    app.exit(0);
  } else if (result.kind === 'none') {
    emit('UPDATE_NONE current=' + appVersion() + ' remote=' + (result.version || '?'));
    logBoth('updater-check: UPDATE_NONE');
    app.exit(0);
  } else if (result.kind === 'inactive') {
    emitErr('UPDATE_INACTIVE ' + result.detail);
    logBoth('updater-check: UPDATE_INACTIVE');
    app.exit(1);
  } else {
    emitErr('UPDATE_ERROR ' + result.detail);
    logBoth('updater-check: UPDATE_ERROR ' + result.detail);
    app.exit(1);
  }
}

// ---------------------------------------------------------------------------
// 应用启动
// ---------------------------------------------------------------------------
function initPaths() {
  logsDir = ensureDir(path.join(app.getPath('userData'), 'logs'));
  appLogFile = path.join(logsDir, 'server.log');
  windowStatePath = path.join(app.getPath('userData'), 'window-state.json');
  const configuredHome = cliArgs.dshHome || process.env.DSH_LINUX_HOME;
  dshHome = configuredHome ? path.resolve(configuredHome) : path.join(app.getPath('userData'), 'dsh-home');
  ensureDir(dshHome);
}

function setupPermissions() {
  const allowed = new Set(['clipboard-sanitized-write', 'notifications']);
  session.defaultSession.setPermissionRequestHandler((_wc, permission, callback) => {
    callback(allowed.has(permission));
  });
  session.defaultSession.setPermissionCheckHandler((_wc, permission) => allowed.has(permission));
}

function setupAppEvents() {
  app.on('second-instance', () => {
    logLine('second instance detected, focusing main window');
    const win = mainWindow;
    if (win && !win.isDestroyed()) {
      if (win.isMinimized()) win.restore();
      if (!win.isVisible()) win.show();
      win.focus();
    }
  });

  app.on('window-all-closed', () => {
    app.quit();
  });

  app.on('before-quit', (event) => {
    if (quitting) return;
    quitting = true;
    logBoth('quitting: terminating local service process group');
    if (serverAlive()) {
      event.preventDefault();
      killServer().then(() => app.quit()).catch(() => app.quit());
    }
  });

  app.on('will-quit', () => {
    clearTimeout(startupTimer);
    clearTimeout(updaterStartupTimer);
    killServerSync();
  });

  for (const sig of ['SIGINT', 'SIGTERM', 'SIGHUP']) {
    process.on(sig, () => {
      logBoth('received ' + sig + ', shutting down');
      quitting = true;
      killServerSync();
      app.exit(0);
    });
  }

  process.on('exit', () => killServerSync());
}

async function main() {
  process.env.DSH_APP_VERSION = appVersion();
  process.env.DSH_IS_PACKAGED = app.isPackaged ? '1' : '0';
  initPaths();

  // --updater-check：无窗口的更新检查测试钩子（验证 asar 内的 electron-updater 与发布元数据）
  if (cliArgs.updaterCheck) {
    await runUpdaterCheckHook();
    return;
  }

  setupAppEvents();
  setupPermissions();
  buildMenu();

  if (IS_TEST) {
    logBoth('test mode: smoke=' + cliArgs.smokeTest + ' screenshot=' + (cliArgs.screenshot || '-'));
  }
  createSplashWindow();
  startServer();
  scheduleStartupUpdateCheck();
}

const gotLock = app.requestSingleInstanceLock();
if (!gotLock) {
  process.stderr.write('another instance is already running; exiting\n');
  app.exit(0);
} else {
  app.whenReady().then(() => {
    if (app.isPackaged) {
      // 打包后禁用默认菜单的自动隐藏，保持应用菜单可见
      app.setAboutPanelOptions({ applicationName: APP_TITLE, applicationVersion: appVersion() });
    }
    main().catch((err) => {
      logBoth('fatal: ' + String(err && err.stack ? err.stack : err));
      if (IS_TEST) finishTest(1).catch(() => app.exit(1));
      else {
        dialog.showErrorBox(APP_TITLE, String(err && err.stack ? err.stack : err));
        app.quit();
      }
    });
  }).catch((err) => {
    process.stderr.write('app ready failed: ' + String(err) + '\n');
    app.exit(1);
  });
}
