# Build Spec: "Isle" — Dynamic Island Notch for macOS with Claude Code Awareness

> **How to use this doc:** Paste this whole file as your first message to Claude Code (or another coding agent) in a fresh project directory, or drop it in as `PROJECT_BRIEF.md` and tell the agent to read it first. It's written as a spec, not a chat request, so the agent has everything it needs to start scaffolding without guessing.

---

## 1. Role & Objective

You are a senior macOS engineer building a native Swift/SwiftUI menu-bar utility called **Isle**. It turns the MacBook camera notch into a "Dynamic Island"-style live activity area with two jobs:

1. A persistent, hideable media player synced to whatever is currently playing (Spotify or Apple Music).
2. A live status indicator for a running Claude Code session — expanding automatically when Claude needs permission, and showing distinct states for "working" and "finished."

Build this as a real, runnable Xcode project (SwiftUI + AppKit where needed), not a mockup.

---

## 2. Architecture Reference (study, don't clone)

Before designing the window/overlay technique, review the open-source project **boring.notch** (`github.com/TheBoredTeam/boring.notch`, SwiftUI, ~7.8k stars). It already solves:
- Rendering an interactive shape over/around the real hardware notch using a borderless, transparent, always-on-top `NSWindow`.
- Reading system-wide "now playing" state via Apple's private `MediaRemote` framework (works for Spotify, Music, Safari, anything — not per-app APIs).
- Hover-to-expand / collapse animation timing.

Use it as a reference for *technique*, not as a dependency — Isle should be its own codebase, since we're adding a second live-activity source (Claude Code) that changes the state machine.

---

## 3. Core Feature Requirements

