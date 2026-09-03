// claude-model.js
//
// Picks which Claude Code session owns the island and turns its record into
// the state the island shows. A port of the Claude half of NotchViewModel:
// urgency-ranked selection, interrupt reconciliation against the transcript,
// the `done`/`failed`/`question`/`compacting` revert timers, and the rotating
// working word.
//
// Nothing here measures silence. Isle has no signal that separates a long
// think from a stalled turn — both fire no hooks and write nothing — so it
// makes no claim either way, and holds the last state it was actually told.

const fs = require('fs');
const os = require('os');
const path = require('path');
const EventEmitter = require('events');
const { ClaudeStatusWatcher } = require('./status-watcher');
const { ClaudeSessionRegistry } = require('./session-registry');

const DISCONNECTED = { state: 'disconnected', project: null, sessionId: null, action: null, target: null, errorType: null, toolActive: false, resetAt: null, updatedAt: null };

const SESSION_STATE_MAP = {
  idle: 'idle',
  busy: 'working',
  waiting: 'waitingInput',
};

const WORKING_WORDS = [
  'Thinking', 'Coalescing', 'Percolating', 'Ruminating', 'Cogitating',
  'Simmering', 'Pondering', 'Noodling', 'Churning', 'Brewing',
  'Conjuring', 'Wrangling', 'Synthesizing', 'Contemplating', 'Marinating',
  'Deliberating', 'Computing', 'Puzzling', 'Finagling', 'Vibing',
];

const QUESTION_REVERT_SECONDS = 45;
const COMPACTING_REVERT_SECONDS = 25;

/** How much a state deserves the island. Higher wins. */
function urgency(state) {
  switch (state) {
    case 'needsApproval': case 'needsQuestion': case 'failed': return 3;
    case 'working': case 'compacting': return 2;
    case 'waitingInput': case 'done': case 'idle': return 1;
    default: return 0;
  }
}

/** Claude Code's project slug for a working directory: every non-alphanumeric
 *  becomes a dash, so `C:\VsCode\isle` is `C--VsCode-isle`. */
function projectSlug(cwd) {
  return cwd.replace(/[^A-Za-z0-9]/g, '-');
}

function isInterruption(entry) {
  const message = entry && entry.message;
  if (!message) return false;
  const texts = typeof message.content === 'string'
    ? [message.content]
    : Array.isArray(message.content) ? message.content.map((b) => b && b.text).filter(Boolean) : [];
  return texts.some((t) => t.startsWith('[Request interrupted'));
}

/**
 * The transcript's last conversation entry: whether it leaves the model owing
 * a response, and whether it's the marker an interrupt leaves behind. Reads
 * only the tail — transcripts run to megabytes and this is called on a timer.
 */
function transcriptTail(session) {
  const file = path.join(os.homedir(), '.claude', 'projects', projectSlug(session.cwd), `${session.sessionId}.jsonl`);
  let fd;
  try {
    fd = fs.openSync(file, 'r');
    const size = fs.fstatSync(fd).size;
    const window = 64 * 1024;
    const start = size > window ? size - window : 0;
    const buffer = Buffer.alloc(size - start);
    fs.readSync(fd, buffer, 0, buffer.length, start);
    const lines = buffer.toString('utf8').split('\n');
    for (let i = lines.length - 1; i >= 0; i--) {
      let entry;
      try { entry = JSON.parse(lines[i]); } catch { continue; }
      if (!entry || (entry.type !== 'user' && entry.type !== 'assistant') || !entry.timestamp) continue;
      const interrupted = entry.type === 'user' && isInterruption(entry);
      return { awaitingModel: entry.type === 'user' && !interrupted, interrupted };
    }
    return null;
  } catch {
    return null;
  } finally {
    if (fd !== undefined) { try { fs.closeSync(fd); } catch { /* closed */ } }
  }
}

class ClaudeModel extends EventEmitter {
  constructor(settings) {
    super();
    this.settings = settings;
    this.watcher = new ClaudeStatusWatcher();
    this.registry = new ClaudeSessionRegistry();
    this.statuses = [];
    this.sessions = [];
    this.running = false;
    this.lastApplied = null;
    this.revertTimer = null;
    this.reselectTimer = null;
    this.wordTimer = null;
    this.wordIndex = 0;

    this.current = { ...DISCONNECTED };
    this.workingWord = 'Working';

    this.watcher.on('statuses', (statuses) => {
      this.statuses = statuses;
      this.apply(this.select());
    });
    this.registry.on('sessions', (sessions) => {
      this.sessions = sessions;
      // A session dropping out of the registry is dead for real; re-running
      // selection is what retires its lingering status file.
      this.apply(this.select());
    });
  }

  start() {
    if (this.running) return;
    this.running = true;
    this.watcher.start();
    this.registry.start();
  }

  stop() {
    if (!this.running) return;
    this.running = false;
    this.watcher.stop();
    this.registry.stop();
    this.statuses = [];
    this.sessions = [];
    this.lastApplied = null;
    this.clearRevert();
    this.stopReselect();
    this.stopWords();
    this.current = { ...DISCONNECTED };
    this.publish();
  }

  // MARK: - Selection

