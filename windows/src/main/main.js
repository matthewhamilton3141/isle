// main.js
//
// Entry point. Isle is a tray app — no taskbar entry, no main window.
// Everything the user sees is either the island overlay (a transparent,
// non-activating, always-on-top window hugging the top of the screen) or the
// tray menu, plus the Settings and Setup windows opened from it.
//
// The main process owns the subsystems — the SMTC bridge, the Claude bridge,
// the Pomodoro clock, the settings file — and streams one state snapshot to
// the overlay whenever anything changes. The overlay owns presentation: hover,
// animation, layout, the playback clock, the palette.

'use strict';

const path = require('path');

// `--isle-cli`: run as the hook helper and exit before touching the GUI. This
// is the fallback launcher HookInstaller writes when node.exe isn't on PATH.
const cliIndex = process.argv.indexOf('--isle-cli');
if (cliIndex >= 0) {
  process.argv = [process.argv[0], 'isle-cli', ...process.argv.slice(cliIndex + 1)];
  require('./claude/isle-cli.js');
  require('electron').app.exit(process.exitCode || 0);
  return;
}

const {
  app, BrowserWindow, Tray, Menu, ipcMain, screen, session, desktopCapturer,
  nativeTheme, dialog, shell,
} = require('electron');

const { SettingsStore } = require('./settings-store');
const { PomodoroTimer } = require('./pomodoro');
const { SmtcClient } = require('./media/smtc-client');
const { ClaudeModel } = require('./claude/claude-model');
const hooks = require('./claude/hook-installer');
const { GEOMETRY, WINDOW } = require('./geometry');
const { trayIcon } = require('./tray-icon');

const isDev = process.argv.includes('--dev');

if (!app.requestSingleInstanceLock()) {
  app.quit();
  return;
}

// A tray app must not quit when its last window closes.
app.on('window-all-closed', () => {});

const settings = new SettingsStore(path.join(app.getPath('userData'), 'settings.json'));
const pomodoro = new PomodoroTimer(settings);
const smtc = new SmtcClient();
const claude = new ClaudeModel(settings);

let overlay = null;
let settingsWindow = null;
let setupWindow = null;
let tray = null;
let overlayShown = false;

/** How hooks reach Isle's own binary when node.exe isn't available. */
function launcher() {
  return { exe: process.execPath, appPath: app.isPackaged ? null : app.getAppPath() };
}

// MARK: - State fan-out

function snapshot() {
  return {
    settings: settings.snapshot(),
    claude: claude.snapshot(),
    pomodoro: pomodoro.snapshot(),
    media: smtc.last,
    hookInstalled: hooks.isInstalled(),
    version: app.getVersion(),
  };
}

function send(win, channel, payload) {
  if (win && !win.isDestroyed()) win.webContents.send(channel, payload);
}

function broadcast() {
  const state = snapshot();
  send(overlay, 'state', state);
  send(settingsWindow, 'state', state);
  send(setupWindow, 'state', state);
}

settings.on('change', () => {
  applyMode();
  broadcast();
});
pomodoro.on('change', broadcast);
pomodoro.on('intervalEnded', (phase) => {
  if (settings.get('pomodoroSound')) send(overlay, 'pomodoro:ended', phase);
});
claude.on('change', () => send(overlay, 'state', snapshot()));
smtc.on('update', () => send(overlay, 'state', snapshot()));

// Switching the Pomodoro off takes the timer with it.
settings.on('change', (keys) => {
  if (keys.includes('pomodoroEnabled') && !settings.get('pomodoroEnabled')) pomodoro.reset();
});

/** Brings the running subsystems in line with the active mode. */
function applyMode() {
  if (!overlayShown) {
    smtc.stop(); claude.stop();
    return;
  }
  settings.showsMusic ? smtc.start() : smtc.stop();
  settings.showsClaude ? claude.start() : claude.stop();
}

// MARK: - Overlay

function overlayBounds() {
  const display = screen.getPrimaryDisplay();
  const { x, y, width } = display.bounds;
  return {
    x: Math.round(x + (width - WINDOW.width) / 2),
    y,
    width: WINDOW.width,
    height: WINDOW.height,
  };
}

