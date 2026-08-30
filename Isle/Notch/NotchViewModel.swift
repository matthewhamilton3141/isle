//
//  NotchViewModel.swift
//
//  Single observable the notch views read from. Holds the two inputs that
//  can open the notch (pointer hover, Claude Code activity), derives the
//  resolved NotchState from them, and owns the media feed.
//

import SwiftUI
import AppKit
import Combine

/// Element widths for the collapsed notch, shared by the width calculation
/// (NotchViewModel) and the layout (CollapsedNotchView) so they can't drift.
enum CollapsedSize {
    static let album: CGFloat = 22
    static let waveSplit: CGFloat = 22   // waveform when paired with the album
    static let waveSolo: CGFloat = 26    // waveform when it's the only thing
    static let dots: CGFloat = 16
    static let gap: CGFloat = 5          // between elements within a cluster
    static let cutoutGap: CGFloat = 6    // between a cluster and the camera
    static let minSide: CGFloat = 30     // resting half-width when a side is empty
    static let claudeSoloLeading: CGFloat = 14
    static let statusFontSize: CGFloat = 10
}

@MainActor
final class NotchViewModel: ObservableObject {
    /// Pointer is over the notch's hit area. Set only through `setHovering`,
    /// never directly, so the collapse-commit gate can't be bypassed.
    @Published private(set) var isHovering: Bool = false

    /// While true, pointer-driven expansion is refused. Set the instant the
    /// notch starts collapsing and cleared once the close animation has
    /// settled — see `setHovering`.
    private var collapseLocked = false

    /// How long re-expansion stays locked out after a collapse begins. Covers
    /// the close spring (`Animation.notchClose`, response 0.30) so the hover
    /// region has fully shrunk before hover can fire again.
    private static let collapseLockDuration: TimeInterval = 0.32

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

    /// Position the user is dragging the scrubber to. Non-nil only mid-drag;
    /// while set, the scrubber renders this instead of the live position so
    /// the thumb doesn't fight the playback clock under the finger.
    @Published var scrubTarget: Double?

    var metrics: NotchMetrics?

    private let settings: AppSettings
    private let adapter = MediaRemoteAdapterClient()
    private let spotify = SpotifyController()
    private let audio = SystemAudioLevels()
    private let claudeWatcher = ClaudeStatusWatcher()
    private let sessionRegistry = ClaudeSessionRegistry()
    private var cancellables = Set<AnyCancellable>()

    /// True between `start()` and `stop()` — i.e. while the notch window is
    /// shown. Guards the live mode-change subscription so it doesn't spin up
    /// subsystems while the overlay is hidden.
    private var isRunning = false

    /// Whether the media subsystems (adapter, Spotify, audio) are currently
    /// live. Tracked so a mode change only toggles the delta rather than
    /// restarting an already-running capture.
    private var mediaRunning = false

    /// Whether the Claude status watcher is currently live.
    private var claudeRunning = false

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

    // MARK: - Staleness

    /// How long a live state (`working` / `compacting`) may go without a hook
    /// write before the island stops asserting it as fresh. Claude Code fires
    /// nothing while it retries an API error — the "API error · Retrying in 5s"
    /// banner is TUI-only, with no hook and no transcript entry — so silence is
    /// the only signal we get. It's deliberately not read as "stalled": a long
    /// tool-free reasoning turn fires no hooks either and looks identical. The
    /// island just shows how long it's been since anything was confirmed.
    /// 90s is comfortably past a normal tool-call cadence.
    private static let staleAfterSeconds: TimeInterval = 90

