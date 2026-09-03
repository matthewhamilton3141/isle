// preload.js
//
// The bridge between the renderers and the main process. One small API,
// exposed as `window.isle`, shared by the overlay, Settings and Setup.

const { contextBridge, ipcRenderer } = require('electron');

const geometryArg = process.argv.find((a) => a.startsWith('--isle-geometry='));
const geometry = geometryArg ? JSON.parse(geometryArg.slice('--isle-geometry='.length)) : null;

contextBridge.exposeInMainWorld('isle', {
  geometry,
  /** Full state pushes from main: { settings, claude, pomodoro, media, hookInstalled, version }. */
  onState(callback) {
    const listener = (_event, state) => callback(state);
    ipcRenderer.on('state', listener);
    return () => ipcRenderer.removeListener('state', listener);
  },
  getState: () => ipcRenderer.invoke('state:get'),
  onPomodoroEnded(callback) {
    ipcRenderer.on('pomodoro:ended', (_event, phase) => callback(phase));
  },

  // Overlay
  setInteractive: (interactive) => ipcRenderer.send('overlay:interactive', !!interactive),
  pollPointer: (wanted) => ipcRenderer.send('overlay:poll-pointer', !!wanted),
  onPointer(callback) {
    ipcRenderer.on('pointer', (_event, point) => callback(point));
  },
  media: {
    playPause: () => ipcRenderer.send('media:command', 'playpause'),
    next: () => ipcRenderer.send('media:command', 'next'),
    previous: () => ipcRenderer.send('media:command', 'prev'),
    seek: (seconds) => ipcRenderer.send('media:command', 'seek', seconds),
    setShuffle: (on) => ipcRenderer.send('media:command', 'shuffle', on),
    setRepeat: (mode) => ipcRenderer.send('media:command', 'repeat', mode),
  },
  pomodoro: {
    toggle: () => ipcRenderer.send('pomodoro:action', 'toggle'),
    skip: () => ipcRenderer.send('pomodoro:action', 'skip'),
    reset: () => ipcRenderer.send('pomodoro:action', 'reset'),
  },

  // Settings / Setup
  updateSettings: (partial) => ipcRenderer.send('settings:update', partial),
  installHooks: () => ipcRenderer.invoke('hooks:install'),
  uninstallHooks: () => ipcRenderer.invoke('hooks:uninstall'),
  closeWindow: () => ipcRenderer.send('window:close'),
  openSettings: () => ipcRenderer.send('open:settings'),
  openSetup: () => ipcRenderer.send('open:setup'),
  openExternal: (url) => ipcRenderer.send('open:external', url),
});
