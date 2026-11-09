//
//  FaceSwipe.swift
//
//  The two-finger swipe between faces, as a plain state machine: scroll
//  samples in, an offset and a settle out. No AppKit, no clock — every
//  decision is made from the samples themselves, so it can be fed synthetic
//  phases and deltas and checked without a trackpad.
//
//  The rules:
//
//  - Each gesture picks an axis on its first few points of travel and keeps
//    it. Horizontal is ours; vertical goes through untouched, so the Agenda
//    list and a long question still scroll.
//  - A horizontal gesture moves the face with the fingers, part-way, and
//    never further than the neighbour: one face per gesture.
//  - It settles only on the gesture's own end phase. `.ended` snaps to the
//    nearer face, or on to the neighbour after a flick in its direction;
//    `.cancelled` always goes back. Nothing here waits for a quiet period —
//    a gesture that never ends never settles.
//  - Past the first or last face it rubber-bands, and always goes back.
//  - Momentum that follows a horizontal gesture is swallowed, so one flick is
//    one face and the coasting doesn't scroll whatever is underneath.
//

import CoreGraphics
import Foundation

/// Where a scroll sample is in its gesture — `NSEvent.Phase` reduced to the
/// cases that matter here, for the gesture and for its momentum alike.
enum SwipePhase: Equatable {
    /// Not part of a gesture: a mouse wheel, or no momentum.
    case none
    case mayBegin
    case began
    case changed
    case stationary
    case ended
    case cancelled
}

/// One scroll event, as the tracker sees it. Deltas are in points and follow
/// the fingers: positive `dx` is the fingers moving right, whatever the
/// scrolling-direction setting (see `IslandPresentation.handleScroll`).
struct SwipeSample: Equatable {
    var phase: SwipePhase
    var momentum: SwipePhase = .none
    var dx: CGFloat = 0
    var dy: CGFloat = 0
    /// The event's own timestamp, in seconds. Only differences are read.
    var time: TimeInterval
}

struct FaceSwipeTracker {
    /// What to do with the event that produced a result.
    enum Verdict: Equatable {
        /// Let it through to the views under the pointer.
        case pass
        /// It was a face swipe; nothing else should see it.
        case consume
    }

    /// What the faces should do.
    enum Change: Equatable {
        /// Follow the fingers: the face on screen sits `offset` points from
        /// home, and the neighbour on `side` (-1 the previous face, entering
        /// from the left; +1 the next, from the right; 0 none, at an edge)
        /// comes in behind it.
        case track(offset: CGFloat, side: Int)
        /// The gesture ended. Land on the face `step` away (-1, 0 or +1).
        /// `velocity` is the fingers' speed at lift-off, in points a second,
        /// for the settle's spring to start from.
        case settle(step: Int, velocity: CGFloat)
    }

    struct Result: Equatable {
        var verdict: Verdict
        var change: Change?
    }

    private enum State: Equatable {
        /// Between gestures.
        case idle
        /// A gesture has started and not yet moved far enough to call.
        case deciding(dx: CGFloat, dy: CGFloat)
        /// Ours: the fingers have moved `travel` points sideways in all.
        case horizontal(travel: CGFloat)
        /// Someone else's, until it ends.
        case vertical
        /// A gesture already under way when we first saw it, or one we were
        /// told to drop. Left alone until it ends.
        case ignoring
        /// A horizontal gesture has settled and its momentum may follow.
        case coasting
    }

    // MARK: Tunables

    /// Travel before a gesture is given an axis. Small enough that the face
    /// picks up the fingers at once, large enough that a hair of sideways
    /// drift at the start of a vertical scroll doesn't steal it.
    static let axisSlop: CGFloat = 4

    /// A slow release lands on whichever face is nearer: past half a page.
    static let commitFraction: CGFloat = 0.5

    /// A release this fast (points a second) counts as a flick: it goes on to
    /// the neighbour in the flick's direction, however little it has moved,
    /// or back home if it flicks the other way.
    static let flickSpeed: CGFloat = 450

    /// A flick has to have moved the face at least this far, so a tap that
    /// jitters on lift-off doesn't turn the page.
    static let flickMinTravel: CGFloat = 12