    /// How long the transcript may go without growing — while the CLI still
    /// reports the session busy and no tool is running — before the island
    /// stops claiming a live model. Claude Code appends to the transcript per
    /// *content block*, not per message, so an active tool-free turn writes a
    /// line every few to ~15s even though it fires no hooks. Nothing lands at
    /// all while the API is being retried, which is what makes this the signal
    /// that separates "thinking" from "getting nowhere". 45s is several times
    /// the observed block cadence.
    private static let noResponseSeconds: TimeInterval = 45

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
    private func reconciled(_ status: ClaudeStatus) -> ClaudeStatus {
        guard status.state == .working,
              // A tool is mid-flight; the CLI can look idle while it runs.
              !status.toolActive,
              let id = status.sessionId,
              let session = claudeSessions.first(where: { $0.sessionId == id }),
              session.status == .idle,
              // No readable transcript is no second signal — leave the record
              // alone rather than guess.
              let tail = transcriptTail(for: session),
              !tail.awaitingModel
        else {
            return status
        }
        var corrected = status
        corrected.state = .idle
        corrected.action = nil
        corrected.target = nil
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
    @Published private(set) var claudeSessions: [ClaudeSession] = []

    /// The registry record for the session the island is currently showing,
    /// matched by the session id the hook bridge reported.
    var displayedSession: ClaudeSession? {
        guard let id = claudeSessionId else { return nil }
        return claudeSessions.first { $0.sessionId == id }
    }

    /// Seconds since the displayed session's transcript last grew, while it is
    /// busy with no tool running. Zero whenever the question doesn't apply.
    @Published private(set) var claudeNoResponseFor: TimeInterval = 0

    /// The CLI says busy, no tool is running, and nothing has been produced for
    /// a while. Overwhelmingly an API retry or a network stall — but it is an
    /// inference, not a fact, so the island reports the observation ("no
    /// response for 45s") rather than naming a cause, and wears the calm
    /// working treatment rather than the error marker.
    var claudeIsUnresponsive: Bool {
        (claudeState == .working || claudeState == .waitingInput)
            && claudeNoResponseFor >= Self.noResponseSeconds
    }

    /// Seconds since the last hook write, while a live state is showing. Ticks
    /// on a coarse timer — the label it feeds is minute-grained.
    @Published private(set) var claudeSilentFor: TimeInterval = 0

    private var stalenessTimer: Timer?

    /// When the displayed session's transcript last gained a conversation
    /// entry. A recovering turn produces output long before it fires another
    /// hook, so this counts as liveness alongside `claudeUpdatedAt` — otherwise
    /// the island keeps showing a stale "· 3m" after everything is fine again.
    private var claudeLastTranscriptAt: Date?

    /// The island is still claiming Claude is working, but nothing has confirmed
    /// it for a while. Drives the dimmed treatment and the "· 2m" suffix.
    var claudeIsStale: Bool {
        claudeState == .working && claudeSilentFor >= Self.staleAfterSeconds
    }

    /// Runs the staleness clock only for the states that claim work is in
    /// progress; every other state is quiescent and doesn't go stale.
    private func updateStalenessClock(for state: ClaudeCodeState) {
        guard state == .working || state == .compacting || state == .waitingInput else {
            stopStalenessClock()
            return
        }
        claudeSilentFor = 0
        guard stalenessTimer == nil else { return }
        stalenessTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let since = self.claudeUpdatedAt else { return }
                // Runs first: it refreshes `claudeLastTranscriptAt`.
                self.updateNoResponse()
                // The registry's directory event normally re-runs selection on
                // its own, but an interrupt can leave the CLI record untouched
                // (already `idle`), and then nothing else would ever re-examine
                // the stuck record. Re-apply only on a real change, so this
                // can't reset the staleness clock every tick.
                let resolved = self.selectStatus(from: self.claudeStatuses)
                if resolved.state != self.claudeState {
                    self.applyClaudeStatus(resolved)
                    return
                }
                let lastActivity = max(since, self.claudeLastTranscriptAt ?? .distantPast)
                let silent = Date().timeIntervalSince(lastActivity)
                // Only publish when the label would actually change — once on
                // crossing the threshold, then once a minute — so a 5s tick
                // doesn't re-render the island for nothing.
                let wasStale = self.claudeSilentFor >= Self.staleAfterSeconds
                let isStale = silent >= Self.staleAfterSeconds
                let sameMinute = Int(silent) / 60 == Int(self.claudeSilentFor) / 60
                guard wasStale != isStale || (isStale && !sameMinute) else { return }
                withAnimation(.easeInOut(duration: 0.4)) { self.claudeSilentFor = silent }
            }
        }
    }

    /// Measures how long the displayed session has produced nothing, and
    /// publishes it when the answer would change what's on screen.
    ///
    /// Three conditions have to hold before silence means anything. The CLI has
    /// to still call the session busy (otherwise it's simply finished); no tool
    /// may be running (a long Bash is silent on every signal we have); and the
    /// transcript has to have stopped growing (an active tool-free turn still
    /// appends a block every few seconds). Any one of them failing resets the
    /// clock, so this only accumulates in the narrow case it's meant for.
    private func updateNoResponse() {
        guard let session = displayedSession,
              // `waiting` means a dialog is up — genuinely blocked on the user,
              // not stalled. Every other status is fair game: notably the CLI
              // reports a session as *idle* while it backs off between API
              // retries, so this must not gate on `busy`.
              session.status != .waiting,
              !claudeToolActive,
              let tail = transcriptTail(for: session),
              // The turn is outstanding: the last thing written was an input
              // (a prompt, or a tool result) with no model output after it.
              // This is what separates a retry storm from a session sitting
              // idle at the prompt — both are silent, but only one is owed a
              // response.
              tail.awaitingModel
        else {
            claudeLastTranscriptAt = transcriptTail(for: displayedSession).map(\.at)
            if claudeNoResponseFor != 0 {
                withAnimation(.easeInOut(duration: 0.4)) { claudeNoResponseFor = 0 }
            }
            return
        }

        claudeLastTranscriptAt = tail.at
        let quiet = Date().timeIntervalSince(tail.at)
        // Same publish discipline as the staleness clock: once on crossing the
        // threshold, then once a minute.
        let was = claudeNoResponseFor >= Self.noResponseSeconds
        let now = quiet >= Self.noResponseSeconds
        let sameMinute = Int(quiet) / 60 == Int(claudeNoResponseFor) / 60
        guard was != now || (now && !sameMinute) else { return }
        withAnimation(.easeInOut(duration: 0.4)) { claudeNoResponseFor = quiet }
    }

    private func transcriptTail(for session: ClaudeSession?) -> (awaitingModel: Bool, at: Date)? {
        session.flatMap { transcriptTail(for: $0) }
    }

    /// The transcript's last timestamped entry: whether it leaves the model
    /// owing a response, and when it was written.
    ///
    /// Reads only the tail of the file — transcripts run to megabytes and this
    /// is called on a timer. Entries without a timestamp (`file-history-snapshot`
    /// and friends) are skipped rather than treated as the end, since they're
    /// interleaved with the real ones.
    private func transcriptTail(for session: ClaudeSession) -> (awaitingModel: Bool, at: Date)? {
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
            return (awaitingModel: type == "user" && !Self.isInterruption(object), at: at)
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

    private func stopStalenessClock() {
        stalenessTimer?.invalidate()
        stalenessTimer = nil
        claudeSilentFor = 0
        claudeNoResponseFor = 0
    }

    // MARK: - Working words

    /// A rotating "thinking" word shown in the expanded view while working,
    /// echoing the Claude Code CLI's spinner (the real word isn't exposed to
    /// hooks, so this is our own set in the same spirit).
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
        workingWordTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.workingWordIndex = (self.workingWordIndex + 1) % Self.workingWords.count
                withAnimation(.easeInOut(duration: 0.3)) {
                    self.workingWord = Self.workingWords[self.workingWordIndex]
                }
            }
        }
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

    // The two now-playing sources, kept separately and merged in
    // `recomputeSource`. The adapter (MediaRemote) is preferred when Spotify
    // owns the system session — it pushes updates and ships artwork as bytes.
    // The AppleScript poll is the fallback for when something else (a browser
    // tab, say) owns the session, so the notch still shows Spotify.
    private var adapterModel = MediaPlaybackModel()
    private var spotifyModel: MediaPlaybackModel?
    private var lastApplied = MediaPlaybackModel()

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

    /// Live per-band audio magnitudes. Empty when capture isn't running, which
    /// EqualizerView reads as "use the procedural fallback".
    @Published private(set) var audioLevels: [Double] = []

    /// Why audio capture isn't running, if it isn't.
    var audioFailureReason: String? { audio.failureReason }

    // `settings` defaults to the shared instance, resolved inside the
    // main-actor-isolated init body rather than as a default argument — a
    // default-argument reference to a main-actor static is a Swift 6 error.
    init(settings: AppSettings? = nil) {
        let resolvedSettings = settings ?? .shared
        self.settings = resolvedSettings
        self.activeTab = resolvedSettings.lastTab

        adapter.onUpdate = { [weak self] model in
            self?.adapterModel = model
            self?.recomputeSource()
        }
        spotify.onUpdate = { [weak self] model in
            self?.spotifyModel = model
            self?.recomputeSource()
        }

        claudeWatcher.onStatuses = { [weak self] statuses in
            guard let self else { return }
            self.claudeStatuses = statuses
            self.applyClaudeStatus(self.selectStatus(from: statuses))
        }

        sessionRegistry.onSessions = { [weak self] sessions in
            guard let self else { return }
            self.claudeSessions = sessions
            // A session dropping out of the registry is dead for real — its pid
            // is gone. A clean exit removes its status file too, but a SIGKILL
            // fires no SessionEnd, so the file lingers and no status event will
            // ever arrive. Re-running selection here is what retires it.
            self.applyClaudeStatus(self.selectStatus(from: self.claudeStatuses))
        }

        // Re-render notch views on any settings change (waveform/scrubber
        // toggles etc.), since those views observe this view model, not
        // AppSettings directly. Mode changes are handled separately below so
        // they also restart subsystems.
        self.settings.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // Republish rather than exposing `audio` directly: nesting an
        // ObservableObject inside another doesn't propagate to SwiftUI.
        audio.$levels
            .sink { [weak self] levels in
                self?.audioLevels = levels
            }
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
    }

    func start() {
        isRunning = true
        applyMode()
    }

    func stop() {
        isRunning = false
        setMediaRunning(false)
        setClaudeRunning(false)
    }

    /// Brings the running subsystems in line with the active mode.
    private func applyMode() {
        setMediaRunning(settings.effectiveMode.showsMusic)
        setClaudeRunning(settings.effectiveMode.showsClaude)
    }

    private func setMediaRunning(_ running: Bool) {
        guard running != mediaRunning else { return }
        mediaRunning = running
        if running {
            adapter.start()
            spotify.start()
            audio.start()
        } else {
            adapter.stop()
            spotify.stop()
            audio.stop()
        }
    }

    private func setClaudeRunning(_ running: Bool) {
        guard running != claudeRunning else { return }
        claudeRunning = running
        if running {
            claudeWatcher.start()
            sessionRegistry.start()
        } else {
            claudeWatcher.stop()
            sessionRegistry.stop()
            claudeSessions = []
            claudeNoResponseFor = 0
            doneRevertTask?.cancel()
            doneRevertTask = nil
            stopWorkingWords()
            stopStalenessClock()
            claudeState = .disconnected
            claudeProject = nil
            claudeSessionId = nil
            claudeAction = nil
            claudeTarget = nil
            claudeErrorType = nil
            claudeResetAt = nil
            claudeUpdatedAt = nil
        }
    }

    /// Applies a fresh status from the watcher. Keeps the `done` checkmark on
    /// screen briefly, then eases it back to `idle` so it behaves like a toast.
    private func applyClaudeStatus(_ status: ClaudeStatus) {
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

        // Rotate the "thinking" word only while actually working.
        if status.state == .working {
            startWorkingWords()
        } else {
            stopWorkingWords()
        }
        updateStalenessClock(for: status.state)

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
            // "Question" wedge the island until the next prompt.
            revertDelay = Self.questionRevertSeconds
        case .compacting:
            // Only PreCompact fires — a cancelled compaction sends no follow-up,
            // so ease back to idle rather than animating forever. A finished
            // compaction is usually cleared sooner by the next real event.
            revertDelay = Self.compactingRevertSeconds
        default: return
        }
        doneRevertTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(revertDelay))
            guard !Task.isCancelled else { return }
            // Idle is quiescent: stop the clock so a reverted toast can't go on
            // to trip the give-up disconnect.
            self?.stopStalenessClock()
            withAnimation(.easeInOut(duration: 0.25)) {
                self?.claudeState = .idle
            }
        }
    }

    /// Picks which source drives the notch and feeds it through `apply`.
    ///
    /// Prefer the adapter whenever it carries a Spotify track (Spotify owns
    /// the system session); otherwise fall back to the AppleScript poll. The
    /// equality guard matters: without it, a 1 Hz poll tick would re-apply an
    /// unchanged adapter model and yank the scrubber back to that model's
    /// now-stale elapsed time every second.
    private func recomputeSource() {
        var effective = adapterModel.hasTrack
            ? adapterModel
            : (spotifyModel ?? MediaPlaybackModel())

        // The AppleScript poll reads Spotify's *true* player position, which
        // the adapter's cached elapsed lags after a seek/restart (MediaRemote
        // catches up on its own schedule). For a Spotify-scoped app the poll is
        // the ground truth for the clock, so let it drive the timing fields
        // while the adapter still supplies metadata and byte artwork. Without
        // this, a stale adapter position snaps the bar back over a fresh seek;
        // apply()'s drift easing absorbs the steady 1 Hz corrections so this
        // doesn't reintroduce jitter, and a restart self-corrects within ~1s.
        if let poll = spotifyModel, poll.hasTrack,
           poll.title == effective.title, poll.album == effective.album {
            effective.reportedElapsed = poll.reportedElapsed
            effective.timestamp = poll.timestamp
            effective.isPlaying = poll.isPlaying
            effective.playbackRate = poll.playbackRate
            // Shuffle/repeat come from the poll too: the MediaRemote adapter
            // doesn't report them for Spotify (they're absent from its payload),
            // so without this the toggles would read permanently off and never
            // light up even when Spotify has them on.
            effective.isShuffled = poll.isShuffled
            effective.repeatMode = poll.repeatMode
        }

        holdOptimisticTransport(&effective)

        guard effective != lastApplied else { return }
        lastApplied = effective
        apply(effective)
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
        let now = Date()
        let reported = model.elapsed(at: now)

        let isNewTrack = model.title != media.title || model.album != media.album
        let transportChanged = model.isPlaying != media.isPlaying
            || model.playbackRate != anchorRate

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
        media = model
    }

    /// Elapsed position extrapolated from the anchor, clamped to the track.
    private func projectedElapsed(at date: Date) -> TimeInterval {
        guard let anchorDate else { return 0 }
        let raw = anchorElapsed + date.timeIntervalSince(anchorDate) * anchorRate
        guard media.duration > 0 else { return max(0, raw) }
        return min(max(0, raw), media.duration)
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
    private var autoExpandsForActivity: Bool {
        hasLiveActivity && settings.expandOnAlert && !alertDismissed
    }

    var state: NotchState {
        NotchStateResolver.resolve(
            isHovering: isHovering,
            hasLiveActivity: autoExpandsForActivity
        )
    }

    /// The only way `isHovering` changes. Opening is immediate; closing commits
    /// to the collapse and locks re-expansion out for the length of the close
    /// animation. That's what stops the panel flapping back open under a
    /// pointer that's on its way off the island — a stray hover-in during the
    /// shrink is ignored until the notch has fully settled. A live-activity
    /// interrupt is unaffected: it opens through `hasLiveActivity`, not hover.
    func setHovering(_ hovering: Bool) {
        if hovering {
            // Remember that this alert's panel was actually visited, so hovering
            // back off it can count as a dismiss.
            if hasLiveActivity { alertWasHovered = true }
            guard !collapseLocked, !isHovering else { return }
            isHovering = true
        } else {
            guard isHovering else { return }
            isHovering = false
            // Hovering away from an auto-opened alert the user has visited
            // retracts the panel (if they allow it); the glyph stays in the
            // island until the alert resolves.
            if hasLiveActivity, alertWasHovered, settings.dismissAlertPanel {
                alertDismissed = true
            }
            collapseLocked = true
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.collapseLockDuration) { [weak self] in
                self?.collapseLocked = false
            }
        }
    }

    /// Retract the current alert's panel now (a click on it). No-op unless an
    /// alert is live and the user allows dismissing; the glyph stays until the
    /// alert resolves.
    func dismissAlert() {
        guard hasLiveActivity, settings.dismissAlertPanel else { return }
        alertDismissed = true
        // The pointer is still over the (large) panel at click time, so drop the
        // hover explicitly or it'd stay open as a hover-expand. The hover region
        // shrinks to the collapsed island, which the pointer is now outside of.
        isHovering = false
    }

    /// Whether the expanded panel shows the Music/Claude segmented switcher —
    /// only in `.both` mode; single-source modes show that one source.
    var showsTabBar: Bool {
        settings.effectiveMode == .both
    }

    /// Which content the expanded panel should render right now. In `.both`
    /// mode this is the user's selected tab, except that a live Claude interrupt
    /// (a question / error) forces the Claude tab — without mutating `activeTab`,
    /// so the user's choice is restored automatically once the alert clears.
    var expandedTab: IsleTab {
        switch settings.effectiveMode {
        case .music: return .music
        case .claude: return .claude
        case .both:
            // An alert auto-jumps to Claude, but a manual tab tap during the
            // alert sticks (see `selectTab`) so the user can still look at music.
            return (hasLiveActivity && !tabOverriddenDuringAlert) ? .claude : activeTab
        }
    }

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
        !hasMusicActivity && !hasClaudeActivity
    }

    /// Claude has something worth showing in the collapsed notch.
    var hasClaudeActivity: Bool {
        settings.effectiveMode.showsClaude
            && claudeState != .disconnected && claudeState != .idle
    }

    /// The collapsed island is showing Claude alone (no music). Drives the
    /// dots-left / status-right layout and the warm thinking/working colouring —
    /// when music shares the island the Claude cluster stays compact on the
    /// right and keeps the artwork tint.
    var isClaudeSolo: Bool {
        hasClaudeActivity && !hasMusicActivity
    }

    /// Warm status colour for the working phases in the Claude-solo island:
    /// yellow while thinking (no tool yet), orange once a tool is running. Nil
    /// for every other state and layout, so those keep their marker colour.
    var workingTint: Color? {
        guard isClaudeSolo, claudeState == .working else { return nil }
        let tint = isThinking ? Color(hex: "#F2C14E") : Color(hex: "#E8842B")
        // Unconfirmed for a while — fade it so the island reads as "still
        // showing this" rather than "just heard this". Nothing being produced
        // is the stronger signal of the two, so it fades further.
        if claudeIsUnresponsive { return tint.opacity(0.3) }
        return claudeIsStale ? tint.opacity(0.45) : tint
    }

    /// Both sources live at once — collapsed view splits (spec 3.1): music keeps
    /// its place on the left, Claude sits on the right. Alerts (approval /
    /// question) stay on Claude's side too rather than taking over the whole
    /// island, so the music isn't displaced.
    var shouldSplitCollapsed: Bool {
        hasMusicActivity && hasClaudeActivity
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

        if shouldSplitCollapsed {
            // Music cluster is album + waveform, with the waveform tucked toward
            // the camera so the album sits outboard, clear of the housing.
            let leading = s.album + s.gap + s.waveSplit + g
            return (leading, s.dots + statusSlot + g)
        }
        if hasClaudeActivity {
            // Claude solo: the dot glyph moves to the *left* of the camera and
            // the status word sits on the *right*, so the two straddle the
            // cutout instead of crowding together on one side. The glyph takes
            // the album's footprint (not the smaller split-view dots) so it
            // lands in exactly the spot the album cover occupies in music mode.
            let word = Self.textWidth(collapsedStatusText)
            let trailing = word > 0 ? word + g : s.minSide
            return (s.album + g, trailing)
        }
        if hasMusicActivity {
            return (s.album + g, s.waveSolo + g)
        }
        return (s.minSide, s.minSide)   // resting
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
            // The CLI still calls it busy but nothing is coming out — report the
            // observation, not a diagnosis. It reads the same whether the cause
            // is an API retry, a network stall, or a very long think, and it's
            // true in all three.
            if claudeIsUnresponsive {
                return "No response · \(Self.compactDuration(claudeNoResponseFor))"
            }
            let word = isThinking ? "Thinking" : workingWord
            // Past the staleness threshold the word alone would be a claim we
            // can't back up, so say how long it's been since anything confirmed
            // it ("Thinking · 2m") rather than inventing a "stalled" verdict.
            guard claudeIsStale else { return word }
            return "\(word) · \(Self.compactDuration(claudeSilentFor))"
        // Approvals are surfaced as a question — the expanded panel still offers
        // the Approve/Deny buttons for a live `ask`, but the word is unified.
        case .needsApproval, .needsQuestion: return "Question"
        case .waitingInput:
            // The CLI fires its idle notification ~60s into a retry storm, which
            // lands the island here. "Waiting" would read as "it's your turn"
            // when in fact nothing has come back yet, so the observation wins.
            if claudeIsUnresponsive {
                return "No response · \(Self.compactDuration(claudeNoResponseFor))"
            }
            return "Waiting"
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

    /// "45s" under a minute, "2m" above — the island has no room for more.
    private static func compactDuration(_ seconds: TimeInterval) -> String {
        seconds < 60 ? "\(Int(seconds))s" : "\(Int(seconds) / 60)m"
    }

    private static func textWidth(_ string: String) -> CGFloat {
        guard !string.isEmpty else { return 0 }
        let font = NSFont.systemFont(ofSize: CollapsedSize.statusFontSize, weight: .semibold)
        return ceil((string as NSString).size(withAttributes: [.font: font]).width)
    }

    // MARK: - Transport

    // Spotify handles every command over AppleScript, so controls are live
    // whenever a track is showing, regardless of which app owns the system
    // now-playing session.
    var canControlPlayback: Bool { media.hasTrack }
    var canSeek: Bool { media.hasTrack && media.duration > 0 }

    /// Shuffle/repeat state for the transport buttons, read from the merged
    /// model so the optimistic hold in `holdOptimisticTransport` shows through.
    var isShuffled: Bool { media.isShuffled }
    var repeatMode: RepeatMode { media.repeatMode }

    func togglePlayPause() {
        spotify.playPause()
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

        // Hold this state until a source confirms it, so the next poll can't
        // flicker it back before Spotify has processed the command.
        pendingPlayState = media.isPlaying
        pendingCommandDeadline = Date().addingTimeInterval(Self.commandGrace)
    }

    func nextTrack() { spotify.nextTrack() }
    func previousTrack() { spotify.previousTrack() }

    /// Toggle shuffle, optimistically, then hold it until a source confirms so a
    /// stale 1 Hz poll can't flicker it back before Spotify processes the flip.
    func toggleShuffle() {
        guard canControlPlayback else { return }
        spotify.toggleShuffle()
        let want = !media.isShuffled
        media.isShuffled = want
        lastApplied = media
        pendingShuffle = want
        pendingCommandDeadline = Date().addingTimeInterval(Self.commandGrace)
    }

    /// Toggle repeat, optimistically. Spotify's AppleScript has no repeat-one, so
    /// this is a boolean off↔all — matching what the poll can read back.
    func toggleRepeat() {
        guard canControlPlayback else { return }
        spotify.toggleRepeat()
        let want: RepeatMode = media.repeatMode == .off ? .all : .off
        media.repeatMode = want
        lastApplied = media
        pendingRepeat = want
        pendingCommandDeadline = Date().addingTimeInterval(Self.commandGrace)
    }

    /// Commits a scrub. Called on drag end, not continuously — seeking on
    /// every drag sample makes the source app stutter.
    func commitScrub() {
        guard let scrubTarget, media.duration > 0 else {
            self.scrubTarget = nil
            return
        }
        let seconds = scrubTarget * media.duration
        spotify.seek(to: seconds)

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
