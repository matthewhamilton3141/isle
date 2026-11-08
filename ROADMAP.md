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
| Calendar events and reminders (Agenda face + ambient toasts) | Shipped; Join, week, timeline, ticks and quick add built (M12) | `Isle/Agenda/` |
| Claude status glyph (breathing + checkmark) | Built, wired (M3) | `Isle/Claude/` |
| Claude hook bridge (`isle-cli` + `settings.json`) | Watched (M3); per-session files, v7 | `Isle/Claude/ClaudeStatusWatcher.swift` |
| Claude session registry (hook-free liveness) | Shipped | `Isle/Claude/ClaudeSessionRegistry.swift` |
| Stall / no-response detection | Shipped, one path unverified | `Isle/Notch/NotchViewModel.swift` |
| Claude hook installer | Done (M3) — menu-bar action, Settings wiring pending | `Isle/Claude/HookInstaller.swift` |
| `NotchViewModel.claudeState` | Live from watcher, mode-gated (M3) | `Isle/Notch/NotchViewModel.swift` |
| Settings pane | Shipped — mode, notch, media, Claude, updates. The SwiftUI `Settings` scene is still empty; the real window is built in `openSettings` | `Isle/Settings/SettingsView.swift` |
| Mode selection (Music / Claude / Both) | Model + gating done (M1); picker shipped in Settings and the menu bar | `Isle/Core/`, `Isle/Settings/SettingsView.swift` |
| Claude accent colour | Shipped | `Isle/Core/ClaudeAccent.swift` |
| Jump to the session, reply from the notch | Built (M11), awaiting in-app test | `Isle/Claude/ClaudeSessionHost.swift`, `TerminalBridge.swift` |
| Every session at once (list, pin, home count) | Built (M16), awaiting in-app test | `Isle/Claude/ClaudeSessionList.swift`, `ClaudeExpandedView.swift` |
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

### Review fixes (`feature/claude-done-and-watch-fixes`, 2026-11-05)

| Was | Now |
|---|---|
| Every watch (`~/.isle/requests`, `~/.isle/sessions`, `~/.claude/sessions`) held its directory's vnode. Delete and recreate the directory (a reinstall, `rm -rf ~/.isle`) and the watch stayed on the dead one: no request, status or session reached the island until a stop/start. The registry also never watched at all if Claude Code created `~/.claude/sessions` after Isle started. | `DirectoryWatch` follows the path. On `.delete`/`.rename`/`.revoke` it re-arms on whatever is at the path; while the directory is missing it watches the nearest ancestor that exists and walks back down as each level reappears. It re-checks once the watch has registered (by inode), because a directory unlinked between `open` and registration never reports its own deletion — that race is real, mid-`rm -rf`. No timers. |
| An orphaned `*.response.json` under 5s old was skipped and only swept on the next directory event, which might never come. | The sweep sets one re-sweep for when the youngest orphan comes of age. |
| While Claude was active, every status event decoded every session file, re-scanned the registry and parsed transcript tails with `split` on the main thread, twice (selection, then keep-awake). | `ClaudeStatusWatcher` scans on its own queue and publishes only if still the newest (generation counter). Every re-selection path — status, request, registry, tick — asks for one background read of the registry and the tails `reconciled` needs; selection runs on main against that, and a superseded read is dropped. An event's apply survives a tick that overtakes it. Request changes reach the buttons through the same read, so a click's `working` and its request leaving land in write order. Reply confirmation reads off main too. |
| The transcript path replaced only `/` in the cwd. Claude Code replaces every non-alphanumeric character (`/private/…/my_dir.v2 sp` → `…-my-dir-v2-sp`), so a session under a path with a dot, underscore or space had no transcript for Isle: no interrupt reconciliation, and reply confirmation always failed. | `transcriptURL` uses Claude Code's rule (per UTF-16 unit), and finds a very long path's hashed folder by prefix. |
| The 64 KB tail window could start inside a multi-byte character, and then the whole window failed to decode as one string. | Lines are split on bytes; the partial first line is dropped. |

Verified: a watcher test against a scratch tree (13 checks: write, directory
deleted, recreated, all of `~/.isle` deleted and recreated, renamed away,
requests recreated, young orphan kept then swept with no further event,
registry created late and recreated, stop drops in-flight scans, restart
rescans), three runs clean. The pre-fix watcher fails the recreate check.
Transcript tails read correctly for a real session under `my_dir.v2 sp`
(~1 ms per read, now off main).

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

> **Status (2026-11-04): built on `feature/act-from-notch`, awaiting an
> in-app test.** The hook side and the app's own request/response code were
> run end to end against Claude Code 2.1.318 (see "What shipped" at the end of
> this section); the notch UI has been built and read, not yet seen or
> clicked. The test plan for the running app is in that section too.

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

Re-verified and extended while building (2026-11-04, Claude Code 2.1.318,
same `expect` method, hooks pointed at a scratch `HOME` with
`--setting-sources project` so the real settings never loaded):

