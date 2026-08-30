# Isle

**A Dynamic Island for the MacBook notch — for Spotify and Claude Code.**

Isle turns the dead space around your camera housing into a live, interactive
island. It shows what's playing and reacts to the music with a real audio
waveform; it shows what your Claude Code session is doing and pops open when
Claude needs you. It expands on hover and folds back out of the way when you're
done.

<!-- TODO: hero screenshot / short screen recording -->

---

## Install

Isle uses a private framework and AppleScript automation, which rules out the
Mac App Store. It ships as a disk image you install yourself, and updates itself
from there.

**1. Download and drag to Applications**

[**Download Isle 0.1.3**](https://github.com/matthewhamilton3141/isle/releases/latest)
— universal, macOS 14+. Open the DMG and drag **Isle** to **Applications**.

**2. Clear the quarantine flag**

Isle is signed, but not with a paid Apple Developer ID, so macOS quarantines it
on download and refuses to launch it — usually with *"Isle is damaged and can't
be opened"* (that message is Gatekeeper's wording for "unnotarised", not an
actual corrupt download). One command clears it:

```bash
xattr -dr com.apple.quarantine /Applications/Isle.app
```

Then open Isle normally. You only need to do this once — in-app updates are not
quarantined, so it won't come back on the next version.

<details>
<summary>If the DMG itself won't even mount</summary>

Same flag, applied to the download:

```bash
xattr -dr com.apple.quarantine ~/Downloads/Isle-0.1.3.dmg
```
</details>

<details>
<summary>What that command actually does</summary>

`com.apple.quarantine` is an extended attribute macOS attaches to anything you
download. Gatekeeper reads it and, finding no Developer ID signature and no
notarisation ticket, blocks the app. `xattr -dr` deletes the attribute
recursively from the bundle, which tells macOS you're vouching for the app
yourself. It changes nothing about the app — the code is unmodified and still
signed, just not by an identity Apple has on file.

