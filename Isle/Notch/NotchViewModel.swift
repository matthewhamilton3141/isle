//
//  NotchViewModel.swift
//
//  Single observable every island reads from. Owns the media feed, the Claude
//  bridge and the power toasts — i.e. everything the notch *shows*, which is
//  identical on every screen it's drawn on.
//
//  The other input that can open the notch, pointer hover, is per-screen and
//  lives on IslandPresentation. This file keeps the live-activity half of the
//  rule (`autoExpandsForActivity`); that file crosses it with its own hover.
//

import SwiftUI
import AppKit
import Combine

/// Element widths for the collapsed notch, shared by the width calculation
/// (NotchViewModel) and the layout (CollapsedNotchView) so they can't drift.
enum CollapsedSize {
    static let album: CGFloat = 22
    /// The waveform, one size in every layout. It used to narrow to 22 when
    /// the album shared the island, which drew the same waveform at a lighter
    /// weight in the split view; the album never shrank for Claude, and
    /// `NotchMetrics.collapsedClaudeExtra` says outright that the waveform
    /// isn't meant to either. Costs 4pt of island width in the split view.
    static let wave: CGFloat = 26
    static let dots: CGFloat = 16
    static let gap: CGFloat = 5          // between elements within a cluster
    static let cutoutGap: CGFloat = 6    // between a cluster and the camera
    static let minSide: CGFloat = 30     // resting half-width when a side is empty
    static let claudeSoloLeading: CGFloat = 14
    static let statusFontSize: CGFloat = 10
}

/// How many live sessions besides the island's own are busy or blocked —
/// see `NotchViewModel.otherSessions`.
struct ClaudeOtherSessions: Equatable {
    /// Working or compacting.
    var working = 0
    /// Blocked on an approval or a question.
    var needYou = 0

    var isEmpty: Bool { working == 0 && needYou == 0 }
}

/// Everything the island *shows*, shared by every island on every screen.
///
/// Hover and per-screen geometry are not here — they belong to one island and
/// live on `IslandPresentation`. See that file for where the line is drawn and
/// why the alert flags stayed on this side of it.
@MainActor
final class NotchViewModel: ObservableObject {

    /// The user retracted the current alert's auto-opened panel (hovered away or
    /// clicked it). The panel collapses to the island but the alert glyph stays
    /// until the state resolves; re-armed for the next alert. Ignored unless
    /// `settings.dismissAlertPanel` is on.
    @Published private(set) var alertDismissed = false

    /// The pointer entered the panel during the current alert — a prerequisite
    /// for hover-away to count as a dismiss (so an untouched auto-open isn't
    /// dismissed by a stray move nearby).
    private var alertWasHovered = false

    /// The user manually picked a tab while the current alert was live, so the
    /// auto-jump to the Claude tab (see `expandedTab`) should stop overriding
    /// their choice for the rest of this alert. Re-armed on the next state
    /// change, so a fresh interrupt still grabs the Claude tab once.
    private var tabOverriddenDuringAlert = false

    /// Claude Code state from the hook bridge, driven by `ClaudeStatusWatcher`.
    /// Stays `.disconnected` when the active mode doesn't show Claude, or when
    /// there's no live session.
    @Published var claudeState: ClaudeCodeState = .disconnected

    /// Project directory name from the status file. For the Claude expanded
    /// view (Milestone 4).
    @Published private(set) var claudeProject: String?

    /// Session id from the status file, when the installed `isle-cli` emits it.
    @Published private(set) var claudeSessionId: String?

    /// The tool Claude is currently running (Edit / Bash / …) and its target,
    /// for the "what it's doing" line in the expanded view.
    @Published private(set) var claudeAction: String?
    @Published private(set) var claudeTarget: String?

    /// For `.failed`, the API `error_type` (rate_limit / overloaded / …) so the
    /// notch can name the failure. Nil in every other state.
    @Published private(set) var claudeErrorType: String?

    /// A tool is executing right now (between `PreToolUse` and `PostToolUse`).
    /// Only used to suppress the no-response inference — deliberately *not*
    /// wired into `isThinking`, which stays on the lingering-action rule so the
    /// collapsed word doesn't flap on every tool boundary.
    @Published private(set) var claudeToolActive: Bool = false

    /// For a `usage_limit` failure, the moment the limit resets (when the helper
    /// could recover it). Drives the pinned island's reset clock and the expanded
    /// countdown; the display eases back to idle at this moment. Nil when unknown.
    @Published private(set) var claudeResetAt: Date?

    /// When the last Claude status change arrived, for the "… ago" line in the
    /// Claude expanded view. `nil` when disconnected.
    @Published private(set) var claudeUpdatedAt: Date?

    /// Isle is holding the keep-awake assertion right now. A mirror of
    /// `ClaudeKeepAwake.isHeld`, re-published after every take and release,
    /// so the panel's mark is the assertion itself rather than the setting:
    /// on while `pmset -g assertions` lists the hold, off the moment it goes.
    @Published private(set) var isKeepingAwake = false

    /// Live sessions other than the one on the island that are busy or
    /// blocked — selection shows one session, and this is how the panel
    /// admits the rest. Counted only from sessions the registry vouches for,
    /// so a crashed session's leftover file never inflates it.
    @Published private(set) var otherSessions = ClaudeOtherSessions()

    // MARK: Answering from the notch (Milestone 7)

    /// The request the selected session's hook says it is blocked on — the
    /// status file's `request_id`. Nil once any other verb has written.
    private var claudeRequestId: String?

    /// Every request a hook is blocked on right now, as `requestWatcher` last
    /// reported it.
    private var claudeRequests: [ClaudeRequest] = []

    /// The request the notch can answer right now: the one whose id the
    /// selected session's status names *and* whose file still exists. Either
    /// half going away retires the buttons — the file when the hook exits (an
    /// answer, its deadline, Esc in the terminal), the id when any other verb
    /// writes (the prompt was answered in the terminal and Claude moved on).
    /// Isle offers nothing it can't back with a hook that is actually waiting.
    @Published private(set) var pendingRequest: ClaudeRequest?

    /// The request a click has already answered, from the moment the response
    /// is written until the hook takes it and the request goes away. Disables
    /// the buttons so a double-click can't write twice.
    @Published private(set) var answeredRequestId: String?

    /// Which of a multi-question `AskUserQuestion` is on screen, and what has
    /// been picked for each so far. Held here rather than in the view so every
    /// island shows the same step.
    @Published private(set) var questionIndex = 0
    @Published private(set) var questionPicks: [Set<String>] = []

    /// Whether `run/answering` is currently down, so it's only touched on a
    /// change.
    private var answeringMarkerWritten = false

    /// The tab the user last selected in `.both` mode. Backed by AppSettings so
    /// it survives relaunch. Display may override this during an interrupt —
    /// see `expandedTab`.
    @Published var activeTab: IsleTab {
        didSet {
            guard activeTab != oldValue else { return }
            settings.lastTab = activeTab
        }
    }

    @Published private(set) var media = MediaPlaybackModel()

    /// Colours pulled from the current cover, recomputed only when the cover
    /// itself changes.
    ///
    /// This is cached rather than derived in the view because extraction is
    /// not stable under re-running. It picks `ranked[0]` winner-take-all, and
    /// on real covers the top cells are separated by well under 1% — the
    /// current one by 0.7%. Two artwork sources feed this (the adapter's
    /// embedded bytes and Spotify's CDN fetch) and their decodes differ
    /// slightly, so re-deriving could hand back a different winner each time
    /// and the notch visibly flashed between colours. Held steady here, the
    /// selection runs once per cover and the near-tie stops mattering.
    ///
    /// It also has to be cached for cost: as a computed property on the view
    /// it re-ran on every body evaluation, which is 30 times a second now that
    /// audio levels publish at display rate.
    /// Colours pulled from the current album art, or nil when there is no
    /// artwork to pull from.
    @Published private(set) var artworkPalette: ArtworkPalette?

    /// The palette everything draws from.
    ///
    /// Artwork wins whenever there is any. Without it — a Claude-only island,
    /// or music with no cover — the user's accent supplies one instead, which
    /// is the whole point of `ClaudeAccent`: `ArtworkColors.palette(from: nil)`
    /// returns three greys, and a `.palette` marker drawn from those is the
    /// flat look the accent exists to replace.
    var palette: ArtworkPalette {
        artworkPalette ?? settings.claudeAccentPalette
    }

    /// Identity of the cover `palette` was built from, to skip the work when
    /// an update carries the same image.
    private var paletteArtwork: NSImage?

    /// Position the user is dragging the scrubber to. Non-nil only mid-drag;
    /// while set, the scrubber renders this instead of the live position so
    /// the thumb doesn't fight the playback clock under the finger.
    @Published var scrubTarget: Double?

    /// The current track's synced lyrics: set when lyrics are switched on and
    /// LRCLIB had a timed match for this very recording, nil otherwise.
    /// Changes at most once a track — the line itself turns over on
    /// `lyricsClock`, which only the lyric line observes.
    @Published private(set) var lyrics: SyncedLyrics?

    /// Keeps the lyric line current against the playback clock below. Handed
    /// out whole, like `audioLevelSource`, so a line change redraws the line
    /// and nothing else.
    let lyricsClock = LyricsClock()

    /// The audio outputs and the system default, for the music face's output
    /// switcher. Handed out whole like `lyricsClock`, so a device coming or
    /// going redraws the switcher alone; it listens to the HAL only while
    /// that face is on screen.
    let outputDevices = OutputDevices()

    /// What's left of today — events still to come or in progress, and
    /// reminders due by the end of the day — as `AgendaMonitor` last reported
    /// it. Empty when both agenda switches are off. Drawn by the agenda face
    /// of the expanded panel.
    @Published private(set) var agendaItems: [AgendaItem] = []

    private let settings: AppSettings
    private let adapter = MediaRemoteAdapterClient()
    /// One controller per supported player, in cold-start preference order.
    /// Commands go to the one whose track the island is showing — see
    /// `routedPlayer` — never to a fixed app.
    private let players: [MediaPlayerController] = [SpotifyController(), AppleMusicController()]
    private let audio = SystemAudioLevels()
    private let claudeWatcher = ClaudeStatusWatcher()
    private let requestWatcher = ClaudeRequestWatcher()
    private let sessionRegistry = ClaudeSessionRegistry()
    private let keepAwake = ClaudeKeepAwake()
    private let power = PowerMonitor()
    private let bluetoothBattery = BluetoothBatteryMonitor()
    private let agenda = AgendaMonitor()
    private let lyricsLibrary = LyricsLibrary()
    private var cancellables = Set<AnyCancellable>()

    /// The Pomodoro clock. Always constructed (it's cheap and idle until
    /// started) but only *offered* while `settings.pomodoroEnabled` is on —
    /// see `pomodoroAvailable`. Turning the setting off resets it.
    let pomodoro: PomodoroTimer

    /// True between `start()` and `stop()` — i.e. while the notch window is
    /// shown. Guards the live mode-change subscription so it doesn't spin up
    /// subsystems while the overlay is hidden.
    private var isRunning = false

    /// Whether the media subsystems (adapter, Spotify, audio) are currently
    /// live. Tracked so a mode change only toggles the delta rather than
    /// restarting an already-running capture.
    private var mediaRunning = false
    private var audioRunning = false

    /// Whether the Claude status watcher is currently live.
    private var claudeRunning = false

    /// Whether each power monitor is currently live. Tracked separately
    /// because the two settings are independent.
    private var powerRunning = false
    private var deviceBatteryRunning = false

    /// Reverts a `done` glyph back to `idle` after a beat, so the checkmark
    /// reads as a toast rather than sticking until the next prompt. Cancelled
    /// if any other status arrives first. Also times out a lingering
    /// `needs_question` (see `applyClaudeStatus`).
    private var doneRevertTask: Task<Void, Never>?

    /// How long a `needs_question` lingers before easing back to idle, so a
    /// declined or ignored terminal question can't wedge the island on
    /// "Question". Long enough to notice; short enough that an abandoned one
    /// clears on its own.
    private static let questionRevertSeconds: TimeInterval = 45

    /// How long the `compacting` glyph runs before easing back to idle. Only the
    /// `PreCompact` hook fires — Claude Code emits nothing when compaction ends
    /// or is cancelled — so without this a cancelled compact animates forever.
    /// A finished compaction is normally cleared sooner by the next real event
    /// (a tool call / prompt); this is the backstop for the cancelled/idle case.
    private static let compactingRevertSeconds: TimeInterval = 25

    /// Every session that currently has a status file, as last published by
    /// the watcher. Retained so selection can be re-run when the *registry*
    /// changes without waiting for a status write.
    private var claudeStatuses: [ClaudeStatus] = []

