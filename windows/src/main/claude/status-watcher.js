// status-watcher.js
//
// The Claude Code side of the bridge. Claude's hooks call `isle-cli`, which
// writes one status file per session under ~/.isle/sessions/<session-id>.json;
// this watches that directory and reports every live session's status the
// moment anything changes. Choosing between sessions is the model's job (see
// claude-model.js) — it can't choose if the data was clobbered on disk, which
// is why the files are per session rather than one shared record.

const fs = require('fs');
const os = require('os');
const path = require('path');
const EventEmitter = require('events');
const { DirWatcher } = require('./dir-watcher');

const STATE_MAP = {
  idle: 'idle',
  working: 'working',
  needs_approval: 'needsApproval',
  needs_question: 'needsQuestion',
  waiting_input: 'waitingInput',
  done: 'done',
  error: 'failed',
  compacting: 'compacting',
};

const nonEmpty = (value) => (typeof value === 'string' && value.length ? value : null);

function parseResetAt(raw) {
  const value = Number(raw);
  if (!raw || !Number.isFinite(value) || value <= 0) return null;
  return value > 1_000_000_000_000 ? value : value * 1000;
}

class ClaudeStatusWatcher extends EventEmitter {
  constructor(directory = path.join(os.homedir(), '.isle', 'sessions')) {
    super();
    this.directory = directory;
    this.watcher = new DirWatcher(directory, { coalesceMs: 80, createIfMissing: true });
    this.watcher.on('scan', (names) => this.refresh(names));
    this.last = null;
  }

  start() { this.watcher.start(); }

  stop() {
    this.watcher.stop();
    this.last = null;
  }

  refresh(names) {
    const statuses = names
      .map((name) => this.read(name))
      .filter(Boolean)
      .sort((a, b) => (a.sessionId || '').localeCompare(b.sessionId || ''));
    const key = JSON.stringify(statuses);
    if (key === this.last) return;
    this.last = key;
    this.emit('statuses', statuses);
  }

  /** Parses one `<session-id>.json`; any failure drops that record only. */
  read(name) {
    if (!name.endsWith('.json')) return null;
    let payload;
    try {
      payload = JSON.parse(fs.readFileSync(path.join(this.directory, name), 'utf8'));
    } catch {
      return null;
    }
    if (!payload || typeof payload !== 'object') return null;
    const updated = Date.parse(payload.updated_at || '');
    return {
      state: STATE_MAP[payload.state] || 'disconnected',
      project: nonEmpty(payload.project),
      sessionId: nonEmpty(payload.session_id) || name.slice(0, -5),
      action: nonEmpty(payload.action),
      target: nonEmpty(payload.target),
      errorType: nonEmpty(payload.error_type),
      toolActive: payload.tool_active === true,
      resetAt: parseResetAt(payload.reset_at),
      updatedAt: Number.isFinite(updated) ? updated : null,
    };
  }
}

module.exports = { ClaudeStatusWatcher };