| # | Finding | Consequence for the design |
|---|---|---|
| 10 | **When `ask-question` returns without an answer, Claude Code raises a `PermissionRequest` for `AskUserQuestion`** — that *is* the terminal question UI coming up, and like finding 2 the UI is on screen while that hook runs. A `PermissionRequest` reply of `{"decision":{"behavior":"allow","updatedInput":{"questions":[…],"answers":{…}}}}` answered it (*User answered Claude's questions … Allowed by PermissionRequest hook*). | `ask` must never offer it as an approval (Approve would be the wrong button) — it returns at once for `AskUserQuestion`. And a later change could answer questions on this channel instead, with no blank-terminal wait at all (see "What shipped"). |
| 11 | **Esc on the permission dialog SIGTERMs the blocked hook** (its request vanished at the keypress) and writes no status; the turn ends *Interrupted · What should Claude do instead?* and the transcript gets the usual `[Request interrupted by user for tool use]`. | The buttons retire on their own (the request file goes), but the status still says `needs_approval`, which has no revert timer — Isle retires it from the transcript's interrupt marker, as it already does for an interrupted `working`. |
| 12 | Answering the dialog **Yes** in the terminal while the hook waits: the hook was gone within the same second (the `PostToolUse` write supersedes its id). | Finding 4 holds, and the "another verb wrote" check is what notices it. |
| 13 | A hook reply of `{}` is no decision: the question UI came up the moment the hook returned; an approval dialog stays up. | "Answer in terminal" is exactly `{}`. |
| 14 | Multi-question and multi-select answered from the hook: *Which fruit? → Apples · Which toppings? → Cream, Honey*; the model echoed `Cream, Honey`. | The `", "` join is right. |
| 15 | With **auto mode** on (it was on by default in these nested sessions), the classifier approved `touch` and `python3 -c …` itself and no `PermissionRequest` fired; tests had to pass `--permission-mode default`. `AskUserQuestion` still reached the user in auto mode. | Approvals in the notch only matter in modes that ask; questions matter in every mode. |

**Not verified:** the *Chat about this* row. (The multi-select join and
Esc are now findings 14 and 11; free-text `answers` — the *Type something*
row — were verified under Milestone 11, finding R6.)

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
// Approve a plan (ExitPlanMode) — the input handed back, verbatim (finding 18)
{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow","updatedInput":{"plan":"…","planFilePath":"…"}}}}
// Always… → Confirm — `permission_suggestions` echoed verbatim (finding 16)
{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow","updatedPermissions":[…]}}}
// Deny — no `interrupt`, so Claude can try another way, as after a terminal "No"
// ("The user rejected this plan from the Isle notch." for ExitPlanMode)
{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"The user denied this tool call from the Isle notch."}}}
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
  tool; Deny blocks it and Claude sees *The user denied this tool call from
  the Isle notch.* (originally *Denied from the Isle notch*). The
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
  **Superseded by Milestone 11:** the panel now becomes key on demand,
  without activating Isle, only while a field is composing; *Type
  something* and "No, and tell Claude…" are answered in the notch.
- **"Always allow"** — was deferred here; shipped as **Always…** (see
  "Approval options" below).
- **Deadlines** — approvals 300s (the dialog is concurrent, a long block is
  free), questions 45s (the terminal is blank meanwhile). **Locked as
  recommended.**
- **Panel growth for questions** — **grows, capped at 230pt, only while a
  question is on the Claude face**; the descriptions are usually the whole
  reason the option exists.
- **Toggle default** — **on**: the hook path is gated on the marker, so
  nothing changes for anyone until Isle is running with it on.
- **Permission posture** — a notch click authorises a tool. Always show the
  exact command; a timeout is never an allow — it falls through to the
  terminal prompt, which still asks.

### What shipped (`feature/act-from-notch`)

**Hook side** (`isle-cli`, kept byte-for-byte in `HookInstaller.scriptBody`,
installer v9):

- `ask` / `ask-question` as specified above, with three refinements the
  probes called for: `ask` returns at once for a `PermissionRequest` on
  `AskUserQuestion` (finding 10); the wait also ends the moment `run/answering`
  goes (Isle quit or the toggle turned off — the marker and its pid are
  re-checked every tick, builtins only); and after a notch decision the hook
  writes `working` itself before printing, so the island moves on at once
  instead of waiting for the next hook (a deny fires no `PostToolUse`).
- The status file carries `request_id` and `request_kind`. The request id
  ends in the hook's pid, which Isle uses to drop (and delete) a request whose
  hook was SIGKILLed and never ran its trap.
- `hookEvents` entries carry an optional `matcher` and `timeout`; the merge
  filters Isle's old entries once per event before appending, since
  PreToolUse now has two.

**Isle side** — as specified, plus:

- `ClaudeRequestWatcher` also writes the responses (temp file not ending in
  `.json`, then `rename(2)`), so the payload shapes live in one place, and
  sweeps a response nobody read after 5s (a hook that gave up just before the
  click).
- `pendingRequest` additionally requires the request's kind to match the
  status (`approval` ↔ `needs_approval`, `question` ↔ `needs_question`) and its
  session to be the selected one.
- Esc on a prompt (finding 11): the attention states join the 5s reselect
  timer, and `reconciledPrompt` retires one whose transcript ends on the
  interrupt marker — never while its request is live.
- The question face drops the 24pt headline (it can't fit with four options
  under the cap) and leads with the header chip and "1 of 3"; single-select
  rows answer and advance on tap, multi-select rows toggle with Next/Done,
  and a chevron steps back. The tallest question sizes the panel so it
  doesn't bob between steps. "Answer in terminal" and "Terminal" also
  retract the panel (when the dismiss setting allows).
- Every option is always on screen. Claude Code 2.1.318's schema caps an
  `AskUserQuestion` at 1–4 questions of 2–4 options each (a hard zod
  `min(2).max(4)`, multi-select included; its own *Other* row is added by
  the terminal and is "Answer in terminal" here). On the question face the
  glyph shrinks into its top-left corner and the options take the face's
  full width; when the cap can't hold the descriptions as the setting draws
  them, the longest lose lines first, then all move beside their labels,
  then go, and only then does the question give up its second line. Four
  options fit side by side under a two-line question below a 32pt housing
  (3pt to spare), and label-only rows fit five, so nothing scrolls within
  the schema (a scroll, with an "N options" count beside the action, is
  kept only for a future schema that allows more).
- Two approvals pending at once *in one session* (parallel tool calls)
  can't both be answered: the second's status write supersedes the first's
  id, which falls through to the terminal. Safe, just not notch-answerable.

**Verified here** (scratch `HOME`, never the real settings; nested sessions
with `--setting-sources project --settings <scratch>`):

- 14 scripted `isle-cli` checks with a stand-in Isle: no marker / dead pid /
  garbage marker return at once; allow, deny, answer and `{}` produce the
  right stdout; the request file is stdin verbatim and is gone after every
  exit path including SIGTERM; the deadline, Isle going away, and a
  superseding write all release silently; `notify` keeps a blocked approval;
  two sessions never cross.
- Real Claude Code, `-p` and interactive: notch allow (*Allowed by
  PermissionRequest hook*, file created), notch deny (*Denied by
  PermissionRequest hook*, *Reason: Denied from the Isle notch*, nothing
  created), question answered with no terminal UI, multi-question +
  multi-select, `{}` → question UI at once, the real 45s question deadline →
  terminal UI answerable, a 10s approval deadline with the dialog still
  answerable afterwards, dead-pid marker → terminal UI at once, Yes and Esc
  in the terminal while the hook waits.
- The allow / deny / answer / `{}` runs were repeated with the stand-in
  built from the app's own `ClaudeRequestWatcher.swift`, so the exact JSON the
  app writes is what Claude Code accepted. The same harness confirmed its
  decoding: dead-pid requests dropped and deleted, `PermissionRequest` for
  `AskUserQuestion` ignored, unknown tools shown as compact JSON, old orphan
  responses swept.

**Not verified — needs the running app:**

1. Install the new build; Settings → Claude Code shows "Answer questions and
   approvals from the notch" on, and `~/.isle/run/answering` holds Isle's pid
   (`cat ~/.isle/run/answering; pgrep -x Isle`). The hooks refresh to v9 on
   launch: `~/.claude/settings.json` has a second PreToolUse entry
   (`matcher: AskUserQuestion`, `ask-question`, `timeout: 60`) and
   `ask` with `timeout: 330`.
2. In a session in default permission mode (`/permissions` or Shift-Tab out of
   auto), ask Claude to run something that prompts (`python3 -c "…"`). The
   notch opens with "Needs your approval", the tool and the full command in
   monospace, Approve / Deny / Terminal; the collapsed word reads "Approve".
   Approve runs it; repeat and Deny stops it with *Denied from the Isle
   notch*; repeat and Terminal leaves the dialog to answer there.
3. Answer one in the terminal instead (Yes, then Esc on another): the notch
   buttons disappear within a moment, and after Esc the island settles to
   idle within ~5s rather than holding "Needs your approval".
4. Ask Claude to use AskUserQuestion with four options and descriptions, then
   a two-question one with a multi-select: the panel grows (no clipping of the
   action row, nothing under the camera or the waveform, the face toggle in
   the corner clear of the rows), a tap answers and Claude continues with
   that label, Next/Done/back work.
5. Let a question sit 45s: the notch buttons go and the terminal shows the
   question. Turn the toggle off mid-question: same, at once.
6. Quit Isle (from the menu, not pkill) with a prompt up: the terminal
   prompt is there; `~/.isle/run/answering` is gone.
7. Switch to the Music tab while a question is up: the panel returns to its
   normal height; switch back and it grows again.

**Later, now cheap:** answering questions on finding 10's channel instead
(the `PermissionRequest` for `AskUserQuestion`, where the terminal UI is
already up) would remove the 45s blank-terminal wait entirely; it needs a
check that it fires in every permission mode before the PreToolUse path is
retired.

### Approval options (`feature/approval-options`)

"Make sure it works for the different options" — every kind of tool that
asks, and the terminal dialog's answers beyond yes and no. Checked against
Claude Code 2.1.318 with a dump hook first (the raw stdin of every prompt is
kept under the scratchpad's `m7/payloads/`, and the debug fixtures decode
those same payloads), then end to end with the stand-in Isle built from the
app's own `ClaudeRequestWatcher.swift`, in `-p` and interactive sessions,
scratch `HOME`, `--setting-sources project,local`, each in its own scratch
project. The real `~/.claude/settings.json` was hashed before and after:
unchanged.

| # | Finding | Consequence for the design |
|---|---|---|
| 16 | `decision.updatedPermissions` = the request's `permission_suggestions`, verbatim, did exactly what the dialog's "Yes, and don't ask again" does: the rule landed in the project's `.claude/settings.local.json` (`Bash(npm run *)`, `WebSearch`, `mcp__acme__deploy_service`, `WebFetch(domain:example.com)`, `Bash(python3 -c 'print\(6*7\)')`), or for a `session` destination only in memory, and the next matching call didn't ask — in the same session (`npm run build` → `npm run lint`, a second WebSearch, the MCP tool with other arguments, a second Edit under `setMode: acceptEdits`) and in a fresh one. | **Always…** is an echo, never a rule of Isle's making. |
| 17 | The suggestions are often *not* what the terminal's option 2 shows. For `python3 -c 'print(6*7)'` the hook got the exact command while the dialog offered `python3 *`; a Bash `find /etc …` got a *Read* rule; a `touch` in the project got `addDirectories` **and** `setMode: acceptEdits` together (finding 9); Read outside the project got two rules (`//etc/**`, `//private/etc/**`); a subagent's Bash got `[]`. Destinations seen: `localSettings`, `session`. | The label comes from the suggestion alone, so it can't match the terminal's wording — and must not try. Saving a rule outlives the call, so Always… is two taps: the first shows exactly what would be saved. |
| 18 | **ExitPlanMode ignores a bare `allow`**: the hook's output is taken, nothing happens, the plan dialog stays up (the first build's Approve did nothing for a plan). With `updatedInput` = its `tool_input` echoed it is *Allowed by PermissionRequest hook* and the session leaves plan mode for **default** (the next Write asked) — the dialog's "Yes, manually approve edits". `updatedPermissions: setMode` alone is ignored too. A deny keeps it in plan mode and Claude says so. Its request carries no suggestions. | Approve on a plan echoes the input. No "auto mode" / "accept edits" choice from the notch: nothing in the request offers one. |
| 19 | The deny `message` is the *only* thing Claude is told — it arrives as the tool's error. With "Denied from the Isle notch" the model reasoned aloud about what an Isle notch was. | Now "The user denied this tool call from the Isle notch." (plans: "The user rejected this plan …"). Claude doesn't retry and carries on, as before (no `interrupt`). |
| 20 | Tools that asked in `default` mode: Bash, Edit, Write, NotebookEdit, WebFetch (run inside a `web-fetch` subagent, so its payload has `agent_type`), WebSearch, MCP tools (payload has `mcp_server.name`), Read outside the project, ExitPlanMode (plan mode). Didn't ask: Task/Agent itself (its subagent's tools do, with `agent_id`/`agent_type`), Skill, Monitor, CronCreate, PushNotification, ScheduleWakeup, EnterWorktree, RemoteTrigger, SendMessage. **MultiEdit no longer exists** in 2.1.318 (the name survives only as a rule alias). | The decoder covers MultiEdit anyway; unknown tools still fall back to their whole input. |
| 21 | **Parallel calls each raise a PermissionRequest at once**, and the second `ask`'s status write retires the first's id: in `-p` the first was denied for want of an answer, interactively it falls through to its terminal dialog. | As before: safe, but only one of two parallel prompts is notch-answerable. A queue is a later change. |

