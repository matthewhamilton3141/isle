# Isle

**A Dynamic Island for the MacBook notch — built for Spotify.**

Isle turns the dead space around your camera housing into a live, interactive
island. It shows what's playing, reacts to the music with a real audio
waveform, and gives you transport controls a glance away — expanding on hover
and folding back out of the way when you're done.

<!-- TODO: hero screenshot / short screen recording -->

## Features

- **Now playing at a glance.** Album art, title, and artist live in the
  collapsed notch; hover to expand into full controls and a scrubbable playbar.
- **Real audio-reactive waveform.** A Core Audio process tap on Spotify drives
  the equalizer from the actual signal — it moves with *your* music and nothing
  else on the system.
- **Transport controls.** Play/pause, next, previous, and scrub, sent straight
  to Spotify.
- **Sharp artwork.** Cover art is decoded at true pixel resolution so the tiny
  collapsed thumbnail stays crisp instead of mushy.
- **Stays out of the way.** A borderless, non-activating overlay that never
  steals focus and never resizes the window under your cursor.

## Requirements

- macOS 14 (Sonoma) or newer — the audio waveform uses the Core Audio
  process-tap API (14.4+).
- Spotify.
- To build from source: Xcode 16 or newer.

## Install & run

```bash
# One-time: build the bundled now-playing bridge (see "How it works" below).
./scripts/build-mediaremote-adapter.sh

open Isle.xcodeproj    # then ⌘R
```

Isle runs as a menu bar app with no Dock icon (`LSUIElement`). Look for the
menu bar item, with **Toggle Notch** and **Quit**.

On first launch macOS will ask permission to control Spotify (Automation) and
to capture its audio — both are required for controls and the waveform.

## How it works

Reading now-playing state on modern macOS is not as simple as the obvious API
suggests, and the way Isle handles it is worth understanding before changing
anything in `Isle/Media/`.

The textbook approach is to `dlopen` Apple's private `MediaRemote` framework and
call `MRMediaRemoteGetNowPlayingInfo`. **That no longer works.** Around macOS
15.4 Apple gated the read side behind an entitlement third-party apps can't
obtain. The call still *succeeds* — it just returns an empty dictionary, so an
app built the naive way silently never shows a track. Verified through macOS
26.5.

So Isle splits the media layer:

| Operation | Mechanism | Source |
|---|---|---|
| Read now-playing | `mediaremote-adapter` subprocess | `Media/MediaRemoteAdapterClient.swift` |
| Play / pause / next / prev / seek | AppleScript to Spotify | `Media/SpotifyController.swift` |
| Audio waveform | Core Audio process tap on Spotify | `Media/SystemAudioLevels.swift` |

**Reading** goes through [`mediaremote-adapter`][mra], which loads MediaRemote
inside `/usr/bin/perl` — an Apple-signed binary that *does* hold the
entitlement — and streams JSON lines back over a pipe. Isle runs it as a
long-lived child process. A 1 Hz AppleScript poll of Spotify runs alongside it
and owns the playback clock, since it reads Spotify's true player position
directly and stays accurate through seeks and restarts.

**Commands** target Spotify by name over AppleScript. Isle is Spotify-scoped, so
addressing the app directly is both simpler and more correct than routing
through whatever app happens to own the system session.

`scripts/build-mediaremote-adapter.sh` fetches a pinned upstream tag, compiles a
universal framework with `clang`, and drops it plus the Perl driver into
`Isle/Resources/`. Isle never *links* the framework — it only invokes it by
path — so it ships as a plain resource.

### Distribution

Isle relies on a private framework and AppleScript automation, which rules out
the Mac App Store. It's distributed as a sideloaded build.

## Claude Code awareness (coming soon)

Isle is also designed to surface the live status of a [Claude Code](https://claude.com/claude-code)
session in the notch — expanding on its own when Claude is waiting on you. The
glyph is built and the hook bridge in `integration/claude-code-hooks/` is ready
to install, but the app doesn't watch its status file yet. See
[PROJECT_BRIEF.md](PROJECT_BRIEF.md) for the full roadmap.

## Project layout

```
Isle/
├── IsleApp.swift              # @main, agent app + menu bar item
├── Notch/                     # the overlay: window, shape, state, views
│   ├── NotchWindow.swift          borderless non-activating NSPanel
│   ├── NotchHostingView.swift     hit-testing clipped to the drawn shape
│   ├── NotchViewModel.swift       media feed + playback clock
│   ├── CollapsedNotchView.swift
│   └── ExpandedNotchView.swift
├── Media/
│   ├── MediaPlaybackModel.swift    now-playing snapshot (value type)
│   ├── MediaRemoteAdapterClient.swift   reads (subprocess)
│   ├── SpotifyController.swift          poll + commands (AppleScript)
│   └── SystemAudioLevels.swift          audio-reactive waveform
├── Components/
│   ├── MarqueeText.swift      # ticker for overflowing titles
│   ├── EqualizerView.swift    # the waveform
│   └── ArtworkColors.swift    # dominant-color extraction
├── Claude/                    # status glyph — built, not yet wired
└── Resources/                 # adapter framework + .pl (build script output)
```

Two design decisions that aren't obvious from the file names:

- **The panel never resizes.** It's created at its fully-expanded size and only
  the SwiftUI content animates. Resizing an `NSWindow` every frame fights the
  window server and tears along the notch edge. Hit-testing is then restricted
  to the drawn shape so the invisible remainder doesn't eat clicks.
- **The playback clock is smoothed, not sampled.** The scrubber runs off its own
  anchor and eases toward reported positions, so it stays continuous between the
  coarse updates the source apps provide.

## Licensing

- **Isle** is its own codebase.
- **[`mediaremote-adapter`][mra]** — BSD-3-Clause, © 2025 Jonas van den Berg.
  Vendored into `Isle/Resources/` by the build script; the license text is
  copied alongside it.
- **[boring.notch][bn]** is **GPL-3.0** and is cited only as a *reference* for
  overlay-window and now-playing technique. No code from it is used here, and
  none should be copied in — doing so would make Isle GPL-3 too. Read it for
  technique, then write your own.

[mra]: https://github.com/ungive/mediaremote-adapter
[bn]: https://github.com/TheBoredTeam/boring.notch
