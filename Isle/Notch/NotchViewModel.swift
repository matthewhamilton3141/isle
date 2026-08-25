//
//  NotchViewModel.swift
//
//  Single observable the notch views read from. Holds the two inputs that
//  can open the notch (pointer hover, Claude Code activity), derives the
//  resolved NotchState from them, and owns the media feed.
//

import SwiftUI
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
    private let commands = MediaRemoteCommands.shared
    private let audio = SystemAudioLevels()
    private var cancellables = Set<AnyCancellable>()

    /// Live per-band audio magnitudes. Empty when capture isn't running, which
    /// EqualizerView reads as "use the procedural fallback".
    @Published private(set) var audioLevels: [Double] = []

    /// Why audio capture isn't running, if it isn't.
    var audioFailureReason: String? { audio.failureReason }

    init() {
        adapter.onUpdate = { [weak self] model in
            self?.media = model
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
        audio.start()
    }

    func stop() {
        adapter.stop()
        audio.stop()
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

    var canControlPlayback: Bool { commands.canControlPlayback }
    var canSeek: Bool { commands.canSeek }

    func togglePlayPause() { commands.togglePlayPause() }
    func nextTrack() { commands.nextTrack() }
    func previousTrack() { commands.previousTrack() }

    func toggleShuffle() {
        let target = !media.isShuffled
        commands.setShuffle(target)
        // Reflect immediately. MediaRemote doesn't echo shuffle changes back
        // promptly and the button would otherwise sit visibly stale for a
        // beat after every tap.
        media.isShuffled = target
    }

    func cycleRepeat() {
        let target = media.repeatMode.next
        commands.setRepeat(target)
        media.repeatMode = target
    }

    /// Commits a scrub. Called on drag end, not continuously — seeking on
    /// every drag sample makes the source app stutter.
    func commitScrub() {
        guard let scrubTarget, media.duration > 0 else {
            self.scrubTarget = nil
            return
        }
        let seconds = scrubTarget * media.duration
        commands.seek(to: seconds)

        // Optimistically move our own clock, otherwise the thumb snaps back
        // to the old position until the adapter reports the new one.
        media.reportedElapsed = seconds
        media.timestamp = Date()
        self.scrubTarget = nil
    }

    /// Progress to render: the drag target while scrubbing, else live.
    func displayProgress(at date: Date = Date()) -> Double {
        scrubTarget ?? media.progress(at: date)
    }
}
