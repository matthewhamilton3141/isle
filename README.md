# Isle

A Dynamic Island for the MacBook notch, with Claude Code awareness.

Isle renders an interactive overlay around the camera housing that shows what's
playing and — once Phase 2 lands — the live status of a Claude Code session,
expanding on its own when Claude is waiting on you.

**Status: Phase 1.** The notch shell and media layer are built. The Claude Code
bridge (Phase 2) and the settings pane (Phase 3) are not — see
[PROJECT_BRIEF.md](PROJECT_BRIEF.md) for the full spec and build phases.

## Build & run

Requires Xcode 16 or newer (the project uses file-system synchronized groups)
and macOS 14+.

```bash
# One-time: build the bundled now-playing bridge (see "Media" below).
./scripts/build-mediaremote-adapter.sh

open Isle.xcodeproj    # then ⌘R
```

Isle is an agent app — `LSUIElement`, so no Dock icon. It appears as a menu bar
item with **Toggle Notch** and **Quit**.

## Media: how now-playing actually works

This is the part where the original spec is out of date, and it's worth
understanding before you change anything here.

The spec called for reading now-playing state by `dlopen`-ing Apple's private
`MediaRemote` framework and calling `MRMediaRemoteGetNowPlayingInfo`. **That no
longer works.** Around macOS 15.4 Apple gated the read side behind an
entitlement that third-party apps can't get. The symbols still resolve and the
call still succeeds — it just hands back an empty dictionary, so an app built
the way the spec describes will silently never show a track. This was verified
on macOS 26.5.

So Isle splits the media layer in two:

| Operation | Mechanism | Notes |
|---|---|---|
| Read now-playing | `mediaremote-adapter` subprocess | `Isle/Media/MediaRemoteAdapterClient.swift` |
| play / pause / next / prev / seek / shuffle / repeat | Direct `CFBundleGetFunctionPointerForName` on MediaRemote | `Isle/Media/MediaRemoteCommands.swift` |
| Volume, favorites | AppleScript | Spotify and Music only |

**Reading** goes through [`mediaremote-adapter`][mra], which loads MediaRemote
inside `/usr/bin/perl` — an Apple-signed binary that *does* hold the
entitlement — and streams JSON lines back over a pipe. Isle runs it as a
long-lived child process. This gives a genuinely universal feed: Spotify, Music,
Safari, a Chrome tab, anything that registers a now-playing session.

**Commanding** is unaffected by the gating and still works in-process, so
transport controls are a direct call into the private framework.

**Volume and favorites** have no MediaRemote API at all. They fall back to
AppleScript, which means they only work for Spotify and Apple Music — the volume
slider is hidden for browser audio rather than showing a dead control. Expect an
Automation permission prompt the first time.

`scripts/build-mediaremote-adapter.sh` fetches a pinned upstream tag, compiles a
universal framework with `clang`, and drops it plus the Perl driver into
`Isle/Resources/`. Isle never *links* the framework — it only ever invokes it by
path — so it ships as a plain resource.

### Distribution caveat

Isle uses a private framework, which rules out the App Store. This is a
personal, sideloaded build and that's the assumed distribution model.

Going to the App Store would mean replacing this whole subsystem with `MusicKit`
(Apple Music only) plus Spotify's Web API (OAuth, no local playback control, no
browser audio). That's a real downgrade in capability, not a drop-in swap.

## Licensing

- **Isle** is its own codebase.
- **[`mediaremote-adapter`][mra]** — BSD-3-Clause, © 2025 Jonas van den Berg.
  Vendored into `Isle/Resources/` by the build script; the license text is
  copied alongside it.
- **[boring.notch][bn]** is **GPL-3.0**. The spec cites it as a reference for
  the overlay-window and now-playing techniques, and it's a genuinely useful
  one — but no code from it is used here, and none should be copied in, because
  doing so would make Isle GPL-3 too. Read it for technique, then write your own.

[mra]: https://github.com/ungive/mediaremote-adapter
[bn]: https://github.com/TheBoredTeam/boring.notch

## Layout

```
Isle/
├── IsleApp.swift              # @main, agent app + menu bar item
├── Notch/
│   ├── NotchMetrics.swift     # camera-housing geometry, per-state frames
│   ├── NotchShape.swift       # the outline, with inverted top corners
│   ├── NotchState.swift       # collapsed / hover / live-activity + precedence
│   ├── NotchWindow.swift      # borderless non-activating NSPanel
│   ├── NotchHostingView.swift # passthrough hit-testing
│   ├── NotchWindowController.swift
│   ├── NotchViewModel.swift
│   ├── NotchRootView.swift
│   ├── CollapsedNotchView.swift
│   └── ExpandedNotchView.swift
├── Media/
│   ├── MediaPlaybackModel.swift
│   ├── MediaRemoteAdapterClient.swift   # reads (subprocess)
│   └── MediaRemoteCommands.swift        # writes (in-process)
├── Components/
│   ├── MarqueeText.swift      # ticker for overflowing titles
│   ├── EqualizerView.swift    # 6-bar procedural waveform
│   └── ArtworkColors.swift    # dominant-color extraction
├── Claude/                    # Phase 2 glyph — built, not yet wired
└── Resources/                 # adapter framework + .pl (build script output)
```

Two implementation notes that aren't obvious from the file names:

- **The panel never resizes.** It's created at its fully-expanded size and only
  the SwiftUI content animates. Resizing an `NSWindow` every frame fights the
  window server and tears along the notch edge. `NotchHostingView` then
  restricts hit-testing to the drawn shape so the invisible remainder doesn't
  eat clicks meant for the app underneath.
- **The equalizer is procedural, not audio-reactive.** Real levels need a system
  audio tap and its permission flow; the spec scopes that out of v1.

## Claude Code bridge (Phase 2, not yet wired)

`integration/claude-code-hooks/` holds the ready-to-install half of the bridge:
a hooks `settings.json` and the `isle-cli` script that writes
`~/.isle/claude-status.json`. The app does not watch that file yet.

```bash
mkdir -p ~/.local/bin
cp integration/claude-code-hooks/isle-cli ~/.local/bin/isle-cli
chmod +x ~/.local/bin/isle-cli
# ensure ~/.local/bin is on PATH
```

Then merge `integration/claude-code-hooks/settings.json` into the
`.claude/settings.json` of any project you want Isle to watch.

## Known gaps

- Claude Code file watcher isn't implemented — `claudeState` is hardcoded to
  `.disconnected`, so the notch currently behaves as a music-only overlay.
- No settings pane; control visibility, accent color, and auto-collapse timing
  aren't configurable yet.
- `isle-cli` doesn't parse `session_id` from the hook's stdin, so concurrent
  Claude Code sessions overwrite each other. Fine for the single-session MVP.
- `SparkShape` is still the placeholder geometry.
- Multi-display: renders on the built-in display only, by design.
