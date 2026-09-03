// smtc-client.js
//
// Runs the PowerShell SMTC bridge as a long-lived child process and turns its
// JSON lines into now-playing snapshots. The counterpart of the Mac app's
// MediaRemoteAdapterClient + SpotifyController: one source here does both
// jobs, since SMTC reports metadata, artwork, position and shuffle/repeat and
// also accepts the transport commands.
//
// Restarted with a short backoff if it dies while wanted, and told to quit on
// stop() so a crash of Isle itself is the only way to orphan it — and even then
// the bridge exits on its own when its stdin pipe closes.

const { spawn } = require('child_process');
const path = require('path');
const EventEmitter = require('events');

const POWERSHELL = path.join(
  process.env.SystemRoot || 'C:\\Windows',
  'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe'
);

const SCRIPT = path.join(__dirname, 'smtc-bridge.ps1');

/** Maps an SMTC snapshot onto the shape the renderer's media model consumes. */
function toModel(snapshot, artwork) {
  if (!snapshot.hasTrack) return { hasTrack: false };
  const playing = snapshot.status === 'Playing';
  return {
    hasTrack: true,
    title: snapshot.title || '',
    artist: snapshot.artist || '',
    album: snapshot.album || '',
    duration: Number(snapshot.duration) || 0,
    reportedElapsed: Number(snapshot.position) || 0,
    // Epoch ms of the position reading. Extrapolated from by the renderer.
    timestamp: Number(snapshot.lastUpdated) || Date.now(),
    isPlaying: playing,
    playbackRate: playing ? 1 : 0,
    isShuffled: snapshot.shuffle === true,
    // SMTC: none | list | track  →  off | all | one
    repeatMode: snapshot.repeat === 'track' ? 'one' : snapshot.repeat === 'list' ? 'all' : 'off',
    canSeek: snapshot.canSeek !== false,
    canShuffle: snapshot.canShuffle !== false,
    canRepeat: snapshot.canRepeat !== false,
    artwork, // data: URL or null
    artKey: snapshot.artKey || '',
  };
}

class SmtcClient extends EventEmitter {
  constructor() {
    super();
    this.process = null;
    this.wanted = false;
    this.buffer = '';
    this.restartTimer = null;
    this.restartDelay = 1000;
    // Artwork cache keyed by the bridge's artKey: the bridge only sends bytes
    // when the track changes, so later snapshots for the same track reuse
    // the decoded cover.
    this.artKey = '';
    this.artwork = null;
    this.last = { hasTrack: false };
  }

  start() {
    if (this.wanted) return;
    this.wanted = true;
    this.spawn();
  }

  stop() {
    this.wanted = false;
    clearTimeout(this.restartTimer);
    this.restartTimer = null;
    if (this.process) {
      try { this.process.stdin.write('quit\n'); } catch { /* already gone */ }
      const proc = this.process;
      setTimeout(() => { try { proc.kill(); } catch { /* exited */ } }, 1500);
      this.process = null;
    }
    this.publish({ hasTrack: false });
  }

  spawn() {
    if (this.process || !this.wanted) return;
    const proc = spawn(POWERSHELL, [
      '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', SCRIPT,
    ], { windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'] });
    this.process = proc;
    this.buffer = '';

    proc.stdout.setEncoding('utf8');
    proc.stdout.on('data', (chunk) => this.onData(chunk));
    proc.stderr.setEncoding('utf8');
    proc.stderr.on('data', (chunk) => console.warn('[smtc-bridge]', chunk.trim()));
    proc.on('exit', (code) => {
      if (this.process === proc) this.process = null;
      if (!this.wanted) return;
      console.warn(`[smtc-bridge] exited (${code}); restarting in ${this.restartDelay}ms`);
      this.restartTimer = setTimeout(() => {
        this.restartTimer = null;
        this.spawn();
      }, this.restartDelay);
      this.restartDelay = Math.min(this.restartDelay * 2, 15000);
    });
    proc.on('error', (error) => console.warn('[smtc-bridge] spawn failed:', error.message));
  }

  onData(chunk) {
    this.buffer += chunk;
    let index;
    while ((index = this.buffer.indexOf('\n')) >= 0) {
      const line = this.buffer.slice(0, index).trim();
      this.buffer = this.buffer.slice(index + 1);
      if (!line) continue;
      let message;
      try { message = JSON.parse(line); } catch { continue; }
      this.onMessage(message);
    }
  }

  onMessage(message) {
    switch (message.type) {
      case 'ready':
        this.restartDelay = 1000;
        break;
      case 'np': {
        if (message.hasTrack) {
          if (message.art) {
            this.artKey = message.artKey;
            this.artwork = `data:${message.artMime || 'image/jpeg'};base64,${message.art}`;
          } else if (message.artKey !== this.artKey) {
            // A new track whose cover hasn't arrived yet.
            this.artKey = message.artKey;
            this.artwork = null;
          }
        } else {
          this.artKey = '';
          this.artwork = null;
        }
        this.publish(toModel(message, this.artwork));
        break;
      }
      case 'error':
        console.warn('[smtc-bridge]', message.message);
        break;
      default:
        break;
    }
  }

  publish(model) {
    this.last = model;
    this.emit('update', model);
  }

  send(command) {
    if (!this.process) return;
    try { this.process.stdin.write(command + '\n'); } catch { /* dropped */ }
  }

  // MARK: - Transport

  playPause() { this.send('playpause'); }
  next() { this.send('next'); }
  previous() { this.send('prev'); }
  seek(seconds) { this.send(`seek ${Math.max(0, Number(seconds) || 0)}`); }
  setShuffle(on) { this.send(`shuffle ${on ? 1 : 0}`); }
  /** repeatMode: off | all | one */
  setRepeat(mode) {
    const smtc = mode === 'one' ? 'track' : mode === 'all' ? 'list' : 'none';
    this.send(`repeat ${smtc}`);
  }
}

module.exports = { SmtcClient };
