# Isle — Handoff

**Date:** 2026-08-25
**State:** Phase 1 (notch shell + media sync) builds, runs, and streams live now-playing data. Not visually verified by me — see "Blocked on you".

---

## What Isle is

A native Swift/SwiftUI macOS menu-bar utility (`LSUIElement`, no Dock icon) that turns the MacBook camera notch into a Dynamic-Island-style live activity area. Two jobs per `PROJECT_BRIEF.md`:

1. A persistent, hideable media player synced to whatever is playing system-wide (Spotify / Apple Music / Chrome).
2. A live status indicator for a running Claude Code session that auto-expands when Claude needs permission. **Not started** — Phase 2.

### Decisions already locked in

| Decision | Choice | Consequence |
|---|---|---|
| Distribution | Personal / sideloaded, **not** App Store | Free to use private MediaRemote APIs |
| Claude sessions | ~~One at a time for MVP~~ **superseded** | Now one status file per session under `~/.isle/sessions/`, with urgency-ranked selection — the flat file let a background session wipe the watched session's state. See "Bridge reliability" in `ROADMAP.md` |
| Phase order | Phase 1 first | Media before Claude integration |

---

## The single most important thing to understand: MediaRemote is half-gated

Since roughly macOS 15.4, calling `MRMediaRemoteGetNowPlayingInfo` **in-process returns an empty dictionary** for unentitled apps. I verified this empirically on macOS 26.5 — direct reads returned nothing while the adapter returned full metadata.

But the gating is **asymmetric**:

- **Reads are gated.** They go through `Vendor/mediaremote-adapter/mediaremote-adapter.pl`, a Perl trampoline that loads MediaRemote inside Apple-signed `/usr/bin/perl` (which *does* hold the entitlement) and emits JSON-lines on stdout. See `Isle/Media/MediaRemoteAdapterClient.swift`.
- **Commands are not gated.** Play/pause/next/seek still work in-process via `CFBundleGetFunctionPointerForName`. See `Isle/Media/MediaRemoteCommands.swift`.

Do not "simplify" by collapsing these two paths into one. They are separate for a load-bearing reason.

### Licensing trap — read before copying any code

