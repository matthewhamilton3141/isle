// settings-store.js
//
// Single source of truth for preferences that outlive a launch — the Windows
// stand-in for AppSettings + UserDefaults. A JSON file under Electron's
// userData directory, loaded once and written on every change.
//
// `mode` is null until Setup has been answered; that's what first launch keys
// off. `effectiveMode` treats an unset mode as `both` so nothing is hidden.

const fs = require('fs');
const path = require('path');
const EventEmitter = require('events');

const DEFAULTS = Object.freeze({
  mode: null,                 // 'music' | 'claude' | 'both' | null
  lastTab: 'music',           // 'music' | 'claude' | 'pomodoro'
  showScrubber: true,
  showShuffleRepeat: true,
  waveformSource: 'live',     // 'live' | 'animated' | 'off'
  doneToastSeconds: 4,
  expandOnAlert: true,
  dismissAlertPanel: true,
  showWaitingStatus: true,
  claudeAccent: 'violet',     // see renderer/shared/claude-accent.js
  claudeAccentHex: '#9438E0',
  pomodoroEnabled: false,
  pomodoroFocusMinutes: 25,
  pomodoroShortBreakMinutes: 5,
  pomodoroLongBreakMinutes: 15,
  pomodoroSessionsPerCycle: 4,
  pomodoroSound: true,
  hookInstalledVersion: 0,
});

const MODES = ['music', 'claude', 'both'];

class SettingsStore extends EventEmitter {
  constructor(file) {
    super();
    this.file = file;
    this.values = { ...DEFAULTS, ...this.read() };
  }

  read() {
    try {
      const raw = fs.readFileSync(this.file, 'utf8');
      const parsed = JSON.parse(raw);
      return parsed && typeof parsed === 'object' ? parsed : {};
    } catch {
      return {};
    }
  }

  write() {
    try {
      fs.mkdirSync(path.dirname(this.file), { recursive: true });
      const tmp = `${this.file}.tmp`;
      fs.writeFileSync(tmp, JSON.stringify(this.values, null, 2));
      fs.renameSync(tmp, this.file);
    } catch (error) {
      console.warn('[settings] write failed:', error.message);
    }
  }

  get(key) { return this.values[key]; }

  /** The mode to actually run — unset reads as `both`. */
  get effectiveMode() { return MODES.includes(this.values.mode) ? this.values.mode : 'both'; }
  get hasChosenMode() { return MODES.includes(this.values.mode); }
  get showsMusic() { return this.effectiveMode !== 'claude'; }
  get showsClaude() { return this.effectiveMode !== 'music'; }

  /** Applies a partial update, persists, and emits `change` with the changed keys. */
  update(partial) {
    const changed = [];
    for (const [key, value] of Object.entries(partial || {})) {
      if (!(key in DEFAULTS)) continue;
      if (this.values[key] === value) continue;
      this.values[key] = value;
      changed.push(key);
    }
    if (!changed.length) return;
    this.write();
    this.emit('change', changed, this.snapshot());
  }

  snapshot() {
    return { ...this.values, effectiveMode: this.effectiveMode, hasChosenMode: this.hasChosenMode };
  }
}

module.exports = { SettingsStore, DEFAULTS };