    /// How far back from the end phase the release speed is measured. A
    /// finger that stopped for longer than this before lifting has no speed.
    static let velocityWindow: TimeInterval = 0.08

    /// How hard an edge resists: the offset approaches this fraction of a page
    /// however far the fingers go.
    static let rubberBandReach: CGFloat = 0.25

    // MARK: State

    /// The distance between one face's home and the next: the face's width
    /// plus the gap between faces.
    let page: CGFloat

    private var state: State = .idle

    /// Recent horizontal travel, each with the span of time it covers, for
    /// the release speed.
    private var recent: [(from: TimeInterval, to: TimeInterval, dx: CGFloat)] = []

    /// The timestamp of the gesture's previous event, which is where the next
    /// one's travel started.
    private var lastTime: TimeInterval?

    init(page: CGFloat) {
        self.page = page
    }

    /// The gesture in progress is horizontal and moving a face.
    var isTracking: Bool {
        if case .horizontal = state { return true }
        return false
    }

    /// Forget the gesture in progress. Its remaining events are passed
    /// through untouched until it ends. For when the faces change under the
    /// fingers — a takeover, the panel closing.
    mutating func drop() {
        switch state {
        case .idle, .coasting: state = .idle
        default: state = .ignoring
        }
        recent.removeAll()
        lastTime = nil
    }

    /// Feed one scroll sample. `canGoBack` / `canGoForward` say whether the
    /// face on screen has a neighbour on that side.
    mutating func handle(_ sample: SwipeSample, canGoBack: Bool, canGoForward: Bool) -> Result {
        // Momentum: never moves anything. It belongs to the gesture before
        // it, so after a horizontal one it's swallowed until it ends.
        if sample.momentum != .none {
            guard state == .coasting else { return Result(verdict: .pass) }
            if sample.momentum == .ended || sample.momentum == .cancelled {
                state = .idle
            }
            return Result(verdict: .consume)
        }

        switch sample.phase {
        case .none:
            // A mouse wheel has no gesture to page with. The strip of tiles
            // on Home is the way across for it.
            return Result(verdict: .pass)

        case .mayBegin:
            // Fingers down. Start fresh, whatever came before: a gesture
            // whose end we never saw doesn't outlive the next touch.
            state = .deciding(dx: 0, dy: 0)
            recent.removeAll()
            lastTime = sample.time
            return Result(verdict: .pass)

        case .began, .changed:
            if sample.phase == .began, !isTracking {
                // `.began` without a `.mayBegin` first is still a new
                // gesture; with one, carry on deciding from there.
                if case .deciding = state {} else {
                    state = .deciding(dx: 0, dy: 0)
                    recent.removeAll()
                    lastTime = nil
                }
            }
            defer { lastTime = sample.time }
            return move(by: sample, canGoBack: canGoBack, canGoForward: canGoForward)

        case .stationary:
            // Fingers resting on the pad mid-gesture. Counts as no movement,
            // which is what makes a stop-then-lift a slow release.
            guard case .horizontal = state else { return Result(verdict: .pass) }
            record(0, at: sample.time)
            lastTime = sample.time
            return Result(verdict: .consume)

        case .ended, .cancelled:
            return end(sample, canGoBack: canGoBack, canGoForward: canGoForward)
        }
    }

    // MARK: Moving

    private mutating func move(by sample: SwipeSample, canGoBack: Bool, canGoForward: Bool) -> Result {
        switch state {
        case .idle, .coasting:
            // Movement from a gesture that began before we were looking —
            // over the collapsed island, or another window.
            state = .ignoring
            return Result(verdict: .pass)

        case .ignoring, .vertical:
            return Result(verdict: .pass)

        case .deciding(let dx, let dy):
            let x = dx + sample.dx, y = dy + sample.dy
            guard hypot(x, y) >= Self.axisSlop else {
                state = .deciding(dx: x, dy: y)
                return Result(verdict: .pass)
            }
            guard abs(x) > abs(y) else {
                state = .vertical
                return Result(verdict: .pass)
            }
            // Horizontal, from everything the fingers have done so far.
            state = .horizontal(travel: x)
            recent.removeAll()
            record(x, at: sample.time)
            return Result(verdict: .consume, change: track(x, canGoBack: canGoBack, canGoForward: canGoForward))

        case .horizontal(let travel):
            let next = travel + sample.dx
            state = .horizontal(travel: next)
            record(sample.dx, at: sample.time)
            return Result(verdict: .consume, change: track(next, canGoBack: canGoBack, canGoForward: canGoForward))
        }
    }

