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
| Claude hook bridge (`isle-cli` + `settings.json`) | Watched (M3); per-session files, v7 | `Isle/Claude/ClaudeStatusWatcher.swift` |
| Claude session registry (hook-free liveness) | Shipped | `Isle/Claude/ClaudeSessionRegistry.swift` |
| Stall / no-response detection | Shipped, one path unverified | `Isle/Notch/NotchViewModel.swift` |
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
- **No-response detection**: island `working`/`waiting`, no tool running, and
  the transcript's last conversation entry is a `user` turn older than 45s →
  `No response · 45s`, dimmed. It reports the observation, never a cause — a
  long think is indistinguishable from a retry and the label is true for both.
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
previously stole the island.

### Outstanding

- **The `waitingInput` label path is unverified.** Print-mode sessions never
  fire the idle notification, so covering it needs an interactive run. It is the
  case where the signal is most certain, so it matters.
- **`status: "api_retry"`** appears in the CLI binary. If the session registry
  ever reports it, it replaces this entire inference chain with a direct signal.
  Worth checking before investing further here.
- **Stale session files** accumulate: a `SIGKILL`'d session leaves its
  `~/.isle/sessions/<id>.json` behind. Selection hides it by dead pid, but
  nothing prunes disk. A sweep at launch is a few lines.
- **Calmer glyph while unresponsive** — a slower, dimmer pulse needs staleness
  threaded through `NotchGlyphState` into both the SwiftUI and CALayer renderers.
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

## Milestone 7 — Act from the Notch

Turn the Claude island from a *notifier* into a *control surface*. Today a
`needs_approval` interrupt opens the notch (`hasLiveActivity` →
`liveActivityExpanded`) but you still alt-tab to the terminal to answer it. This
milestone lets you approve or deny a tool call **in the notch**, and have that
click actually decide the call.

This is also the feature that unblocks **Scheduled Prompts** (see "Parked"):
both need the same primitive — a way for the notch to *talk back* into a live
Claude Code session. Building the blocking-hook + decision-file handshake here
de-risks that work.

### Goal
When Claude Code asks permission for a tool, the expanded Claude panel shows the
exact tool + target with **Approve** / **Deny** buttons, and clicking one
resolves the pending call in the session — with a hard timeout that falls back
to Claude's normal in-terminal prompt.

### How it works
Claude Code's `PreToolUse` hook has the two properties this needs: it is an
ordinary command, so **it can block** as long as it likes before it prints; and
it can **return a permission decision** on stdout. Current schema (confirm
against live docs before building — this is the load-bearing detail):

```json
{ "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "allow" | "deny" | "ask",
    "permissionDecisionReason": "…" } }
```

The handshake:
1. `PreToolUse` calls `isle-cli` in a new `ask` mode. It writes `needs_approval`
   with the already-captured `action`/`target` and a request id keyed by
   `session_id`, and clears any stale decision file.
2. The script **blocks**, polling `~/.isle/claude-decision-<session_id>.json`
   with a timeout.
3. The notch is already open (via `isAttention`); `ClaudeExpandedView` renders
   the command/target with Approve / Deny.
4. The click writes the decision file; the blocked hook reads it, prints the
   matching JSON, exits. Claude proceeds or is stopped with the reason fed back.
5. **Timeout or Isle-not-running → exit 0 with no decision**, so Claude falls
   back to its own permission prompt. Never silently allow.

### Scope
- `isle-cli`: new `ask` verb (write request + block-poll for decision + timeout)
  and a `decide <session_id> <allow|deny>` verb the app calls. Keep
  `HookInstaller.scriptBody` byte-for-byte in sync (they're intentionally
  duplicated).
- `integration/claude-code-hooks/settings.json`: point `PreToolUse` at `ask`.
- `ClaudeStatus` / `ClaudeStatusWatcher`: carry the request id through.
- `ClaudeExpandedView`: Approve / Deny buttons (only when `needsApproval`),
  showing the exact tool + target.
- `NotchViewModel`: an action that writes the decision file for the live
  session.

### Acceptance
- A tool permission prompt shows Approve / Deny in the notch; Approve lets the
  tool run, Deny blocks it with the reason surfaced to Claude.
- Quitting Isle (or a 30s timeout) mid-prompt never wedges the session — Claude
  falls back to the terminal prompt.
- Two concurrent sessions each get their own prompt (decisions keyed by
  `session_id`).

### Boundaries & decisions to lock
- **Tool approvals only.** `needsQuestion` (free-text `AskUserQuestion`) can't be
  answered by allow/deny — that needs text injected into the session (the
  fragile terminal-injection problem). Out of scope here; it stays a
  "go to the terminal" case.
- **Timeout length** — default 30s, then fall back. Confirm the number.
- **Permission posture** — a notch click authorizes a tool. Always show the exact
  command/target; default-deny on timeout; never auto-allow.

---

## Suggested sequencing

```
M1 Mode archetype ─┬─> M2 Onboarding
                   ├─> M3 Claude bridge ─┬─> M4 Tabbed "Both" ─┐
                   │                     └─> M7 Act from notch ─┤
                   └───────────────────────> M5 Settings ──────┴─> M6 Launch
                                                                    │
                                     M7 unblocks ──> Scheduled Prompts (Parked)
```

- **M1 is the gate** — everything reads from `AppSettings.mode`.
- **M5 (Settings) can start after M1** and grow a section per milestone as
  features land.
- **M7 (Act from notch) needs M3's bridge** (it extends `isle-cli` and the
  status watcher) and delivers the "talk back into a session" primitive that
  Scheduled Prompts is parked on.
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
