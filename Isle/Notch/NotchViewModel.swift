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

@MainActor
final class NotchViewModel: ObservableObject {
    /// Pointer is over the notch's hit area.
    @Published var isHovering: Bool = false

    /// Claude Code state from the hook bridge. Phase 2 wires this to the
    /// file watcher; until then it stays `.disconnected` and the notch
    /// behaves as a music-only overlay.
    @Published var claudeState: ClaudeCodeState = .disconnected

    @Published private(set) var media = MediaPlaybackModel()

    /// Position the user is dragging the scrubber to. Non-nil only mid-drag;
    /// while set, the scrubber renders this instead of the live position so
    /// the thumb doesn't fight the playback clock under the finger.
    @Published var scrubTarget: Double?

    var metrics: NotchMetrics?

    private let adapter = MediaRemoteAdapterClient()
    private let spotify = SpotifyController()
    private let audio = SystemAudioLevels()
    private var cancellables = Set<AnyCancellable>()

    // The two now-playing sources, kept separately and merged in
    // `recomputeSource`. The adapter (MediaRemote) is preferred when Spotify
    // owns the system session — it pushes updates and ships artwork as bytes.
    // The AppleScript poll is the fallback for when something else (a browser
    // tab, say) owns the session, so the notch still shows Spotify.
    private var adapterModel = MediaPlaybackModel()
    private var spotifyModel: MediaPlaybackModel?
    private var lastApplied = MediaPlaybackModel()

    /// Live per-band audio magnitudes. Empty when capture isn't running, which
    /// EqualizerView reads as "use the procedural fallback".
    @Published private(set) var audioLevels: [Double] = []

    /// Why audio capture isn't running, if it isn't.
    var audioFailureReason: String? { audio.failureReason }

    init() {
        adapter.onUpdate = { [weak self] model in
            self?.adapterModel = model
            self?.recomputeSource()
        }
        spotify.onUpdate = { [weak self] model in
            self?.spotifyModel = model
            self?.recomputeSource()
        }

        // Republish rather than exposing `audio` directly: nesting an
        // ObservableObject inside another doesn't propagate to SwiftUI.
        audio.$levels
            .sink { [weak self] levels in
                self?.audioLevels = levels
            }
            .store(in: &cancellables)
    }

    func start() {
        adapter.start()
        spotify.start()
        audio.start()
    }

    func stop() {
        adapter.stop()
        spotify.stop()
        audio.stop()
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

        guard effective != lastApplied else { return }
        lastApplied = effective
        apply(effective)
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
    /// the notch would flap open on every tool call.
    var hasLiveActivity: Bool {
        claudeState == .needsApproval
    }

    var state: NotchState {
        NotchStateResolver.resolve(
            isHovering: isHovering,
            hasLiveActivity: hasLiveActivity
        )
    }

    var hasMusicActivity: Bool {
        media.hasTrack
    }

    /// Claude has something worth showing in the collapsed notch.
    var hasClaudeActivity: Bool {
        claudeState != .disconnected && claudeState != .idle
    }

    /// Both sources live at once — collapsed view splits (spec 3.1), unless
    /// Claude needs approval, which takes the full width.
    var shouldSplitCollapsed: Bool {
        hasMusicActivity && hasClaudeActivity && claudeState != .needsApproval
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
    }

    /// Progress to render: the drag target while scrubbing, else the smoothed
    /// playback clock.
    func displayProgress(at date: Date = Date()) -> Double {
        if let scrubTarget { return scrubTarget }
        guard media.duration > 0 else { return 0 }
        return projectedElapsed(at: date) / media.duration
    }
}
