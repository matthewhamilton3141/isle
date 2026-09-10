# Isle — Product Roadmap

**Positioning:** *The Dynamic Island for the MacBook — now with Claude Code.*

Isle turns the dead space around the camera housing into a live activity area.
Today it's a Spotify notch (Phase 1, shipped). This roadmap takes it to its real
identity: a configurable island that can run as a **music player**, a **Claude
Code companion**, or **both at once**.

> **Scheduled Prompts** — queue a prompt to auto-fire when your usage window
> reopens — is **deferred pending further research** and lives at the bottom of
> this doc under "Parked". It is not in the active milestone sequence.

This document is organized as milestones. Each is independently shippable and
ordered so nothing downstream is blocked. Milestones list **Goal**, **Scope**,
**Files**, **Acceptance**, and any **Decisions to lock** before starting.

---

## Where we are today

| Subsystem | State | Reference |
|---|---|---|
| Notch overlay shell (window, shape, hit-test, animations) | Shipped | `Isle/Notch/` |
| Media sync + transport (Spotify) | Shipped | `Isle/Media/` |
| Audio-reactive waveform | Shipped; source preference pending (M5) | `Isle/Media/SystemAudioLevels.swift` |
| Display selection (multi-display) | Built-in display only (M8) | `NotchMetrics.preferredScreen()` |
| Power / charging activities | Shipped (M9) | `Isle/Power/` |
| Calendar events and reminders (Agenda face + ambient toasts) | Shipped | `Isle/Agenda/` |
| Claude status glyph (breathing + checkmark) | Built, wired (M3) | `Isle/Claude/` |
| Claude hook bridge (`isle-cli` + `settings.json`) | Watched (M3); per-session files, v7 | `Isle/Claude/ClaudeStatusWatcher.swift` |
| Claude session registry (hook-free liveness) | Shipped | `Isle/Claude/ClaudeSessionRegistry.swift` |
| Stall / no-response detection | Shipped, one path unverified | `Isle/Notch/NotchViewModel.swift` |
| Claude hook installer | Done (M3) — menu-bar action, Settings wiring pending | `Isle/Claude/HookInstaller.swift` |
| `NotchViewModel.claudeState` | Live from watcher, mode-gated (M3) | `Isle/Notch/NotchViewModel.swift` |
| Settings pane | Shipped — mode, notch, media, Claude, updates. The SwiftUI `Settings` scene is still empty; the real window is built in `openSettings` | `Isle/Settings/SettingsView.swift` |
| Mode selection (Music / Claude / Both) | Model + gating done (M1); picker shipped in Settings and the menu bar | `Isle/Core/`, `Isle/Settings/SettingsView.swift` |
| Claude accent colour | Shipped | `Isle/Core/ClaudeAccent.swift` |
| Tabbed "Both" expanded view | Done (M4) | `Isle/Notch/ExpandedNotchView.swift`, `ClaudeExpandedView.swift` |

The state machine (`NotchState`, `NotchStateResolver`) and the collapsed
split-view rule (`CollapsedNotchView`) were already designed for two concurrent
activity sources. That's the foundation the "Both" mode builds on — most of the
work below is wiring, persistence, and UI, not re-architecture.

---

## Bridge reliability — what the hooks can and can't tell us

Shipped outside the milestone sequence, after the island was seen reporting
`Thinking` while the CLI showed an API error.

**The reported symptom turned out to be the multi-session bug, not a missing
retry detector.** The failing session wrote `error`, and a *second* session's
next `PreToolUse` overwrote the shared status file with `working` — the island
was showing the wrong session. Urgency ranking (below) is the fix: `failed`
outranks `working`, so the errored session now wins regardless of write order.

The rest of what follows was found while chasing that misdiagnosis, by
instrumenting a forced failure rather than by reading code — the hook surface
behaves differently from how it reads. Those findings are real and independently
verified, but note the no-response detector addresses a gap adjacent to the
original report, not the report itself.

### Claude Code behaviours worth not rediscovering

| Behaviour | Consequence |
|---|---|
| `StopFailure` names the failure `error`, not `error_type`, and carries `last_assistant_message` rather than `message` | Isle read the wrong field for months: every failure arrived kind-less, so no usage limit was ever pinned and the error marker was always generic |
| **A session backing off between API retries reports `status: "idle"`**, not `busy` | Any "is it working?" check gated on `busy` is false in exactly the case it exists to catch |
| Retryable API errors are an internal frame (`{type:"system", subtype:"api_error", retry_in_ms, retry_attempt, max_retries}`) rendered straight to the TUI | Never written to the transcript, no hook fires. Its wire twin `api_retry` reaches SDK/`stream-json` consumers only, so an interactive session cannot observe a retry directly |
| Claude Code fires its "waiting for your input" Notification ~60s after going idle — **including mid-retry-storm** | Isle downgraded a stalled turn to `Waiting`, which reads as "your turn" when nothing has come back |
| The transcript flushes per *content block*, not per message, and is interleaved with `queue-operation` / `attachment` / `file-history-snapshot` bookkeeping | A tool-free turn still appends every few seconds (so silence is meaningful), but only `user` / `assistant` entries answer "is a turn outstanding" |
| `~/.claude/sessions/<pid>.json` is written by the CLI itself, hook-free, pid-keyed | Liveness is `kill(pid, 0)` rather than a timeout; survives broken or uninstalled hooks |
| **An interrupt (ESC) fires no hook at all** — no `Stop`, no `PostToolUse` — and appends a synthetic `user` entry (`[Request interrupted by user]`) to the transcript | Every exit from `working` is hook-driven, so the record froze at `working`; and since that entry parses as a `user` turn, the no-response check read the ended turn as one still owed a response |

### What changed

- **Per-session status files** (`~/.isle/sessions/<session-id>.json`, helper v7).
  The old single `claude-status.json` was last-writer-wins, so a background
  session's `Stop` or idle notification silently wiped the state of the session
  the user was watching.
- **Urgency-ranked selection** (`NotchViewModel.selectStatus`): attention >
  active > quiescent, ties broken by recency. A quiescent session can never
  displace an active one, however recently it moved.
- **Session registry** as the liveness spine — a `SIGKILL`'d session fires no
  `SessionEnd`, and used to freeze the island on `Thinking` forever.