**What the face shows now** (renders: `approval-renders/` in the
scratchpad, `before_*` / `after_*` / `afterrev_*` and `compare_*.png`):

- The tool, then its exact subject. MCP tools read `acme › deploy_service`
  then every argument as `key: <json>` (strings keep their quotes, a newline
  stays `\n`). File paths are relative to the session's directory when inside
  it (the eyebrow names the project), otherwise whole with `~`.
- Edits give the second line to what they change, counted from the input:
  `−1 +1 lines` (Edit, plus `· every occurrence` for `replace_all`),
  `3 lines` (Write), `replace · cell c1` (NotebookEdit). The path then keeps
  one line, middle-truncated.
- ExitPlanMode: headline **Plan ready**, the plan's own text (heading marks
  and blank lines dropped), cut at the end — read from the top.
- **Always…** sits between Approve and Deny when every suggestion is one Isle
  can name exactly (allow `addRules`, `setMode`, `addDirectories`, with a
  known destination); otherwise it isn't offered. Terminal then gives up its
  word for its icon (tooltip and accessibility label keep it); in Both mode,
  beside the corner toggle, the four pills drop their symbols instead of
  truncating. A tap turns the face into **Don't ask again?** with the change
  in Claude Code's own terms — `Allow Bash(npm run *)`, `Switch to
  acceptEdits mode`, `Allow access to ~/Documents/isle` — and where it's kept
  (`this session`, `this project · .claude/settings.local.json`, `every
  project · ~/.claude/settings.json`), and **Confirm** / **Back**.
- A request without suggestions keeps the face exactly as it was.
- "No, and tell Claude what to do differently" stays **Terminal**: it needs
  free text (Milestone 11's reply-to-agent). **Now built** — see Milestone
  11.

**Test in the running app:** default permission mode, then

1. `python3 -c "print(1)"` → Approve; again → Deny (Claude says you denied
   it); again → Always… → check the review names `Allow Bash(python3 -c …)`
   and `.claude/settings.local.json` → Back returns, → Always… → Confirm; ask
   for the identical command again: no prompt anywhere. Remove the rule from
   the project's `.claude/settings.local.json` afterwards.
2. An Edit: the second line reads `−n +m lines`; Always… says `Switch to
   acceptEdits mode · this session`; Confirm, then a second edit doesn't ask
   (the terminal footer shows accept edits on).
3. A WebFetch and an MCP tool if one is configured: `server › tool` with its
   arguments.
4. Shift-Tab into plan mode, ask for a small plan: the notch says **Plan
   ready** with the plan's first lines; Approve → Claude starts implementing
   and asks again before its first edit; another plan → Deny → Claude stays
   in plan mode.
5. Both mode: a prompt with Always… shows four word-only pills, none cut off.

## Milestone 11 — Jump to the session, and Reply to Claude

> **Status (2026-11-05): built on `feature/jump-and-reply` (off
> `test/field-scan-batch`), awaiting an in-app test.** Host resolution and
> the Terminal tab lookup were checked read-only against this Mac's live
> sessions; the reply channel was chosen by driving real Claude Code 2.1.318
> sessions with `expect` and `screen`. Nothing was clicked in the running app.

The Claude face's action row, held empty since Milestone 7 "for jump on the
leading side", now carries both features from the navigation decision:

- **Jump** — a pill named for the app hosting the session (*Terminal*,
  *iTerm*, *Ghostty*, *VS Code*, *Cursor*…). A click brings that session's
  tab, or failing that its app, to the front. *Answer in terminal* and the
  approval's *Terminal* pill now jump there too.
- **Reply** — a "Reply to Claude…" field taking the rest of the row on a
  session that's at its prompt (Done, Waiting, Ready, Error). Click to
  type, Return sends, Esc cancels.
- On the request faces: **Type something** next to *Answer in terminal* on
  a question, and **No, and tell Claude…** (a speech-bubble pill beside
  Deny) on an approval. Both open the same field in the row.

Each is drawn only when it can actually reach the session. No pill and no
field rather than one aimed at a guess.

### Jump — how the host is found (`ClaudeSessionHost`)

The registry gives the CLI's pid. From it:

- **The tab's tty** is the CLI's controlling terminal (`sysctl`
  `KERN_PROC_PID` → `e_tdev` → `devname`), which is what Terminal and
  iTerm2 address tabs by.
- **The app** is the first ancestor that's a regular (Dock-visible) app.
  VS Code's and Cursor's terminal helpers are apps too, but not regular
  ones, so the walk lands on the editor.
- **tmux** breaks the chain (the pane's shell hangs off the tmux server, a
  daemon). The CLI's own environment (`KERN_PROCARGS2`, same user only)
  has `TMUX` (socket) and `TMUX_PANE`. tmux names the client attached to
  that session, and the client sits in the terminal tab. A jump runs
  `switch-client -c <client tty> -t <pane>` and `select-pane`, then
  brings the client's tab forward.
- **screen** breaks it the same way, and can't say which terminal shows a
  session, so it resolves to nothing (no pill).

| Host | Precision | How | Verified |
|---|---|---|---|
| Terminal | exact tab | AppleScript: the tab whose `tty` matches, `selected`, window `index` 1, `activate` | Resolution and tab lookup, read-only, on all four live sessions (below). The `type_into` handler was called with a tty no tab has and returned *missing*. Focus change not run. |
| iTerm2 | exact session | AppleScript: the session whose `tty` matches, `select` window, tab and session | Not installed here. Script compiles only when iTerm2 is the host. |
| tmux inside any of these | exact pane, then the outer tab | `switch-client` / `select-pane`, then the client's tab as above | Not installed here. |
| kitty | exact window when started with remote control listening (`KITTY_LISTEN_ON`) | `kitten @ --to … focus-window --match id:` | Not installed here. Otherwise app-level. |
| Ghostty, Warp, Alacritty, WezTerm, VS Code, Cursor, Zed… | the app only | Launch Services `openApplication` (activates and reopens, like a Dock click) | Not installed here (VS Code and Cursor are, but no sessions run in them). |
| screen, a detached tmux, SSH | none | — | screen resolved to nothing against a real screen-hosted session. |

Read-only check, every live session on this Mac (all in Terminal):
`77016 → window 1 tab 1 /dev/ttys001`, `49210 → window 2 /dev/ttys006`,
`38412 → window 3 /dev/ttys000`, `85069 → window 4 /dev/ttys003`. Each CLI
owns its terminal (`pgid == tpgid`), including the one mid-tool.

Activation goes through Launch Services for non-scriptable apps because
Isle is never the active app, and under cooperative activation (macOS 14+)
`NSRunningApplication.activate` from a background app can be declined.

### Reply — the channel

Every way to get text into a running interactive session was tried:

| # | Finding (Claude Code 2.1.318) | Consequence |
|---|---|---|
| R1 | An **`asyncRewake` Stop hook** (`"asyncRewake": true`; runs in the background and wakes the model on exit 2) keeps the terminal free and does wake an idle session. Its stderr reaches the model as a task notification wrapped in **`[SYSTEM NOTIFICATION - NOT USER INPUT] … Do NOT interpret this as user acknowledgement, confirmation, or response to any pending question … must NOT be treated as approval or consent`**. `rewakeMessage` / `rewakeSummary` (schema-marked `@internal`) only change the prefix and the "Stop hook feedback" line. | **Rejected.** By design, this channel can't carry the user's word. Asked "create made-ok.txt?", Sonnet refused a "Yes, go ahead" sent this way: *"it says not to treat it as approval… I can't count that as your confirmation."* (Haiku complied.) Isle won't work around that framing. |
| R2 | A **blocking Stop hook** returning `{"decision":"block","reason":…}`: the session shows *"running Stop hook"* with the spinner for as long as the hook waits, so the turn never ends. The reason renders in red as *"Stop hook error: …"*. Text typed meanwhile is **queued** behind it ("Press up to edit queued messages"), and goes in *after* the hook's reply. Sonnet did act on the reason. | **Rejected.** A reply can come minutes later, and the terminal would look busy the whole time. |
| R3 | `asyncRewake` hooks are **not** cancelled by the user typing in the terminal. Two were left waiting at once, and the older one took the reply. Both got SIGTERM at `/exit`. | Any hook channel would need its own supersede check. |
| R4 | `asyncRewake` only backgrounds in an interactive or streaming-input session. In `-p` it runs synchronously. | It would block a `-p` run for its whole wait. |
| R5 | Sessions carry `messagingSocketPath` (cross-session peer messaging). Its messages are framed `[MESSAGE FROM NON-USER SOURCE - NOT USER INPUT]`. | Same problem as R1. |
| R6 | **Typing into the session's own terminal** puts the text in as the user's own turn: the transcript entry has `origin: {kind: "human"}`, `UserPromptSubmit` fires, and the reply is answered. Verified by `screen -X stuff` into a detached screen-hosted session (`SCREENOK`). **CR submits; a bare LF only adds a line to the prompt.** A burst of text ending in CR is submitted, not treated as a paste. CR then LF submits and leaves nothing behind. | **Chosen.** This is the only channel where the reply is the user's own turn. |
| R7 | Free-text `answers` for `AskUserQuestion` (PreToolUse, `permissionDecision: allow`): *"User answered Claude's questions: · Which fruit? → Mango, and make it a smoothie"*, and the model echoed it verbatim. | *Type something* uses the existing question channel. |
| R8 | Deny with a message via `PermissionRequest` (`"The user denied this tool call from the Isle notch and said: Name the file made-alt.txt instead…"`) shows as the tool's error, and Sonnet's next call was a Write to `made-alt.txt`. | "No, and tell Claude…" uses the existing approval channel. |
| R9 | `--resume <id> -p` forks a headless turn the interactive session never sees. `claude --help` lists nothing that sends a message to a running interactive session (`--bg`/`attach` cover only background jobs). | Not usable. |

So **Reply types into the terminal**, and only where that can happen
without focus or keystroke injection:

- **Terminal**: `do script (text & return) in <tab>`. Terminal then adds
  its own line ending, which lands on an empty, already-submitted prompt
  (R6).
- **iTerm2**: `write text (text & return) newline no`.
- **tmux**: `send-keys -l -- text`, then `send-keys Enter`.
- **Everywhere else** (Ghostty, Warp, VS Code's terminal…): no Reply
  field. Typing there would mean System Events keystrokes into a focused
  window.

The text is passed to the AppleScript handlers as Apple-event parameters,
never spliced into script source.

**Safety at Send** (all checked fresh, at the click):

1. The registry must say `idle`. Not `busy` (mid-turn), and not `waiting`
   (a dialog is open, and a typed Return would answer it).
2. The CLI's process group must own its terminal. If Claude has exited and
   a shell is in front, the text would otherwise run as a command.
3. The host is resolved again, so the right tab gets it.
4. Newlines are folded to spaces, since a Return mid-text would submit half
   of it.

**Delivery is claimed only from the transcript.** *Sending…* until a `user`
entry with `origin.kind == "human"` ending with the reply appears (polled
over ~6s), then **Sent · <text>** for the rest of that turn. Otherwise it
says what happened, in the detail line, and keeps the text in the field:

- *Allow Isle to control Terminal in Privacy › Automation* (-1743)
- *Couldn't find Claude's tab*
- *Claude isn't at its prompt right now*
- *Something else is in front in Claude's tab*
- *Typed into Terminal, but Claude didn't take it — check its prompt*

Drafts are kept per session id, so text for one session is never offered
to another.

### Typing in a non-activating panel

- `NotchWindow.canBecomeKey` returns `allowsKey`, which is true only while
  `NotchViewModel.composing` is set. The window controller makes the
  hovered panel key with `makeKey()` and never calls `NSApp.activate`.
  `.nonactivatingPanel` means the terminal stays the active app.
- Composing ends on Return / Send, Esc, the panel resigning key (a click in
  another app), the field leaving the face (a swipe, or an approval taking
  the face), the session changing, or the bridge stopping. Keys go back by
  re-activating the app that was frontmost. If the panel is still key one
  run-loop turn later, it's ordered out and straight back in.
- While a field holds the keys, moving the pointer away doesn't collapse
  the panel, and a click on the card doesn't retract it.

### Renders

`scratchpad/jump-reply-renders/` (`sheet_jr_1…5.png`, `jr_jr_*.png`):

- the pill for Terminal, iTerm, tmux-in-Terminal, Ghostty, VS Code and
  Cursor
- the working face (pill, no field) and an unresolved host (empty row)
- the field at rest, composing (empty and with text), a kept draft,
  *Sending…*, *Sent*, and three failures
- Both mode
- *Type something* (single and multi-question, and typing)
- the approval row with the bubble pill, with and without *Always…* (five
  word-only pills)
- denying with a message, for a tool and for a plan

The hairline ticks at the ends of the field's outline are a
`CALayer.render` artifact of the harness: `ImageRenderer` draws the same
capsule clean.

### Test in the running app

1. Install the build and finish a turn in a Terminal session. The face
   reads *Done* with **Terminal** and **Reply to Claude…**. Click
   **Terminal**: that exact tab comes forward (the first time, macOS asks
   to let Isle control Terminal).
2. From another app, open the notch and click **Reply to Claude…**, type
   *say hi*, and press Return.
   - Your app keeps its focus ring; the keys go to the notch.
   - After sending: the keys come back to your app (type somewhere to
     check), the Terminal tab shows the prompt submitted, and the notch
     reads *Sent · say hi* while Claude works.
3. Click into another app mid-compose: the field stops, and the text is
   still there next time. Press Esc mid-compose: the same. Move the
   pointer away mid-compose: the panel stays open.
4. Try a reply while Claude is mid-turn or showing a dialog. It should say
   *Claude isn't at its prompt right now*, and nothing is typed.
5. Quit Claude in that tab (the shell is in front), and try to reply. It
   should say *Something else is in front…*, and nothing is typed.
6. On a question, click **Type something**, type an answer, and press
   Return: Claude shows *User answered … → your text*. On an approval,
   click the speech-bubble pill, type a reason, and press Return: the call
   is denied and Claude follows the reason.
7. Click *Answer in terminal* or *Terminal* on a prompt: the tab comes
   forward.
8. In System Settings › Privacy › Automation, turn Isle → Terminal off and
   reply. It should show the Automation message, and the text stays.

### Decisions to confirm

- **Reply types into the terminal.** It's the only channel where the reply
  is the user's own turn (R1, R2). Its reach is Terminal, iTerm2 and tmux.
- **The Terminal `do script` path is the least-proven link.** The byte it
  appends is unknown, and the design is robust to either (R6). Matthew's
  first live reply settles it.
- **Reply rides the existing *Answer questions and approvals from the
  notch* toggle**, not a new setting.
- **Esc keeps the draft** rather than discarding it.
- A draft with the field unfocused **doesn't hold the panel open**. Only
  focus does.
- **Focusing a kept draft selects it all** (the AppKit default), so typing
  replaces it.

### Lone Jump (2026-11-05)

Matthew found Jump awkward where it's the only action: a big pill alone at
the bottom-left of an empty row. Three placements were rendered for Done,
Working and Waiting, single face and Both (`lj_*` fixtures):

- **(a) a chip at the eyebrow's trailing end** — chosen. It sits on the row
  that already says where the session is, right of the camera cutout and
  inside the waveform clearance, and gives way to nothing (the eyebrow
  drops the elapsed time and the cup's word first). The action row is
  simply empty, which leaves the room to what Claude said (M15).
- (b) inline after the detail: with a two-line M15 message it pushed the
  stack up, and the eyebrow rose to within 4pt of the band. Rejected.
- (c) right-aligned in the row: reads as a primary button, and is still a
  pill alone in a row.

Placement is decided by the host, not the state (`repliesFromNotch`): on a
terminal Isle can type into, Jump keeps its place in the row while the
reply field comes and goes beside it, so nothing moves between Working and
Done. The chip is for hosts that never take a reply (Ghostty, VS Code,
Cursor, kitty, Warp), or when replying from the notch is off.

## Milestone 15 — Done says what happened

From Field scan 2: a competitor shows what an agent did when it finishes.
The `Stop` hook's stdin carries `last_assistant_message`, so Isle can show
the start of what Claude actually said — never a summary Isle invents.

### The payload (Claude Code 2.1.318, captured)

`Stop` stdin, one line, `JSON.stringify` shape: `session_id`,
`transcript_path`, `cwd`, `prompt_id`, `permission_mode`, `effort`,
`hook_event_name`, `stop_hook_active`, `last_assistant_message`,
`background_tasks`, `session_crons`. The message is only the final text
block: in a turn that used tools it's the closing sentence, with no tool
noise. Non-ASCII arrives raw (UTF-8); quotes, backslashes, tabs and
newlines as escapes. Same shape in `-p` and interactive sessions.

### The helper (v10)

- A `Stop` writes `last_message`: the first 300 characters, **kept in the
  JSON-escaped form Claude Code sent** — so the script never escapes it
  again — cut on whole tokens (an escape, or one character under a UTF-8
  locale) with a `grep -E` of two runs of 150 (255 is the most one repeat
  counts). A cut can't land inside an escape or a multi-byte character, a
  bare quote or backslash can't get through, and a `\u` escape for half a
  surrogate pair isn't a token, so the excerpt ends before one. A raw DEL
  is dropped, and anything still not valid UTF-8 (`iconv`) drops the
  excerpt. ~40 ms per Stop on a 60 KB message.
- The idle nudge (`waiting_input`) copies `last_message` from the record
  verbatim; a new prompt's `working` drops it.
- The project name is now escaped (`json_escape`, pure bash): a `"` in a
  folder name used to make the whole record unreadable.