    /// Picks which session owns the island.
    ///
    /// Not "most recent": that was the old single-file behaviour and it's what
    /// let a background session's `Stop` or idle notification wipe the session
    /// the user was watching. Rank by how much the state wants attention, and
    /// only break ties by recency — so a quiescent session can never displace
    /// an active one, however recently it moved.
    private func selectStatus(from statuses: [ClaudeStatus]) -> ClaudeStatus {
        // Drop records whose process is gone. Skipped entirely while the
        // registry is empty (not yet scanned, or ~/.claude/sessions missing),
        // since filtering against nothing would blank the island.
        let live = claudeSessions.isEmpty ? statuses : statuses.filter { status in
            guard let id = status.sessionId else { return true }
            return claudeSessions.contains { $0.sessionId == id }
        }
        let pool = (live.isEmpty ? statuses : live).map(reconciled)
        return pool.max {
            (Self.urgency($0.state), $0.updatedAt ?? .distantPast)
                < (Self.urgency($1.state), $1.updatedAt ?? .distantPast)
        } ?? .disconnected
    }

    /// Corrects a `working` record the hooks will never close out.
    ///
    /// Every exit from `working` is hook-driven — `Stop`, `SessionEnd`, a
    /// notification — and an *interrupt fires none of them*. Pressing ESC ends
    /// the turn silently, so the last `UserPromptSubmit` / `PreToolUse` write
    /// stays the newest thing on disk and the session sits at `working`
    /// forever. Because `working` outranks every quiescent state, that record
    /// also keeps the island away from whichever session is genuinely live. A
    /// hook that failed to run leaves exactly the same residue.
    ///
    /// Two independent signals have to agree before overriding the file, since
    /// getting this wrong blanks a session that really is thinking: the CLI's
    /// own record must no longer call the session busy, and its transcript must
    /// show the turn already closed. The second is what keeps a retry storm
    /// intact — a backing-off session reports `idle` too, but its transcript
    /// still owes a response.
    ///
    /// Except when the transcript carries the interrupt marker, which decides
    /// it on its own — see below.
    private func reconciled(_ status: ClaudeStatus) -> ClaudeStatus {
        if status.state.isAttention {
            return reconciledPrompt(status)
        }
        guard status.state == .working,
              let id = status.sessionId,
              let session = claudeSessions.first(where: { $0.sessionId == id }),
              // No readable transcript is no second signal — leave the record
              // alone rather than guess.
              let tail = transcriptTail(for: session)
        else {
            return status
        }

        // The marker is written for one reason only — the user ended the turn —
        // so it outranks everything else we could ask, and it is the *only*
        // thing that can retire a record frozen mid-tool. An interrupt during a
        // tool call fires neither PostToolUse nor Stop, so `tool_active` stays
        // true on disk forever; and since a tool that is genuinely still
        // running leaves identical residue (working, tool active, and the CLI
        // reporting idle while it waits), nothing weaker is safe to act on.
        // Typing the next prompt supersedes this immediately: that writes a
        // fresh `working` record and puts a new user turn at the tail.
        if !tail.interrupted {
            guard !status.toolActive,
                  session.status == .idle,
                  !tail.awaitingModel
            else {
                return status
            }
        }
        var corrected = status
        corrected.state = .idle
        corrected.action = nil
        corrected.target = nil
        return corrected
    }

    /// Retires a prompt that was dismissed with Esc.
    ///
    /// Esc on Claude Code's permission dialog (or its question UI) interrupts
    /// the turn and fires no hook. It does cancel a hook blocked on the
    /// prompt — that much was verified — but the status file it leaves behind
    /// still says the prompt is up, and an approval has no revert timer, so
    /// without this the panel would sit open asking for something nobody is
    /// waiting on until the next prompt.
    ///
    /// Same evidence as the `working` case: the interrupt marker at the
    /// transcript's tail, which is written for no other reason. And never
    /// while a hook is still waiting under the status's request id — a live
    /// request is a prompt that is genuinely still up.
    private func reconciledPrompt(_ status: ClaudeStatus) -> ClaudeStatus {
        if let requestId = status.requestId, claudeRequests.contains(where: { $0.id == requestId }) {
            return status
        }
        guard let id = status.sessionId,
              let session = claudeSessions.first(where: { $0.sessionId == id }),
              let tail = transcriptTail(for: session),
              tail.interrupted
        else {
            return status
        }
        var corrected = status
        corrected.state = .idle
        corrected.action = nil
        corrected.target = nil
        corrected.requestId = nil
        return corrected
    }

    /// How much a state deserves the island. Higher wins.
    private static func urgency(_ state: ClaudeCodeState) -> Int {
        switch state {
        // Blocked on the user, or ended badly — these are the whole point.
        case .needsApproval, .needsQuestion, .failed: return 3
        // Something is actually happening.
        case .working, .compacting: return 2
        // Alive but not doing anything; must never displace the tier above.
        case .waitingInput, .done, .idle: return 1
        case .disconnected: return 0
        }
    }

    /// Live sessions as the CLI itself reports them, hook-free. Ground truth
    /// for liveness: a session killed with SIGKILL fires no SessionEnd, and its
    /// pid simply stops existing here.
    ///
    /// Not published: no view reads it, and it changes with every CLI status
    /// flip, so publishing it would invalidate the whole notch on each one for
    /// nothing. Selection re-runs on the change (see `onSessions`) and
    /// publishes through `claudeState` only when the result differs.
    ///
    /// Only as fresh as the last `sessionRegistry.refresh()` — the directory
    /// watch sees sessions start and exit, not status changes — so selection
    /// paths refresh it before reading.
    private var claudeSessions: [ClaudeSession] = []

    private var reselectTimer: Timer?

