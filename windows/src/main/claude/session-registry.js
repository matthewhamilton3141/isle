// session-registry.js
//
// The second, hook-free half of the Claude Code bridge. Claude Code writes a
// record per live session to ~/.claude/sessions/<pid>.json and keeps its
// `status` field current itself — no hook involved. It works when the hooks
// don't, and it's keyed by pid, so liveness is a process check rather than a
// guess: a session killed outright fires no SessionEnd, and its record simply
// stops describing a live process.
//
// Internal surface, not a documented API: every field is optional and a
// record that won't parse is skipped, so a schema change degrades to "no
// registry" and the hook bridge carries on alone.

const fs = require('fs');
const os = require('os');
const path = require('path');
const EventEmitter = require('events');
const { DirWatcher } = require('./dir-watcher');

const STATUSES = new Set(['idle', 'busy', 'waiting']);

function isAlive(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    // EPERM: alive but owned by someone else — still alive.
    return error && error.code === 'EPERM';
  }
}

class ClaudeSessionRegistry extends EventEmitter {
  constructor(directory = path.join(os.homedir(), '.claude', 'sessions')) {
    super();
    this.directory = directory;
    this.watcher = new DirWatcher(directory, { coalesceMs: 120 });
    this.watcher.on('scan', (names) => this.refresh(names));
    this.last = null;
  }

  start() { this.watcher.start(); }

  stop() {
    this.watcher.stop();
    this.last = null;
  }

  refresh(names) {
    const sessions = names
      .map((name) => this.read(name))
      .filter((s) => s && isAlive(s.pid))
      .sort((a, b) => a.pid - b.pid);
    const key = JSON.stringify(sessions);
    if (key === this.last) return;
    this.last = key;
    this.emit('sessions', sessions);
  }

  /** Parses one `<pid>.json` — not the `<pid>.<hash>.key` siblings. */
  read(name) {
    const match = /^(\d+)\.json$/.exec(name);
    if (!match) return null;
    let payload;
    try {
      payload = JSON.parse(fs.readFileSync(path.join(this.directory, name), 'utf8'));
    } catch {
      return null;
    }
    if (!payload || typeof payload.sessionId !== 'string' || typeof payload.cwd !== 'string') return null;
    return {
      pid: Number(match[1]),
      sessionId: payload.sessionId,
      cwd: payload.cwd,
      name: payload.name || null,
      kind: payload.kind || null,
      status: STATUSES.has(payload.status) ? payload.status : 'unknown',
      statusUpdatedAt: Number(payload.statusUpdatedAt) || null,
    };
  }
}

module.exports = { ClaudeSessionRegistry };