  sessionStatus(session) {
    return {
      state: SESSION_STATE_MAP[session.status] || 'idle',
      project: path.basename(session.cwd),
      sessionId: session.sessionId,
      action: null,
      target: null,
      errorType: null,
      toolActive: false,
      resetAt: null,
      updatedAt: session.statusUpdatedAt || null,
    };
  }

  select() {
    const hookIds = new Set(this.statuses.map((s) => s.sessionId).filter(Boolean));
    const unhooked = this.sessions
      .filter((s) => !hookIds.has(s.sessionId))
      .map((s) => this.sessionStatus(s));
    const live = this.sessions.length === 0 ? this.statuses : this.statuses.filter((status) => {
      if (!status.sessionId) return true;
      return this.sessions.some((s) => s.sessionId === status.sessionId);
    });
    const pool = (live.length ? [...live, ...unhooked] : [...this.statuses, ...unhooked]).map((s) => this.reconciled(s));
    let best = null;
    for (const status of pool) {
      if (!best) { best = status; continue; }
      const a = [urgency(status.state), status.updatedAt || 0];
      const b = [urgency(best.state), best.updatedAt || 0];
      if (a[0] > b[0] || (a[0] === b[0] && a[1] > b[1])) best = status;
    }
    return best || { ...DISCONNECTED };
  }

  /**
   * Corrects a `working` record the hooks will never close out: an interrupt
   * (ESC) fires no Stop, so the last PreToolUse write stays newest forever.
   * Two independent signals have to agree — the CLI no longer calls the
   * session busy, and the transcript shows the turn already closed — unless
   * the transcript carries the interrupt marker, which decides it on its own.
   */
  reconciled(status) {
    if (status.state !== 'working' || !status.sessionId) return status;
    const session = this.sessions.find((s) => s.sessionId === status.sessionId);
    if (!session) return status;
    const tail = transcriptTail(session);
    if (!tail) return status;
    if (!tail.interrupted) {
      if (status.toolActive || session.status !== 'idle' || tail.awaitingModel) return status;
    }
    return { ...status, state: 'idle', action: null, target: null };
  }

  // MARK: - Apply

  apply(status) {
    const key = JSON.stringify(status);
    if (key === this.lastApplied) return;
    this.lastApplied = key;
    this.clearRevert();

    this.current = {
      state: status.state,
      project: status.project,
      sessionId: status.sessionId,
      action: status.action,
      target: status.target,
      errorType: status.errorType,
      toolActive: status.toolActive,
      resetAt: status.resetAt,
      updatedAt: status.state === 'disconnected' ? null : Date.now(),
    };

    if (status.state === 'working') this.startWords(); else this.stopWords();
    this.updateReselect(status.state);

    // `done` and `failed` are terminal toasts; a question and a compaction
    // ease back to idle so an abandoned one can't wedge the island.
    let revert = null;
    switch (status.state) {
      case 'done':
        revert = this.settings.get('doneToastSeconds');
        break;
      case 'failed':
        if (status.errorType === 'usage_limit') {
          if (status.resetAt == null) break;
          revert = Math.max(0, (status.resetAt - Date.now()) / 1000);
        } else {
          revert = Math.max(this.settings.get('doneToastSeconds'), 6);
        }
        break;
      case 'needsQuestion':
        revert = QUESTION_REVERT_SECONDS;
        break;
      case 'compacting':
        revert = COMPACTING_REVERT_SECONDS;
        break;
      default:
        break;
    }
    if (revert != null) {
      this.revertTimer = setTimeout(() => {
        this.revertTimer = null;
        this.stopReselect();
        this.current = { ...this.current, state: 'idle' };
        this.publish();
      }, revert * 1000);
    }
    this.publish();
  }

  clearRevert() {
    if (this.revertTimer) clearTimeout(this.revertTimer);
    this.revertTimer = null;
  }

  /** Re-runs selection on a coarse timer while a busy-looking state shows, so
   *  a record an interrupt left stuck still gets re-examined. */
  updateReselect(state) {
    const wants = state === 'working' || state === 'compacting' || state === 'waitingInput';
    if (!wants) { this.stopReselect(); return; }
    if (this.reselectTimer) return;
    this.reselectTimer = setInterval(() => {
      const resolved = this.select();
      if (resolved.state !== this.current.state) this.apply(resolved);
    }, 5000);
  }

  stopReselect() {
    if (this.reselectTimer) clearInterval(this.reselectTimer);
    this.reselectTimer = null;
  }

  // MARK: - Working words

  startWords() {
    if (this.wordTimer) return;
    this.wordIndex = Math.floor(Math.random() * WORKING_WORDS.length);
    this.workingWord = WORKING_WORDS[this.wordIndex];
    this.wordTimer = setInterval(() => {
      this.wordIndex = (this.wordIndex + 1) % WORKING_WORDS.length;
      this.workingWord = WORKING_WORDS[this.wordIndex];
      this.publish();
    }, 15000);
  }

  stopWords() {
    if (this.wordTimer) clearInterval(this.wordTimer);
    this.wordTimer = null;
  }

  snapshot() {
    return { ...this.current, workingWord: this.workingWord };
  }

  publish() { this.emit('change', this.snapshot()); }
}

module.exports = { ClaudeModel, projectSlug };