    /// Re-runs selection on a coarse timer while a state that claims work is in
    /// progress is showing.
    ///
    /// Nothing here measures silence. Isle has no signal that separates a long
    /// think from a stalled turn — both fire no hooks and write nothing — so it
    /// makes no claim either way, in text or in treatment, and the island holds
    /// the last state it was actually told about.
    ///
    /// The timer earns its place on the other job: nothing else re-examines a
    /// stuck record. An interrupt fires no hook, and the registry's directory
    /// watch can't see the CLI rewriting its record in place, so each tick
    /// re-reads the registry and re-selects.
    ///
    /// Also kept running while the keep-awake assertion is held, or the panel
    /// is counting other busy sessions, whatever the island shows: a session
    /// needing attention outranks one still working, so the island can sit on
    /// a state the timer ignores while a background session holds the Mac
    /// awake or is counted as working — and that session's interrupt or
    /// SIGKILL is only ever noticed by a tick.
    ///
    /// A prompt dismissed with Esc is the same kind of stuck record — no hook
    /// fires — so the attention states ride along (see `reconciledPrompt`).
    private func updateReselectTimer(for state: ClaudeCodeState) {
        guard keepAwake.isHeld || !otherSessions.isEmpty
                || state == .working || state == .compacting || state == .waitingInput
                || state.isAttention else {
            stopReselectTimer()
            return
        }
        guard reselectTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // The registry's watch misses in-place rewrites and killed
                // pids, so the tick is also what keeps it current.
                self.sessionRegistry.refresh()
                self.updateKeepAwake()
                // Apply only on a real change, so an unchanged state doesn't
                // re-render the island every tick.
                let resolved = self.selectStatus(from: self.claudeStatuses)
                guard resolved.state != self.claudeState else { return }
                self.applyClaudeStatus(resolved)
            }
        }
        // Coarse by design, so it can afford to be coalesced with whatever
        // else wakes the process.
        timer.tolerance = 1
        reselectTimer = timer
    }

    /// The transcript's last timestamped entry: whether it leaves the model
    /// owing a response, whether it's the marker an interrupt leaves behind,
    /// and when it was written.
    ///
    /// Reads only the tail of the file — transcripts run to megabytes and this
    /// is called on a timer. Entries without a timestamp (`file-history-snapshot`
    /// and friends) are skipped rather than treated as the end, since they're
    /// interleaved with the real ones.
    private func transcriptTail(for session: ClaudeSession) -> (awaitingModel: Bool, interrupted: Bool, at: Date)? {
        let slug = session.cwd.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects/\(slug)/\(session.sessionId).jsonl")
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        guard let end = try? handle.seekToEnd() else { return nil }
        let window: UInt64 = 64 * 1024
        try? handle.seek(toOffset: end > window ? end - window : 0)
        guard let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8)
        else { return nil }

        for line in text.split(separator: "\n").reversed() {
            guard let lineData = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = object["type"] as? String,
                  // Only conversation turns answer the question. The transcript
                  // is interleaved with bookkeeping — `queue-operation`,
                  // `attachment`, `system`, `file-history-snapshot` — and any of
                  // those landing after a prompt would otherwise mask it and
                  // make an unanswered turn look answered.
                  type == "user" || type == "assistant",
                  let stamp = object["timestamp"] as? String,
                  let at = Self.transcriptDate(stamp)
            else { continue }
            // A `user` entry is either a fresh prompt or a tool result; both
            // leave the model owing output. An `assistant` entry means it has
            // already answered. The exception is an interruption: ESC appends a
            // synthetic `user` entry and fires no hook at all, so reading it as
            // an outstanding turn is precisely what pins the island on
            // `Thinking` with nothing running.
            let interrupted = type == "user" && Self.isInterruption(object)
            return (
                awaitingModel: type == "user" && !interrupted,
                interrupted: interrupted,
                at: at
            )
        }
        return nil
    }

    /// Whether a transcript entry is the marker Claude Code writes when the
    /// user interrupts a turn ("[Request interrupted by user]", and the
    /// "…for tool use" variant). It arrives as a `user` entry but terminates a
    /// turn rather than opening one.
    private static func isInterruption(_ object: [String: Any]) -> Bool {
        guard let message = object["message"] as? [String: Any] else { return false }
        let texts: [String]
        if let text = message["content"] as? String {
            texts = [text]
        } else if let blocks = message["content"] as? [[String: Any]] {
            texts = blocks.compactMap { $0["text"] as? String }
        } else {
            return false
        }
        return texts.contains { $0.hasPrefix("[Request interrupted") }
    }

    private static let transcriptFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func transcriptDate(_ string: String) -> Date? {
        transcriptFormatter.date(from: string)
            ?? ISO8601DateFormatter().date(from: string)
    }

    private func stopReselectTimer() {
        reselectTimer?.invalidate()
        reselectTimer = nil
    }

    // MARK: - Keep awake

    /// Holds the keep-awake assertion exactly while the setting is on and at
    /// least one live session is working, and releases it on every other path.
    ///
    /// Read from the per-session records, not from `claudeState`: selection is
    /// urgency-ranked, so an approval or a failure in one session takes the
    /// island while another is still mid-turn — and that turn is the one that
    /// needs the Mac awake.
    ///
    /// Each record goes through `reconciled`, the same correction selection
    /// applies, so an interrupted turn stops holding the Mac awake at the
    /// moment the island stops calling it working — no second opinion about
    /// what a frozen `working` means. Liveness is stricter than selection's,
    /// though: selection falls back to every record when the registry is empty
    /// rather than blank the island, but a record with no live pid behind it is
    /// exactly the SIGKILL residue that would otherwise pin the Mac awake
    /// forever. Holding a power assertion needs a process Isle can see.
    private func updateKeepAwake() {
        liveSessionStates = readLiveSessionStates()
        let wasHeld = keepAwake.isHeld
        keepAwake.setHeld(settings.keepAwakeWhileWorking && claudeRunning
                          && liveSessionStates.values.contains(.working))
        publishKeepAwake()
        updateOtherSessions()
        // The tick is what notices a background session's interrupt or kill,
        // so it has to run for as long as the assertion does.
        if keepAwake.isHeld != wasHeld {
            updateReselectTimer(for: claudeState)
        }
    }

    /// Mirrors the assertion into `isKeepingAwake`, publishing only on a
    /// change. Called after every take or release, so the panel's mark can
    /// never outlive the hold or show before it.
    private func publishKeepAwake() {
        if isKeepingAwake != keepAwake.isHeld { isKeepingAwake = keepAwake.isHeld }
    }

    /// The reconciled state of every session the registry can vouch for,
    /// keyed by session id — the shared reading behind the keep-awake hold
    /// and the other-sessions count. Liveness is the strict kind (see
    /// `updateKeepAwake`): a record with no live pid behind it is left out,
    /// and so is one with no session id to check. Reconciling reads each
    /// working session's transcript tail, so this is done once per pass and
    /// kept in `liveSessionStates`.
    private func readLiveSessionStates() -> [String: ClaudeCodeState] {
        var states: [String: ClaudeCodeState] = [:]
        for status in claudeStatuses {
            guard let id = status.sessionId,
                  claudeSessions.contains(where: { $0.sessionId == id })
            else { continue }
            states[id] = status.state == .working || status.state.isAttention
                ? reconciled(status).state
                : status.state
        }
        return states
    }

    /// The last `readLiveSessionStates`. Re-read with the keep-awake decision
    /// on every status, registry and tick; a re-selection in between only
    /// changes which session is excluded from `otherSessions`.
    private var liveSessionStates: [String: ClaudeCodeState] = [:]

    /// Recounts `otherSessions` from `liveSessionStates`, leaving out the
    /// session the island is showing. Publishes only on a change.
    private func updateOtherSessions() {
        var others = ClaudeOtherSessions()
        if claudeRunning {
            for (id, state) in liveSessionStates where id != claudeSessionId {
                if state.isAttention {
                    others.needYou += 1
                } else if state == .working || state == .compacting {
                    others.working += 1
                }
            }
        }
        guard others != otherSessions else { return }
        let wasEmpty = otherSessions.isEmpty
        otherSessions = others
        // A busy background session is only ever noticed going quiet by an
        // event or a tick — an interrupt fires no hook — so the tick runs
        // for as long as the count does.
        if others.isEmpty != wasEmpty {
            updateReselectTimer(for: claudeState)
        }
    }

    // MARK: - Working words

    /// A rotating "thinking" word shown in the expanded view while working,
    /// echoing the Claude Code CLI's spinner (the real word isn't exposed to
    /// hooks, so this is our own set in the same spirit). Stored bare — the
    /// trailing "…" is added where it's displayed, since the collapsed label
    /// drops it when a duration follows the word.
    @Published private(set) var workingWord: String = "Working"

    private var workingWordTimer: Timer?
    private var workingWordIndex = 0

    private static let workingWords = [
        "Thinking", "Coalescing", "Percolating", "Ruminating", "Cogitating",
        "Simmering", "Pondering", "Noodling", "Churning", "Brewing",
        "Conjuring", "Wrangling", "Synthesizing", "Contemplating", "Marinating",
        "Deliberating", "Computing", "Puzzling", "Finagling", "Vibing",
    ]

    private func startWorkingWords() {
        guard workingWordTimer == nil else { return }
        workingWordIndex = Int.random(in: 0..<Self.workingWords.count)
        workingWord = Self.workingWords[workingWordIndex]
        let timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.workingWordIndex = (self.workingWordIndex + 1) % Self.workingWords.count
                withAnimation(.easeInOut(duration: 0.3)) {
                    self.workingWord = Self.workingWords[self.workingWordIndex]
                }
            }
        }
        // Nobody is counting the seconds between "Coalescing" and "Percolating".
        timer.tolerance = 2
        workingWordTimer = timer
    }

    private func stopWorkingWords() {
        workingWordTimer?.invalidate()
        workingWordTimer = nil
    }

    // MARK: - Settings passthrough

    /// Show the seekable scrubber in the expanded panel (Settings).
    var showScrubber: Bool { settings.showScrubber }

    /// Show the shuffle/repeat toggles in the expanded panel (Settings).
    var showShuffleRepeat: Bool { settings.showShuffleRepeat }

    /// Focus intervals per Pomodoro cycle (Settings), for the tally dots.
    var pomodoroSessionsPerCycle: Int { settings.pomodoroSessionsPerCycle }

    // The now-playing sources, kept separately and merged in
    // `recomputeSource`. The adapter (MediaRemote) is preferred when a
    // supported player owns the system session — it pushes updates and ships
    // artwork as bytes. The per-player AppleScript polls are the fallback for
    // when something else (a browser tab, say) owns the session, so the notch
    // still shows the player.
    private var adapterModel = MediaPlaybackModel()
    /// Each player's latest poll, keyed by bundle id. Absent when that player
    /// isn't running or is stopped.
    private var pollModels: [String: MediaPlaybackModel] = [:]
    private var lastApplied = MediaPlaybackModel()

    /// The player whose track the island is showing, by bundle id — the one
    /// every command is sent to. Nil while nothing is showing.
    private var routedPlayerID: String?

    /// The last player that was routed. Breaks the tie when both players are
    /// running with a track and neither is playing: the one the island was
    /// on stays, rather than a cold-start default displacing it.
    private var lastActivePlayerID: String?

    private var routedPlayer: MediaPlayerController? {
        players.first { $0.bundleID == routedPlayerID }
    }

    // After a manual transport action, trust the optimistic value and ignore
    // contradicting source reads until a source confirms it or this window
    // lapses — otherwise a stale 1 Hz poll flickers play/pause back and snaps
    // the scrubber to the pre-seek position, which reads as lag.
    private var pendingPlayState: Bool?
    private var pendingSeekTarget: TimeInterval?
    private var pendingShuffle: Bool?
    private var pendingRepeat: RepeatMode?
    private var pendingCommandDeadline: Date = .distantPast
    private static let commandGrace: TimeInterval = 1.5

    /// The live per-band magnitudes, handed out as the object that publishes
    /// them rather than as a republished array.
    ///
    /// Deliberately *not* mirrored into an `@Published` here. Levels change 30
    /// times a second, and republishing them on this view model invalidated
    /// every view observing it — which is the whole notch, including the shape
    /// sizing, the hit rect and the Claude glyph, none of which depend on audio.
    /// Handing the source out directly means only the waveform itself (see
    /// `LiveEqualizer`) redraws on a level change. Empty levels mean capture
    /// isn't running, which EqualizerView reads as "use the procedural fallback".
    var audioLevelSource: SystemAudioLevels { audio }

    /// The waveform source as chosen in Settings. The views read it here rather
    /// than from `AppSettings` so a change re-renders them through this model.
    var waveformSource: WaveformSource { settings.waveformSource }

    /// Whether a waveform is drawn at all. Off gives the bars' space back in
    /// the split layout and holds it in music-solo — see `waveSlot`.
    var showsWaveform: Bool { settings.waveformSource.isShown }

    /// Why audio capture isn't running, if it isn't.
    var audioFailureReason: String? { audio.failureReason }

    // `settings` defaults to the shared instance, resolved inside the
    // main-actor-isolated init body rather than as a default argument — a
    // default-argument reference to a main-actor static is a Swift 6 error.
    init(settings: AppSettings? = nil) {
        let resolvedSettings = settings ?? .shared
        self.settings = resolvedSettings
        self.activeTab = resolvedSettings.lastTab
        self.pomodoro = PomodoroTimer(settings: resolvedSettings)

        // The timer publishes on its own object; the island reads it through
        // this model, so forward its changes (they're at most once a second
        // apart from the phase rolls — the digits themselves tick off a
        // TimelineView, not off a publish).
        pomodoro.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)

        pomodoro.onIntervalEnded = { [weak self] _ in
            guard let self, self.settings.pomodoroSoundEnabled else { return }
            self.settings.pomodoroSound.play()
        }

        // Switching the feature off takes the timer with it: a clock that kept
        // running behind a hidden tab would ring with nothing on screen to say
        // why. Also drops the user off the Pomodoro tab if they were on it.
        resolvedSettings.$pomodoroEnabled
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in
                guard let self, !enabled else { return }
                self.pomodoro.reset()
                if self.activeTab == .pomodoro {
                    self.activeTab = self.availableTabs.first ?? .music
                }
            }
            .store(in: &cancellables)

        adapter.onUpdate = { [weak self] model in
            guard let self else { return }
            let wasPlaying = self.adapterModel.isPlaying
            self.adapterModel = model
            // For a track both sources can see, the poll — not the adapter —
            // supplies `isPlaying` (see `recomputeSource`), and a collapsed
            // island reads that poll only every third second. So a play
            // pressed anywhere but in the panel — Spotify's own button, a
            // media key, a phone on Spotify Connect — took up to three
            // seconds to be believed. Nothing on a collapsed island shows
            // the transport, so the only visible symptom was the waveform:
            // past the pause grace the tap is suspended, and it is this flag
            // that resumes it, so the bars stayed dots for those seconds
            // while music played. The adapter hears the change in ~100ms;
            // take that as the cue to read the truth now rather than at the
            // next relaxed tick.
            if model.isPlaying != wasPlaying {
                self.players.first { $0.bundleID == model.bundleIdentifier }?.pollNow()
            }
            // The adapter losing the track is the moment a poll's model — and
            // so its cover — becomes the one on screen. `recomputeSource`
            // fetches any cover the routed player's poll held back while the
            // adapter was supplying one; see `wantsArtwork` below.
            self.recomputeSource()
        }
        for player in players {
            let id = player.bundleID
            player.onUpdate = { [weak self] model in
                guard let self else { return }
                self.pollModels[id] = model
                self.recomputeSource()
            }
            // A poll's cover is only drawn when its player is the one the
            // island is routed to and the adapter isn't supplying the track
            // (`recomputeSource` prefers the adapter's model whole, artwork
            // included). Fetching it otherwise was a download — or, for
            // Music, an Apple-event blob — and a decode per track change that
            // never reached the screen. "Routed to nobody" counts as yes: the
            // first poll to show a track is about to become the island.
            player.wantsArtwork = { [weak self] in
                guard let self else { return false }
                return !self.adapterModel.hasTrack
                    && (self.routedPlayerID == nil || self.routedPlayerID == id)
            }
            // Full rate while this player's poll is the only source (the
            // adapter has no track — a browser owns the session), or while a
            // panel is open and its scrubber and toggles are actually drawn
            // from it. Otherwise the adapter pushes every change a collapsed
            // island shows, and the poll can relax — see `tick` in either
            // controller. A player the island isn't routed to always relaxes —
            // including when nothing is routed at all, so an open-but-stopped
            // player isn't sent an Apple event every second for nothing. It
            // only needs to be noticed if it starts playing: the adapter hears
            // that in ~100ms when the player takes the session, and three
            // seconds is soon enough when a browser holds it. Hovering an
            // empty island still asks every player at once.
            player.wantsFullRate = { [weak self] in
                guard let self else { return false }
                guard self.routedPlayerID == id else { return false }
                return !self.adapterModel.hasTrack
                    || self.hoveredIslands > 0
                    || self.autoExpandsForActivity
            }
        }

        claudeWatcher.onStatuses = { [weak self] statuses in
            guard let self else { return }
            self.claudeStatuses = statuses
            // Selection reads the registry's `status` and session ids, which
            // the CLI rewrites in place where the registry's watch can't see
            // it. Re-read it now: a snapshot left at `idle` from before the
            // prompt makes `reconciled` retire a turn that is still running,
            // and one holding an outdated session id would filter the live
            // session out.
            // (A change publishes through `onSessions`, which re-selects; the
            // apply below is then a no-op.)
            self.sessionRegistry.refresh()
            self.applyClaudeStatus(self.selectStatus(from: statuses))
            self.updateKeepAwake()
        }

        requestWatcher.onRequests = { [weak self] requests in
            guard let self else { return }
            self.claudeRequests = requests
            self.refreshPendingRequest()
            // A request that disappears with no status write behind it is a
            // hook Claude Code cancelled — Esc on its prompt. Re-select so an
            // interrupted prompt stops asking (see `reconciledPrompt`); the
            // reselect timer catches it if the transcript marker lands after
            // this.
            self.sessionRegistry.refresh()
            self.applyClaudeStatus(self.selectStatus(from: self.claudeStatuses))
        }

        sessionRegistry.onSessions = { [weak self] sessions in
            guard let self else { return }
            self.claudeSessions = sessions
            // A session dropping out of the registry is dead for real — its pid
            // is gone. A clean exit removes its status file too, but a SIGKILL
            // fires no SessionEnd, so the file lingers and no status event will
            // ever arrive. Re-running selection here is what retires it.
            self.applyClaudeStatus(self.selectStatus(from: self.claudeStatuses))
            self.updateKeepAwake()
        }

        power.onEvent = { [weak self] toast in
            self?.enqueueToast(toast)
        }

        // Plugging in is the one moment a flat pair of headphones is worth
        // mentioning unprompted — you are sitting down to charge things.
        // Peripheral levels can't be watched (only read, at the cost of a
        // subprocess), so this is the cue to go and look.
        power.onPluggedIn = { [weak self] in
            guard let self, self.settings.showDeviceBattery else { return }
            self.bluetoothBattery.refreshLowDevices()
        }

        bluetoothBattery.onDeviceConnected = { [weak self] device in
            self?.enqueueToast(.device(device))
        }

        bluetoothBattery.onLowDevice = { [weak self] device in
            self?.enqueueToast(.device(device))
        }

        agenda.onEvent = { [weak self] toast in
            self?.enqueueToast(toast)
        }

        agenda.onAgendaChanged = { [weak self] items in
            guard let self, self.agendaItems != items else { return }
            self.agendaItems = items
        }

        // The tap only earns its keep while something is playing. Paused, the
        // bars rest at zero whether or not anything is listening, so the
        // capture is told to stand down — see `SystemAudioLevels.setPlaybackPaused`
        // for what that saves. `hasTrack` is folded in so "nothing playing at
        // all" counts as paused too.
        $media
            .map { $0.isPlaying && $0.hasTrack }
            .removeDuplicates()
            .sink { [weak self] playing in
                self?.audio.setPlaybackPaused(!playing)
            }
            .store(in: &cancellables)

        // Re-render notch views on any settings change (waveform/scrubber
        // toggles etc.), since those views observe this view model, not
        // AppSettings directly. Mode changes are handled separately below so
        // they also restart subsystems.
        self.settings.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // React to a live mode change (Settings — Milestone 6): start or
        // stop the affected subsystems and re-derive the collapsed layout.
        self.settings.$mode
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.isRunning else { return }
                self.applyMode()
                self.objectWillChange.send()
            }
            .store(in: &cancellables)

        // The power and agenda toggles start and stop their own monitors, the
        // same way mode does — turning the feature off should stop watching
        // IOKit, Bluetooth or EventKit, not just hide the toasts. The waveform
        // source rides the same path: leaving Live tears the tap down,
        // returning to it builds one (and, first time, asks).
        Publishers.MergeMany(
            self.settings.$showBatteryEvents.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            self.settings.$showDeviceBattery.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            self.settings.$showCalendarEvents.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            self.settings.$showReminders.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            self.settings.$eventLeadMinutes.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            self.settings.$waveformSource.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            self.settings.$keepAwakeWhileWorking.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            // Puts down or picks up `run/answering`. Off releases every hook
            // that is waiting on the notch, back to its terminal prompt.
            self.settings.$answerFromNotch.dropFirst().map { _ in () }.eraseToAnyPublisher()
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] in
            guard let self, self.isRunning else { return }
            self.applyMode()
        }
        .store(in: &cancellables)

        // The lyric line reads the same anchored clock the scrubber does.
        lyricsClock.position = { [weak self] in
            guard let self else { return (0, 0) }
            return (self.projectedElapsed(at: Date()), self.anchorRate)
        }

        // On: look the current track up now rather than at the next track
        // change. Off: drop what's held and cancel what's in flight.
        self.settings.$syncedLyrics
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.syncLyrics(to: self.media)
            }
            .store(in: &cancellables)
    }

    func start() {
        isRunning = true
        observeDisplayState()
        applyMode()
    }

    /// The termination path: stop everything, then give the audio teardown a
    /// bounded moment to land before the process exits. See
    /// `SystemAudioLevels.awaitTeardown`.
    func shutdown() {
        stop()
        audio.awaitTeardown()
    }

    func stop() {
        isRunning = false
        setAudioRunning(false)
        setMediaRunning(false)
        setClaudeRunning(false)
        setPowerRunning(battery: false, devices: false)
        agenda.configure(events: false, reminders: false, leadMinutes: settings.eventLeadMinutes)
        for (center, token) in displayObservers { center.removeObserver(token) }
        displayObservers.removeAll()
    }

    /// Brings the running subsystems in line with the active mode, and with
    /// whether there's a display awake to show any of it on.
    private func applyMode() {
        let media = settings.effectiveMode.showsMusic && !displayAsleep
        setMediaRunning(media)
        setAudioRunning(media && settings.waveformSource.capturesAudio)
        setClaudeRunning(settings.effectiveMode.showsClaude)
        updateKeepAwake()
        updateAnsweringMarker()
        // Power is ambient — it runs in every mode, gated only by its own two
        // toggles. Suppressed while the display is off for the same reason the
        // media pipeline is: nothing it produces could be seen.
        setPowerRunning(battery: settings.showBatteryEvents && !displayAsleep,
                        devices: settings.showDeviceBattery && !displayAsleep)
        // Ambient in the same way. Also stood down while the display is off:
        // a "Standup · in 5 min" that fires into a dark screen would be found
        // on wake as a stale claim, and the monitor drops those anyway.
        agenda.configure(events: settings.showCalendarEvents && !displayAsleep,
                         reminders: settings.showReminders && !displayAsleep,
                         leadMinutes: settings.eventLeadMinutes)

        // Anything already on screen that the user has just switched off
        // shouldn't sit out the rest of its four seconds.
        if let toast = activeToast, !allows(toast.gate) {
            clearToasts()
        }
    }

    /// Whether a message's governing switch is on. Each source answers to its
    /// own toggle — the Mac's battery and a peripheral's are separate
    /// questions about separate hardware, and the calendar and reminders are
    /// separate permissions.
    private func allows(_ gate: IslandToast.Gate) -> Bool {
        switch gate {
        case .macBattery: return settings.showBatteryEvents
        case .deviceBattery: return settings.showDeviceBattery
        case .calendar: return settings.showCalendarEvents
        case .reminders: return settings.showReminders
        }
    }

    // MARK: - Display sleep

    /// The screen is off or locked, so nothing the media pipeline produces can
    /// be seen.
    ///
    /// Worth gating on because the expensive half of that pipeline doesn't stop
    /// by itself. The marker's animation does — it's driven off the display,
    /// which isn't ticking — but audio capture is not: the tap keeps running,
    /// the FFT keeps running ~94 times a second, and the levels keep publishing
    /// at 30Hz, all to move a waveform on a dark screen. Music playing with the
    /// lid shut is the normal case for this, not an edge case.
    ///
    /// Note that occlusion is deliberately *not* part of this. The notch window
    /// is `.fullScreenAuxiliary` and sits above the menu bar, so it stays up over
    /// full-screen apps and is never covered — there is no occluded state to
    /// react to.
    private var displayAsleep = false

    private var displayObservers: [(NotificationCenter, NSObjectProtocol)] = []

    /// Sleep and lock are watched separately because they're genuinely different
    /// events: locking the screen doesn't put the display to sleep, and the
    /// display sleeping doesn't lock. Either one means nobody can see the notch.
    private func observeDisplayState() {
        guard displayObservers.isEmpty else { return }

        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()

        func observe(_ center: NotificationCenter, _ name: Notification.Name, asleep: Bool) {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.setDisplayAsleep(asleep) }
            }
            displayObservers.append((center, token))
        }

        observe(workspace, NSWorkspace.screensDidSleepNotification, asleep: true)
        observe(workspace, NSWorkspace.screensDidWakeNotification, asleep: false)
        observe(distributed, Notification.Name("com.apple.screenIsLocked"), asleep: true)
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked"), asleep: false)
    }

    private func setDisplayAsleep(_ asleep: Bool) {
        guard asleep != displayAsleep else { return }
        displayAsleep = asleep
        guard isRunning else { return }
        applyMode()
    }

    private func setMediaRunning(_ running: Bool) {
        guard running != mediaRunning else { return }
        mediaRunning = running
        if running {
            adapter.start()
            players.forEach { $0.start() }
        } else {
            adapter.stop()
            players.forEach { $0.stop() }
        }
    }

    /// The audio tap runs on its own switch, apart from the rest of the media
    /// pipeline: it is the one piece that costs a permission prompt. Only the
    /// `.live` waveform asks for it — `.animated` and `.off` never build a
    /// tap, so macOS never asks, which is the whole point of those choices.
    private func setAudioRunning(_ running: Bool) {
        guard running != audioRunning else { return }
        audioRunning = running
        running ? audio.start() : audio.stop()
    }

    private func setClaudeRunning(_ running: Bool) {
        guard running != claudeRunning else { return }
        claudeRunning = running
        if running {
            claudeWatcher.start()
            requestWatcher.start()
            sessionRegistry.start()
        } else {
            claudeWatcher.stop()
            requestWatcher.stop()
            sessionRegistry.stop()
            // Not watching means nothing to back the claim with.
            keepAwake.release()
            publishKeepAwake()
            liveSessionStates = [:]
            otherSessions = ClaudeOtherSessions()
            claudeSessions = []
            claudeStatuses = []
            claudeRequests = []
            claudeRequestId = nil
            pendingRequest = nil
            answeredRequestId = nil
            lastAppliedStatus = nil
            doneRevertTask?.cancel()
            doneRevertTask = nil
            stopWorkingWords()
            stopReselectTimer()
            claudeState = .disconnected
            claudeProject = nil
            claudeSessionId = nil
            claudeAction = nil
            claudeTarget = nil
            claudeErrorType = nil
            claudeResetAt = nil
            claudeUpdatedAt = nil
        }
        updateAnsweringMarker()
    }

    /// Puts `run/answering` down exactly while the Claude bridge is running
    /// with "Answer from the notch" on, and picks it up otherwise — so a hook
    /// only ever blocks when there is a notch on screen that can answer it.
    /// Hiding the notch, a mode without Claude, and quitting all stop the
    /// bridge, and with it every wait.
    private func updateAnsweringMarker() {
        let answering = claudeRunning && settings.answerFromNotch
        guard answering != answeringMarkerWritten else { return }
        answeringMarkerWritten = answering
        if answering {
            ClaudeAnsweringMarker.write()
        } else {
            ClaudeAnsweringMarker.remove()
        }
    }

    /// Starts or stops each power monitor from its own switch.
    ///
    /// A switch that is off stops the watching, not just the drawing: there is
    /// no point paying for a signal whose only purpose is a message the user
    /// has said they don't want. Off means Isle isn't looking.
    ///
    /// That has one honest consequence worth knowing. The peripheral check on
    /// plug-in is cued by `PowerMonitor` — the charger event *is* the cue — so
    /// with battery updates off, device updates are connect-driven only. The
    /// alternative was keeping IOKit watched purely to serve the other switch,
    /// which is exactly the cost this is meant to avoid.
    private func setPowerRunning(battery: Bool, devices: Bool) {
        if battery != powerRunning {
            powerRunning = battery
            battery ? power.start() : power.stop()
        }

        if devices != deviceBatteryRunning {
            deviceBatteryRunning = devices
            devices ? bluetoothBattery.start() : bluetoothBattery.stop()
        }
    }

    /// The record most recently put through `applyClaudeStatus`, so a re-run
    /// of selection that lands on the same record is a no-op.
    ///
    /// Selection re-runs on every registry event, and the registry is
    /// rewritten whenever any session's CLI status changes — so without this
    /// an unchanged `done` record was re-applied on each of those, which
    /// restarted its revert timer, reset the "… ago" clock, and — once the
    /// checkmark had already eased back to idle — put it back on the island as
    /// if the turn had just finished again. Compared as a whole record: a
    /// genuine re-write carries a fresh `updatedAt` and still gets through.
    private var lastAppliedStatus: ClaudeStatus?

    /// Applies a fresh status from the watcher. Keeps the `done` checkmark on
    /// screen briefly, then eases it back to `idle` so it behaves like a toast.
    private func applyClaudeStatus(_ status: ClaudeStatus) {
        guard status != lastAppliedStatus else { return }
        lastAppliedStatus = status

        doneRevertTask?.cancel()
        doneRevertTask = nil

        // The glyph's cross-fade between states (BreathingShapeView ->
        // CheckmarkBurstView and back) rides `.animation(value:)` inside
        // ClaudeStatusGlyphView, but that only fires for changes made in a
        // SwiftUI transaction. This assignment comes from the watcher's async
        // callback, so wrap it explicitly — see the note in
        // ClaudeStatusGlyphView.swift.
        // Re-arm the dismiss state whenever the actual state changes, so a fresh
        // alert opens even if the previous one was dismissed — but a re-write of
        // the same state (e.g. a still-pending approval) stays dismissed.
        if status.state != claudeState {
            alertDismissed = false
            alertWasHovered = false
            // Re-arm the Claude-tab auto-jump: a fresh interrupt gets to grab
            // the tab once again, even if the user overrode the previous one.
            tabOverriddenDuringAlert = false
            playSound(for: status.state, errorType: status.errorType)
        }
        withAnimation(.easeInOut(duration: 0.25)) {
            claudeState = status.state
        }
        claudeProject = status.project
        claudeSessionId = status.sessionId
        claudeAction = status.action
        claudeTarget = status.target
        claudeErrorType = status.errorType
        claudeToolActive = status.toolActive
        claudeResetAt = status.resetAt
        claudeUpdatedAt = status.state == .disconnected ? nil : Date()
        claudeRequestId = status.requestId
        refreshPendingRequest()
        // The island may have moved to another session; the count leaves out
        // whichever one it now shows.
        updateOtherSessions()

        // Rotate the "thinking" word only while actually working.
        if status.state == .working {
            startWorkingWords()
        } else {
            stopWorkingWords()
        }
        updateReselectTimer(for: status.state)

        // `done` and `failed` are both terminal toasts: show them, then ease
        // back to idle so they don't stick until the next prompt. A failure
        // lingers a little longer since it's easier to miss and worth reading.
        let revertDelay: TimeInterval
        switch status.state {
        case .done: revertDelay = settings.doneToastSeconds
        case .failed:
            if status.errorType == "usage_limit" {
                // The usage/subscription limit is pinned, not a transient toast:
                // it stays on the island until it resets. When the reset moment is
                // known, ease back to idle exactly then (clearing at once if it's
                // already past); when it isn't, leave it pinned with no timer —
                // the next real session activity replaces it.
                guard let reset = status.resetAt else { return }
                revertDelay = max(0, reset.timeIntervalSinceNow)
            } else {
                revertDelay = max(settings.doneToastSeconds, 6)
            }
        case .needsQuestion:
            // A question is answered in the terminal, and nothing clears it if
            // you decline or ignore it (Claude Code fires no hook for a declined
            // tool). So ease it back to idle after a spell rather than letting
            // "Question" wedge the island until the next prompt. Held while
            // a hook is still waiting on the notch — see `scheduleIdleRevert`.
            revertDelay = Self.questionRevertSeconds
        case .compacting:
            // Only PreCompact fires — a cancelled compaction sends no follow-up,
            // so ease back to idle rather than animating forever. A finished
            // compaction is usually cleared sooner by the next real event.
            revertDelay = Self.compactingRevertSeconds
        default: return
        }
        scheduleIdleRevert(after: revertDelay)
    }

    /// Eases the island back to idle after `delay`, unless something else
    /// arrives first (any new status cancels it).
    ///
    /// Never while a request is pending: a question the notch is offering is
    /// not an abandoned one, however long it has been up. The revert then
    /// stands down, and `refreshPendingRequest` re-arms it once the request
    /// goes away.
    private func scheduleIdleRevert(after delay: TimeInterval) {
        doneRevertTask?.cancel()
        doneRevertTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            guard self.pendingRequest == nil else {
                self.doneRevertTask = nil
                return
            }
            // Idle is quiescent — nothing left to re-select for, unless a
            // background session is holding the Mac awake.
            self.updateReselectTimer(for: .idle)
            withAnimation(.easeInOut(duration: 0.25)) {
                self.claudeState = .idle
            }
        }
    }

    /// The chime for a state the user asked to hear about. Only called on a
    /// genuine state change, so a still-pending approval being re-written
    /// doesn't ring again, and a `done` that eased back to idle and is then
    /// re-selected rings only if the turn genuinely finished again (the
    /// `lastAppliedStatus` guard above handles the re-selection case).
    ///
    /// A usage-limit failure is deliberately silent: it is pinned for as
    /// long as hours, and there is nothing to do about it but wait.
    private func playSound(for state: ClaudeCodeState, errorType: String?) {
        switch state {
        case .needsApproval, .needsQuestion:
            guard settings.claudeAlertSoundEnabled else { return }
            settings.claudeAlertSound.play()
        case .failed:
            guard settings.claudeAlertSoundEnabled, errorType != "usage_limit" else { return }
            settings.claudeAlertSound.play()
        case .done:
            guard settings.claudeDoneSoundEnabled else { return }
            settings.claudeDoneSound.play()
        default:
            return
        }
    }

    /// Picks which source drives the notch, which player the island is routed
    /// to, and feeds the result through `apply`.
    ///
    /// Prefer the adapter whenever it carries a supported player's track (that
    /// player owns the system session); otherwise fall back to a poll — see
    /// `fallbackPollModel` for which. The equality guard matters: without it,
    /// a 1 Hz poll tick would re-apply an unchanged adapter model and yank the
    /// scrubber back to that model's now-stale elapsed time every second.
    private func recomputeSource() {
        var effective = adapterModel.hasTrack
            ? adapterModel
            : (fallbackPollModel() ?? MediaPlaybackModel())

        // The AppleScript poll reads the player's *true* position, which the
        // adapter's cached elapsed lags after a seek/restart (MediaRemote
        // catches up on its own schedule). The poll is the ground truth for
        // the clock, so let it drive the timing fields while the adapter still
        // supplies metadata and byte artwork. Without this, a stale adapter
        // position snaps the bar back over a fresh seek; apply()'s drift
        // easing absorbs the steady 1 Hz corrections so this doesn't
        // reintroduce jitter, and a restart self-corrects within ~1s. Keyed by
        // the track's owner, so Music's poll can never time Spotify's track.
        if let poll = pollModels[effective.bundleIdentifier], poll.hasTrack,
           poll.title == effective.title, poll.album == effective.album {
            effective.reportedElapsed = poll.reportedElapsed
            effective.timestamp = poll.timestamp
            effective.isPlaying = poll.isPlaying
            effective.playbackRate = poll.playbackRate
            // Shuffle/repeat come from the poll too: the MediaRemote adapter
            // doesn't report them for Spotify (they're absent from its payload),
            // so without this the toggles would read permanently off and never
            // light up even when the player has them on.
            effective.isShuffled = poll.isShuffled
            effective.repeatMode = poll.repeatMode
        }

        holdOptimisticTransport(&effective)

        // Route to whoever owns the track on screen. The waveform's tap
        // follows: it is bound to one process, and it must be this one.
        routedPlayerID = effective.hasTrack ? effective.bundleIdentifier : nil
        if let routedPlayerID {
            lastActivePlayerID = routedPlayerID
            audio.setTarget(routedPlayerID)
        }
        // With the adapter silent, the routed poll's model — and so its cover —
        // is the one on screen. Any cover it held back while the adapter was
        // supplying one, or while another player was routed, is fetched now.
        if !adapterModel.hasTrack {
            routedPlayer?.fetchArtworkIfNeeded()
        }

        guard effective != lastApplied else { return }
        lastApplied = effective
        apply(effective)
    }

    /// Which poll drives the island when the adapter is silent: the player
    /// that's playing; failing that, the one the island was already on; and on
    /// a cold start with two paused players, the first in `players` order —
    /// Spotify, the behaviour Isle has always had. Nil when no player has a
    /// track.
    private func fallbackPollModel() -> MediaPlaybackModel? {
        let candidates = players.compactMap { pollModels[$0.bundleID] }.filter(\.hasTrack)
        return candidates.first(where: \.isPlaying)
            ?? candidates.first(where: { $0.bundleIdentifier == lastActivePlayerID })
            ?? candidates.first
    }

    /// Keeps the user's last play/pause or seek in place until a source agrees
    /// (or the grace window passes), so a stale poll can't undo it.
    private func holdOptimisticTransport(_ model: inout MediaPlaybackModel) {
        let now = Date()
        let expired = now >= pendingCommandDeadline

        if let want = pendingPlayState {
            if model.isPlaying == want || expired {
                pendingPlayState = nil            // confirmed, or gave up
            } else {
                model.isPlaying = want
                model.playbackRate = want ? 1 : 0
            }
        }

        if let target = pendingSeekTarget {
            // Landed once the source reports within a couple seconds of the seek.
            if abs(model.elapsed(at: now) - target) < 2.0 || expired {
                pendingSeekTarget = nil
            } else {
                model.reportedElapsed = target
                model.timestamp = now
            }
        }

        if let want = pendingShuffle {
            if model.isShuffled == want || expired {
                pendingShuffle = nil            // confirmed, or gave up
            } else {
                model.isShuffled = want
            }
        }

        if let want = pendingRepeat {
            if model.repeatMode == want || expired {
                pendingRepeat = nil
            } else {
                model.repeatMode = want
            }
        }
    }

    // MARK: - Haptics

    private var lastHapticDate: Date = .distantPast

    /// One tick per open/close, throttled.
    ///
    /// Expanding changes the notch's shape, which changes its hit-test region,
    /// which can hand back a fresh hover event — so a single deliberate open
    /// could emit a burst of ticks that felt like a drum roll. The throttle
    /// collapses any such burst into the one click the gesture deserves.
    func playTransitionHaptic() {
        guard settings.haptics else { return }
        let now = Date()
        guard now.timeIntervalSince(lastHapticDate) > 0.35 else { return }
        lastHapticDate = now
        NSHapticFeedbackManager.defaultPerformer.perform(
            .levelChange,
            performanceTime: .now
        )
    }

    // MARK: - Playback clock

    // The scrubber runs off its own anchor rather than off whatever the
    // adapter last reported.
    //
    // The adapter re-reports elapsed time about once a second, and each report
    // is quantised to the source app's own update granularity. Anchoring
    // directly to it meant the extrapolated position was yanked back into line
    // every second — small, but a visible stutter on a bar that's otherwise
    // moving continuously. Here a report only moves the anchor outright when
    // it disagrees materially (a seek, a track change, a play/pause); ordinary
    // sub-second disagreement is absorbed a fraction at a time, so the bar
    // stays monotonic and the correction is invisible.
    private var anchorElapsed: TimeInterval = 0
    private var anchorDate: Date?
    private var anchorRate: Double = 0

    /// How much of a small disagreement to absorb per report. Low enough to be
    /// imperceptible, high enough to converge within a couple of seconds.
    private static let driftCorrection: Double = 0.18

    /// Beyond this many seconds of disagreement, assume it's a real jump
    /// (seek, track change) and snap rather than easing.
    private static let snapThreshold: TimeInterval = 1.5

    private func apply(_ model: MediaPlaybackModel) {
        var model = model
        let now = Date()
        let reported = model.elapsed(at: now)

        let isNewTrack = model.title != media.title || model.album != media.album
        let transportChanged = model.isPlaying != media.isPlaying
            || model.playbackRate != anchorRate

        // Same track, no cover: keep the one on screen. The sources swap when
        // a browser takes the now-playing session — the adapter drops out and
        // the poll takes over — and the poll's model arrives before its cover
        // does (the download is deferred until it's needed; see
        // `SpotifyController.wantsArtwork`). Without this the island showed
        // the gradient for the fraction of a second in between, for a track
        // that hadn't changed.
        if model.artwork == nil, !isNewTrack {
            model.artwork = media.artwork
        }

        if anchorDate == nil || isNewTrack || transportChanged {
            anchorElapsed = reported
        } else {
            let predicted = projectedElapsed(at: now)
            let disagreement = reported - predicted
            anchorElapsed = abs(disagreement) > Self.snapThreshold
                ? reported
                : predicted + disagreement * Self.driftCorrection
        }

        anchorDate = now
        anchorRate = model.playbackRate

        // Reference identity, not image equality: the sources hand over a new
        // NSImage only when they actually fetched or decoded one, so this is
        // exactly the question of whether the cover changed.
        if model.artwork !== paletteArtwork {
            paletteArtwork = model.artwork
            // nil artwork leaves this nil rather than storing `.fallback`, so
            // `palette` can hand over to the accent instead of the greys.
            artworkPalette = model.artwork.map { ArtworkColors.palette(from: $0) }
        }

        // The anchor above is the only thing that needs the timing fields, and
        // it has them now. Publish only when something a view draws has
        // changed — otherwise every 1 Hz poll re-evaluated the whole notch
        // (shape, glyph, equalizer bridge, palette) to redraw nothing.
        //
        // The lyrics follow either way — the anchor may have moved even when
        // nothing drawn did — and last, so they read the model just applied.
        defer { syncLyrics(to: model) }
        guard !model.hasSameDisplay(as: media) else { return }
        media = model
    }

    /// Elapsed position extrapolated from the anchor, clamped to the track.
    private func projectedElapsed(at date: Date) -> TimeInterval {
        guard let anchorDate else { return 0 }
        let raw = anchorElapsed + date.timeIntervalSince(anchorDate) * anchorRate
        guard media.duration > 0 else { return max(0, raw) }
        return min(max(0, raw), media.duration)
    }

    // MARK: - Lyrics

    // Synced lyrics, from LRCLIB, for the music face. Off unless the user
    // turned them on; on, a track is looked up once — when it is first seen
    // playing with a known length — and the answer, lyrics or none, holds
    // until the track changes. No polling, no retry beyond the library's own
    // single one for a busy server: a track that found nothing shows nothing.

    /// The track the lyrics state below belongs to, as title/artist/album.
    private var lyricsTrack: String?
    /// Whether that track has been asked about yet.
    private var lyricsRequested = false
    private var lyricsTask: Task<Void, Never>?

    /// Whether the music face holds a place for the lyric line: lyrics are
    /// on and this track has synced lyrics. True for the whole track, intro
    /// and gaps included, so nothing on the face moves as lines come and go —
    /// a line turns over in a place that is already there. Changes at most
    /// twice a track: when the lookup answers, and when the track ends.
    var showsLyrics: Bool {
        settings.syncedLyrics && media.hasTrack && lyrics != nil
    }

    /// Brings the lyrics in line with `model`: drops them on a track change,
    /// starts the one lookup a track gets, and re-times the line against the
    /// anchor, which every caller has just moved.
    private func syncLyrics(to model: MediaPlaybackModel) {
        defer { lyricsClock.resync() }

        guard settings.syncedLyrics, model.hasTrack else {
            clearLyrics()
            return
        }

        let track = [model.title, model.artist, model.album].joined(separator: "\n")
        if track != lyricsTrack {
            clearLyrics()
            lyricsTrack = track
        }

        // Nothing is sent for a track that's only sitting paused in a player,
        // and without a length there's no telling one version from another.
        guard !lyricsRequested, model.isPlaying, model.duration > 0 else { return }
        lyricsRequested = true

        let query = LyricsQuery(
            title: model.title,
            artist: model.artist,
            album: model.album,
            duration: model.duration
        )
        let library = lyricsLibrary
        lyricsTask = Task { [weak self] in
            let found = await library.lyrics(for: query)
            // Dropped if the track moved on, or lyrics were switched off,
            // while this was in flight.
            guard let self, !Task.isCancelled, self.lyricsTrack == track else { return }
            self.lyrics = found
            self.lyricsClock.lyrics = found
        }
    }

    private func clearLyrics() {
        lyricsTask?.cancel()
        lyricsTask = nil
        lyricsTrack = nil
        lyricsRequested = false
        if lyrics != nil { lyrics = nil }
        lyricsClock.lyrics = nil
    }

    // MARK: - Derived state

    /// Whether Claude Code warrants opening the notch on its own.
    ///
    /// Only `needsApproval` interrupts. `working` and `done` are ambient —
    /// they show in the collapsed glyph but must not pop the panel open, or
    /// the notch would flap open on every tool call. Suppressed entirely when
    /// the active mode doesn't show Claude.
    var hasLiveActivity: Bool {
        // Approvals/questions interrupt; a transient failure also pops the panel
        // so the stopped turn is noticed (it auto-reverts to idle — see
        // applyClaudeStatus). The usage limit is the exception: it's pinned
        // ambient info, shown in the island but never taking over the panel, so
        // it doesn't sit maximized for however long the limit lasts.
        guard settings.effectiveMode.showsClaude else { return false }
        if claudeState.isAttention { return true }
        return claudeState == .failed && !isUsageLimit
    }

    /// The current failure is the Claude usage/subscription limit (pinned, resets
    /// on a schedule) rather than a transient API error.
    var isUsageLimit: Bool {
        claudeState == .failed && claudeErrorType == "usage_limit"
    }

    /// A live activity takes over the panel only when the user hasn't chosen to
    /// receive alerts minimized. When off, the alert still shows in the collapsed
    /// island (glyph/label) and the user expands on hover — it just doesn't pop
    /// open on its own. `hasLiveActivity` itself stays true so a manual expand
    /// still lands on the Claude tab (see `expandedTab`).
    /// Internal rather than private: `IslandPresentation.state` crosses it with
    /// that island's own hover.
    var autoExpandsForActivity: Bool {
        hasLiveActivity && settings.expandOnAlert && !alertDismissed
    }

    /// An island was hovered while this alert was live — a prerequisite for
    /// hover-away to count as a dismiss, so an untouched auto-open isn't
    /// dismissed by a stray move nearby. Called by `IslandPresentation`.
    func noteAlertVisited() {
        if hasLiveActivity { alertWasHovered = true }
    }

    /// How many islands the pointer currently holds open. The pointer is only
    /// ever on one screen, so this is 0 or 1 in practice; a count rather than
    /// a flag so two islands changing in the same event can't leave it wrong.
    /// Feeds the player polls' cadence — see `wantsFullRate` in `init`.
    private var hoveredIslands = 0

    /// An island's hover flipped. Called by `IslandPresentation` on every
    /// transition, in both directions.
    func islandHoverChanged(_ hovering: Bool) {
        hoveredIslands = max(0, hoveredIslands + (hovering ? 1 : -1))
        // Opening the panel puts the scrubber on screen: bring the position
        // current now rather than at the next relaxed read. With nothing
        // routed, every player gets asked, so whichever has a track is found.
        if hovering, hoveredIslands == 1 {
            (routedPlayer.map { [$0] } ?? players).forEach { $0.pollNow() }
        }
    }

    /// The pointer left an island. Hovering away from an auto-opened alert the
    /// user has visited retracts the panel (if they allow it); the glyph stays
    /// in the island until the alert resolves.
    ///
    /// Shared across islands on purpose: the alert has been seen and waved off,
    /// and it should not stay open on a screen the user isn't looking at.
    func noteHoveredAway() {
        if hasLiveActivity, alertWasHovered, settings.dismissAlertPanel {
            alertDismissed = true
        }
    }

    /// Retract the current alert's panel now (a click on it). No-op unless an
    /// alert is live and the user allows dismissing; the glyph stays until the
    /// alert resolves. Returns whether it actually dismissed, so the island the
    /// click landed on can drop its hover to match.
    @discardableResult
    func dismissAlert() -> Bool {
        guard hasLiveActivity, settings.dismissAlertPanel else { return false }
        alertDismissed = true
        return true
    }

    // MARK: - Answering from the notch

    /// Re-derives `pendingRequest` from the status's request id and the
    /// requests on disk. Called whenever either side moves.
    private func refreshPendingRequest() {
        let match = claudeRequests.first { request in
            guard request.id == claudeRequestId else { return false }
            // The id is session-scoped already; this just refuses to show one
            // session's request under another's status.
            if let session = request.sessionId, session != claudeSessionId { return false }
            switch request.kind {
            case .approval: return claudeState == .needsApproval
            case .question: return claudeState == .needsQuestion
            }
        }
        guard match != pendingRequest else { return }

        if match?.id != pendingRequest?.id {
            // A different request (or none): start its questions from the top
            // and re-arm the buttons.
            questionIndex = 0
            questionPicks = Array(repeating: [], count: match?.questions.count ?? 0)
            answeredRequestId = nil
        }
        withAnimation(.easeInOut(duration: 0.25)) {
            pendingRequest = match
        }

        // The question went back to the terminal (or was answered) without a
        // status write to restart the clock: let it ease off as any other
        // question would.
        if match == nil, claudeState == .needsQuestion, doneRevertTask == nil {
            scheduleIdleRevert(after: Self.questionRevertSeconds)
        }
    }

    /// A click has been sent for the pending request and is waiting for the
    /// hook to take it.
    var isAnsweringRequest: Bool {
        guard let id = pendingRequest?.id else { return false }
        return answeredRequestId == id
    }

    /// Approve or Deny the pending tool call.
    func decide(allow: Bool) {
        guard let request = pendingRequest, request.kind == .approval, !isAnsweringRequest else { return }
        send(allow ? .allow : .deny, to: request)
    }

    /// The question currently on screen, when a question is pending.
    var currentQuestion: ClaudeQuestion? {
        guard let request = pendingRequest, request.kind == .question,
              request.questions.indices.contains(questionIndex) else { return nil }
        return request.questions[questionIndex]
    }

    /// A tap on an option. Single-select records it and moves on — to the
    /// next question, or, on the last, sends every answer. Multi-select only
    /// toggles; `advanceQuestion` commits it.
    func pickOption(_ label: String) {
        guard let question = currentQuestion, !isAnsweringRequest,
              questionPicks.indices.contains(questionIndex) else { return }
        if question.multiSelect {
            if questionPicks[questionIndex].contains(label) {
                questionPicks[questionIndex].remove(label)
            } else {
                questionPicks[questionIndex].insert(label)
            }
        } else {
            questionPicks[questionIndex] = [label]
            advanceQuestion()
        }
    }

    /// Next / Done: moves past the current question once it has an answer,
    /// and sends them all after the last.
    func advanceQuestion() {
        guard let request = pendingRequest, request.kind == .question, !isAnsweringRequest,
              questionPicks.indices.contains(questionIndex),
              !questionPicks[questionIndex].isEmpty
        else { return }

        if questionIndex + 1 < request.questions.count {
            withAnimation(.easeInOut(duration: 0.2)) { questionIndex += 1 }
            return
        }

        // Keyed by the question text, as Claude Code expects. A multi-select's
        // labels go in the order the options were offered, comma-joined.
        var answers: [String: String] = [:]
        for (index, question) in request.questions.enumerated() {
            let picked = questionPicks[index]
            answers[question.question] = question.options
                .map(\.label)
                .filter { picked.contains($0) }
                .joined(separator: ", ")
        }
        send(.answers(answers), to: request)
    }

    /// Back to the previous question of a multi-question ask.
    func previousQuestion() {
        guard currentQuestion != nil, questionIndex > 0, !isAnsweringRequest else { return }
        withAnimation(.easeInOut(duration: 0.2)) { questionIndex -= 1 }
    }

    /// Answer in terminal: releases the hook with no decision, so Claude shows
    /// its own prompt now rather than at the deadline. For a question that is
    /// the difference between a blank terminal and the question UI.
    func deferToTerminal() {
        guard let request = pendingRequest, !isAnsweringRequest else { return }
        send(.terminal, to: request)
    }

    private func send(_ reply: ClaudeRequestWatcher.Reply, to request: ClaudeRequest) {
        answeredRequestId = request.id
        guard requestWatcher.respond(reply, to: request) else {
            // The hook let go first (its deadline, Esc in the terminal) or the
            // write failed. Claim nothing: re-arm, and re-scan so buttons for a
            // request that is already gone retire now.
            answeredRequestId = nil
            requestWatcher.refresh()
            return
        }
    }

    /// Whether the agenda face is on at all — either switch is enough. The
    /// face shows even when access was declined, so the panel can say so;
    /// hiding it would leave the switch in Settings looking like it did nothing.
    var showsAgenda: Bool {
        settings.showCalendarEvents || settings.showReminders
    }

    /// The two switches individually, for the agenda face's empty-state copy.
    var agendaShowsEvents: Bool { settings.showCalendarEvents }
    var agendaShowsReminders: Bool { settings.showReminders }

    /// The Pomodoro timer is offered — the Settings toggle is on.
    var pomodoroAvailable: Bool { settings.pomodoroEnabled }

    /// The faces the expanded panel can show right now, in switcher order:
    /// whatever the mode brings, then Pomodoro if it's been switched on, then
    /// the agenda if either of its switches is.
    var availableTabs: [IsleTab] {
        var tabs: [IsleTab] = []
        if settings.effectiveMode.showsMusic { tabs.append(.music) }
        if settings.effectiveMode.showsClaude { tabs.append(.claude) }
        if pomodoroAvailable { tabs.append(.pomodoro) }
        if showsAgenda { tabs.append(.agenda) }
        return tabs
    }

    /// Whether the expanded panel shows the switcher — only when there is
    /// more than one face to switch between; a single source is just shown.
    var showsTabBar: Bool {
        availableTabs.count > 1
    }

    /// Whether the switcher is the strip of every face in the housing band
    /// rather than a single toggle in the corner. Two faces flip: the toggle
    /// shows the other face's icon and there is nothing to cycle past. From
    /// three, cycling would make someone pass through a face they didn't
    /// want to reach the one they did, so each gets its own button.
    var showsTabStrip: Bool {
        availableTabs.count > 2
    }

    /// The single toggle is on: exactly two faces — see `showsTabStrip`.
    var showsTabToggle: Bool {
        showsTabBar && !showsTabStrip
    }

    /// The face the single toggle offers: the one after the current, cycling.
    /// With two faces that is simply the other one.
    var nextTab: IsleTab {
        let tabs = availableTabs
        guard let index = tabs.firstIndex(of: expandedTab) else { return tabs.first ?? .music }
        return tabs[(index + 1) % tabs.count]
    }

    /// Which content the expanded panel should render right now. Normally the
    /// user's selected tab, except that a live Claude interrupt (a question /
    /// error) forces the Claude tab — without mutating `activeTab`, so the
    /// user's choice is restored automatically once the alert clears. A
    /// selection that is no longer available (the mode changed, the agenda
    /// or Pomodoro was switched off) falls back to the first face rather than a blank.
    var expandedTab: IsleTab {
        let tabs = availableTabs
        // An alert auto-jumps to Claude, but a manual tab tap during the
        // alert sticks (see `selectTab`) so the user can still look at music.
        if hasLiveActivity, !tabOverriddenDuringAlert, tabs.contains(.claude) {
            return .claude
        }
        if tabs.contains(activeTab) { return activeTab }
        return tabs.first ?? .music
    }

    /// The height the question face wants, while it is the face on screen —
    /// the one case where the panel grows past `expandedSize` (see
    /// `NotchMetrics.questionPanelHeight`). Nil for every other face, which
    /// all keep the standard height. The tallest question of a multi-question
    /// ask sizes it, so stepping through them doesn't bob the panel. Depends
    /// on the description setting (row heights) and on the corner toggle
    /// (which narrows the rows, so a description may wrap sooner).
    var questionContentHeight: CGFloat? {
        guard expandedTab == .claude, let request = pendingRequest, request.kind == .question else {
            return nil
        }
        let clearance = showsTabToggle ? ClaudePanelLayout.toggleClearance : 0
        return request.questions.map {
            ClaudePanelLayout.questionContentHeight(
                $0, descriptions: optionDescriptions, trailingClearance: clearance
            )
        }.max()
    }

    /// How much of each option's description the question face shows.
    var optionDescriptions: OptionDescriptions { settings.optionDescriptions }


    /// A user tap on the Music/Claude switcher. Records the pick and, when an
    /// alert is live, marks it as a manual override so `expandedTab` stops
    /// forcing the Claude tab for the rest of this alert.
    func selectTab(_ tab: IsleTab) {
        if hasLiveActivity { tabOverriddenDuringAlert = true }
        activeTab = tab
        // `activeTab`'s change publishes, but publish explicitly too: if the tap
        // re-selects the already-active tab, only the override flag moved and the
        // view still needs to re-read `expandedTab`.
        objectWillChange.send()
    }

    var hasMusicActivity: Bool {
        settings.effectiveMode.showsMusic && media.hasTrack
    }

    /// Nothing worth showing in the collapsed island — no music, no Claude. In
    /// this state the notch shrinks to the physical cutout so it disappears into
    /// the hardware; it stays hoverable (see NotchWindowController's pointer
    /// backstop), so hovering the notch still reveals it.
    var isCollapsedIdle: Bool {
        !showsToast && !hasMusicActivity && !hasClaudeActivity && !hasPomodoroActivity
    }

    /// The Pomodoro clock has something worth showing in the collapsed island:
    /// it's enabled and has been started (running or paused mid-interval). A
    /// fresh, untouched timer stays off the island — it's reachable from the
    /// expanded panel, and a "25:00" that never moves says nothing.
    var hasPomodoroActivity: Bool {
        pomodoroAvailable && pomodoro.isActive
    }

    /// The collapsed island is showing the timer alone — no music, no Claude —
    /// so it straddles the cutout the way Claude solo does: glyph on the left
    /// in the album's footprint, the clock on the right.
    var isPomodoroSolo: Bool {
        hasPomodoroActivity && !hasMusicActivity && !hasClaudeActivity
    }

    /// Width reserved for the collapsed clock. Measured from a template shaped
    /// by the interval's full length rather than from the live string, so the
    /// slot is fixed for the whole interval and the island never jitters as
    /// the digits count down. Measured in the *monospaced-digit* font the
    /// clock is actually drawn in — its digits are wider than the status
    /// font's, and measuring with the wrong one left the text spilling past
    /// its slot and clipped by the notch outline. Padded by a couple of points
    /// so rounding in either layout can't shave the last digit.
    var pomodoroClockWidth: CGFloat {
        let template: String
        switch pomodoro.phaseDuration {
        case 3600...: template = "0:00:00"
        case 600...: template = "00:00"
        default: template = "0:00"
        }
        return Self.clockTextWidth(template) + 2
    }

    private static let clockFont = NSFont.monospacedDigitSystemFont(
        ofSize: CollapsedSize.statusFontSize, weight: .semibold
    )

    private static var clockWidthCache: [String: CGFloat] = [:]

    private static func clockTextWidth(_ string: String) -> CGFloat {
        if let cached = clockWidthCache[string] { return cached }
        let width = ceil((string as NSString).size(withAttributes: [.font: clockFont]).width)
        clockWidthCache[string] = width
        return width
    }

    /// Claude has something worth showing in the collapsed notch.
    var hasClaudeActivity: Bool {
        settings.effectiveMode.showsClaude
            && claudeState != .disconnected && claudeState != .idle
            // `waiting` is opt-out (settings > Claude Code): when it's off the
            // state is ambient like `idle` — the expanded panel still says
            // "Waiting for you", but the island stays with the music rather
            // than splitting to seat the word. Selection is untouched: waiting
            // already sits in the bottom urgency tier, so a working session
            // elsewhere outranks it either way.
            && (claudeState != .waitingInput || settings.showWaitingStatus)
    }

    /// The collapsed island is showing Claude alone (no music). Drives the
    /// dots-left / status-right layout and the warm thinking/working colouring —
    /// when music shares the island the Claude cluster stays compact on the
    /// right and keeps the artwork tint.
    var isClaudeSolo: Bool {
        hasClaudeActivity && !hasMusicActivity
    }

    /// Status colour for the working phases in the Claude-solo island: the
    /// lighter stop while thinking (no tool yet), the fuller one once a tool is
    /// running. Nil for every other state and layout, so those keep their
    /// marker colour.
    ///
    /// This used to be two literals, `#F2C14E` and `#E8842B`. What they encoded
    /// was never those particular hues but the *relationship* — thinking is the
    /// paler form of working — and that survives any accent, so it now comes
    /// off the palette. Isle keeps the distinction because it is real
    /// information: whether a tool is actually running.
    var workingTint: Color? {
        guard isClaudeSolo, claudeState == .working else { return nil }
        // Full strength for as long as the state stands. It used to fade once
        // hooks had been quiet a while, but hook silence is normal during a
        // long think, so the fade only ever second-guessed a state that was
        // still true.
        let accent = palette
        return isThinking ? accent.accent : accent.primary
    }

    /// Both sources live at once — collapsed view splits (spec 3.1): music keeps
    /// its place on the left, Claude sits on the right. Alerts (approval /
    /// question) stay on Claude's side too rather than taking over the whole
    /// island, so the music isn't displaced.
    var shouldSplitCollapsed: Bool {
        hasMusicActivity && (hasClaudeActivity || hasPomodoroActivity)
    }

    /// The Pomodoro clock is seated on the trailing side beside (or instead
    /// of) the Claude cluster — i.e. it isn't the solo straddle, whose glyph
    /// sits on the left.
    var pomodoroOnTrailingSide: Bool {
        hasPomodoroActivity && !isPomodoroSolo
    }

    /// Content widths either side of the camera cutout in the collapsed notch,
    /// including the small gap that separates each cluster from the camera.
    /// Music (album + waveform) groups on the left, Claude (dots + status text)
    /// on the right. Everything is sized to the actual content — including the
    /// measured width of the status word — so the island grows and shrinks with
    /// what's shown (e.g. "Working" → "Done" narrows it) rather than sitting at
    /// a fixed width. The notch shape is sized and shifted from these — see
    /// NotchRootView.
    var collapsedSideWidths: (leading: CGFloat, trailing: CGFloat) {
        let s = CollapsedSize.self
        let g = s.cutoutGap

        // A toast — power, calendar, reminder — borrows the whole island for
        // its few seconds: the symbol takes the album's footprint on the left,
        // the message sits on the right. Same straddle as the Claude-solo
        // layout, so music and Claude slide back into place when it ends
        // rather than jumping.
        if let toast = activeToast, showsToast {
            return (s.album + g, IslandToast.width(of: toast.text) + g)
        }

        if shouldSplitCollapsed {
            // Music cluster is album + waveform, with the waveform tucked toward
            // the camera so the album sits outboard, clear of the housing. With
            // the waveform off the album is the whole cluster and the island
            // narrows — see `waveSlot`. The other side seats Claude, the timer,
            // or both in that order.
            let leading = s.album + waveSlot + g
            var trailing: CGFloat = 0
            if hasClaudeActivity { trailing += s.dots + statusSlot }
            if pomodoroOnTrailingSide {
                trailing += (trailing > 0 ? s.gap : 0) + pomodoroSlot
            }
            return (leading, trailing + g)
        }
        if hasClaudeActivity {
            // Claude solo: the dot glyph moves to the *left* of the camera and
            // the status word sits on the *right*, so the two straddle the
            // cutout instead of crowding together on one side. The glyph takes
            // the album's footprint (not the smaller split-view dots) so it
            // lands in exactly the spot the album cover occupies in music mode.
            // A running timer follows the word on the right.
            let word = Self.textWidth(collapsedStatusText)
            var trailing = word
            if pomodoroOnTrailingSide {
                trailing += (trailing > 0 ? s.gap : 0) + pomodoroSlot
            }
            return (s.album + g, trailing > 0 ? trailing + g : s.minSide)
        }
        if hasPomodoroActivity {
            // Timer solo: same straddle as Claude solo — the timer glyph in the
            // album's footprint on the left, the clock on the right.
            return (s.album + g, pomodoroClockWidth + g)
        }
        if hasMusicActivity {
            // The waveform's seat on the right is held whether or not the bars
            // are drawn, so the album and the island stay exactly put when the
            // waveform is switched off — see `waveSlot`.
            return (s.album + g, s.wave + g)
        }
        return (s.minSide, s.minSide)   // resting
    }

    /// The waveform's share of the music cluster — the gap plus the bars, or
    /// nothing when the bars are switched off.
    ///
    /// Only the music-solo layout holds the empty seat (see `collapsedSideWidths`),
    /// where album and waveform straddle the camera and the seat is what keeps
    /// the two sides even. In the split layout Claude already sits on the other
    /// side, so an empty seat is just 31pt of dead air between the album and the
    /// housing: it goes back and the island narrows with it.
    private var waveSlot: CGFloat {
        showsWaveform ? CollapsedSize.gap + CollapsedSize.wave : 0
    }

    /// The timer's compact cluster on the trailing side: a small glyph, a gap,
    /// and the clock.
    private var pomodoroSlot: CGFloat {
        CollapsedSize.dots + CollapsedSize.gap + pomodoroClockWidth
    }

    /// Extra trailing width for the status word beside the dots — the gap plus
    /// the word's measured width, or zero when there's no word.
    private var statusSlot: CGFloat {
        let width = Self.textWidth(collapsedStatusText)
        return width > 0 ? CollapsedSize.gap + width : 0
    }

    /// The current tool call as a display model, used by the expanded "what it's
    /// doing" line. Nil until a `PreToolUse` has reported a tool (e.g. right
    /// after a prompt submit, before the first tool runs).
    var claudeActivity: ClaudeActivity? {
        ClaudeActivity(action: claudeAction, target: claudeTarget)
    }

    /// Claude is `working` but not inside a tool call — the reasoning/planning
    /// phase. That's the case right after a prompt (before the first tool) and
    /// for a whole text-only turn, so the island can honestly say "Thinking"
    /// then and "Working" once a tool is actually running. Between tools the
    /// last tool's action lingers (we don't clear it on PostToolUse), so this
    /// deliberately doesn't flip on every tool boundary — that would flap the
    /// collapsed word constantly.
    var isThinking: Bool {
        claudeState == .working && claudeActivity == nil
    }

    /// The word for the collapsed notch. During the no-tool reasoning phase it's
    /// an honest "Thinking"; once a tool is actually running it becomes the same
    /// rotating word the expanded panel shows (`workingWord`) — "Coalescing",
    /// "Percolating", … — so the label stays truthful about the phase while the
    /// working phase still gets the CLI spinner's personality. Deliberately *not*
    /// the per-tool action (that changes every tool call); the rotating word
    /// turns over on a slow 15s timer, so the occasional resize is gentle, not
    /// churn. The expanded view shows the detailed "Editing …" line separately.
    var collapsedStatusText: String {
        switch claudeState {
        case .working:
            // No clock on the working word, in either phase. Hooks are silent
            // through a whole reasoning turn and through a long tool call, so
            // the number was only ever counting normal quiet, and a figure
            // ticking up next to "Coalescing…" reads as a fault when nothing
            // is wrong. Past the staleness threshold the word just dims
            // (`claudeTint`) — the island says nothing it can't back up.
            return (isThinking ? "Thinking" : workingWord) + "…"
        // "Approve" only while a hook is actually waiting on the notch's
        // Approve / Deny; every other prompt — a question, or an approval
        // whose wait has ended and lives on only in the terminal — reads as
        // the one word for "it needs you".
        case .needsApproval, .needsQuestion:
            return pendingRequest?.kind == .approval ? "Approve" : "Question"
        case .waitingInput: return "Waiting"
        case .done: return "Done"
        case .idle: return "Ready"
        // Every failure reads as one thing — a usage limit and a transient API
        // error are indistinguishable to the user, so both just say "Error".
        case .failed: return "Error"
        case .compacting: return "Compacting"
        case .disconnected: return ""
        }
    }

    /// The marker to render for the current Claude state. For a failure this
    /// picks a specific error marker from `error_type` (rate-limit vs server vs
    /// generic) so the glyph itself distinguishes them; otherwise it's the plain
    /// lifecycle marker.
    var claudeMarkerKind: MarkerKind {
        guard claudeState == .failed else { return MarkerKind(state: claudeState) }
        switch claudeErrorType {
        case "usage_limit", "rate_limit", "rate_limit_error", "rate_limited": return .rateLimited
        case "server_error", "api_error", "overloaded", "overloaded_error": return .serverError
        default: return .apiError
        }
    }

    /// Measured widths, kept because this is on the hot path. `collapsedSideWidths`
    /// is read several times per body evaluation (the shape's size, the shift that
    /// re-centres the cutout, the hit rect, and the collapsed layout itself), and
    /// laying out a string to measure it is not cheap — it was the single largest
    /// main-thread cost in the app. The status word comes from a fixed handful
    /// ("Thinking…", "Done", the rotating working words), so the cache stays tiny
    /// and every read after the first is a dictionary hit.
    private static var textWidthCache: [String: CGFloat] = [:]

    /// The font is resolved once for the same reason — `systemFont(ofSize:weight:)`
    /// is a lookup, not a constant.
    private static let statusFont = NSFont.systemFont(
        ofSize: CollapsedSize.statusFontSize, weight: .semibold
    )

    private static func textWidth(_ string: String) -> CGFloat {
        guard !string.isEmpty else { return 0 }
        if let cached = textWidthCache[string] { return cached }
        let width = ceil((string as NSString).size(withAttributes: [.font: statusFont]).width)
        textWidthCache[string] = width
        return width
    }

    // MARK: - Toasts

    /// The momentary message currently on screen, if any. Set only through
    /// `enqueueToast` / `advanceToast` so the timer and the value
    /// can't drift apart.
    @Published private(set) var activeToast: IslandToast?

    /// Toasts waiting their turn. Deliberately shallow: plugging in can
    /// produce a charging toast and then a flat-headphones toast, and that is
    /// about as much as anyone wants to read off a notch in one go.
    private var toastQueue: [IslandToast] = []

    private var toastTask: Task<Void, Never>?

    /// How long each toast holds the island. Matched to the Claude `done`
    /// checkmark's default so the island's two transient messages have the
    /// same rhythm — but a constant, not a setting: `doneToastSeconds` is
    /// tunable because a slow reader wants the checkmark to linger, and this
    /// is the same reading task at the same size.
    private static let toastSeconds: TimeInterval = 4

    private static let toastQueueLimit = 2

    /// Whether the toast should actually be drawn. Separate from
    /// `activeToast != nil` so a Claude alert arriving mid-toast takes the
    /// island back immediately — attention outranks ambient. The toast's timer
    /// keeps running underneath and it simply expires unseen, rather than
    /// being queued to reappear after the alert, which would deliver "Charging
    /// · 42%" minutes after the fact.
    var showsToast: Bool {
        activeToast != nil && !hasLiveActivity
    }

    /// Accepts a toast, or declines it. Dropped rather than queued when a
    /// Claude alert is live — a power event or a meeting reminder is ambient
    /// and stale within seconds, so waiting its turn behind an approval would
    /// make it a lie.
    private func enqueueToast(_ toast: IslandToast) {
        guard allows(toast.gate), !hasLiveActivity else { return }

        // Coalesce: a second event of the same kind replaces the first rather
        // than stacking. A loose MagSafe connector jiggling in and out should
        // leave one current message, not six stale ones.
        if let current = activeToast, current.coalesces(with: toast) {
            showToast(toast)
            return
        }
        toastQueue.removeAll { $0.coalesces(with: toast) }

        guard activeToast != nil else {
            showToast(toast)
            return
        }
        toastQueue.append(toast)
        if toastQueue.count > Self.toastQueueLimit {
            toastQueue.removeFirst()
        }
    }

    /// Puts a toast on screen and restarts the clock. The animation is
    /// explicit because these arrive from IOKit and subprocess callbacks,
    /// outside any SwiftUI transaction.
    private func showToast(_ toast: IslandToast) {
        toastTask?.cancel()
        // Chime as the toast lands, not when it's accepted: a queued toast
        // that rang on arrival and appeared four seconds later would have the
        // sound pointing at the wrong message.
        if settings.agendaSoundEnabled, toast.gate == .calendar || toast.gate == .reminders {
            settings.agendaSound.play()
        }
        withAnimation(.easeInOut(duration: 0.25)) {
            activeToast = toast
        }
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.toastSeconds))
            guard !Task.isCancelled else { return }
            self?.advanceToast()
        }
    }

    /// The current toast's time is up: show the next one, or hand the island
    /// back to music and Claude.
    private func advanceToast() {
        toastTask = nil
        if toastQueue.isEmpty {
            withAnimation(.easeInOut(duration: 0.25)) {
                activeToast = nil
            }
        } else {
            showToast(toastQueue.removeFirst())
        }
    }

    private func clearToasts() {
        toastTask?.cancel()
        toastTask = nil
        toastQueue.removeAll()
        withAnimation(.easeInOut(duration: 0.25)) {
            activeToast = nil
        }
    }

    // MARK: - Transport

    // The routed player handles every command over AppleScript, so controls
    // are live whenever a track is showing, regardless of which app owns the
    // system now-playing session.
    var canControlPlayback: Bool { media.hasTrack && routedPlayer != nil }
    var canSeek: Bool { canControlPlayback && media.duration > 0 }

    /// Shuffle/repeat state for the transport buttons, read from the merged
    /// model so the optimistic hold in `holdOptimisticTransport` shows through.
    var isShuffled: Bool { media.isShuffled }
    var repeatMode: RepeatMode { media.repeatMode }

    func togglePlayPause() {
        guard let player = routedPlayer else { return }
        player.playPause()
        // Optimistic: flip locally so the icon and scrubber react at once
        // rather than waiting up to a second for the next poll to confirm.
        // Re-anchor the clock at the current position with the new rate so
        // the bar stops/resumes from where it visually is.
        let now = Date()
        anchorElapsed = projectedElapsed(at: now)
        anchorDate = now
        media.isPlaying.toggle()
        media.playbackRate = media.isPlaying ? 1 : 0
        anchorRate = media.playbackRate
        lastApplied = media
        // Stops or restarts the lyric timer with the bar — and, for a track
        // that had only sat paused until now, makes its one lookup.
        syncLyrics(to: media)

        // Hold this state until a source confirms it, so the next poll can't
        // flicker it back before the player has processed the command.
        pendingPlayState = media.isPlaying
        pendingCommandDeadline = Date().addingTimeInterval(Self.commandGrace)
    }

    func nextTrack() { routedPlayer?.nextTrack() }
    func previousTrack() { routedPlayer?.previousTrack() }

    /// Toggle shuffle, optimistically, then hold it until a source confirms so a
    /// stale 1 Hz poll can't flicker it back before the player processes the flip.
    func toggleShuffle() {
        guard let player = routedPlayer, canControlPlayback else { return }
        player.toggleShuffle()
        let want = !media.isShuffled
        media.isShuffled = want
        lastApplied = media
        pendingShuffle = want
        pendingCommandDeadline = Date().addingTimeInterval(Self.commandGrace)
    }

    /// Toggle repeat, optimistically. Off ↔ all in both players: Spotify's
    /// AppleScript has no repeat-one at all, and Music's `one` — set in Music
    /// itself, shown here as the lit repeat-1 key — clears to off, which is
    /// what pressing a lit key should do. One control, one meaning.
    func toggleRepeat() {
        guard let player = routedPlayer, canControlPlayback else { return }
        player.toggleRepeat()
        let want: RepeatMode = media.repeatMode == .off ? .all : .off
        media.repeatMode = want
        lastApplied = media
        pendingRepeat = want
        pendingCommandDeadline = Date().addingTimeInterval(Self.commandGrace)
    }

    /// Commits a scrub. Called on drag end, not continuously — seeking on
    /// every drag sample makes the source app stutter.
    func commitScrub() {
        guard let scrubTarget, media.duration > 0, let player = routedPlayer else {
            self.scrubTarget = nil
            return
        }
        let seconds = scrubTarget * media.duration
        player.seek(to: seconds)

        // Optimistically move our own clock, otherwise the thumb snaps back
        // to the old position until the source reports the new one. The
        // anchor has to move too — it's what the scrubber actually renders
        // from, so updating only the model would leave the bar where it was.
        media.reportedElapsed = seconds
        media.timestamp = Date()
        anchorElapsed = seconds
        anchorDate = Date()
        lastApplied = media
        self.scrubTarget = nil
        // The line jumps with the thumb rather than at the next report.
        lyricsClock.resync()

        // Hold the seek target so a stale poll can't snap the bar back to the
        // pre-seek position before Spotify reports the new one.
        pendingSeekTarget = seconds
        pendingCommandDeadline = Date().addingTimeInterval(Self.commandGrace)
    }

    /// Progress to render: the drag target while scrubbing, else the smoothed
    /// playback clock.
    func displayProgress(at date: Date = Date()) -> Double {
        if let scrubTarget { return scrubTarget }
        guard media.duration > 0 else { return 0 }
        return projectedElapsed(at: date) / media.duration
    }
}