Only run this on software you trust and got from a source you trust. Isle's
source is all here; you can also [build it yourself](#build-from-source) and
skip the step entirely.
</details>

**3. Pick a mode**

First launch asks what you want Isle to be: **Music**, **Claude Code**, or
**Both**. You can change it any time in **Settings…**. Only the subsystems your
mode needs ever run, so a Claude-only user is never asked for Spotify
permissions.

**4. Grant permissions (Music / Both only)**

macOS asks twice on first use:

- **Automation → Spotify**, for the transport controls. Required for playback
  control.
- **Audio capture**, for the waveform. Decline it and everything still works —
  the waveform falls back to a procedural pattern rather than going dead.

If you dismissed a prompt by accident, both live in **System Settings → Privacy
& Security** — under *Automation*, and under *Microphone* (older macOS) or
*Audio Recording* (newer).

Isle runs as a menu bar app with no Dock icon. Look for the menu bar item.

### Requirements

| | |
|---|---|
| Operating system | macOS 14 Sonoma or newer |
| Waveform requires | macOS 14.4 (Core Audio process-tap API) |
| Music source | Spotify |
| Claude source | Claude Code |
| Build from source | Xcode 16 or newer |

---

## What it does

- **Now playing at a glance.** Album art, title, and artist live in the
  collapsed notch; hover to expand into full controls and a scrubbable playbar.
- **Real audio-reactive waveform.** A Core Audio process tap on Spotify drives
  the equalizer from the actual signal — it moves with *your* music and nothing
  else on the system.
- **Transport controls.** Play/pause, next, previous, scrub, shuffle, and
  repeat, sent straight to Spotify.
- **Sharp artwork.** Cover art is decoded at true pixel resolution so the tiny
  collapsed thumbnail stays crisp instead of mushy.
- **Live Claude Code status.** Working, waiting on you, done, or failed — with
  a breathing glyph while it runs and a checkmark when it lands.
- **Both at once.** In *Both* mode the collapsed island splits between music
  and Claude, and the expanded view tabs between them.
- **Stays out of the way.** A borderless, non-activating overlay that never
  steals focus and never resizes the window under your cursor.

### The menu bar

| Item | What it does |
|---|---|
| **Toggle Notch** | Show or hide the island |
| **Pop out notch for alerts** | Whether Claude alerts expand the island on their own |
| **Settings…** | Mode, music options, Claude hook, updates |
| **Setup…** | Re-run the first-launch mode picker |
| **Check for Updates…** | Manual update check |
| **Marker Editor…** | Design the dot-matrix markers for each Claude state |
| **Animation Gallery…** | Preview the island's animations |
| **Quit Isle** | |

### Updates

Isle checks for updates on launch and from **Check for Updates…**. Releases are
published as a DMG plus a `latest.json` manifest signed with an Ed25519 key
whose public half is baked into the app, so an update that isn't ours is
rejected before it's installed.

---

## Claude Code

Isle surfaces the live status of a [Claude Code](https://claude.com/claude-code)
session in the notch — expanding on its own when Claude is waiting on you.

**Setup:** open **Settings… → Claude Code → Install**. That drops a helper into
`~/.isle/bin` and merges Isle's hook entries into `~/.claude/settings.json`
without disturbing hooks you already have. **Remove** takes both back out.
Existing installs are quietly brought up to date when Isle launches.

**How it works:** Claude's hooks call the helper, which writes one small JSON
file per session to `~/.isle/sessions/<session-id>.json`. Isle watches that
directory with file-system events and maps each session's state to a marker —
`working` breathes, `needs_approval` pops the island open even when your pointer
is elsewhere, `done` shows a checkmark and settles back on its own. When several
sessions are live, the one needing attention wins over the one merely working,
regardless of write order.

Liveness doesn't depend on the hooks firing: Isle also reads the CLI's own
`~/.claude/sessions/<pid>.json` records, so a session killed outright can't
freeze the island on *Thinking*. If a turn has gone unanswered for 45s with no
tool running, the island says so rather than guessing why.

See [ROADMAP.md](ROADMAP.md) for what's built and what's next — including the
hook-surface behaviours that are worth not rediscovering.

---

## Build from source

```bash
git clone https://github.com/matthewhamilton3141/isle.git
cd isle

# One-time: build the bundled now-playing bridge (see "How it works" below).
./scripts/build-mediaremote-adapter.sh

open Isle.xcodeproj    # then ⌘R
```

A build you compile yourself is never quarantined, so the `xattr` step above
doesn't apply.

<details>
<summary>Cutting a release</summary>

```bash
swift scripts/isle-sign.swift keygen     # once — private key to ~/.isle-signing/
scripts/sign-release.sh                  # builds, packages, signs, writes dist/latest.json
```

The script refuses to ship a DMG the app itself would reject: it verifies its
own signature against the public key embedded in `Isle/Update/Updater.swift`
before writing the manifest. Upload **both** the DMG and `latest.json` to the
GitHub release for the matching tag.
</details>

---

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
| Claude status | Per-session JSON + FS events | `Claude/ClaudeStatusWatcher.swift` |

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

### Project layout

```
Isle/
├── IsleApp.swift              # @main, agent app + menu bar item
├── Core/                      # AppSettings, IsleMode (music / claude / both)
├── Notch/                     # the overlay: window, shape, state, views
│   ├── NotchWindow.swift          borderless non-activating NSPanel
│   ├── NotchHostingView.swift     hit-testing clipped to the drawn shape
│   ├── NotchViewModel.swift       media + Claude feeds, playback clock
│   ├── CollapsedNotchView.swift
│   ├── ExpandedNotchView.swift    music tab
│   └── ClaudeExpandedView.swift   Claude tab
├── Media/
│   ├── MediaPlaybackModel.swift         now-playing snapshot (value type)
│   ├── MediaRemoteAdapterClient.swift   reads (subprocess)
│   ├── SpotifyController.swift          poll + commands (AppleScript)
│   └── SystemAudioLevels.swift          audio-reactive waveform
├── Claude/
│   ├── ClaudeStatusWatcher.swift    per-session status files
│   ├── ClaudeSessionRegistry.swift  hook-free liveness via the CLI's own records
│   ├── HookInstaller.swift          installs/removes the hooks + helper
│   └── …GlyphView / BreathingShape  the marker renderers
├── Markers/                   # designable dot-matrix markers per Claude state
├── Components/                # MarqueeText, EqualizerView, ArtworkColors
├── Settings/, Onboarding/     # settings pane, first-launch mode picker
├── Update/                    # signed-manifest updater
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

---

## Troubleshooting

**"Isle is damaged and can't be opened."** The quarantine flag — run the `xattr`
command in [Install](#install). The download is fine.

**Nothing appears in the notch.** Isle has no Dock icon; check the menu bar for
its item and use **Toggle Notch**. It also works on Macs without a notch, drawn
against the top edge.

**The waveform doesn't move.** Audio capture needs macOS 14.4+ and permission.
If you declined the prompt, re-enable Isle under **System Settings → Privacy &
Security**, under *Microphone* or *Audio Recording* depending on your macOS
version. Without it the waveform runs a procedural pattern.

**Controls do nothing.** Automation permission for Spotify was declined — turn
Isle back on under **System Settings → Privacy & Security → Automation**.

**The Claude glyph never changes.** Confirm the hook is installed in
**Settings… → Claude Code**, and that `~/.claude/settings.json` still contains
the `isle-cli` entries. Sessions started before installing the hook won't
report.

---

## Licensing

Isle is [MIT licensed](LICENSE) — © 2026 Matthew Hamilton.

- **[`mediaremote-adapter`][mra]** — BSD-3-Clause, © 2025 Jonas van den Berg.
  Vendored into `Isle/Resources/` by the build script; the license text is
  copied alongside it.
- **[boring.notch][bn]** — GPL-3.0, credited as prior art for overlay-window and
  now-playing technique. No code from it is used in Isle, and none should be:
  see [HANDOFF.md](HANDOFF.md) before borrowing from it.

[mra]: https://github.com/ungive/mediaremote-adapter
[bn]: https://github.com/TheBoredTeam/boring.notch