### 3.1 Notch UI Shell & State Behavior
- Borderless, transparent `NSWindow`, `.floating` or `.statusBar` level, positioned to hug the physical notch area on notched MacBooks (`NSScreen.safeAreaInsets`), with a graceful fallback pill/bar for non-notched Macs (external display, older MacBook).
- Runs as an agent app — `LSUIElement = true` (no Dock icon, menu-bar item only, with a menu-bar icon for quit/settings).
- Three visual states, each with its own size/shape: **Collapsed**, **Hover-expanded** (user-triggered, not urgent), **Live-activity-expanded** (agent-triggered by Claude Code events — must interrupt/override collapsed state even if the mouse isn't there).
- Smooth spring animations between states (match system feel — see boring.notch's animation curves as a reference point).

#### Expanded state (hover-expanded or live-activity-expanded)
- Full media control row: play/pause, previous/next, plus **shuffle and repeat/loop** — both toggleable in Settings, since some users want a minimal control row (see 3.4).
- Duration/progress bar: scrubber with elapsed/remaining time labels, seekable by drag.
- Album art (large), song title, artist name.
- **Marquee scroll** for song title/artist when the text overflows the available width — a smooth, continuous horizontal scroll with a brief pause at each end before looping (the standard "now playing" ticker pattern, e.g. iPod Classic / CarPlay). Implement as a horizontal offset animation, not an opacity flash — keeps it readable and avoids an actual strobing/flashing effect, which is worth avoiding on accessibility grounds as well as aesthetics.
- When the notch expands because of a Claude Code event rather than a music hover, show Claude's status card (see below) — if music is also playing, see "Both active at once" for how the two share the expanded view.

#### Minimized (collapsed) state
- **Music playing, Claude idle/disconnected:** show a small album-art thumbnail plus an animated **6-bar equalizer waveform**. Bars are painted with a gradient built from the artwork's dominant colors (sample 2–3 prominent colors from the album art — e.g. simple average-color-per-region extraction — and drive a linear/angular gradient across the bars). For v1, animate the bars procedurally (a pleasant looping pattern cued to playback state, not real audio analysis); true audio-reactive levels need a system audio tap, which adds permission complexity — flag as a stretch goal, not MVP.
- **Claude Code active, no music showing:** show an animated status glyph — a pulsing/rotating orb or spinner styled after Claude Code's own CLI "thinking" indicator for `working`, an attention-color pulse for `needs_approval`, and a checkmark morph for `done`. Since this is a personal build, styling it after Claude's visual identity is reasonable, but design an original glyph that's clearly *inspired by* rather than a pixel-for-pixel copy of Anthropic's logo/wordmark — and check Anthropic's brand guidelines before any public release of the app.
  - **Implementation: native vector code, not an asset file** (SwiftUI `Canvas`/`TimelineView`, or `CAShapeLayer` path animation). This glyph needs to recolor per state and per the user's accent setting, interrupt/restart instantly on a state change, and morph smoothly between shapes (orb → checkmark) — all of which procedural vector animation handles cleanly and a baked video/GIF/sprite-sheet does not.
  - **Concrete implementation:** two drop-in components — `BreathingShapeView.swift` (`TimelineView(.animation)` + `Canvas`, sine-wave-driven scale/opacity off wall-clock time, frame-accurate/never drifts — use for SwiftUI previews and anywhere the glyph's phase needs to sync with another `TimelineView`-driven element like the marquee or equalizer) and `BreathingShapeLayer.swift` (`CAShapeLayer` subclass with looping `CABasicAnimation`s on `transform.scale`/`opacity`, wrapped in `NSViewRepresentable`, cheaper since Core Animation runs it on the render server — **use this one for the shipped build**, since the glyph is on-screen essentially the entire time the app runs and CPU/battery cost compounds). Both take a generic `Shape`/`Path` closure and expose `period`, `minScale`/`maxScale`, `minOpacity`/`maxOpacity`.
  - Drive shape/color from state: `working` = steady slow breathe, `needs_approval` = faster/brighter attention-color breathe, `done` = one-shot animation to a checkmark. If morphing the `CAShapeLayer` path between shapes (spark → checkmark) via `CABasicAnimation` on `path`, both paths need matching point count and point ordering for Core Animation to interpolate cleanly — mismatched paths jump-cut instead of morphing.
  - Keep the placeholder 4-point spark shape as an **original design**, not a reproduction of Anthropic's actual mark — swap `SparkShape`/`sparkCGPath(radius:)` for your own tuned geometry rather than sourcing "the official" asset. A breathing 4-point sparkle is common, non-exclusive visual language; the specific proprietary path isn't something to copy, particularly once this goes beyond personal/local use (public repo, App Store, etc. all count).
- **Both active at once (music playing + a live Claude Code status):** default to a **split minimized view** — left half of the notch shows the mini equalizer, right half shows the Claude status glyph, mirroring how iOS Dynamic Island handles two concurrent Live Activities. Exception: if Claude's state is `needs_approval`, that's urgent and takes over the *full* minimized notch (music demotes to a thin colored ring at the edge, or disappears until hovered) so it can't be missed. Keep the split-vs-priority rule and each side's width as configurable constants, not hardcoded, so a later Settings option like "cycle instead of split" is a small change, not a rewrite.

### 3.2 Media Sync (Spotify + Apple Music)
- Use `MediaRemote` (private framework, loaded via `dlopen`/`dlsym` — this is the standard technique third-party "now playing" utilities use; document the entitlement caveat below) to get a single unified now-playing feed: track, artist, artwork, playback position, playing/paused state — regardless of whether the source is Spotify or Apple Music.
- Controls: play/pause, next/previous, seek (scrubber), volume. Route commands back through `MediaRemote`'s command-sending API so they work regardless of source app.
- Album art should drive the notch's ambient background color (blurred/extracted dominant color), matching the "Dynamic Island" aesthetic.
- **Caveat to document in the README:** `MediaRemote` is a private framework. This is fine for a personal, sideloaded, non-notarized-for-App-Store build (this is the assumed distribution model — see Section 8). If the user later wants App Store distribution, this whole subsystem needs to be swapped for Apple's public `MusicKit` (Apple Music only, no Spotify) plus Spotify's official Web API (requires OAuth, no local Spotify-app control) — flag this as a real trade-off in the README, don't silently downgrade.

### 3.3 Claude Code Awareness Integration
This is the novel part. Claude Code has a **hooks system** — user-defined commands that fire at specific points in its lifecycle (`SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Notification`, `Stop`, and others). Hooks can run a shell command or POST to an HTTP endpoint, and receive JSON context about the event. There is no other API for "current status" — this hook bridge **is** the integration.

**Bridge design (default: local status file, not a network server — see rationale below):**

1. Claude Code hooks write a small JSON status file, e.g. `~/.isle/claude-status.json`:
   ```json
   { "state": "working", "project": "my-app", "session_id": "abc123", "updated_at": "2026-08-25T10:32:00Z" }
   ```
2. Isle watches that file with `DispatchSource` (file-system events), not polling, and updates UI state the moment it changes.
3. Map hook events → notch state:

| Claude Code hook event | Isle state | Meaning |
|---|---|---|
| `UserPromptSubmit`, `PreToolUse` | `working` | Claude is actively doing something |
| `Notification` (fired when Claude is awaiting permission or idle-waiting-on-user) | `needs_approval` | **Auto-expand the notch.** This is the important interrupt case. |
| `Stop` | `done` | Claude finished responding |
| `SessionStart` | `idle` | Session ready, nothing happening yet |
| (hook errors / missing file) | `disconnected` | No active session detected |

4. Ship a ready-to-drop-in `.claude/settings.json` hooks config (write this file into the repo under `/integration/claude-code-hooks/`) so the user doesn't have to hand-write it:
   ```json
   {
     "hooks": {
       "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "isle-cli set-state working" }] }],
       "PreToolUse": [{ "hooks": [{ "type": "command", "command": "isle-cli set-state working" }] }],
       "Notification": [{ "hooks": [{ "type": "command", "command": "isle-cli set-state needs_approval" }] }],
       "Stop": [{ "hooks": [{ "type": "command", "command": "isle-cli set-state done" }] }],
       "SessionStart": [{ "hooks": [{ "type": "command", "command": "isle-cli set-state idle" }] }]
     }
   }
   ```
   Where `isle-cli` is a tiny helper binary (or shell one-liner using `plutil`/`jq`) shipped alongside the app that just writes the JSON status file. Keep this dead simple — it should not require the main app to be running to succeed (avoid a crash loop if Isle isn't open).

**Why file-watching over a local HTTP server for v1:** no port management, no firewall prompts, no auth story, and hooks already support `command` type trivially. If later you want near-zero-latency push instead of FS-event latency (~tens of ms, imperceptible in practice), swap to Claude Code's `http` hook type posting to a `127.0.0.1` listener inside the app — note this as a Phase 3 option, don't build it first.

- Symbol design and minimized/expanded appearance per state (`working`, `needs_approval`, `done`, `idle`/`disconnected`) — see the "Minimized state" and "Expanded state" breakdowns in 3.1, including the split-view rule for when music and Claude Code are both active. `needs_approval` should stay expanded/prioritized until the user dismisses or actions it, not auto-collapse on a timer like `done` does (~4s toast).
- Support multiple concurrent Claude Code sessions/projects as a stretch goal, not MVP — MVP is single active session. Flag the multi-session design question in Section 7.

### 3.4 Customizable Media Controls
- Settings pane (SwiftUI, opened from menu-bar icon): choose which controls appear in the expanded view (scrubber on/off, volume slider on/off, next/prev on/off, **shuffle on/off, repeat/loop on/off**), reorder them, pick accent color / auto-color-from-artwork toggle, adjust auto-collapse timing for the `done` state.
- Also expose: minimized-state waveform on/off (fall back to plain album art if the user finds the equalizer distracting), and the "split vs. priority-override" behavior for the combined music+Claude Code minimized state (see 3.1) — split is the default, cycling is an alternative worth a toggle.
- Persist via `@AppStorage`/`UserDefaults`.

---

## 4. Tech Stack
- Swift 5.10+, SwiftUI for views, AppKit interop for the overlay window (`NSWindow`, `NSHostingView`), macOS 14+ target (Sonoma notch APIs).
- No third-party UI frameworks — keep it native and light.
- Xcode project (not SPM-only script) so it's directly runnable/debuggable.

---

## 5. Explicit Non-Goals (v1)
- App Store distribution (blocked by `MediaRemote` private API use — see 3.2 caveat).
- Windows/other OS support.
- Multi-display notch sync beyond "just render on the built-in display."
- Remote/cloud-hosted Claude Code sessions (only local CLI sessions on the same Mac).
- Full multi-session Claude Code dashboard (single active session for MVP).

---

## 6. Build Phases
1. **Phase 1 — Notch shell + media sync.** Overlay window, collapsed/hover states, `MediaRemote` now-playing + controls. Ship something usable as a music-only notch app first.
2. **Phase 2 — Claude Code bridge.** File watcher, state enum, hook config file, live-activity-expanded state with the approval-needed interrupt behavior.
3. **Phase 3 — Customization + polish.** Settings pane, accent theming, animation polish, optional HTTP-hook low-latency mode, multi-session stretch goal.

---

## 7. Open Questions / Assumptions Made (flag these back to the user, don't silently guess further)
- **Distribution assumed: personal/sideloaded, not App Store.** This unlocks `MediaRemote`. Confirm before Phase 1 if this is wrong.
- **Single active Claude Code session assumed for MVP.** If the user runs several Claude Code sessions across projects simultaneously, the status file needs a `session_id`-keyed structure and the UI needs a session switcher — bigger scope, confirm before building.
- **Hook bridge assumed to be file-based**, not a local HTTP server. Revisit only if the user reports FS-event latency is noticeable (it shouldn't be).
- Icon/symbol set (SF Symbols vs. custom art) — default to SF Symbols for speed; swap later if the user wants a custom visual identity.

---

## 8. Deliverables
- Runnable Xcode project with README covering: build steps, the private-API/App-Store caveat, how to install the Claude Code hooks config, and how to grant any required permissions (Accessibility/Automation prompts if applicable).
- The `.claude/settings.json` hook config and `isle-cli` helper, ready to copy into any project the user wants monitored.