- Verified with 44 hostile payloads under a scratch HOME (quotes,
  backslashes, `\n`/`\r`/`\t`, control characters and ANSI, emoji and ZWJ
  sequences, flags, combining marks, RTL, `$(…)` and backticks, a fake
  nested key, every escape and multi-byte character at the 298–300
  boundary, lone and paired surrogate escapes, pretty-printed and missing
  keys, hostile project names) plus every real capture: all valid JSON,
  every excerpt an exact prefix of the message. Round trip through Isle's
  own decoder (`ClaudeStatusWatcher.decode`) exact for real interactive
  Stops and the carried nudge.

### Isle

- `ClaudeDoneLine` turns the excerpt into the face's line: the first line
  of prose (a heading only if nothing else; a line ending in `:` carries on
  into the one it introduces), Markdown taken off (emphasis, links, lists,
  quotes, backticks; `snake_case` and `__init__.py` survive), cut at the
  end of a sentence when one ends within ~two lines, else truncated at the
  tail — with "…" when the helper's 300-character cut lands in the line.
  Code blocks (fenced, or cut off before their closing fence), rules and
  control characters are left out. Only code, or no text → nil.
- The detail line shows it for Done, the Ready it eases back to, and
  Waiting for you, up to two lines, in place of the stock line only when
  there are words. The home grid's Claude tile uses it too.