    /// Where the face sits for this much finger travel, and which neighbour
    /// shows. Negative travel (fingers moving left) brings in the next face.
    private func track(_ travel: CGFloat, canGoBack: Bool, canGoForward: Bool) -> Change {
        let side = travel < 0 ? 1 : (travel > 0 ? -1 : 0)
        let open = side == 1 ? canGoForward : (side == -1 ? canGoBack : false)
        guard open else {
            return .track(offset: rubberBand(travel), side: 0)
        }
        // One face per gesture: the neighbour comes all the way in and stops.
        return .track(offset: min(max(travel, -page), page), side: side)
    }

    /// Diminishing travel past an edge: easy at first, firmer the further it
    /// goes, never more than `rubberBandReach` of a page.
    func rubberBand(_ travel: CGFloat) -> CGFloat {
        let reach = page * Self.rubberBandReach
        guard reach > 0, travel != 0 else { return 0 }
        let pulled = (1 - 1 / (abs(travel) * 0.55 / reach + 1)) * reach
        return travel < 0 ? -pulled : pulled
    }

    // MARK: Ending

    private mutating func end(_ sample: SwipeSample, canGoBack: Bool, canGoForward: Bool) -> Result {
        guard case .horizontal(let travel) = state else {
            // Not ours. The end goes through so whatever did take the
            // gesture closes it.
            state = .idle
            recent.removeAll()
            lastTime = nil
            return Result(verdict: .pass)
        }

        let velocity = releaseVelocity(at: sample.time)
        recent.removeAll()
        lastTime = nil
        state = .coasting

        let step: Int
        if sample.phase == .cancelled {
            step = 0
        } else {
            step = settleStep(travel: travel, velocity: velocity,
                              canGoBack: canGoBack, canGoForward: canGoForward)
        }
        // The end itself goes through: anything that saw the gesture's first
        // event before it was called horizontal gets to close it.
        return Result(verdict: .pass, change: .settle(step: step, velocity: velocity))
    }

    /// -1, 0 or +1: which face a release lands on.
    private func settleStep(travel: CGFloat, velocity: CGFloat,
                            canGoBack: Bool, canGoForward: Bool) -> Int {
        // The face in the direction of travel, if there is one.
        let toward = travel < 0 ? 1 : (travel > 0 ? -1 : 0)
        let open = toward == 1 ? canGoForward : (toward == -1 ? canGoBack : false)
        guard open else { return 0 }

        if abs(velocity) >= Self.flickSpeed {
            // A flick decides by its direction. With the travel: on to the
            // neighbour. Against it: home, however far it had got.
            let withTravel = (velocity < 0) == (travel < 0)
            return withTravel && abs(travel) >= Self.flickMinTravel ? toward : 0
        }
        return abs(travel) >= page * Self.commitFraction ? toward : 0
    }

    /// Notes `dx` of travel arriving at `time`, covering the span since the
    /// gesture's previous event, and lets go of anything too old to count.
    private mutating func record(_ dx: CGFloat, at time: TimeInterval) {
        recent.append((from: lastTime ?? time, to: time, dx: dx))
        let since = time - Self.velocityWindow
        if let first = recent.firstIndex(where: { $0.to >= since }), first > 0 {
            recent.removeFirst(first)
        }
    }

    /// The fingers' speed over the last `velocityWindow` before `time`, in
    /// points a second: the travel in that window over the time it took, up
    /// to the end phase. Zero if they'd stopped.
    private func releaseVelocity(at time: TimeInterval) -> CGFloat {
        let since = time - Self.velocityWindow
        let window = recent.filter { $0.to >= since }
        guard let start = window.map(\.from).min() else { return 0 }
        let span = time - max(since, start)
        guard span > 0 else { return 0 }
        return window.reduce(0) { $0 + $1.dx } / CGFloat(span)
    }
}
