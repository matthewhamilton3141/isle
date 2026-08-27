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
    static let approvalDots: CGFloat = 18
    static let ring: CGFloat = 8
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
    /// if any other status arrives first.
    private var doneRevertTask: Task<Void, Never>?

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

    /// Show the animated waveform in the collapsed notch (Settings).
    var showWaveform: Bool { settings.showWaveform }

    /// Show the seekable scrubber in the expanded panel (Settings).
    var showScrubber: Bool { settings.showScrubber }

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

        claudeWatcher.onStatus = { [weak self] status in
            self?.applyClaudeStatus(status)
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
        } else {
            claudeWatcher.stop()
            doneRevertTask?.cancel()
            doneRevertTask = nil
            stopWorkingWords()
            claudeState = .disconnected
            claudeProject = nil
            claudeSessionId = nil
            claudeAction = nil
            claudeTarget = nil
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
        withAnimation(.easeInOut(duration: 0.25)) {
            claudeState = status.state
        }
        claudeProject = status.project
        claudeSessionId = status.sessionId
        claudeAction = status.action
        claudeTarget = status.target
        claudeUpdatedAt = status.state == .disconnected ? nil : Date()

        // Rotate the "thinking" word only while actually working.
        if status.state == .working {
            startWorkingWords()
        } else {
            stopWorkingWords()
        }

        guard status.state == .done else { return }
        let duration = settings.doneToastSeconds
        doneRevertTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
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
        settings.effectiveMode.showsClaude && claudeState.isAttention
    }

    var state: NotchState {
        NotchStateResolver.resolve(
            isHovering: isHovering,
            hasLiveActivity: hasLiveActivity
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
            guard !collapseLocked, !isHovering else { return }
            isHovering = true
        } else {
            guard isHovering else { return }
            isHovering = false
            collapseLocked = true
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.collapseLockDuration) { [weak self] in
                self?.collapseLocked = false
            }
        }
    }

    /// Whether the expanded panel shows the Music/Claude segmented switcher —
    /// only in `.both` mode; single-source modes show that one source.
    var showsTabBar: Bool {
        settings.effectiveMode == .both
    }

    /// Which content the expanded panel should render right now. In `.both`
    /// mode this is the user's selected tab, except that a `needsApproval`
    /// interrupt forces the Claude tab — without mutating `activeTab`, so the
    /// user's choice is restored automatically once the approval clears.
    var expandedTab: IsleTab {
        switch settings.effectiveMode {
        case .music: return .music
        case .claude: return .claude
        case .both: return hasLiveActivity ? .claude : activeTab
        }
    }

    var hasMusicActivity: Bool {
        settings.effectiveMode.showsMusic && media.hasTrack
    }

    /// Claude has something worth showing in the collapsed notch.
    var hasClaudeActivity: Bool {
        settings.effectiveMode.showsClaude
            && claudeState != .disconnected && claudeState != .idle
    }

    /// Both sources live at once — collapsed view splits (spec 3.1), unless
    /// Claude needs approval, which takes the full width.
    var shouldSplitCollapsed: Bool {
        hasMusicActivity && hasClaudeActivity && claudeState != .needsApproval
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

        if claudeState.isAttention {
            return (s.approvalDots + g, hasMusicActivity ? s.ring + g : s.minSide)
        }
        if shouldSplitCollapsed {
            let leading = s.album + (showWaveform ? s.gap + s.waveSplit : 0) + g
            return (leading, s.dots + statusSlot + g)
        }
        if hasClaudeActivity {
            return (s.claudeSoloLeading, s.dots + statusSlot + g)
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

    /// A short, stable word for the collapsed notch — deliberately *not* the
    /// per-tool action (that changes every tool call and would make the island
    /// resize constantly). The expanded view shows the detailed "Editing …".
    var collapsedStatusText: String {
        switch claudeState {
        case .working: return isThinking ? "Thinking" : "Working"
        case .needsApproval: return "Approve"
        case .needsQuestion: return "Question"
        case .waitingInput: return "Waiting"
        case .done: return "Done"
        case .idle: return "Ready"
        case .disconnected: return ""
        }
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
