//
//  LyricsClock.swift
//
//  Which lyric line is in effect, kept current against the playhead.
//
//  No per-frame tick. The position is a straight line between reports —
//  `NotchViewModel`'s anchor, elapsed plus rate × time — so the moment the
//  next line begins can be worked out exactly, and one timer is set for it.
//  When it fires the line is read afresh from the position (never assumed to
//  be "the next one"), published, and the next timer set. A seek, a pause, a
//  drift correction or a new track moves the anchor, and the owner calls
//  `resync()`, which throws the pending timer away and starts over from
//  wherever the playhead now is. Paused, nothing is scheduled at all.
//
//  A separate object rather than state on the view model for the same reason
//  the audio levels are: a line change every few seconds would otherwise
//  invalidate the whole notch. Only the lyric line observes this.
//
//  And it only runs while someone is looking. The music face attaches on
//  appear and detaches on disappear; with nobody attached there is no timer,
//  so a collapsed island — or the panel open on another face — costs nothing.
//

import Foundation
import Combine

@MainActor
final class LyricsClock: ObservableObject {
    struct Line: Equatable {
        /// Position in `SyncedLyrics.lines`. Identity for the view's
        /// transition, so a repeated line ("Yeah / Yeah") still turns over.
        let index: Int
        /// Empty in a gap.
        let text: String
    }

    /// The line in effect, or nil before the first one (or when there are no
    /// lyrics, or nobody is attached).
    @Published private(set) var line: Line?

    /// The current track's lyrics. Setting this resyncs.
    var lyrics: SyncedLyrics? {
        didSet {
            guard lyrics != oldValue else { return }
            resync()
        }
    }

    /// Where the playhead is now, and how fast it moves (0 when paused).
    /// Supplied by the owner, which keeps the playback anchor.
    var position: (() -> (elapsed: TimeInterval, rate: Double))?

    /// Lines are shown this much ahead of their stamp. LRC stamps mark where
    /// the voice comes in; a line that arrives with the voice reads as late,
    /// because reading takes a moment the singing doesn't wait for.
    static let lead: TimeInterval = 0.2

    private var viewers = 0
    private var timer: Timer?

    func attach() {
        viewers += 1
        if viewers == 1 { resync() }
    }

    func detach() {
        viewers = max(0, viewers - 1)
        guard viewers == 0 else { return }
        timer?.invalidate()
        timer = nil
        // Cleared rather than left standing, so the next open starts from the
        // line that's actually current instead of flashing a stale one.
        publish(nil)
    }

    /// Re-reads the line from the playhead and sets the timer for the next
    /// one. Cheap; the owner calls it whenever the anchor moves.
    func resync() {
        timer?.invalidate()
        timer = nil

        guard viewers > 0, let lyrics, let position else {
            publish(nil)
            return
        }

        let (elapsed, rate) = position()
        let now = elapsed + Self.lead
        publish(lyrics.index(at: now).map { Line(index: $0, text: lyrics.lines[$0].text) })

        guard rate > 0, let next = lyrics.nextChange(after: now) else { return }
        // A floor so a drift correction that lands just short of a stamp
        // can't spin the timer.
        let wait = max(0.05, (next - now) / rate)
        let timer = Timer(timeInterval: wait, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.resync() }
        }
        // A line a few hundredths late is invisible; the slack lets the
        // wakeup coalesce with others.
        timer.tolerance = 0.03
        // .common so lines keep turning while the panel is being dragged over.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func publish(_ new: Line?) {
        guard new != line else { return }
        line = new
    }
}
