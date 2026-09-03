// pomodoro.js
//
// The Pomodoro state machine: focus → short break → … → long break, with
// start / pause / skip / reset. A port of PomodoroTimer.swift.
//
// The countdown is anchored to a wall-clock end date rather than decremented
// by a timer. The renderer reads `remaining(at)` off its own frame clock so
// the digits are exact at any frame; the single one-shot timer here, armed
// for the end date itself, exists only to notice that an interval has ended
// and roll to the next phase — so a late fire can never make the clock drift.

const EventEmitter = require('events');

const PHASES = {
  focus: { title: 'Focus', isBreak: false },
  shortBreak: { title: 'Short break', isBreak: true },
  longBreak: { title: 'Long break', isBreak: true },
};

class PomodoroTimer extends EventEmitter {
  constructor(settings) {
    super();
    this.settings = settings;
    this.phase = 'focus';
    this.isRunning = false;
    // Explicitly records that the clock was touched. Deriving this only from
    // elapsed time fails when the user starts and pauses within the same
    // millisecond, and skipping a pristine interval also leaves a full clock.
    this.hasStarted = false;
    this.completedInCycle = 0;
    this.completedFocusTotal = 0;
    this.endDate = null;            // epoch ms while running
    this.phaseDuration = this.duration('focus');
    this.remainingWhenPaused = this.phaseDuration;
    this.tick = null;
  }

  /** Touched: running, paused mid-interval, or sitting on a completed count. */
  get isActive() {
    return this.hasStarted || this.isRunning || this.remainingWhenPaused < this.phaseDuration
      || this.completedInCycle > 0 || this.completedFocusTotal > 0;
  }

  remaining(at = Date.now()) {
    if (this.endDate == null) return this.remainingWhenPaused;
    return Math.max(0, (this.endDate - at) / 1000);
  }

  start() {
    if (this.isRunning) return;
    this.hasStarted = true;
    this.isRunning = true;
    this.endDate = Date.now() + this.remainingWhenPaused * 1000;
    this.startTick();
    this.publish();
  }

  pause() {
    if (!this.isRunning) return;
    this.remainingWhenPaused = this.remaining();
    this.endDate = null;
    this.isRunning = false;
    this.stopTick();
    this.publish();
  }

  toggle() { this.isRunning ? this.pause() : this.start(); }

  /** Abandon the current interval and move to the next one, paused. */
  skip() {
    this.hasStarted = true;
    this.advance(false);
    this.publish();
  }

  reset() {
    this.stopTick();
    this.isRunning = false;
    this.hasStarted = false;
    this.endDate = null;
    this.phase = 'focus';
    this.completedInCycle = 0;
    this.completedFocusTotal = 0;
    this.phaseDuration = this.duration('focus');
    this.remainingWhenPaused = this.phaseDuration;
    this.publish();
  }

  startTick() {
    this.stopTick();
    if (!this.isRunning || this.endDate == null) return;
    const delay = Math.max(0, this.endDate - Date.now());
    this.tick = setTimeout(() => this.intervalMayHaveEnded(), delay);
  }

  intervalMayHaveEnded() {
    this.tick = null;
    if (!this.isRunning) return;
    // Fired ahead of the end (clock adjustment): re-arm for what's left.
    if (this.remaining() > 0) { this.startTick(); return; }
    const ended = this.phase;
    this.advance(true);
    // Breaks roll straight into the next interval; the next focus waits to be
    // started so a break ending doesn't put you on the clock without asking.
    if (!PHASES[ended].isBreak) this.start();
    this.publish();
    this.emit('intervalEnded', ended);
  }

  stopTick() {
    if (this.tick) clearTimeout(this.tick);
    this.tick = null;
  }

  advance(completed) {
    this.stopTick();
    this.isRunning = false;
    this.endDate = null;
    let next;
    switch (this.phase) {
      case 'focus':
        if (completed) { this.completedFocusTotal += 1; this.completedInCycle += 1; }
        next = this.completedInCycle >= Math.max(1, this.settings.get('pomodoroSessionsPerCycle')) ? 'longBreak' : 'shortBreak';
        break;
      case 'shortBreak':
        next = 'focus';
        break;
      default:
        this.completedInCycle = 0;
        next = 'focus';
    }
    this.phase = next;
    this.phaseDuration = this.duration(next);
    this.remainingWhenPaused = this.phaseDuration;
  }

  duration(phase) {
    const key = phase === 'focus' ? 'pomodoroFocusMinutes'
      : phase === 'shortBreak' ? 'pomodoroShortBreakMinutes' : 'pomodoroLongBreakMinutes';
    return Math.max(1, Number(this.settings.get(key)) || 1) * 60;
  }

  snapshot() {
    return {
      phase: this.phase,
      phaseTitle: PHASES[this.phase].title,
      isBreak: PHASES[this.phase].isBreak,
      isRunning: this.isRunning,
      isActive: this.isActive,
      hasStarted: this.hasStarted,
      completedInCycle: this.completedInCycle,
      completedFocusTotal: this.completedFocusTotal,
      endDate: this.endDate,
      remainingWhenPaused: this.remainingWhenPaused,
      phaseDuration: this.phaseDuration,
    };
  }

  publish() { this.emit('change', this.snapshot()); }
}

module.exports = { PomodoroTimer };
