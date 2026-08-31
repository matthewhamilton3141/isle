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
    @Published private(set) var palette: ArtworkPalette = .fallback

    /// Identity of the cover `palette` was built from, to skip the work when
    /// an update carries the same image.
    private var paletteArtwork: NSImage?

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

    private var reselectTimer: Timer?

    /// Re-runs selection on a coarse timer while a state that claims work is in
    /// progress is showing.
    ///
    /// Nothing here measures silence. Isle has no signal that separates a long
    /// think from a stalled turn — both fire no hooks and write nothing — so it
    /// makes no claim either way, in text or in treatment, and the island holds
    /// the last state it was actually told about.
    ///
    /// The timer earns its place on the other job: the registry's directory
    /// event normally re-runs selection itself, but an interrupt can leave the
    /// CLI record untouched (already `idle`), and then nothing else would ever
    /// re-examine the stuck record.
    private func updateReselectTimer(for state: ClaudeCodeState) {
        guard state == .working || state == .compacting || state == .waitingInput else {
            stopReselectTimer()
            return
        }
        guard reselectTimer == nil else { return }
        reselectTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Apply only on a real change, so an unchanged state doesn't
                // re-render the island every tick.
                let resolved = self.selectStatus(from: self.claudeStatuses)
                guard resolved.state != self.claudeState else { return }
                self.applyClaudeStatus(resolved)
            }
        }
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
        setMediaRunning(false)
        setClaudeRunning(false)
        for (center, token) in displayObservers { center.removeObserver(token) }
        displayObservers.removeAll()
    }

    /// Brings the running subsystems in line with the active mode, and with
    /// whether there's a display awake to show any of it on.
    private func applyMode() {
        setMediaRunning(settings.effectiveMode.showsMusic && !displayAsleep)
        setClaudeRunning(settings.effectiveMode.showsClaude)
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
            // Idle is quiescent — nothing left to re-select for.
            self?.stopReselectTimer()
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

        // Reference identity, not image equality: the sources hand over a new
        // NSImage only when they actually fetched or decoded one, so this is
        // exactly the question of whether the cover changed.
        if model.artwork !== paletteArtwork {
            paletteArtwork = model.artwork
            palette = ArtworkColors.palette(from: model.artwork)
        }

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

    /// Warm status colour for the working phases in the Claude-solo island:
    /// yellow while thinking (no tool yet), orange once a tool is running. Nil
    /// for every other state and layout, so those keep their marker colour.
    var workingTint: Color? {
        guard isClaudeSolo, claudeState == .working else { return nil }
        // Full strength for as long as the state stands. It used to fade once
        // hooks had been quiet a while, but hook silence is normal during a
        // long think, so the fade only ever second-guessed a state that was
        // still true.
        return isThinking ? Color(hex: "#F2C14E") : Color(hex: "#E8842B")
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
            // No clock on the working word, in either phase. Hooks are silent
            // through a whole reasoning turn and through a long tool call, so
            // the number was only ever counting normal quiet, and a figure
            // ticking up next to "Coalescing…" reads as a fault when nothing
            // is wrong. Past the staleness threshold the word just dims
            // (`claudeTint`) — the island says nothing it can't back up.
            return (isThinking ? "Thinking" : workingWord) + "…"
        // Approvals are surfaced as a question — the expanded panel still offers
        // the Approve/Deny buttons for a live `ask`, but the word is unified.
        case .needsApproval, .needsQuestion: return "Question"
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