- **Toast:** the island's own session already says "Done" collapsed, so
  it gets none. A session the island isn't showing — which used to finish
  silently — gets one, naming its project: `isle-website · done`.

### Renders

`done-renders/after_m15_*`: short, long, Markdown, list, hostile and
code-only messages; Ready and Waiting after a turn; Terminal (with Reply),
Ghostty, crowded eyebrow; Both; home tile (short, long, code-only); the
background toast (short and long project).

### Decisions to confirm

- **Claude's words stay through Ready and Waiting**, not just the few
  seconds of Done, until the next prompt. Without that the line is visible
  only for `doneToastSeconds`.
- **Plain text, not quoted.** The face doesn't mark the line as Claude's
  words beyond its place under "Done".
- **A first sentence under 24 characters** ("Done.") takes the next one
  with it.
- **The background toast** has no setting of its own; it's on whenever the
  bridge is.

## Milestone 18 — A bigger calendar: Join, the week, a timeline, ticks and quick add

**Status:** Built on `feature/calendar-plus`, rendered, awaiting in-app test.

### What it is

- **Taller agenda face.** Every face may ask for its own content height
  (`NotchViewModel.faceContentHeight`), capped by one shared
  `NotchMetrics.panelMaxHeight` (230) that the window is already sized
  for. The question face is now one case of it; the agenda is another
  (`AgendaLayout.contentHeight` = 144 → a 186pt panel under a 32pt band).
  A new face that grows (the shelf, next) is one more case, no new path.
- **Three views, Day the default.** Day (the list, five lines), Timeline,
  Week — a switcher under the date card. Opens on today's list every time.
- **Week strip, not month grid.** Both were rendered; the strip won because
  a picked day's list fits under it, where the month grid fills the column
  and a pick has to go back to Day. Paged by chevrons, last week to four
  ahead — the range `AgendaMonitor.dayInterval` reads.
- **Timeline** from an hour ago to the end of the last event (another day:
  9–6 widened to fit), six hours minimum, blocks in lanes per run of
  overlaps, all-day events as chips, one line of free/busy. The now line
  steps with `TimelineView(.everyMinute)` — on the minute, never per frame.
- **Join** (`MeetingLink`): exact hosts only — Zoom (+ company subdomains),
  ZoomGov, Meet, Teams, FaceTime, Webex (+ subdomains), GoTo, Whereby,
  Jitsi, Chime — with a meeting-shaped path; URL field, then location,
  then notes; two different meetings in one field is no Join. A pill when
  the call is within `max(10, lead)` minutes or under way, a quiet camera
  before. On the home tile too. The toast wears `video.fill` for a call;
  it isn't clickable, so it has no button.
- **Ticks** save at once (`EKReminder.isCompleted`, `commit: true`); the
  line stays ticked with Undo for five seconds. Repeating reminders get no
  Undo: EventKit moves them on, and unticking wouldn't move them back.