#if DEBUG
// MARK: - Preview support

/// Drives the toasts from SwiftUI previews and the debug menu. In this
/// file rather than beside the previews because `activeToast` and
/// `showToast` are private, and Swift's `private` is file-scoped — so an
/// extension here can reach them without widening their access for the app.
extension NotchViewModel {
    /// One of each kind, in the order they read best: the two adapter events
    /// that bracket a charge, the two terminal states, a peripheral, then the
    /// two agenda messages.
    ///
    /// Levels come from the machine the preview is running on rather than from
    /// constants, so the numbers on screen are in the same ballpark as the
    /// menu bar's — a demo that says 89% on a Mac sitting at 100% reads as a
    /// mock-up rather than as the feature. Rounded to the nearest ten, which
    /// is as precise as a glance at a demo needs to be.
    ///
    /// A function rather than a stored value because it samples live state:
    /// held as a `static let` it would freeze whatever the battery happened to
    /// read the first time the preview was built.
    static func previewToasts() -> [IslandToast] {
        let live = PowerMonitor.read()
        let level = live.map { roundedToTen($0.percent) } ?? 80

        // The one level that can't just mirror reality: a low-battery toast
        // fires on crossing a threshold, so on a Mac at 100% the honest
        // preview is what the toast *will* say — 20% — not the current level.
        // On a Mac that really is low, the real number is the accurate one.
        let lowLevel = min(level, 20)

        return [
            .pluggedIn(percent: level, minutesToFull: live?.minutesToFull ?? 80),
            .fullyCharged(),
            .lowBattery(percent: lowLevel),
            .unplugged(percent: level, minutesToEmpty: live?.minutesToEmpty ?? 627),
            .lowPowerMode(on: live?.isLowPowerMode == false, percent: level),
            .device(PeripheralBattery(
                name: "AirPods Pro", address: "A4:F6:E6:76:55:32",
                percent: 12, minorType: "Headphones"
            )),
            .event(
                key: "preview-event", title: "Design review",
                minutesBefore: 5, tint: IslandToast.legible(NSColor.systemBlue.cgColor)
            ),
            .reminder(
                key: "preview-reminder", title: "Call the dentist",
                tint: IslandToast.legible(NSColor.systemOrange.cgColor)
            ),
        ]
    }

