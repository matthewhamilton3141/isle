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
| Audio-reactive waveform | Shipped | `Isle/Media/SystemAudioLevels.swift` |
| Claude status glyph (breathing + checkmark) | Built, wired (M3) | `Isle/Claude/` |
| Claude hook bridge (`isle-cli` + `settings.json`) | Watched (M3) | `Isle/Claude/ClaudeStatusWatcher.swift` |
| Claude hook installer | Done (M3) — menu-bar action, Settings wiring pending | `Isle/Claude/HookInstaller.swift` |
| `NotchViewModel.claudeState` | Live from watcher, mode-gated (M3) | `Isle/Notch/NotchViewModel.swift` |
| Settings pane | Empty `Settings` scene | `Isle/IsleApp.swift:20` |
| Mode selection (Music / Claude / Both) | Model + gating done (M1); picker UI pending (M2/M6) | `Isle/Core/` |
| Tabbed "Both" expanded view | Done (M4) | `Isle/Notch/ExpandedNotchView.swift`, `ClaudeExpandedView.swift` |

The state machine (`NotchState`, `NotchStateResolver`) and the collapsed
split-view rule (`CollapsedNotchView`) were already designed for two concurrent
activity sources. That's the foundation the "Both" mode builds on — most of the
work below is wiring, persistence, and UI, not re-architecture.

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
    on/off, split-vs-cycle behavior.
  - **Claude** (visible in Claude/Both) — hook install/uninstall status.
- All persisted via `AppSettings` / `@AppStorage`.
- Mode change tears down and restarts only the affected subsystems (no relaunch).

### Files
- New `Isle/Settings/SettingsView.swift` (+ per-section subviews).
- `Isle/IsleApp.swift` — populate the `Settings` scene; add "Settings…" and
  "Setup…" menu items.
- `Isle/Notch/NotchViewModel.swift` — observe settings for live control toggles.

### Acceptance
- Switching Music → Both at runtime starts the Claude watcher and reveals tabs
  without relaunch.
- Toggling a media control hides/shows it in the expanded row immediately.

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

## Suggested sequencing

```
M1 Mode archetype ─┬─> M2 Onboarding
                   ├─> M3 Claude bridge ──> M4 Tabbed "Both" ─┐
                   └─────────────────────> M5 Settings ───────┴─> M6 Launch
```

- **M1 is the gate** — everything reads from `AppSettings.mode`.
- **M5 (Settings) can start after M1** and grow a section per milestone as
  features land.
- A credible public build = **M1 + M2 + M3 + M4** (the full three-mode island),
  with **M5** and **M6** finishing it for release.

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

Revisit and promote to a numbered milestone once the delivery mechanism is
chosen.