- **Quick add** (`QuickAddParser`, `NSDataDetector` plus "in N min", "for N
  minutes", "remind me"): a clock time makes an event in the default
  calendar; a day only, no date, or "remind me" a reminder. Return
  previews (kind · title · when · calendar); only Add, or Return again on
  the same line, saves. Refuses two dates, "at 9" with no day, "the 1st",
  and times already past. Keys through `ComposeKind.quickAdd`, the same
  composing path as Reply.
- **Access**: the full access the agenda already asks for covers writing.
  A quick add of a kind never asked for (Reminders while its switch is
  off) asks at Add, the first write.

### Decisions to confirm

- The waveform overlay is off the agenda face now (its week strip and
  timeline run to the column's corner), as it is off the shelf.
- Opening the panel while a call's toast is up doesn't jump to the agenda;
  Join is on the home tile and the face. A takeover like Claude's is
  possible but would be the first non-Claude one.
- "Call mom in 30 min" is an event (it has a time), per the rule; "remind
  me to…" is the way to a reminder.
- Parts of the day ("morning", "tonight", "lunch") make a dated reminder,
  not an event at the hour the detector picks.

## Milestone 16 — Every Claude Code session at once

From Field scan 2: several competitors show every running agent session,
each with its state. Isle already tracked them all (per-session records,
the registry for liveness, urgency selection); the face showed one and
admitted the rest only as "+2 working".

### What it does

- **The way in** is the other-sessions marks, now a button with a chevron:
  "+1 needs you  +1 working ›". With nothing busy elsewhere but another
  session alive, "+1 more ›" stands in, so the list is reachable whenever
  there's more than one session. Three entries were rendered
  (`session-list-renders/sheet_entry{A,B,C}_1.png`): (A) the marks, chosen;
  (B) the marks plus a `square.stack` count chip — a fourth thing in the
  eyebrow, and in a crowded eyebrow its capsule lands under the camera
  cutout 2pt below the band, so the project name collapses to "i";
  (C) the project label as a picker ("isle ⌃⌄ 3") — tidy, but the marks
  that actually say something needs you weren't the way in, and the
  chevron reads as a pop-up menu that isn't there.
- **The list** takes the face's width (no big glyph; each row has its own),
  one line a session: a 12pt dot-matrix marker (the user's own design),
  the project, the state in its marker's colour, the detail — the tool and
  target, the command or question a hook is blocked on, or for Done/Waiting/
  Ready the M15 excerpt — then how long since its hook last wrote, and an
  icon-only Jump chip (the app's name is its tooltip). The session on the
  island is lit. Four rows fit the 146pt panel under a 32pt housing; more
  scroll vertically, with "7 live ↕" in the eyebrow and a fading foot. No
  height change.
- **Order** is selection's own ranking, now shared (`ClaudeSelection.ranked`):
  needs you / failed, then working, then waiting / done / ready, each by
  recency. A 5000-pool random check confirms `ranked.first` is exactly what
  the old `selectStatus` picked.
- **Live only**: a row needs a record with a session id and a pid the
  registry can see — the strict liveness keep-awake uses. Each record goes
  through `reconciled` (an interrupted turn isn't "Working"), then the face's
  own clock: a question nothing is waiting on past 45s, a compaction past
  25s and a usage limit past its reset list as Ready, since no hook will
  ever close them. Done stays Done, with Claude's words, until the session
  moves — that's what the list is for.
- **Clicking a row** pins that session: the face, the approval buttons, the
  question and the reply are all its. The eyebrow's folder becomes a
  chevron ("‹ notch-bench"), the way back up to the list.
- **Home tile**: "3 sessions · 1 needs you" in place of the other-sessions
  line when more than one is live; the island's own approval or question
  keeps its detail.

### The pin (`ClaudeSelection.Pin`)

The smallest override that's correct: `selectStatus` asks
`ClaudeSelection.select(from:pin:)`, which returns the pinned record while
it holds and the ranking's pick otherwise.

- It yields only to another session that **newly** needs you — approval,
  question or failure — while the pinned one doesn't. The pin remembers what
  already outranked it that way (`heldAgainst`), so an approval that was up
  when you picked another session doesn't snatch the face straight back; if
  it's answered in the terminal and asks again, that's new. A session that
  merely starts working never takes a pinned face.
- If the pinned session needed you and you answer it, anything else needing
  you now outranks it, newly — so answering one of two waiting sessions
  moves the face to the other.
- It goes when the session's pid leaves the registry, when you go back to
  the list, and when the panel closes: a collapsed island always means
  selection's pick, so a session picked once and forgotten can't keep a more
  pressing one off it.
- A switch the user made applies quietly (`applyClaudeStatus(announce:
  false)`): no chime, and an alert it lands on counts as already seen, so
  the panel doesn't pop open for it.

### Tests

A harness compiled with every Isle source (`scratchpad/sl/tests`), 42 checks:
the ranking against the old selection; pin holds over working, yields to a
new approval and a new failure, holds against an approval already up and
its re-writes, yields when that session asks again; a pinned approval holds
against a newer question, and answering it hands the face over; death; and
through the real view model (`applyTestReading`): pin, an approval arriving
in another session (its buttons are its own), a SIGKILL'd pinned session,
back from the face and from the list, the panel closing, stale and live
questions in the list, the question face not growing the panel under the
list, and leftover/id-less records never listed.

### Renders

`session-list-renders/sheet_final_*.png`: entry points (busy, quiet,
crowded with Ghostty's chip and the cup, on an approval); lists of 2, 4 and
7 (with and without hosts); pinned Done and Waiting; the override (pinned on
a working session, then an approval arriving elsewhere); Both mode (lists,
entry, pinned); the home tile (3 with one needing you, 2 quiet, 1).

### Decisions to confirm

- **The pin ends when the panel closes.** The alternative — holding it while
  collapsed — makes the island show a chosen session over the ranking with
  nothing on screen saying so.
- **Only needing you overrides a pin**, not a session starting work, though
  working outranks done in selection.
- **States are the list's own words**: "Error" (as the face says it, not
  "Failed"), "Usage limit", "Question", and "Done" persists after the face
  has eased to Ready.
- **Two sessions in the same project** show the same name; the detail tells
  them apart. The CLI's `name` ("isle-cf") could disambiguate.
- **The row's Jump is an icon**, unlike the eyebrow's named chip — the same
  app name down every row was noise.

## Island motion — the proximity swell and a shaped collapse

From Field scan 2's polish note: Apple's island reacts to the pointer
approaching, and iPhone's collapses with a genie-like motion. Built on
`feature/island-motion`; numbers in `IslandMotion.swift`, checked by
`scripts/test-island-motion.sh`.

- **Swell.** Within 56pt of the collapsed island it grows by up to 3pt a side
  and 2pt down, and leans up to 1.5pt toward the pointer. The top never moves.
  It's a `scaleEffect` on the black fill, outside the clip, so the hover
  zones, the hit rect and the open timing don't see it. The reading is
  stepped (8 levels, 3 of lean) and published only on a change, from the
  pointer monitor that already runs. Out of reach it costs one rect test. A
  sideways sweep, a drag, an open or settling island, and Reduce Motion all
  hold it at rest.
- **Collapse.** Corners lead (0.18s), then width (0.24s, ζ 0.78, settling
  ~2% past its target), then height on the old close spring, which is
  critically damped and so never shorter than the housing. While the width
  leads, the walls pinch toward the bottom (up to ~8pt). The pinch never
  reaches into the camera band, and the outline is never narrower than the
  band. Each channel is a SwiftUI spring picked by a transaction flag set only
  on the open→collapsed change. There's no clock. Reduce Motion gets a plain
  0.18s ease.
- **Still to judge on the real screen:** whether the swell reads at all over a
  dark menu bar, and whether sweeping along the menu bar beside the notch
  pulses it too often.

## Milestone 17 — Guarded commands

From Field scan 2 ("every git push waits for your click, even in auto
mode"). A short list, the user's own, of commands that always ask: in auto
mode, with edits accepted, past an allow rule, with permissions bypassed.
**A speed bump for honest mistakes, not a sandbox**, and the UI says so.

### How it works

- **The hook.** A third PreToolUse entry, matched to `Bash|Monitor`, runs
  `isle-cli guard` (timeout 10s). With no list file it exits before reading
  stdin. Otherwise it reads the command the way a shell splits it (words,
  quotes off, simple commands at `;` `&&` `||` `|` `&`, newlines, parens,
  `$(…)`, backticks, `bash -c`, `eval`, a heredoc fed to a shell, through
  `env`, `sudo`, `xargs`, `nohup`, `timeout`…), and on a match answers
  `permissionDecision: "ask"` with the reason "Guarded in Isle: matches
  `git push`, which always asks." It can't see through an alias, a variable
  in command position, a script file, or a name built at run time.
- **Patterns** are words: the program (by name, so `/usr/bin/git` is git),
  its subcommand words in order, flags anywhere. An option's value may sit
  between program and subcommand (`git -C dir push`). Short-flag clusters
  match in any grouping (`rm -rf` = `rm -fr` = `rm -r -f`), exactly as
  written (`-R` isn't `-r`).
- **Over 16 KB** (unescaped), a command isn't read word by word: if every
  word of a pattern appears in it, it asks ("too long to read, and it
  mentions `git push`"). Reading 16 KB in bash takes up to ~1.3s, and a hook
  that hits its 10s timeout lets the call through unasked, so the guard errs
  toward asking.
- **The list** lives at `~/.isle/guarded-commands`, written by rename from
  Settings (`GuardedCommands.sync`) only while the toggle is on and the list
  isn't empty. Off by default.
- **The notch's reason.** The PermissionRequest that follows a hook's ask
  carries no reason and no `tool_use_id`, so the guard leaves
  `~/.isle/guarded/<session>.json` (pattern + command). The watcher reads it
  from beside its own requests folder and marks the approval guarded only
  when the record names this exact command and was written within 60s
  before the request. A "Guarded" chip sits beside the headline; the pattern
  and the speed-bump line are its tooltip. The record goes at SessionEnd.

### Always… never covers a guarded command

Three layers, each tested:

1. **Claude Code sends no `permission_suggestions`** with the
   PermissionRequest after a hook's ask (every guarded run below; 2.1.318
   and 2.1.319). The notch only offers Always… when there are suggestions,
   and its terminal dialog shows only Yes / No.
2. **The app** clears `remember` on an approval it marks guarded, so even
   with suggestions the face shows no Always…, and `respond(.allowRemembering)`
   writes nothing.
3. **The hook** is the last word: `ask` re-runs the matcher on a Bash or
   Monitor request and, when the notch's answer carries `updatedPermissions`
   for a guarded command, replaces it with a plain allow. Verified live: an
   auto-mode session where the stand-in for Isle answered Always… with a
   `localSettings` rule ran the command once and wrote no
   `settings.local.json`. The control (an unguarded `python3 -c`, same
   answer) did write the rules, so the strip is what stopped it.

The guard also holds against a rule saved some other way: a hook's ask
beats an allow rule (row "manual + allow rule" below).

### Permission modes vs the guard (Claude Code 2.1.319, 2026-11-06)

Nested `env -u CLAUDECODE claude` sessions (haiku), `--setting-sources
project,local` plus a scratch `--settings` whose hooks ran the real
`isle-cli guard` and `isle-cli ask` from this branch under a scratch HOME.
"Isle" was a stand-in: a live pid in `run/answering` and a script that
answered each request file as the app would. Harness:
`scratchpad/m17/matrix/` (`run.sh`, `drive.exp`, `responder.py`,
`matrix-summary.txt`).

| Mode | Command / pattern | Answered by | Guard asked | Prompt | Outcome |
|---|---|---|---|---|---|
| `manual` | `echo GUARDED-1` | notch: allow | yes | Yes / No | ran |
| `default` (reported as `default`, shown as "manual mode") | same | notch: allow | yes | Yes / No | ran |
| `acceptEdits` + allow rules | same | notch: allow | yes | Yes / No | ran |
| `plan` | same | notch: allow | yes | Yes / No | ran |
| `auto` | same | notch: **Always…** | yes | Yes / No | ran once; answer stripped to allow; no rule saved |
| `auto`, Monitor tool | same | notch: allow | yes | Yes / No | ran |
| `bypassPermissions` | same | notch: allow | yes | Yes / No | ran |
| `bypassPermissions` | `cd repo && git push origin main` / `git push` | notch: deny | yes | Yes / No | denied; the scratch remote got nothing |
| `bypassPermissions`, Isle not running | `echo GUARDED-1` | terminal (Enter) | yes | Claude Code's own Yes / No | ran after Yes |
| `dontAsk` | same | notch: allow | yes | Yes / No | ran |
| `manual` + `Bash(python3:*)` allowed | `python3 -c …` / `python3 -c` | notch: allow | yes | Yes / No | ran (the rule alone runs it unasked) |
| `claude -p`, `bypassPermissions` | `echo GUARDED-1` | nobody can | yes | none (no PermissionRequest) | refused: the tool error is the guard's reason |
| control: `-p`, bypass, guard off | `echo GUARDED-1` | — | no | none | ran unasked |
| control: `-p`, default, unguarded | `python3 -c …` | notch: Always… | no | — | suggestions sent; rules written to `settings.local.json` |

In every guarded run the PermissionRequest carried no
`permission_suggestions`, and the record matched the request's command
(lead 0.08–0.13s), so the notch would have shown the chip. 2.1.319's modes
are `acceptEdits`, `auto`, `bypassPermissions`, `manual`, `dontAsk`, `plan`;
`default` is still accepted and is the same mode as `manual`.

### Cost per Bash call

`isle-cli guard` (bash 3.2, builtins on the common path): off 5ms (the bash
process floor is 3ms); on with five patterns, `ls -la` 6ms; a near miss 9ms;
a match 21ms; an 11 KB heredoc 36–52ms; 85 KB 0.2s; 350 KB 1.1s; the worst
case under the 16 KB cap (16 KB on one line) 1.3s. The WIP used
`${x//[…]/}` and a rescanning unescape, which took 11s at 11 KB and over an
hour at 85 KB; both now split once with IFS.

### Tests

- `scripts/test-guarded-commands.sh`: 124 checks of the real `isle-cli`
  under a scratch HOME (nothing is executed; every command is text in a
  payload): the matcher (compound commands, quoting, prefixes, shells and
  eval, heredocs, flags, what it can't see), JSON unescaping, the 16 KB
  path, the record and its removal at SessionEnd, the exact ask payload,
  and `ask` stripping Always… for guarded Bash and Monitor commands while
  passing every other answer through.
- A harness compiled with every Isle source (`scratchpad/m17/tests`), 35
  checks: pattern normalizing; `sync` writing and removing the list, read
  back by the real hook; the record lookup on real 2.1.319 bytes; and a
  real `ClaudeRequestWatcher` on a scratch folder — guarded marks, no
  Always…, an Always… reply refused, the controls offering and writing it,
  stale and mismatched records ignored, other tools never marked.

### Renders

`scratchpad/m17/render/png/{before,after}_*.png` (before = c2c38e8, after =
this branch), sheets `sheet_faces_{before,after}.png` and
`settings_strip.png`: guarded approvals (git push, a long chain, rm, a long
pattern, Monitor, a crowded eyebrow, Both mode), the ordinary approvals
unchanged (Always… still there with suggestions), and Settings (off, on and
empty, a list, every suggestion used, the hook not installed).

### Decisions to confirm

- **Off by default, empty list**; the five suggestions are one click each.
- **The chip says "Guarded", not the pattern.** "Guarded · git push" never
  fit beside "Needs your approval"; the pattern is in the tooltip.
- **Over 16 KB, a mention is enough to ask.** The alternative is reading it
  and risking the 10s timeout, which lets it through.
- **`claude -p` refuses a guarded command** rather than running it: Claude
  Code's own behaviour for a hook's ask with nobody to answer.
- **Monitor is guarded too**, since it runs a shell command and never asks on
  its own.

## Milestone 21 — Background sessions in the list

From Field scan 3. Claude Code's agent view runs sessions with no terminal
(`claude --bg`, `claude agents`), hosted by a supervisor. Isle couldn't see
most of them: a blocked one (since June, its process long gone) was in
`claude agents` and nowhere on the notch.

### What we found (2.1.319, 2026-11-07)

Two short `claude --bg` runs (haiku, a scratch project, a scratch
`--settings` that dumped every hook's stdin), both removed afterwards.

- **A live background session is an ordinary session to the bridge.** Its
  process (`claude bg-spare`, under `claude daemon run`) writes
  `~/.claude/sessions/<pid>.json` with `kind: "bg"` and its `jobId`, and fires
  the user's hooks: SessionStart, UserPromptSubmit, PreToolUse,
  PermissionRequest, Notification (`permission_prompt`), PostToolUse, Stop,
  SessionEnd. Isle's real `isle-cli` wrote `~/.isle/sessions/<id>.json`
  (`done`, "ok") for the first run. The hook `session_id` is the
  `sessionId` `claude agents` prints; the job's short id is its first eight
  characters. No tty (`CLAUDE_CODE_SESSION_ATTENDED=0`, `CLAUDE_JOB_DIR` set).
- **The approval handshake works with no terminal.** The second run's
  PermissionRequest went to the worktree's `isle-cli ask` under a scratch
  HOME, with a stand-in for Isle answering by rename after 10s: the hook
  blocked, `claude agents` said `state: blocked, status: waiting, waitingFor:
  "permission prompt"` throughout, the answer was honoured, `touch` ran,
  PostToolUse fired the same second. So the notch's Approve/Deny reach a
  background session; nothing new is needed for them.
- **What the bridge can't see** is everything after the process: `claude
  stop` (or the supervisor's ~1h idle stop) fires SessionEnd, `isle-cli end`
  deletes the record, and `claude agents` keeps listing the session (`done`,
  no pid). A session blocked on you can sit there for days. Nor does any
  hook say *blocked* when a turn ends on a question — the hooks say Done.
- **`claude agents --json --all`**: 0.09–0.15s wall, ~0.12s CPU, ~150 MB
  peak RSS (short-lived), 1 KB for four sessions. It doesn't start the
  supervisor. Background entries carry `id`, `state`, `name`, and while the
  process lives `pid`, `status`, `waitingFor`; interactive ones `pid`,
  `status`, `waitingFor` and no `state`.
- **What to watch.** `~/.claude/jobs/<id>/state.json` is replaced by rename
  on every change (inode changed at start, blocked and done), so a directory
  watch on each job's folder sees it; `~/.claude/jobs` itself sees jobs come
  and go. The docs say those files aren't a stable interface, so Isle never
  parses them — they're only the cue.
- **Attach** is `claude attach <id|name>` (CLI help and the docs); it restarts
  a stopped session from its conversation.

### What it does

- **The list** gets every background session `claude agents` reports, merged
  with the hook rows by session id (then the registry's `jobId`, then pid),
  so nothing is listed twice. A row goes by Claude Code's own name for the
  session (up to 170pt, against a project's 120). A live one keeps its
  hook detail; one only agent view knows of says the state in Claude Code's
  words (Working, Needs you, Needs approval, Done, Failed, Stopped, or an
  unknown word verbatim) and, as its detail, what it's waiting for when
  Claude Code names it, then the project. No age: no hook wrote it. The
  header says "N sessions" instead of "N live" when a row may have no process.
- **Blocked beats a hook's Done.** When the hooks saw a turn end and Claude
  Code says the session is blocked, the row and the island say Needs you,
  with Claude's last words (usually the question). Every other disagreement
  goes to the hook, which is fresher.
- **Finished ones are quieter** (dimmer name, grey state) and listed while
  their process is alive — Claude Code keeps it about an hour — or for an
  hour after Isle saw them finish. Done/failed/stopped seen only after the
  fact (at launch) aren't listed.
- **Counts.** `otherSessions` and the home tile count them (blocked needs you,
  working is working). The 5s reselect tick doesn't run for them.
- **The island** is never taken by a session only agent view knows of; it can
  be picked from the list and pinned, under M16's rules. The face then says
  Needs you / Needs your approval / Stopped… with its name in the eyebrow and
  an **Attach in Terminal** pill. No reply field: there's no terminal.
- **Jump** prefers the M11 path (a terminal the pid's tree resolves to); a
  background session with a known id otherwise opens Terminal.app running
  `cd -- '<cwd>' 2>/dev/null; claude attach <id>` (the id must be
  `[A-Za-z0-9_-]`, ≤64, no leading `-`). No id, no Jump.
- **With nothing live** but agent view's sessions, the face says "One session
  in the background" with the marks as the way in, and the home tile "Needs
  you · 1 session · 1 needs you".

### Cost and cues

Read on a cue only: a `~/.claude/jobs` change, a job folder's change, a
background session's registry record changing, the panel opening (Claude
showing), and the list opening. Coalesced (0.4s) and at most once every 3s,
however many cues arrive. No timer, fast or slow: every change Claude Code
makes to a background session's state renames its `state.json`, so there's
nothing a timer would catch that the watch doesn't, and an hour's expiry of
a finished row is checked at the next read. `claude` is found in the usual
install places, then once via the login shell; a miss is retried after ten
minutes. A failed read empties the background half rather than keeping a
stale one.

### Tests

`scripts/test-background-sessions.sh`, 174 checks, compiled with every Isle
source: the parser against the real `claude agents --json --all` output from
this Mac and the probe's shapes (`scripts/fixtures/`), malformed and partial
JSON, unknown states, wrong types; attach-id safety; the merge (by id,
jobId, pid; registry-only; listing rules; blocked over Done); the rows; the
attach command line; and through the view model — counts, the pin, a
background session going away, nothing live, and a live one turning blocked.

### Renders

`scratchpad/m21/render/png/{before,after}_*.png` and `sheet_*.png`:
terminal-only lists (unchanged), mixed lists of 4 and 7, Both mode, the way
in, pinned (blocked with a long name, on a permission prompt, working and
done with hooks, Both), the home tile, and background-only face/list/tile.

### Not verified

- In the running app: Terminal's attach window, the jobs watch firing in
  Isle (the rename was seen from the shell), and the `claude` lookup from a
  launchd-started app.
- A session sent to the background from a terminal with `←`: assumed the
  same `kind: "bg"` record; not run.
- Being attached to a background session elsewhere: its worker's process
  tree has no terminal, so Jump opens a second attach.

### Decisions to confirm

- **Agent-only sessions never take the island by themselves.** The list's
  first row can then be one the island isn't showing (it's lit, so it's
  visible). The alternative puts a session blocked for days on the island for
  days.
- **Finished background sessions**: listed while their process lives or an
  hour after Isle saw them finish, quieter; else hidden.
- **Blocked over a hook's Done** for a live background session.
- **"Failed"** for Claude Code's failed (the hooks' API error stays "Error").
- **Attach always opens Terminal.app**, whatever terminal the user prefers —
  it's the one Isle already scripts for Start Claude.

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

## Milestone 10 — Apple Music Compatibility

**Status: built (0.4.1 branch, September 2026).** `MediaPlayerController` +
`AppleMusicController`; the adapter passes Music through; the view model
routes commands, the poll clock, the artwork fallback and the audio tap to the
player whose track is showing. Decisions taken as recommended: repeat is a
toggle in both players; with the adapter silent the playing player wins, then
the one last routed, then Spotify. Verified so far: build, and every Music
script compiles against Music's dictionary; not yet exercised against a
running Music.app.

*Same island, different player.* Isle is Spotify-scoped by construction: the
adapter reads whatever owns the system now-playing session, but every transport
command, the position poll, and the artwork fetch go to
`application "Spotify"` by name. Apple Music users already see their track
(the empty state even says "Start something in Spotify or Music") and then hit
a play button that launches Spotify.

### Goal
Music mode works end to end with Apple Music as the player — read, transport,
scrub, shuffle/repeat, artwork — with no Spotify installed at all, and picks
the right target when both are running.

### Scope
- Lift the Spotify-specific half of `SpotifyController` behind a
  `MediaPlayerController` protocol (poll, `playPause`, `nextTrack`,
  `previousTrack`, `seek`, `toggleShuffle`, `toggleRepeat`, `fetchArtworkIfNeeded`,
  `bundleID`). Spotify keeps its implementation unchanged.
- New `Isle/Media/AppleMusicController.swift` over AppleScript to
  `application "Music"` (`com.apple.Music`): `player state`, `player position`,
  `current track` name/artist/album/duration, `shuffle enabled`,
  `song repeat` (three-state: `off`/`one`/`all`), and `artwork 1 of current
  track` for the cover when the adapter doesn't carry one.
- **Routing.** Commands go to the app that owns the track the island is
  showing, keyed on `MediaPlaybackModel.bundleIdentifier` from the adapter;
  when the adapter is silent, fall back to whichever supported player is
  running. Never launch a player: the process-exists guard from
  `SpotifyController` applies to both.
- Empty-state copy and the "open in player" affordance follow the routed
  player, not Spotify.
- Automation permission is per target app in TCC, so the first Music command
  raises its own prompt. Onboarding's permission step should say which player
  it is asking for and skip a player that isn't installed.

### Files
- New `Isle/Media/MediaPlayerController.swift` (protocol), new
  `Isle/Media/AppleMusicController.swift`.
- `Isle/Media/SpotifyController.swift` — conform, no behaviour change.
- `Isle/Notch/NotchViewModel.swift` — replace the single `spotify` owner and
  `spotifyModel` merge with a routed player; the adapter-preferred /
  poll-fallback rule in `recomputeSource` stays, generalised per player.
- `Isle/Notch/ExpandedNotchView.swift` — repeat control becomes three-state
  when the routed player is Music.
- `Isle/Onboarding/` — Automation step names the player.

### Acceptance
- With Spotify uninstalled, playing a song in Music shows the track, cover,
  and a scrubber that tracks the real position; play/pause, next, previous,
  seek, shuffle, and repeat all act on Music.
- With both running, the island controls the one whose track it is showing,
  and never launches the other.
- Nothing about the Spotify path changes: same poll cadence, same artwork
  rule, same permission prompt.

### Decisions to lock
- **Repeat in Music is three-state**, Spotify's AppleScript is boolean. Either
  the control cycles off → all → one for Music, or it stays a toggle
  (off ↔ all) everywhere. *Recommend the toggle: one control that means the same
  thing in both players.*
- **Which player wins when both are running and the adapter is silent.**
  *Recommend the most recently playing one, falling back to Spotify (the
  existing behaviour) on a cold start.*
- **Artwork for Music** comes from the adapter when it has it, else from
  `artwork 1 of current track` — a data blob over AppleScript, so fetched on
  track change only, the same way `wantsArtwork` gates the Spotify CDN fetch.
  Palette extraction from the cover is unchanged.

---

## Suggested sequencing

```
M1 Mode archetype ─┬─> M2 Onboarding
                   ├─> M3 Claude bridge ─┬─> M4 Tabbed "Both" ─┐
                   │                     └─> M7 Act from notch ─┤
                   └───────────────────────> M5 Settings ──────┴─> M6 Launch
                                              │                     │
                                              ├─> M8 Display picker │
                                              ├─> M9 Power/charging │
                                              └─> M10 Apple Music   │
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
- **M10 (Apple Music) is a media-track change only** — it touches nothing on
  the Claude side and can ship in any release after M5.
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

### M13 — Synced lyrics — built, then removed (2026-11-04)

Built: the current line from LRCLIB, timed to the playhead, as a third row
of the music face's text block, opt-in in Settings. Removed at the user's
call the same day: they tried it and didn't want it. The music face is back
to its design without lyrics; the setting is gone, and nothing is sent to
LRCLIB. Lookups already made sit in `~/Library/Caches/<bundle id>/Lyrics`,
left for the user to delete. The code is in `db371db`, `b22f5fb`, `fb55728`
and `b1980fb` if it's ever wanted back.

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