    /// Nearest ten, clamped to a real battery's range.
    private static func roundedToTen(_ percent: Int) -> Int {
        min(100, max(0, Int((Double(percent) / 10).rounded()) * 10))
    }

    /// Pins a toast on screen with no timer, so a static preview doesn't empty
    /// itself four seconds after the canvas renders it.
    func pinPreviewToast(_ toast: IslandToast) {
        activeToast = toast
    }

    /// Cycles the full set on a loop, through the real queue and the real
    /// timers. The gap between toasts is deliberate: it's long enough to see
    /// the island hand itself back to whatever was underneath before the next
    /// one claims it, which is the half of the behaviour a still can't show.
    func runPreviewToastLoop() async {
        while !Task.isCancelled {
            for toast in Self.previewToasts() {
                enqueueToast(toast)
                try? await Task.sleep(for: .seconds(5.2))
            }
            try? await Task.sleep(for: .seconds(1.5))
        }
    }
}

/// Puts the Claude face into a fixed state for previews and the offscreen
/// render harness — see `ClaudePanelFixture`. Sets the published values the
/// face reads directly, with no watcher, hook or timer behind them, so a
/// render shows exactly the state described and nothing eases it away.
extension NotchViewModel {
    func applyPreviewFixture(_ fixture: ClaudePanelFixture) {
        claudeState = fixture.state
        claudeProject = fixture.project
        claudeSessionId = fixture.request?.sessionId ?? "preview-session"
        claudeAction = fixture.action
        claudeTarget = fixture.target
        claudeErrorType = fixture.errorType
        claudeResetAt = fixture.resetAt
        claudeUpdatedAt = fixture.state == .disconnected ? nil : fixture.updatedAt
        claudeRequestId = fixture.request?.id
        pendingRequest = fixture.request
        questionIndex = fixture.questionIndex
        questionPicks = fixture.picks.isEmpty
            ? Array(repeating: [], count: fixture.request?.questions.count ?? 0)
            : fixture.picks
        if let word = fixture.workingWord { workingWord = word }
        // The published mirrors only — no assertion is taken for a preview.
        isKeepingAwake = fixture.keepAwake
        otherSessions = fixture.others
        activeTab = .claude
    }
}
#endif