The brief points at [`TheBoredTeam/boring.notch`](https://github.com/TheBoredTeam/boring.notch) as a reference. **It is GPL-3.0.** Treat it as a *technique* reference only — do not copy code from it into Isle unless you intend to GPL Isle.

The vendored `mediaremote-adapter` (from `ungive/mediaremote-adapter`) is **BSD-3-Clause**, which is fine. Its license text ships in the bundle as `mediaremote-adapter-LICENSE.txt`.

---

## Build & run

```sh
# One-time: build the adapter framework (universal, ad-hoc signed, self-tests)
./scripts/build-mediaremote-adapter.sh

# Build the app
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project Isle.xcodeproj -scheme Isle -configuration Debug build
```

`DEVELOPER_DIR` is required because `xcode-select` on this machine points at the Command Line Tools, not Xcode. Without it `xcodebuild` can't find the macOS SDK.

Built app lands in:
```
~/Library/Developer/Xcode/DerivedData/Isle-hfdsgqxoaufajwbibtimmlbusuwq/Build/Products/Debug/Isle.app
```

---

## Architecture landmines (each one cost real debugging time)

### 1. The framework must NOT be inside `Isle/`

`Isle/` is a `PBXFileSystemSynchronizedRootGroup` (Xcode 16+, `objectVersion = 77`). It auto-syncs files — convenient — but it **auto-links any `.framework` it finds inside it**. That produced a dyld crash at launch:

```
Library not loaded: @rpath/MediaRemoteAdapter.framework/...
```

...because Xcode linked it but nothing embedded it. Isle must **never link this framework** — it only ever hands the *path* to `/usr/bin/perl`, which `dlopen`s it out-of-process.

The fix: the framework lives in `Vendor/mediaremote-adapter/` (deliberately outside `Isle/`) and is copied in by the `Copy MediaRemoteAdapter` shell script build phase. Verify with:

```sh
otool -L .../Isle.app/Contents/MacOS/Isle | grep -i mediaremote   # must print nothing
```

If that prints anything, the framework has crept back into the synchronized group.

### 2. Never touch the main actor from the Core Audio realtime thread

`SystemAudioLevels.swift` taps system audio. The IOProc block runs on `com.apple.audio.IOThread.client`. My first version called `MainActor.assumeIsolated` there, which **traps rather than degrading** — instant SIGTRAP:

```
_swift_task_checkIsolatedSwift → dispatch_assert_queue → brk 1
```

The fix, which must be preserved: all DSP lives in `private final class AudioAnalyzer: @unchecked Sendable`, guarded by an `NSLock`. The IOProc captures **`analyzer`, not `self`**:

```swift
// Capture the analyzer, not self: self is main-actor isolated and
// must not be touched from the realtime thread at all.
let analyzer = self.analyzer
AudioDeviceCreateIOProcIDWithBlock(&procID, aggregate, nil) { _, inputData, _, _, _ in
    analyzer.process(inputData)
}
```

A 30 Hz `Timer` on the main run loop then calls `analyzer.snapshot()` and publishes. `MainActor.assumeIsolated` *is* valid there, because a scheduled `Timer` genuinely fires on main.

### 3. `.nonactivatingPanel` only works on `NSPanel`

Not on `NSWindow`. `NotchWindow` is an `NSPanel` for exactly this reason — the overlay must never steal focus. Window level is `.mainMenu + 1` (verified rendering at layer 25 vs. the menu bar's 24).

### 4. ISO8601 timestamp parsing needs both formatters

The adapter emits whole-second timestamps (`2026-08-25T19:12:47Z`) but switches to fractional under `--micros`. `ISO8601DateFormatter` is strict: a fractional-configured formatter returns `nil` on a whole-second string. That would silently peg every timestamp to `Date()` and make the scrubber drift. `parseTimestamp` tries both.

---

## Current status by component

| Component | State |
|---|---|
| Xcode project scaffold | Done |
| Notch overlay panel (`NotchWindow`, controller, hit-testing) | Done |
| now-playing feed via adapter | **Working** — verified live, including Chrome |
| Collapsed + expanded views | Done |
| Menu bar item + README | Done |
| Real-audio waveform | Built; **needs your eyes** |
| Transport commands | Code written, **never fired live** |
| Claude Code integration (Phase 2) | **Not started** |
| Settings pane (Phase 3) | Not started |

### Design pass just completed (your five points)

1. **Notch too wide** → `NotchMetrics.collapsedSideInset` 90 → **46**, sized to actual content (18pt thumbnail / 26pt waveform + padding) rather than picked by eye.
2. **Waveform should truly work** → new `Isle/Media/SystemAudioLevels.swift`: Core Audio process tap (`AudioHardwareCreateProcessTap` + aggregate device) → 1024-pt Hann-windowed vDSP FFT → 6 **log-spaced** bands → fast-attack/slow-release smoothing. Log spacing is not cosmetic: linear bands dump nearly all of music's energy into bar 1.
3. **Waveform both ways** → `EqualizerView` rewritten. Bars grow symmetrically from a centre line; silence rests as a row of dots (`dotHeight: 2.5`).
4. **Gradient vertical** → one `GraphicsContext.Shading` spanning the strip's full height, sampled per bar, so colour encodes amplitude instead of each bar restarting the ramp.
5. **Remove shadows / gradient bottom-up** → panel and artwork shadows deleted; ambient gradient inverted (transparent at top, artwork colour pooling at bottom) so the top edge stays pure black against the bezel. Artwork 96 → 108; expanded column now distributes with flexible `Spacer`s.

---

## Bugs found and fixed this session

- **SIGTRAP on the audio thread** — see landmine #2 above. Fixed.
- **`AudioHardwareDestroyProcessTap` availability** — macOS 14.2+, but deployment target is 14.0. Wrapped in `if #available(macOS 14.2, *)`, guarded narrowly so aggregate-device teardown still runs on older systems.
- **Waveform was using fake data in the common case** — `CollapsedNotchView.swift` had two `EqualizerView` call sites. The *split* branch passed `levels:`; the **music-only branch did not**. Since `claudeState` is hardcoded `.disconnected`, the music-only branch is the one that actually renders — so the real-audio feature was unreachable. Fixed; both sites now pass `viewModel.audioLevels`.

---

## Known open issues

### Adapter orphans on abnormal termination
Graceful quit is clean (`applicationWillTerminate` → `hide()` → `viewModel.stop()` → `process.terminate()`). But a **crash or force-quit leaves the perl subprocess running forever**, and each relaunch adds another. macOS does not kill children when the parent dies.

I hit this during testing and reaped it manually. If you see multiple adapters:
```sh
pkill -f mediaremote-adapter
```
Proper fix: either have the app reap stale adapters at `start()`, or have the child poll `getppid()` and exit when it's orphaned. The script has no parent-death handling today.

### Spurious SourceKit diagnostics
The editor may show `Cannot find type 'NotchViewModel' in scope` and similar for types that plainly exist in sibling files. This is the indexer lacking whole-module context for the synchronized group, **not** a compile error. `xcodebuild` is the authority — if it says `BUILD SUCCEEDED`, the code is fine.

### `SparkShape` is placeholder geometry
`Isle/Claude/BreathingShapeView.swift:117`. Swap it for the real Claude mark when you have the asset. `ClaudeStatusGlyphView` already takes an `AnyShape`, so it's a one-line change at the call site.

---

## Blocked on you (I could not verify these myself)

**Screen recording is not permitted for this terminal.** `screencapture` fails with "could not create image from display", so I have **never seen the UI**. Every visual claim above is derived from code and from `CGWindowListCopyWindowInfo` geometry, not from looking at it.

Three things need your eyes:

1. **Does the waveform react to real audio?** This requires you to accept the one-time **Audio Recording** permission prompt the Core Audio tap triggers. If you declined it, `SystemAudioLevels.failureReason` is set and `EqualizerView` **silently falls back to the procedural pattern** — which looks plausible and will fool you into thinking it works. Check System Settings → Privacy & Security → Audio Recording. Expect the dB window (`-70dB` floor, `60dB` range in `SystemAudioLevels`) to need tuning against real music.

2. **Is anything rendering under the camera housing?** `NotchMetrics` derives the cutout width from `auxiliaryTopLeftArea` / `auxiliaryTopRightArea`. This is *more pressing now* because I cut `collapsedSideInset` from 90 to 46 — there is much less slack. If content is drawing under your camera, that derivation is off.

3. **Do the narrower notch, bottom-up gradient, and removed shadows look right?**

**Also: boringNotch was still running** and occupies the same physical space. Quit it before evaluating, or you'll be comparing against the wrong overlay.

---

## Next steps, in the order I'd do them

1. **Visually verify the above.** Everything downstream is guesswork until the UI is confirmed.
2. **Fire a live transport command.** The code in `MediaRemoteCommands` has never been exercised — I deliberately avoided sending one unprompted, since it would have blipped your paused Spotify. Say the word and it's a one-line test.
3. **Phase 2: Claude Code integration.** `NotchViewModel.claudeState` is hardcoded `.disconnected`. Needs the hook bridge + status-file watcher from brief §3.3. Note the deliberate design in `hasLiveActivity`: only `.needsApproval` opens the panel — `.working` and `.done` are ambient, or the notch would flap open on every tool call.
4. **Phase 3: settings pane.**
5. **`session_id` parsing in `isle-cli`.**

---

## Version control warning

**This project is entirely untracked.** `git status` shows `isle/` as a single untracked directory inside a parent repo rooted at `~/Documents` (whose only commit is `1e371ab "first commit"`). There is **no version-control safety net for any of this work** — no history, nothing to revert to.

Strongly recommend `git init` inside `isle/` and an initial commit before further changes. Note that the parent repo has ~47 unrelated untracked entries (`League of Legends/`, `Textbooks/`, `.DS_Store`, …), so committing from `~/Documents` would sweep up a great deal you almost certainly don't want.