function createOverlay() {
  if (overlay) return overlay;
  overlay = new BrowserWindow({
    ...overlayBounds(),
    frame: false,
    transparent: true,
    backgroundColor: '#00000000',
    alwaysOnTop: true,
    skipTaskbar: true,
    // Never takes focus — clicks act on the island without activating it,
    // the counterpart of the Mac app's non-activating panel.
    focusable: false,
    resizable: false,
    movable: false,
    minimizable: false,
    maximizable: false,
    fullscreenable: false,
    hasShadow: false,
    show: false,
    webPreferences: {
      preload: path.join(__dirname, '..', 'preload', 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false,
      backgroundThrottling: false,
      additionalArguments: [`--isle-geometry=${JSON.stringify(GEOMETRY)}`],
    },
  });
  overlay.setAlwaysOnTop(true, 'screen-saver');
  overlay.setMenu(null);
  // Transparent to the mouse everywhere except the drawn island — the
  // renderer flips this on and off as the pointer moves (see setInteractive).
  overlay.setIgnoreMouseEvents(true, { forward: true });
  overlay.loadFile(path.join(__dirname, '..', 'renderer', 'overlay', 'index.html'));
  overlay.webContents.on('did-finish-load', broadcast);
  overlay.on('closed', () => { overlay = null; });
  overlay.webContents.on('console-message', (event) => {
    if (isDev || event.level === 'warning' || event.level === 'error') console.log(`[overlay:${event.level}] ${event.message} (${event.sourceId}:${event.lineNumber})`);
  });
  if (isDev) overlay.webContents.openDevTools({ mode: 'detach' });
  return overlay;
}

function showOverlay() {
  overlayShown = true;
  const win = createOverlay();
  win.setBounds(overlayBounds());
  win.showInactive();
  applyMode();
  broadcast();
}

function hideOverlay() {
  overlayShown = false;
  if (overlay) overlay.hide();
  applyMode();
}

function toggleOverlay() { overlayShown ? hideOverlay() : showOverlay(); }

// MARK: - Secondary windows

function openSecondary(existing, options, page, onClosed) {
  if (existing && !existing.isDestroyed()) {
    existing.show();
    existing.focus();
    return existing;
  }
  const win = new BrowserWindow({
    ...options,
    show: false,
    autoHideMenuBar: true,
    backgroundColor: '#000000',
    webPreferences: {
      preload: path.join(__dirname, '..', 'preload', 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false,
    },
  });
  win.setMenu(null);
  win.loadFile(path.join(__dirname, '..', 'renderer', page, 'index.html'));
  win.webContents.on('did-finish-load', () => send(win, 'state', snapshot()));
  win.once('ready-to-show', () => { win.show(); win.focus(); });
  win.on('closed', onClosed);
  return win;
}

function openSettings() {
  settingsWindow = openSecondary(settingsWindow, {
    width: 760, height: 560, minWidth: 640, minHeight: 420, title: 'Isle Settings',
  }, 'settings', () => { settingsWindow = null; });
}

function openSetup() {
  setupWindow = openSecondary(setupWindow, {
    width: 520, height: 560, resizable: false, title: 'Isle Setup',
  }, 'onboarding', () => { setupWindow = null; });
}

// MARK: - Tray

function buildTrayMenu() {
  const mode = settings.effectiveMode;
  return Menu.buildFromTemplate([
    { label: overlayShown ? 'Hide Island' : 'Show Island', click: toggleOverlay },
    {
      label: 'Pop out island for alerts', type: 'checkbox', checked: settings.get('expandOnAlert'),
      click: (item) => settings.update({ expandOnAlert: item.checked }),
    },
    { type: 'separator' },
    { label: 'Mode', enabled: false },
    ...[['music', 'Music'], ['claude', 'Claude Code'], ['both', 'Both']].map(([value, label]) => ({
      label, type: 'radio', checked: mode === value, click: () => settings.update({ mode: value }),
    })),
    { type: 'separator' },
    { label: 'Settings…', click: openSettings },
    { label: 'Setup…', click: openSetup },
    { type: 'separator' },
    { label: 'Quit Isle', click: () => app.quit() },
  ]);
}

function refreshTray() {
  if (!tray) return;
  tray.setImage(trayIcon(nativeTheme.shouldUseDarkColors));
  tray.setContextMenu(buildTrayMenu());
}

function createTray() {
  tray = new Tray(trayIcon(nativeTheme.shouldUseDarkColors));
  tray.setToolTip('Isle');
  tray.on('click', () => tray.popUpContextMenu());
  refreshTray();
  nativeTheme.on('updated', refreshTray);
  settings.on('change', refreshTray);
}

// MARK: - IPC

ipcMain.on('overlay:interactive', (_event, interactive) => {
  if (!overlay) return;
  if (interactive) overlay.setIgnoreMouseEvents(false);
  else overlay.setIgnoreMouseEvents(true, { forward: true });
});

// While the island is open, the renderer asks for the cursor position on a
// timer as well as from forwarded moves. Forwarding stops the instant the
// pointer leaves the window's footprint — often without a final event — and
// the poll is what closes the panel then. Off while collapsed, so it costs
// nothing at rest.
let pointerPoll = null;
ipcMain.on('overlay:poll-pointer', (_event, wanted) => {
  if (wanted && !pointerPoll) {
    pointerPoll = setInterval(() => {
      if (!overlay || overlay.isDestroyed()) return;
      const point = screen.getCursorScreenPoint();
      const bounds = overlay.getBounds();
      send(overlay, 'pointer', { x: point.x - bounds.x, y: point.y - bounds.y });
    }, 50);
  } else if (!wanted && pointerPoll) {
    clearInterval(pointerPoll);
    pointerPoll = null;
  }
});

ipcMain.on('media:command', (_event, command, arg) => {
  switch (command) {
    case 'playpause': smtc.playPause(); break;
    case 'next': smtc.next(); break;
    case 'prev': smtc.previous(); break;
    case 'seek': smtc.seek(arg); break;
    case 'shuffle': smtc.setShuffle(!!arg); break;
    case 'repeat': smtc.setRepeat(arg); break;
    default: break;
  }
});

ipcMain.on('pomodoro:action', (_event, action) => {
  if (action === 'toggle') pomodoro.toggle();
  else if (action === 'skip') pomodoro.skip();
  else if (action === 'reset') pomodoro.reset();
});

ipcMain.on('settings:update', (_event, partial) => settings.update(partial));
ipcMain.handle('state:get', () => snapshot());

ipcMain.handle('hooks:install', () => {
  try {
    hooks.install(launcher());
    settings.update({ hookInstalledVersion: hooks.CURRENT_VERSION });
    broadcast();
    return { ok: true, message: `Installed to ${hooks.paths.binDir} and wired into ~/.claude/settings.json.` };
  } catch (error) {
    return { ok: false, message: error.message };
  }
});

ipcMain.handle('hooks:uninstall', () => {
  try {
    hooks.uninstall();
    broadcast();
    return { ok: true, message: 'Removed. Your other Claude Code hooks were left untouched.' };
  } catch (error) {
    return { ok: false, message: error.message };
  }
});

ipcMain.on('window:close', (event) => {
  const win = BrowserWindow.fromWebContents(event.sender);
  if (win) win.close();
});
ipcMain.on('open:settings', openSettings);
ipcMain.on('open:setup', openSetup);
ipcMain.on('open:external', (_event, url) => {
  if (typeof url === 'string' && /^https?:\/\//.test(url)) shell.openExternal(url);
});

// MARK: - Lifecycle

app.whenReady().then(() => {
  // The live waveform: Chromium's getDisplayMedia asks the app which source
  // to hand over. Answer with the primary screen plus system loopback audio,
  // and the renderer drops the video track at once — it only wants the audio.
  session.defaultSession.setDisplayMediaRequestHandler((request, callback) => {
    desktopCapturer.getSources({ types: ['screen'] }).then((sources) => {
      callback({ video: sources[0], audio: 'loopback' });
    }).catch(() => callback({}));
  }, { useSystemPicker: false });

  hooks.refreshIfNeeded(settings, launcher());
  createTray();
  console.log(`[isle] ready - electron ${process.versions.electron}, mode ${settings.effectiveMode}`);

  if (settings.hasChosenMode) {
    showOverlay();
  } else {
    // First launch: the island starts once Setup has named a mode.
    const onFirstMode = (keys) => {
      if (!keys.includes('mode') || !settings.hasChosenMode) return;
      settings.off('change', onFirstMode);
      showOverlay();
    };
    settings.on('change', onFirstMode);
    openSetup();
  }

  screen.on('display-metrics-changed', () => { if (overlay) overlay.setBounds(overlayBounds()); });
  screen.on('display-added', () => { if (overlay) overlay.setBounds(overlayBounds()); });
  screen.on('display-removed', () => { if (overlay) overlay.setBounds(overlayBounds()); });
});

app.on('second-instance', (_event, argv) => {
  if (argv.includes('--settings')) openSettings();
  else if (argv.includes('--setup')) openSetup();
  else openSettings();
});

app.on('before-quit', () => {
  overlayShown = false;
  smtc.stop();
  claude.stop();
});

process.on('uncaughtException', (error) => {
  console.error('[isle]', error);
  if (isDev) dialog.showErrorBox('Isle', String(error && error.stack || error));
});