- **No-response detection** — *added, then removed.* Island `working`/`waiting`,
  no tool running, and the transcript's last conversation entry a `user` turn
  older than a threshold → `No response · 45s`, dimmed. It reported the
  observation rather than a cause, on the theory that the label was true for
  both a retry and a long think. In practice that was the problem: a single
  reasoning block is written to the transcript only when it *finishes*, so an
  unbroken deep think is silent on every signal Isle has and got labelled as a
  stall. Raising the threshold (45s → 180s → 360s) only traded the frequency of
  the false positive for a slower true one, and a wrong "No response" is more
  confusing than no label at all.
- **The staleness fade** went with it, for the same reason. Hook silence past
  180s dimmed the island to 45%, which is the same inference in a quieter
  register — and equally wrong during a long think. Isle now makes no claim
  about silence at all, in text or in treatment: it holds the last state it was
  actually told about, at full strength, until something tells it otherwise.
  The 5s timer stays on for its other job (re-running selection, so an
  interrupt's stuck record still gets retired), and the transcript tail reader
  survives because reconciliation depends on it.
- **`tool_active`** on the wire so a long `Bash` isn't read as a stalled model.
- **Interrupt reconciliation** (`NotchViewModel.reconciled`): a `working`
  record whose session the CLI no longer calls busy, and whose transcript shows
  the turn already closed, is demoted to `idle` during selection. Both signals
  are required — a retry storm also reports `idle`, but its transcript still
  owes a response — and the demotion happens in selection rather than on the
  displayed state, so a stuck background record also stops outranking the
  session the user is actually watching.

### Verified

A forced retry storm (local always-500 server via `ANTHROPIC_BASE_URL`) held the
island for 73 consecutive ticks, crossed at 48s, throttled to one update per
minute, and reset cleanly when retries exhausted — through both events that
previously stole the island. That verified the detection that has since been
removed; the selection and liveness behaviour it exercised still stands.

### Outstanding

- **`status: "api_retry"`** appears in the CLI binary. If the session registry
  ever reports it, it replaces the whole inference chain with a direct signal —
  and is the only thing that would justify bringing a "stalled" label back.
  Note the registry already discriminates weakly: a backing-off session reports
  `idle` while a real think reports `busy` (`ClaudeSession.status`), which is a
  cheaper starting point than the transcript was.
- **Stale session files** accumulate: a `SIGKILL`'d session leaves its
  `~/.isle/sessions/<id>.json` behind. Selection hides it by dead pid, but
  nothing prunes disk. A sweep at launch is a few lines.
- `~/.claude/sessions` is undocumented internal surface. Every field is optional
  and a bad record is skipped, so a schema change degrades to "no registry"
  rather than breaking the island — but it can break.

---

## Milestone 1 — The Mode Archetype (Music / Claude / Both)

The organizing decision for everything else. Introduce a single source of truth
for *what Isle is for this user*, persist it, and gate every subsystem behind it.

### Goal
A user can pick **Music**, **Claude Code**, or **Both** — and Isle only runs the
subsystems that mode needs.

### Scope
- New `IsleMode` enum: `.music`, `.claude`, `.both`.
- Persist with `@AppStorage("isle.mode")` (raw `String`), default unset →
  triggers onboarding (Milestone 2).
- New `AppSettings` observable (`ObservableObject`, `@MainActor`) owning `mode`
  and future settings. Inject into `NotchViewModel`.
- Gate lifecycle in `NotchViewModel.start()`:
  - `.music` → start `adapter`, `spotify`, `audio`; **skip** the Claude watcher.
  - `.claude` → start the Claude watcher (Milestone 3); **skip** media/audio
    subsystems entirely (no Automation/Audio permission prompts for
    Claude-only users — a real UX win).
  - `.both` → start everything.
- Gate derived state so a disabled source never renders:
  - `hasMusicActivity` returns false in `.claude` mode.
  - `hasClaudeActivity` returns false in `.music` mode.
- The existing `shouldSplitCollapsed` / needs-approval override logic already
  handles the "both live" case — it just needs `mode == .both` folded in.

### Files
- New `Isle/Core/AppSettings.swift`, `Isle/Core/IsleMode.swift`.
- `Isle/Notch/NotchViewModel.swift` — inject settings, gate `start()` and derived
  `has*Activity` flags.
- `Isle/IsleApp.swift` — construct `AppSettings`, pass down.

### Acceptance
- Launching in `.music` mode fires **no** Claude file-watch and shows no glyph.
- Launching in `.claude` mode triggers **no** Automation/Audio permission prompt.
- Switching mode at runtime (Milestone 6) restarts subsystems without relaunch.

### Decisions to lock
- **Claude-only mode with no notch content when idle:** should the island still
  show a resting glyph, or fully collapse to bare pill until an event? *Default:*
  resting idle glyph so the island is discoverable.

---

## Milestone 2 — First-run Onboarding

The download experience. First launch asks intent, so the app configures itself
instead of dumping the user into a music-only notch.

### Goal
On first launch (no persisted mode), present a one-screen picker: **Music /
Claude Code / Both**, with a one-line description and the permission consequence
of each.

### Scope
- A small `NSWindow`-hosted SwiftUI onboarding view (not the notch — a normal
  centered window, shown once).
- Three large cards. Selecting one writes `AppSettings.mode` and dismisses.
- For **Claude** / **Both**, include an inline "Install Claude Code hook"
  step that runs the `isle-cli` install (Milestone 3's installer) so the bridge
  is live immediately.
- Never shown again once mode is set; re-openable from the menu bar
  ("Setup…") and Settings.

### Files
- New `Isle/Onboarding/OnboardingWindow.swift`, `OnboardingView.swift`.
- `Isle/IsleApp.swift` — show onboarding when `mode` is nil at launch.

### Acceptance
- Fresh install (cleared `UserDefaults`) shows onboarding; second launch does not.
- Choosing Music never prompts for anything Claude-related and vice versa.

### Decisions to lock
- Distribution is sideloaded (per `HANDOFF.md`), so onboarding can freely
  reference the private-API/permission caveats — no App Store review copy needed.

---

## Milestone 3 — Complete the Claude Code Bridge (Phase 2)

Wire the already-built glyph and hook config to a live status file. This is
Phase 2 from `PROJECT_BRIEF.md §3.3`, now un-blocked because the mode archetype
decides whether it runs at all.

### Goal
`NotchViewModel.claudeState` reflects the real Claude Code session, and
`needs_approval` auto-expands the notch.

### Scope
- New `Isle/Claude/ClaudeStatusWatcher.swift`: `DispatchSource` file watch on
  `~/.isle/claude-status.json` (per brief — **not** polling). Parse
  `{ state, project, updated_at }`, map to `ClaudeCodeState`, publish on main.
- Handle the file-missing / stale cases → `.disconnected`.
- Replace the hardcoded `NotchViewModel.claudeState = .disconnected` with the
  watcher's output.
- The interrupt path already exists: `hasLiveActivity` returns true only for
  `.needsApproval` (`NotchViewModel.swift:200`), and `NotchStateResolver` opens
  the panel regardless of hover. Just needs a real value flowing in.
- **`isle-cli` installer:** a menu action + onboarding step that copies
  `integration/claude-code-hooks/isle-cli` onto `PATH` (e.g. `~/.local/bin`) and
  merges the hook block into the user's `~/.claude/settings.json` (merge, don't
  clobber existing hooks).
- Fix the known adapter-orphan issue opportunistically while here
  (`HANDOFF.md` → "Adapter orphans on abnormal termination").

### Files
- New `Isle/Claude/ClaudeStatusWatcher.swift`.
- New `Isle/Claude/HookInstaller.swift`.
- `Isle/Notch/NotchViewModel.swift` — own the watcher, gate by mode.
- `integration/claude-code-hooks/isle-cli` — optionally parse `session_id`
  from hook stdin JSON and write it to the status file (cheap to add now; useful
  later for multi-session and the parked Scheduled Prompts feature).

### Acceptance
- Running `isle-cli set-state needs_approval` in any terminal pops the notch open
  within perceptible-instant latency; `done` shows the checkmark and
  auto-collapses; `working` stays ambient (does not flap the panel).
- Uninstalling the hook returns Isle to `.disconnected` cleanly.

### Decisions to lock
- **`session_id` capture:** whether to extend `isle-cli` to read the hook's
  stdin JSON now. Small change; not required for this milestone, but cheap
  insurance for multi-session and the parked Scheduled Prompts work.
  *Recommended: yes, while we're in the file.*

---

## Milestone 4 — Tabbed "Both" Expanded View

When the user runs Both, the expanded island needs to show two full experiences
without cramming them. Tabs, per the request.

### Goal
In `.both` mode, the hover/expanded panel shows a **Music** tab and a **Claude**
tab; the collapsed split view is unchanged (already built).

### Scope
- Tab strip at the top of `ExpandedNotchView`, shown **only** when
  `mode == .both`. In single-mode, no tabs — the panel is just that one view.
- `@Published var activeTab: IsleTab` on the view model (`.music` / `.claude`),
  persisted as a "last used" default.
- **Auto-switch on interrupt:** when Claude hits `needs_approval` and the panel
  opens as a live activity, force the Claude tab regardless of last-used, then
  restore the user's tab on dismiss.
- New `ClaudeExpandedView`: session/project name, current state, and elapsed
  since last event. (Leave room for a future Scheduled Prompts entry point — see
  "Parked".)
- Tab switches animate within the fixed panel — the window never resizes
  (`NotchRootView` / `NotchWindowController` invariant: content animates, panel
  doesn't).

### Files
- New `Isle/Notch/IsleTab.swift`, `Isle/Notch/ClaudeExpandedView.swift`.
- `Isle/Notch/ExpandedNotchView.swift` — add the tab strip + switch.
- `Isle/Notch/NotchViewModel.swift` — `activeTab`, interrupt override.

### Acceptance
- Music-only and Claude-only modes show **no** tab chrome.
- A `needs_approval` interrupt jumps to the Claude tab and returns you to Music
  after you action/dismiss it.
- Panel geometry is identical across tabs (no resize/tear at the notch edge).

### Decisions to lock
- Tab affordance style: segmented pill vs. two icon buttons. *Default: compact
  segmented pill under the housing band.* (Design pass — see `frontend-design`.)

---

## Milestone 5 — Settings Pane & Mode Switching

Make everything reconfigurable without a relaunch. Fills the empty `Settings`
scene (`IsleApp.swift:20`).

### Goal
A real Settings window: change mode, toggle controls, and manage the hook
install — all live.

### Scope
- SwiftUI Settings window with sections:
  - **Mode** — Music / Claude / Both switcher (re-runs Milestone 1 gating live;
    this is the "settings button to allow the change to happen" from the request).
  - **Media** (visible in Music/Both) — the customizable-controls set from
    `PROJECT_BRIEF.md §3.4`: scrubber/volume/next-prev/shuffle/repeat toggles,
    accent color / auto-from-artwork, `done` auto-collapse timing, waveform
    source (see note), split-vs-cycle behavior.
  - **Claude** (visible in Claude/Both) — hook install/uninstall status;
    accent colour (see note), which is the Claude-only equivalent of the
    Media section's auto-from-artwork.
- All persisted via `AppSettings` / `@AppStorage`.
- Mode change tears down and restarts only the affected subsystems (no relaunch).

### Note: Claude-only mode has no palette, and one dead control — **shipped**

A Claude-only user (`IsleMode.claude`) currently cannot change the colour of
their island, and one of the controls that claims they can does nothing. Two
separate causes, both worth fixing together:

**1. `workingTint` overrides the marker system for exactly these users.**
`isClaudeSolo` is `hasClaudeActivity && !hasMusicActivity`, which in `.claude`
mode is *always* true. So `NotchViewModel.workingTint` returns non-nil for the
whole `working` state, and it sets `forceFixed = true` — which
`DotColors.rgba` honours "regardless of the design's colour mode"
(`DotMatrixView.swift:303`). `CollapsedNotchView.markerColor` short-circuits on
it as well, so the status text follows the same two hexes (`#F2C14E` thinking,
`#E8842B` once a tool runs). A Claude-only user can edit `working` in the Marker
Editor and see no change.

**2. `.palette` means *album artwork*, which they don't have.** `idle`,
`working` and `compacting` all default to `colorMode: .palette`. With no music,
`NotchViewModel.palette` never leaves `ArtworkPalette.fallback` — three greys
(`white 0.45 / 0.30 / 0.60`). So the states that aren't force-tinted are flat
grey.

Net: hardcoded amber when busy, grey when not, and an editor control that lies.
The music user gets a palette that responds to what they're doing; the
Claude-only user gets neither half of it.

**The fix is to supply the missing palette, not to add an override.**

- A **Claude accent** in Settings feeds `ArtworkPalette` when there is no
  artwork to derive one from — so `.palette` markers behave for a Claude-only
  user exactly as they do for a music user, and every existing read of
  `palette.primary`/`accent`/`secondary` keeps working untouched.
- **`workingTint` becomes derived rather than literal.** What those two hexes
  encode is a *relationship* — thinking is the paler, softer form of working —
  and that survives any hue. Derive both ends from the accent (thinking =
  lifted/desaturated, working = full) and the ramp reads correctly in blue or
  green as well as amber. This also removes the `forceFixed` special case, so
  the Marker Editor stops being overridden and starts telling the truth.
- **Semantic states stay fixed.** `done` green, `failed` red, `needsQuestion`
  blue carry information the accent does not, and an accent that repainted them
  would delete the fastest signal in the island. This is the line between
  supplying a neutral palette (yes) and a global colour override (no).

**The control is swatches plus a custom picker, not a bare colour well.**
macOS's own accent setting is a swatch row plus "Other…", and there are two
reasons to match it beyond consistency. First, the accent has to yield *three*
stops — `paletteRamp` walks `primary → accent → secondary` — so a swatch can
ship its ramp pre-derived and correct by construction, where an arbitrary hue
has to derive one and degrades at the extremes (a near-black or fully saturated
pick collapses the three stops into nearly one colour). Second, two regions of
the space are actively wrong: near-black vanishes against the camera housing,
and near-red/near-green impersonates `failed`/`done` — which undoes the whole
point of holding the semantic states fixed. *Recommend a swatch row with
**Match system accent** as the default first chip (`BreathingShapeLayer` already
defaults to `.controlAccentColor`), then tuned accents, then **Custom…** opening
the standard `ColorPicker` with a luminance clamp.* The Marker Editor's existing
free `ColorPicker` stays as-is — that is a per-marker choice made deep in a
customisation UI, where an odd colour is the point.

**Status: built.** `Isle/Core/ClaudeAccent.swift` holds the swatches, the
derivation for custom colours, and a small CIE76 implementation;
`AppSettings.claudeAccent` / `.claudeAccentHex` persist the choice;
`NotchViewModel.palette` is now computed and falls back to the accent instead of
`ArtworkPalette.fallback`; `workingTint` derives from it rather than the two
literals; and the picker sits in `SettingsView.claudeSection`.
`MarkerDesign.Hex` was made non-private so the reserved colours have one source
of truth. Two swatches were added late — see the muted note below.

**The swatches.** Seven, not six or eight — because the state machine has already
claimed most of the wheel. `red` `#FF3B30`, `amber` `#FF9F0A`, `green` `#34C759`,
`blue` `#0A84FF`, `cyan` `#32ADE6` and `gray` `#8E8E93` all carry meaning, plus
the two working tints. What is left is four hue families, and the violet band
takes two entries separated on lightness:

| Swatch | primary | secondary | accent |
|---|---|---|---|
| Lime | `#9DC63F` | `#5F8A24` | `#CDEA6A` |
| Teal | `#25BFA4` | `#127A6B` | `#7FE9C8` |
| Violet | `#9438E0` | `#6321A6` | `#C79BFF` |
| Orchid | `#CE5FD2` | `#8F2F96` | `#F0A6EE` |
| Magenta | `#E44C8E` | `#A62760` | `#FF95B8` |

Chosen against two different bars, because they are two different problems.
**Chip vs. semantic colour** must be unmistakable at 20px in the notch — a
`working` island that reads as `failed` is the failure this whole design exists
to avoid — so every stop above clears every semantic hex by **ΔE > 30** (CIE76;
worst case 32.7, Lime primary vs `green`). **Chip vs. chip** only needs to be
telling-apart-able in a settings row, so that bar is ΔE > 18 (worst case 32.8,
Violet vs Orchid). All three stops also clear the extraction brightness floors
(`primary` ≥ 0.35, `secondary` ≥ 0.28, `accent` ≥ 0.45 on `(r+g+b)/3`).

Two candidates were tried and cut, worth not re-proposing: **Sky** sits at hue
211, which *is* `blue`/`needsQuestion` (ΔE 19.9 from `cyan`), and **Rose** has an
accent at hue 9° — red territory — while sitting 24.9 from Magenta. There is
also no second blue-violet available: clearing `blue` requires hue ≥ 267, which
is already Violet, so the band genuinely holds one entry plus a lighter Orchid,
not three.

For **Custom…**, `ClaudeAccent.derive` takes the picked hue and floors it into a
legible band (saturation ≥ 0.35, value ≥ 0.58 — floors, not clamps, so a
near-black pick doesn't collapse all three stops into one colour), then takes
the deep stop at 0.62× value / 1.12× saturation and the highlight at 1.30×
value / 0.60× saturation, each rotated 6–8° so the ramp moves in hue and not
only in lightness.

The earlier plan here said to *nudge* a colliding custom colour to the nearest
safe one. That was wrong and is not what shipped: silently substituting a
different colour than the one someone picked in an explicit colour well is
surprising, and the picker exists precisely to let them override. Custom is
applied as chosen, and `ClaudeAccent.collision(forCustom:)` measures it so the
caption can say plainly which reserved colour it sits near.

**"Match system" cannot use the system accent directly.** Measured against the
eight macOS accents, five collide with a reserved colour — Blue, Red, Orange,
Yellow and Green — and Blue, which is the macOS default, lands **8.0 ΔE** from
`needsQuestion`. Shipping the raw accent would have given most users a `working`
island that reads as a pending question. `.system` therefore snaps to the
nearest measured swatch (`nearestSwatch(to:)`), which is honest where a near
match exists (Pink→Magenta 7.8, Purple→Orchid 17.8, Graphite→Slate 19.6) and
openly approximate where none does (Blue→Violet 44.7, Orange→Stone 64.3, because
there is no safe blue or orange left). The caption says so.

Keep the artwork extraction path itself untouched — it is settled. This adds a
source for the case where it has nothing to extract from.

---

### Note: waveform source is three-way, not on/off

The procedural waveform already exists and is already good — `EqualizerLayer`
runs each bar as its own sine on its own period (deliberately non-harmonic
multipliers, so the bars don't march in a visible wave), handed to the render
server as keyframe loops that need no per-frame updates. Today it is only ever
reached as a *failure* path: `SystemAudioLevels` starts unconditionally with
media (`NotchViewModel.setMediaRunning`), and the pattern appears when capture
can't run — old OS, Spotify not running, or the user declined the audio-capture
prompt.

So the setting is three-way, not a checkbox:

| Choice | Behaviour |
|---|---|
| **Live** (default) | Taps Spotify's audio. Prompts for audio-capture permission the first time. |
| **Animated** | Never starts the tap — no prompt, no Core Audio at all. Renders the existing procedural pattern whenever something is playing. |
| **Off** | No waveform. The collapsed island gives the space back to artwork/title. |

The value of **Animated** is that it is the only choice that never triggers the
permission prompt, which matters for the same reason `IsleMode` gates the media
subsystems: a user who doesn't want to grant audio capture should be able to
decline it once and keep a waveform that looks alive.

Implementation is small — gate the `audio.start()` call in `setMediaRunning` on
the preference, and pass the choice down to `LiveEqualizer` so **Off** renders
nothing. `EqualizerLayerView` already has `Mode { live, procedural, resting }`;
this adds a way to pin it to `procedural` rather than only falling into it.

### Files
- New `Isle/Settings/SettingsView.swift` (+ per-section subviews).
- `Isle/IsleApp.swift` — populate the `Settings` scene; add "Settings…" and
  "Setup…" menu items.
- `Isle/Notch/NotchViewModel.swift` — observe settings for live control toggles;
  gate `audio.start()` in `setMediaRunning` on the waveform source.
- `Isle/Components/EqualizerView.swift` — carry the waveform source into
  `LiveEqualizer` so **Animated** pins the procedural mode and **Off** renders
  nothing.

### Acceptance
- Switching Music → Both at runtime starts the Claude watcher and reveals tabs
  without relaunch.
- Toggling a media control hides/shows it in the expanded row immediately.
- **Animated** never starts the tap — verified by the audio-capture prompt not
  appearing on a clean install that picks it before first playback.
- In Claude-only mode, changing the Claude accent recolours the idle and working
  island live, and editing `working` in the Marker Editor now takes effect —
  today it is silently overridden.

---

## Milestone 6 — Launch Polish & Marketing

Ship-ready framing for the "Dynamic Island + Claude Code" story.

### Scope
- Rewrite `README.md` lead to the three-mode positioning (currently reads
  "built for Spotify" — that's now one of three modes).
- Hero capture per mode: music island and Claude live-activity.
- Brand guardrails: keep the glyph an original "inspired-by" mark, not
  Anthropic's proprietary path (`PROJECT_BRIEF.md §3.1`; `HANDOFF.md` →
  `SparkShape` placeholder). Review Anthropic brand guidelines before any public
  release.
- Onboarding copy, permission-prompt explainers, first-run hook install.

### Acceptance
- README leads with the island + Claude story and documents all three modes.
- A new user can go from download → mode pick → live island in under a minute.

---

## Milestone 7 — Act from the Notch: approvals *and* questions

Turn the Claude island from a *notifier* into a *control surface*. Today a
permission prompt or an `AskUserQuestion` opens the notch, and you still
alt-tab to the terminal to answer it. This milestone lets you **approve or
deny a tool call** and **pick an answer to a question** in the notch, with the
click actually deciding the call in the session — and a fallback that always
lands on Claude's own terminal prompt when the notch doesn't answer.

This is a second attempt, and the first one is worth understanding before
judging the idea by its outcome.

### What happened the first time

Approve/Deny shipped in `04d44aa` on a blocking `PermissionRequest` hook and
was removed in `9a0b93e` ("approvals are unified into questions … the
Approve/Deny UI and its plumbing are gone"). The removed script printed

```json
{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":"allow"}}
```

but `decision` is an **object**, not a string: the real schema is
`"decision": {"behavior": "allow"}`. So a notch click could never have resolved
a prompt — every one fell through to the 30s timeout and the terminal, which
reads exactly like "the button doesn't work". The mechanism was sound; the
payload was wrong.

### What was verified before this draft (2026-09-03, Claude Code 2.1.259)

Interactive sessions driven with `expect` against throwaway hooks in a scratch
directory, so nothing here is read off the docs alone. Findings, in the order
they matter:

| # | Finding | Consequence for the design |
|---|---|---|
| 1 | `PermissionRequest` → `{"decision":{"behavior":"allow"}}` resolved the prompt: the transcript shows *Allowed by PermissionRequest hook* and the tool ran. | The approval channel exists and works. |
| 2 | **The terminal permission dialog is shown *while* the hook runs.** In a hook that slept 6s before allowing, the dialog was up from the start and the hook then dismissed it. | A blocked approval hook costs the user nothing: they can answer in the notch *or* the terminal, whichever they're looking at. The block can be long. |
| 3 | A hook that reaches its `timeout`, or exits with no output, leaves the dialog in place; Enter approved it normally. | Falling through is safe. Never auto-allow. |
| 4 | **A terminal answer does not stop the hook.** A 60s heartbeat hook ran to completion after the dialog was answered; its late output was ignored. | Isle must notice a request that resolved elsewhere and retire its buttons. The hook can't tell on its own. |
| 5 | `PreToolUse` on `AskUserQuestion` returning `permissionDecision: "allow"` + `updatedInput` with an `answers` map answered the question **in an interactive session**: no terminal UI, transcript shows *User answered Claude's questions: … Apples*, the model continued with that label. | Questions are answerable from a hook. The old spec's "questions need terminal injection, out of scope" is no longer true. |
| 6 | Unlike permissions, **the terminal question UI is held back until the hook returns or times out** (only the spinner shows). At timeout it appeared and was answerable. | A question hook must block briefly, and the notch needs an explicit *Answer in terminal* release. |
| 7 | A hook cancelled at `timeout` gets `SIGTERM` (a `trap … TERM` fired). | Cleanup on `TERM`/`EXIT` is reliable. |
| 8 | `-p` mode has no `AskUserQuestion` tool, and auto-allowed commands (`echo`) never fire `PermissionRequest`. | Don't test with either. |
| 9 | `permission_suggestions` for a `touch` carried `addDirectories` + `setMode: acceptEdits` — the dialog's "Yes, and always allow…" option, echoable as `updatedPermissions`. | "Always allow" is available later without new plumbing. |

**Not verified:** free-text answers via `answers` (the dialog's *Type
something* row), the exact multi-select join (docs say comma-joined), what Esc
in the terminal does to a blocked hook, and the *Chat about this* row.

### Goal

- A permission prompt shows the **exact tool and command/target** with
  **Approve** / **Deny** in the expanded Claude panel; a click resolves it.
- An `AskUserQuestion` shows the **question and its options**; a click on an
  option answers it, and Claude continues with that label.
- Both carry an **Answer in terminal** escape, and both fall back to the
  terminal on timeout or when Isle isn't running. Nothing is ever auto-allowed.

### How it works — the handshake

Three files, all under `~/.isle`, all written by rename (Isle watches
directories, and an in-place rewrite fires no event — the rule from the
status bridge applies unchanged):

| Path | Written by | Meaning |
|---|---|---|
| `run/answering` | Isle | Contains Isle's pid. Present only while the Settings toggle is on and Isle is running; removed on quit or when the toggle is turned off. The hook checks `kill -0 <pid>`, so a crash leaves a stale file that gates *off*, never on. |
| `requests/<request-id>.json` | `isle-cli` | The hook's **raw stdin**, verbatim. Created when the hook starts blocking, removed by the hook's `EXIT`/`TERM` trap. Its existence *is* "a hook is waiting". |
| `requests/<request-id>.response.json` | Isle | The **complete stdout payload** for the hook, which `cat`s it and exits. Isle has `JSONSerialization`; the script stays jq-free and never builds JSON. |

The session status file gets `request_id` back (the field still exists in
`ClaudeStatus`), plus `request_kind` (`approval` | `question`).

**Approval** — `PermissionRequest` → `isle-cli ask`:

1. Read stdin. If `run/answering` is absent or its pid is dead, behave exactly
   as today: write `needs_question`, exit 0, no block.
2. `REQUEST_ID="$SESSION_ID-$(date +%s)-$$"`. Write stdin to
   `requests/$REQUEST_ID.json`; write status `needs_approval` with the id.
3. Poll every 0.2s until one of:
   - the response file exists → `cat` it to stdout, exit 0;
   - the session status file's `request_id` is no longer ours — some other
     verb wrote (`PostToolUse`, `Stop`, the next `PreToolUse`), which is how
     "answered in the terminal" shows up (finding 4) → exit 0 silently;
   - the deadline (300s) passes → rewrite status without the id, exit 0
     silently. Claude's dialog is still up (finding 3).
4. The trap removes the request file on every exit path.

**Question** — `PreToolUse` with `"matcher": "AskUserQuestion"` →
`isle-cli ask-question`: the same loop with state `needs_question` and a
**45s** deadline, because the terminal shows nothing but a spinner until the
hook returns (finding 6). Two consequences:

- The generic `PreToolUse` → `set-state working` fires **in parallel** with
  this one, and its existing `AskUserQuestion → needs_question` conversion
  would clobber the request id. `set-state` must skip a `PreToolUse` for
  `AskUserQuestion` and leave that write to `ask-question`.
- `Notification` fires the `permission_prompt` nudge ~6s into a prompt; the
  `notify` guard that keeps an active `needs_question` must also keep an
  active `needs_approval` that carries a request id.

**Response payloads** Isle writes, exactly:

```json
// Approve
{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}
// Deny — no `interrupt`, so Claude can try another way, as after a terminal "No"
{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Denied from the Isle notch"}}}
// Answer — `questions` echoed verbatim from the request; multi-select joins labels with ", "
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","updatedInput":{"questions":[…],"answers":{"Which framework?":"React"}}}}
// Answer in terminal — the hook prints nothing and Claude shows its own UI
{}
```

### Isle side

- **`ClaudeRequestWatcher`** (`Isle/Claude/`) — a directory watch on
  `~/.isle/requests`, same shape as `ClaudeStatusWatcher`, decoding each
  `<id>.json` into a `ClaudeRequest`: `kind`, `id`, `sessionId`, `toolName`,
  the **full** `tool_input` (this is where the exact command comes from —
  the status file's 48-char hygienic `target` is for the collapsed island,
  not for a decision), and for a question the `questions` array as-is.
- **`NotchViewModel.pendingRequest`** — the request whose id matches the
  selected session's `request_id` *and* whose file still exists. Either half
  going away retires the buttons: the file, when the hook exits (timeout,
  terminal answer noticed, Isle's own response); the id, when any other verb
  writes. `decide(allow:)`, `answer(_:)` and `deferToTerminal()` write the
  response file (temp name not ending in `.json`, then rename, as the status
  writes do) and set an in-flight flag so a double-click can't write twice.
  `questionRevertSeconds` must not fire while a request file exists.
- **`ClaudeExpandedView`** —
  - *Approval:* headline "Needs your approval"; detail is the tool plus the
    exact command/target, monospaced, two lines, middle-truncated; the info
    row becomes **Approve** / **Deny** / **Terminal**. Real `Button`s so a tap
    is consumed and doesn't fall through to the card's dismiss gesture (the
    removed build had this right — lift it from `04d44aa`).
  - *Question:* the `header` as a chip where the project chip sits, the
    question as the detail line, then the options as rows (label, with the
    description in the secondary weight). One question at a time with
    "1 of 3" and Next; `multiSelect` rows toggle and a Done button commits.
    **Answer in terminal** always present.
  - Collapsed word: `Approve` for a live approval (it was folded into
    `Question` when the buttons went; unfold it), `Question` otherwise.
- **`AppSettings` / `SettingsView`** — one toggle in the Claude section,
  *Answer questions and approvals from the notch*, default on; it owns the
  `run/answering` marker. The two deadlines are constants, not settings.
- **`HookInstaller`** — bump to **v9**. `hookEvents` grows an optional
  `matcher` and `timeout` per entry: `PreToolUse` gets a second entry
  `{"matcher": "AskUserQuestion", "timeout": 60}` → `ask-question`, and the
  `PermissionRequest` entry sets `"timeout": 330` so Claude Code's cancel
  lands *after* the script's own 300s deadline, never before it. `refersToIsleCLI`
  matches on the command prefix, so uninstall and re-merge already handle two
  entries on one event. `integration/claude-code-hooks/` stays byte-for-byte
  in sync as before.
- **`IsleApp`** — remove the marker in `applicationWillTerminate`, and on
  launch remove a stale one before deciding whether to write a fresh one.

### Panel height

`NotchMetrics.expandedSize` is 520×146 and the same for every face. Approve /
Deny fit: the buttons replace the info row, as in the removed build. A
question with four options and descriptions does not. Two ways out, one to
lock below: grow the panel while a question is live (only then; every other
face keeps 146), or render label-only rows and lose the descriptions.

### Acceptance

- A permission prompt shows Approve / Deny in the notch. Approve runs the
  tool; Deny blocks it and Claude sees *Denied from the Isle notch*. The
  transcript shows *Allowed/Denied by PermissionRequest hook*.
- An `AskUserQuestion` shows its options; clicking one continues Claude with
  that label and no terminal UI appears. Multi-select and multi-question both
  work; the transcript shows *User answered Claude's questions*.
- Answering in the terminal instead retires the notch buttons within a
  status write (no stale Approve after the fact).
- Quitting Isle mid-prompt, the toggle being off, a crash, or a timeout
  never wedges the session — the terminal prompt is there every time.
- Two concurrent sessions each get their own request; a click on one can
  never resolve the other (ids are session-scoped and the hook validates
  by filename).
- With the toggle off, behaviour is identical to today, and `isle-cli ask`
  returns immediately.

### Boundaries & decisions to lock

- **No free text from the notch.** `NotchWindow` is a non-activating panel
  with `canBecomeKey` false; a text field would have to take key focus,
  which is the one thing the overlay must never do to the terminal. *Type
  something* and *Chat about this* stay "Answer in terminal".
- **"Always allow" is deferred.** The suggestions are in the request file
  (finding 9), so a third button that echoes one as `updatedPermissions` is
  a later, additive change.
- **Deadlines** — approvals 300s (the dialog is concurrent, a long block is
  free), questions 45s (the terminal is blank meanwhile). *Confirm both.*
- **Panel growth for questions** — *recommend growing, capped around 230pt,
  only while a question is live*; the descriptions are usually the whole
  reason the option exists.
- **Toggle default** — *recommend on*: the hook path is gated on the marker,
  so nothing changes for anyone until Isle is running with it on.
- **Permission posture** — a notch click authorises a tool. Always show the
  exact command; deny is the only thing a timeout can mean.

## Milestone 8 — Multi-Display  ✅

The spec scoped v1 to the built-in display ("non-goal: multi-display sync"), and
`NotchMetrics.preferredScreen()` held that line: the first screen with a camera
housing, else `NSScreen.main`. On a desk with an external monitor that is often
the wrong screen — the island sits on the laptop panel while the user works on
the display in front of them.

### What shipped
A binary, not a display picker: **Built-in display** (the default, unchanged
behaviour) or **All displays** — one island on every attached screen, all
showing the same thing. Settings → Notch → "Show island on".

A picker over named displays was considered and dropped. It needs a stable
display identity across reconnects (`CGDirectDisplayID` is reassigned on
hotplug, so the durable key is the vendor/model/serial triple), and the answer
almost everyone would give it is "all of them" anyway.

### How it's built
- `DisplayScope` (`Isle/Core/DisplayScope.swift`) — the two-case enum, persisted
  by `AppSettings.displayScope` under `isle.displayScope`.
- `IslandPresentation` (`Isle/Notch/IslandPresentation.swift`) — the per-screen
  half of the notch's state: `isHovering`, the collapse lock, and `metrics`.
  One instance per island.
- `NotchViewModel` stays a **singleton**. Every island shows the same track,
  Claude status and power toast, so the audio tap, the MediaRemote adapter and
  the Claude watcher are not duplicated per display. `alertDismissed` and
  `alertWasHovered` deliberately stayed on it too — they describe the alert, not
  the window, so waving an approval off on one screen dismisses it everywhere.
- `NotchWindowController` owns a `[CGDirectDisplayID: Island]` and reconciles it
  in `syncIslands()`. The display ID is a within-session key only (reuse a
  panel rather than rebuild it, so the marquee and equalizer phases survive a
  re-place); nothing persists it.
- `metrics` became `@Published`. It was a plain `var`, so a display change
  reframed the window but never invalidated the content — nothing here worked
  until that was fixed.
- One global pointer monitor still, routed to the island whose screen contains
  `NSEvent.mouseLocation`; every other island is told to collapse.

### Rules that matter
- **A sync is never applied while an island is open.** The hover geometry
  assumes a target that stays put, so a hotplug mid-reach is deferred
  (`syncDeferred`) and applied on collapse.
- **Mirrored secondaries are skipped** (`CGDisplayMirrorsDisplay`), or two
  panels land on the same pixels with two independent hover states.
- **`.builtIn` falls back to main**, so a clamshelled MacBook or a Mac mini
  still gets an island rather than none.

### Still to verify on real hardware
- Two displays, hover each island in turn; the other must collapse.
- Hotplug while hovering — the deferred sync must land on collapse, not during.
- A Claude alert opens every island at once and one haptic fires, not N (the
  0.35s throttle in `playTransitionHaptic` covers this).
- The idle collapsed pill on a non-notched display is a visible 180×32 black
  rectangle over the middle of a real menu bar. Clicks either side of it pass
  through, but whether it should shrink to a sliver when idle is an open design
  call.

### Boundaries
Still one `NotchViewModel`. "The island follows focus" remains rejected — it
moves the island while you are reaching for it.

---

## Milestone 9 — Power & Charging Activities

*Plugged in. 42%.* A third thing worth reporting, alongside music and Claude:
the Mac's own power state, and the batteries of the devices attached to it.
Nothing exists today — there is no `IOPowerSources` use anywhere in `Isle/`.

### Goal
Connecting a charger, crossing a low-battery threshold, or connecting a device
with a reportable battery briefly claims the collapsed island, then hands it
back to whatever was there.

### The data — what actually works

Checked on macOS 26.5.1 rather than assumed, because the obvious route is a dead
end:

| Source | API | Verdict |
|---|---|---|
| Mac's internal battery | `IOPSCopyPowerSourcesInfo` / `IOPSGetPowerSourceDescription`, with `IOPSNotificationCreateRunLoopSource` for change callbacks | **Works.** Public IOKit, no permission prompt, event-driven. Gives current/max capacity, charging flag, AC vs battery, and time-to-empty/full. |
| Bluetooth devices via IORegistry | `BatteryPercent` / `BatteryPercentLeft`/`Right`/`Case` under `AppleDeviceManagementHIDEventService` | **Dead end here.** `ioreg -r -k BatteryPercent` returns nothing, and a full `ioreg -l` has no battery keys at all — including with an AirPods-class device connected and reporting. |
| Bluetooth devices via System Profiler | `system_profiler SPBluetoothDataType` | **Works**, and is the route that does. Reports `Case Battery Level` / `Left Battery Level` / `Right Battery Level` for connected devices. Measured at ~0.1s, so it is affordable *on a connect/disconnect event*, not on a timer. |

So: IOKit for the Mac, a subprocess for the peripherals, and the peripheral path
is event-driven only. Confirm the `SPBluetoothDataType` key names against the
target macOS before building — this is parsed text, not an API.

### Scope
- New `Isle/Power/PowerMonitor.swift` — an `ObservableObject` publishing the
  Mac's power state, driven by the IOPS run-loop source (no polling).
- Peripheral batteries refreshed on Bluetooth connect/disconnect, cached between
  events.
- Events worth surfacing: charger connected / disconnected (with the level),
  fully charged, low-battery thresholds, device connected with a level, device
  low.
- Presentation: a **momentary toast** in the collapsed island that reverts, not
  a third permanent seat. The collapsed split rule is built for two sources
  (`splitMusicFraction`, `collapsedClaudeExtra`) and a power event is transient
  by nature — it does not want a standing seat the way music and Claude do.
- Gated by a settings toggle, on by default.

### Acceptance
- Plugging in shows a charging toast with the real percentage, then returns the
  island to music/Claude.
- Connecting a device with a reportable battery shows its level; a device whose
  battery is not reported shows **nothing** — no placeholder, no "unknown".
- A power toast never pops the panel open, and never displaces a Claude alert.

### Decisions to lock
- **Ambient behaviour, not a fourth `IsleMode`.** Power is event-driven, not
  something you would run the island *as*, and adding a case to `IsleMode`
  reshapes every `showsMusic` / `showsClaude` gate. *Recommend a toggle.*
- **Does critical battery interrupt?** Everything else here is ambient, but a
  Mac about to sleep is arguably the one power event that earns
  `liveActivityExpanded`. *Recommend no — macOS already has its own low-battery
  alert, and Isle duplicating it is noise.*
- **Collision with a Claude alert** — attention outranks ambient; the toast is
  dropped, not queued.
- **Toast duration**, and whether repeat events within a window coalesce.

### What shipped

Built as specced, with three departures worth recording:

- **`system_profiler -json`, not the text output.** The roadmap warned this was
  "parsed text, not an API" and said to confirm the key names. The `-json` form
  sidesteps the warning entirely: `device_batteryLevelLeft` /
  `device_batteryLevelRight` / `device_batteryLevelMain` and `device_minorType`
  are stable identifiers, where the text output's "Left Battery Level:" labels
  are display strings that have moved between releases. Also faster (~0.08s).
- **IOBluetooth fires connect notifications for devices that are *already*
  connected**, synchronously, at registration. Useful as initial state, but as
  an event it means a toast for your headphones on every launch — hence
  `BluetoothBatteryMonitor.launchGrace`.
- **Peripherals are read on a charger plug-in too**, not only on connect. A
  device's level can't be watched, only fetched, and sitting down to plug the
  Mac in is the moment a flat pair of headphones is worth mentioning. Only the
  lowest device at or below 20% is reported, so this can't turn into a roundup.

Decisions locked: toast duration is a constant 4s, not a setting (`doneToastSeconds`
is tunable because a slow reader wants the checkmark to linger; this is the same
reading task at the same size). Repeats coalesce by kind — a jiggling MagSafe
connector leaves one current message, not six stale ones. Two settings toggles,
not one: the Bluetooth half is separable because it is the half that costs a
subprocess. Critical battery does not interrupt, as recommended.

Two things the island deliberately won't say. Plugging in at 100% reads *Fully
charged*, never "Charging · 100%" — that would be a claim about something that
isn't going to happen. And power monitoring stops with the display, so plugging
in with the lid shut produces no toast on wake rather than a stale one.

### Says-nothing-it-can't-back-up
Report only what the APIs actually return. Time-to-full is a value IOKit
provides — and provides as "still calculating" for the first minutes after a
plug-in — so show it when it is real and omit it when it isn't, rather than
estimating one. Same rule as the Claude island's silence: no inferred state.

---

## Suggested sequencing

```
M1 Mode archetype ─┬─> M2 Onboarding
                   ├─> M3 Claude bridge ─┬─> M4 Tabbed "Both" ─┐
                   │                     └─> M7 Act from notch ─┤
                   └───────────────────────> M5 Settings ──────┴─> M6 Launch
                                              │                     │
                                              ├─> M8 Display picker │
                                              └─> M9 Power/charging │
                                     M7 unblocks ──> Scheduled Prompts (Parked)
```

- **M1 is the gate** — everything reads from `AppSettings.mode`.
- **M5 (Settings) can start after M1** and grow a section per milestone as
  features land.
- **M7 (Act from notch) needs M3's bridge** (it extends `isle-cli` and the
  status watcher) and delivers the "talk back into a session" primitive that
  Scheduled Prompts is parked on.
- **M8 and M9 sit off the Claude track entirely.** Each is an engine plus a
  Settings section, so both want M5 to exist first — but neither blocks anything
  downstream, and neither gates a release.
- A credible public build = **M1 + M2 + M3 + M4** (the full three-mode island),
  with **M5**, **M7**, and **M6** finishing it for release.

---

## Cross-cutting: decisions to confirm before building

1. **Claude-only idle appearance** (M1) — resting glyph vs. bare pill.
   *Recommend resting glyph.*
2. **`session_id` capture in `isle-cli`** (M3) — add now or later.
   *Recommend now, while in the file.*
3. **Tab affordance** (M4) — segmented pill vs. icon buttons.
   *Recommend segmented pill.*

---

## Parked — pending research

### Scheduled Prompts

*Rest now; Claude works the moment your usage window reopens.* Queue a prompt to
fire at a chosen time — or when a usage limit resets — so reset time isn't wasted
while you're away. **Deferred: needs more research before it's specced for
build.** Notes captured so far:

- **Delivery is the open question.** Claude Code has no inbound "receive prompt"
  API, so Isle would have to drive the CLI. Rough options:
  - *Headless spawn* — `claude -p "<text>"` in the project dir. Simple, but a
    fresh session with no prior conversation context.
  - *Resume session* — `claude --resume <session_id> -p "<text>"` (uses the
    `session_id` the M3 bridge can capture). Continues the real conversation, but
    needs a still-valid session id.
  - *Terminal injection* — AppleScript / `tmux send-keys` into a live session.
    Fragile and terminal-specific.
- **Limit-reset detection** — likely manual time first ("fire at 3am"), with
  auto-detect (parse the rate-limit message → reset timestamp) as a follow-up.
- **Unattended safety** — a scheduled run executes without a human present, so it
  needs an explicit, conservative permission posture (default read-only tools;
  never silently skip permissions).
- **Wake/sleep** — a closed-lid MacBook won't run timers; would need a `launchd`
  agent or a "keep awake" caveat.

- **Talk-back primitive** — the hard part (getting the notch to inject something
  into a running session) is prototyped by **Milestone 7 — Act from the Notch**,
  which builds a blocking-hook + decision-file handshake for approvals. Scheduled
  Prompts is the same shape one layer up: instead of writing a decision, write a
  *prompt* the session picks up. Wait for M7 to land, then reassess whether the
  decision-file channel generalizes or a resume-session spawn is cleaner.

Revisit and promote to a numbered milestone once the delivery mechanism is
chosen.
