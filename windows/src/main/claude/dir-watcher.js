// dir-watcher.js
//
// A directory watch with coalescing, shared by the status watcher and the
// session registry. Watches the directory (not individual files — session
// files come and go constantly, so there is no stable handle to hold) and
// re-reads every entry on each burst of events.
//
// fs.watch on Windows uses ReadDirectoryChangesW, which does report in-place
// writes as well as renames, so the rename contract the Mac helper relies on
// is a bonus here rather than a requirement. If the directory doesn't exist
// yet (Claude Code creates ~/.claude/sessions on first run), the watch is
// retried on a slow timer until it does.

const fs = require('fs');
const EventEmitter = require('events');

class DirWatcher extends EventEmitter {
  constructor(directory, { coalesceMs = 100, createIfMissing = false } = {}) {
    super();
    this.directory = directory;
    this.coalesceMs = coalesceMs;
    this.createIfMissing = createIfMissing;
    this.watcher = null;
    this.retry = null;
    this.coalesce = null;
    this.running = false;
  }

  start() {
    if (this.running) return;
    this.running = true;
    this.arm();
    this.emit('scan', this.list());
  }

  stop() {
    this.running = false;
    clearTimeout(this.retry); this.retry = null;
    clearTimeout(this.coalesce); this.coalesce = null;
    if (this.watcher) { try { this.watcher.close(); } catch { /* closed */ } }
    this.watcher = null;
  }

  arm() {
    if (!this.running || this.watcher) return;
    if (this.createIfMissing) {
      try { fs.mkdirSync(this.directory, { recursive: true }); } catch { /* read-only home? */ }
    }
    if (!fs.existsSync(this.directory)) {
      this.retry = setTimeout(() => { this.retry = null; this.arm(); }, 5000);
      return;
    }
    try {
      this.watcher = fs.watch(this.directory, { persistent: true }, () => this.schedule());
      this.watcher.on('error', () => {
        // The directory was removed or the handle went bad: drop the watch and
        // pick it up again once the directory is back.
        try { this.watcher.close(); } catch { /* closed */ }
        this.watcher = null;
        if (this.running) this.retry = setTimeout(() => { this.retry = null; this.arm(); this.schedule(); }, 1000);
      });
    } catch {
      this.retry = setTimeout(() => { this.retry = null; this.arm(); }, 5000);
    }
  }

  schedule() {
    if (!this.running) return;
    clearTimeout(this.coalesce);
    this.coalesce = setTimeout(() => {
      this.coalesce = null;
      this.emit('scan', this.list());
    }, this.coalesceMs);
  }

  /** Entry names in the directory, or [] when it can't be read. */
  list() {
    try { return fs.readdirSync(this.directory); } catch { return []; }
  }
}

module.exports = { DirWatcher };
