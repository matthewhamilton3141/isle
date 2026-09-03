# Isle for Windows

**A Dynamic Island for the top of your screen — for Spotify, Claude Code and a
Pomodoro timer.**

This is the Windows port of [Isle](../README.md). Windows laptops have no
camera housing to hug, so the island is the Mac app's non-notched form: a
black pill flush with the top edge of the primary display that expands on
hover and folds away when you're done. The UI, the state machine and the
Claude Code bridge are ports of the Mac app's, one to one; the platform
plumbing underneath is different and described below.

Built with Electron. No native modules and nothing to compile — the two
platform bridges are a PowerShell script and Node.

---

## Install and run

Requirements: Windows 10 build 19041 or newer (Windows 11 recommended),
[Node.js](https://nodejs.org) 20+, Spotify's desktop app for the music side,
[Claude Code](https://claude.com/claude-code) for the Claude side.

```powershell
cd windows
npm install
npm start
```

Isle runs as a tray app with no taskbar entry. First launch opens **Setup**,
which asks what Isle should be — **Music**, **Claude Code** or **Both** —
whether the waveform should listen to what's playing, and (for Claude/Both)
offers to install the Claude Code hook. Everything is changeable later from
the tray menu's **Settings…**.

> If you run Isle from a shell that has `ELECTRON_RUN_AS_NODE=1` set (some
> editor-integrated terminals do), Electron starts as plain Node and nothing
> appears. `npm start` from a normal terminal, or unset the variable first.

---

## Features

- **Now playing at a glance.** Album art and a waveform in the collapsed
  island; hover to expand into artwork, marquee title/artist, a seekable
  scrubber and transport controls — play/pause, previous, next, shuffle and
  repeat.
- **An audio-reactive waveform.** Six log-spaced bands from an FFT of the
  system's loopback audio, with the same reference-tracking shaping as the Mac
  app. Runs only while Spotify is playing. *Animated* (procedural, never
  listens) and *Off* are in Settings.
- **Live Claude Code status.** Working, question, waiting, done, failed,
  compacting — each with its own dot-matrix marker and status word. A
  question or error pops the island open on its own; hover away or click to
  retract it. Multiple sessions are ranked by urgency, and a session that was
  killed outright is retired by the CLI's own session registry.
- **Pomodoro.** Focus / short break / long break with a progress ring, cycle
  tally and a soft chime. While it runs the remaining time sits in the island.
- **Both at once.** In Both mode the collapsed island splits: music on the
  left, Claude (and the timer) on the right, and the expanded panel shows a
  face switcher.
- **Stays out of the way.** The overlay never takes focus, and it is
  transparent to the mouse everywhere except the drawn island, so the window
  title bars underneath stay clickable.

### The tray menu

| Item | Description |
|---|---|
| Show / Hide Island | Show or hide the overlay |
| Pop out island for alerts | Whether Claude alerts expand the island on their own |
| Mode | Music / Claude Code / Both |
| Settings… | Mode, music options, Claude hook and accent, Pomodoro |
| Setup… | Re-run the first-launch picker |
| Quit Isle | |

---

## Claude Code

Open **Settings → Claude Code → Install**. This copies the `isle-cli.js`
helper into `%USERPROFILE%\.isle\bin` and merges Isle's hook entries into
`%USERPROFILE%\.claude\settings.json`, leaving any existing hooks untouched.
**Remove** reverses both.

The hooks invoke the helper with Node, by absolute path, in a form that runs
identically under Git Bash (which Claude Code uses for hooks on Windows when
Git is installed) and under `cmd.exe`. If no `node.exe` is on `PATH` the
hooks point at Isle's own executable with `--isle-cli` instead. The helper
writes one small JSON file per session to `%USERPROFILE%\.isle\sessions\`,
which Isle watches. It never needs Isle to be running.

Liveness does not depend on the hooks firing: Isle also reads the CLI's own
`%USERPROFILE%\.claude\sessions\<pid>.json` records and checks the process is
alive, and it reads the tail of the session transcript to retire a `working`
record an interrupt (Esc) left behind.

For a manual install, `integration/isle-cli.js` is the same helper; wire it
into `~/.claude/settings.json` the way `HookInstaller` does (see
`src/main/claude/hook-installer.js` for the event → argument table).

---

## How the platform layer works

| Operation | Mechanism | Source |
|---|---|---|
| Read now-playing, artwork, position, shuffle/repeat | Windows' **System Media Transport Controls** via a PowerShell sidecar | `src/main/media/smtc-bridge.ps1`, `smtc-client.js` |
| Play, pause, next, previous, seek, shuffle, repeat | SMTC commands over the same sidecar | same |
| Audio waveform | Chromium display-media **loopback** capture + Web Audio FFT | `src/renderer/overlay/audio-levels.js` |
| Claude status | Per-session JSON files + directory watches | `src/main/claude/` |
| Overlay | Transparent, non-focusable, always-on-top `BrowserWindow`; click-through toggled per pointer position | `src/main/main.js`, `src/renderer/overlay/hover.js` |

**The SMTC bridge** is the Windows analogue of the Mac app's
`mediaremote-adapter`. Windows PowerShell 5.1 — present on every Windows
install — can project WinRT types directly, so a script reaches
`GlobalSystemMediaTransportControlsSessionManager` (the API behind the media
keys and the volume flyout) with nothing to compile. Isle spawns it hidden,
reads JSON lines from its stdout and writes commands to its stdin. It is
Spotify-scoped: of every media session Windows knows about, only the one whose
app id names Spotify is reported. Three .NET-Framework quirks are worked
around in the script and worth knowing before touching it: the opened
thumbnail stream is an opaque COM object that has to be read through
reflection on its interface types; `Console.In.ReadLineAsync` is synchronous
in disguise, so stdin is read from the raw stream; and
`Environment.TickCount64` doesn't exist (PowerShell returns `$null` silently).

**The waveform** captures system loopback audio, not Spotify's process alone
— Chromium has no process-scoped capture. It is gated on Spotify actually
playing, which keeps it honest in practice, but another app's sound will move
the bars while music is on. No permission prompt is involved.

**The overlay** is created once at its maximum extent and never resized; only
the content animates, driven by the Mac app's spring curves (`spring.js`).
Electron forwards pointer moves to the page even while the window is
click-through, and the renderer flips interactivity on only when the pointer
is within a few pixels of the drawn island. Because forwarding stops without
a final event when the pointer leaves the window's footprint, the main
process also polls the cursor at 20 Hz — but only while the island is open.

### Project layout

```
windows/
├── src/main/                    Electron main process
│   ├── main.js                  tray, overlay + secondary windows, IPC, lifecycle
│   ├── geometry.js              island sizes shared with the renderer
│   ├── settings-store.js        preferences (JSON under %APPDATA%\Isle)
│   ├── pomodoro.js              the Pomodoro state machine
│   ├── tray-icon.js             the 3×3 dot mark, rasterised at runtime
│   ├── media/                   SMTC bridge (PowerShell) and its Node client
│   └── claude/                  isle-cli, hook installer, watchers, selection model
├── src/preload/preload.js       the `window.isle` bridge
├── src/renderer/overlay/        the island: view model, hover, springs, faces, components
├── src/renderer/settings/       Settings window
├── src/renderer/onboarding/     Setup window
├── src/renderer/shared/         colours/palettes, marker designs, icons, panel CSS
├── integration/isle-cli.js      the hook helper, for manual installs
└── scripts/                     dev helpers (see below)
```

### Not ported

The Mac app's Agenda face (EventKit), battery and Bluetooth toasts, signed
self-updater, Marker Editor and Animation Gallery are not in this build.
Markers use the Mac app's default designs.

---

## Development

```powershell
npm run dev        # opens detached DevTools for the overlay
```

Handy scripts in `scripts/`:

- `probe-smtc.js [command]` — run the SMTC bridge standalone and print its
  snapshots; optionally send one command (`playpause`, `next`, `seek 30`, …).
- `relaunch.ps1 [-Dev]` — kill any running Isle and relaunch it detached, with
  logs in `%TEMP%\isle-out.log` / `isle-err.log`.
- `screenshot.ps1 <out.png> [x y w h scale]` — capture a screen region, for
  checking the island without a second pair of eyes.

The renderer's `console.warn`/`console.error` are echoed to main's stdout;
`--dev` echoes everything.

To exercise the Claude bridge without a session, pipe a hook payload into the
helper:

```powershell
'{"hook_event_name":"PermissionRequest","session_id":"demo","tool_name":"Bash","tool_input":{"command":"npm test"},"cwd":"C:\\dev\\app"}' | node src/main/claude/isle-cli.js ask
'{"session_id":"demo"}' | node src/main/claude/isle-cli.js end
```

---

## License

MIT, like the rest of Isle. No third-party runtime code beyond Electron.
