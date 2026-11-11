//
//  IslandHold.swift
//
//  One press of the primary button on an island, from button down to button
//  up, and what it turns into:
//
//  - On an open island hanging from the notch, a press held still takes the
//    island off it. Nothing shows for the first moment (`grace`), so a
//    click is a click exactly as before; then a line runs around the panel
//    for `run` seconds, and when it has gone all the way round the island
//    comes loose and follows the pointer until the button comes up.
//  - On an open island already off the notch, the same but quicker: a short
//    hold picks it up to be moved.
//  - On a closed island off the notch, a plain press-and-drag moves it.
//
//  Let go early, or move more than `slop` — a slider, a scrub, an item
//  dragged off the shelf — and the line runs back and nothing happens.
//
//  The hold is timed on purpose: the user asked to press and hold. (Hover
//  is another matter and never waits — see `NotchWindowController`.)
//
//  This is only the deciding. It takes events and the clock as arguments
//  and answers with what to do, so it runs without a window, a pointer or
//  a timer (scripts/test-island-placement.sh). `IslandCarry` feeds it the
//  real ones and does what it says.
//

import CoreGraphics
import Foundation

struct IslandHold {
    /// What a press on the island can become.
    enum Kind: Equatable {
        /// Open, on the notch: hold to take it off.
        case detach
        /// Open, off the notch: a short hold picks it up.
        case pickUp
        /// Closed, off the notch: press and drag.
        case drag

        /// How long nothing shows, and how long the line then runs. Nil for
        /// a plain drag, which isn't timed.
        var timing: (grace: TimeInterval, run: TimeInterval)? {
            switch self {
            // A click is over well inside the grace, so it never sees the
            // line; the run is long enough to read as a decision.
            case .detach: return (0.25, 1.1)
            // Already loose: only long enough to tell a hold from a click
            // on a control.
            case .pickUp: return (0.2, 0.2)
            case .drag: return nil
            }
        }
    }

    /// How far the pointer may move during a hold, in points, before it's a
    /// drag of whatever is under it rather than a hold.
    static let slop: CGFloat = 4

    /// Timers land a hair either side of their deadline.
    private static let tolerance: TimeInterval = 0.01

    enum Phase: Equatable {
        /// No press, or one that was never the island's.
        case idle
        /// Button down, nothing showing yet.
        case waiting
        /// The line is running.
        case tracing
        /// The island is following the pointer.
        case carrying
        /// The press goes on but is no longer a hold: the pointer moved.
        case spent
    }

    /// What becomes of the event that was just handled.
    enum Verdict: Equatable {
        /// On to the views, as if this weren't here.
        case pass
        /// Kept from the views.
        case swallow
        /// A button-up the views mustn't take for a click: they're sent a
        /// release that lands outside whatever was pressed instead.
        case cancelPress
    }

    enum Action: Equatable {
        /// Start the line; it takes `run` seconds to go round.
        case traceBegan(run: TimeInterval)
        /// The line runs back.
        case traceCancelled
        /// The island comes loose (or is picked up), held at `at`.
        case lifted(at: CGPoint)
        case carried(to: CGPoint)
        case dropped(at: CGPoint)
    }

    struct Outcome: Equatable {
        var verdict: Verdict = .pass
        var actions: [Action] = []
    }

    private(set) var phase: Phase = .idle
    private var kind: Kind = .drag
    private var origin: CGPoint = .zero
    private var last: CGPoint = .zero
    private var pressedAt: TimeInterval = 0
    private var traceAt: TimeInterval = 0

    /// The line showed during this press, so its release isn't a click —
    /// even if the line has since run back.
    private var traced = false

    /// When `tick` next has something to decide. Nil when nothing is timed.
    var deadline: TimeInterval? {
        switch phase {
        case .waiting: return kind.timing.map { pressedAt + $0.grace }
        case .tracing: return kind.timing.map { traceAt + $0.run }
        case .idle, .carrying, .spent: return nil
        }
    }

    /// The button went down at `point`. `kind` is what this press could
    /// become, nil when it isn't the island's to take (a closed island on
    /// the notch, a reply being typed, a file drag). Always passed on: the
    /// control under the pointer gets its press as it always did.
    mutating func down(kind: Kind?, at point: CGPoint, time: TimeInterval) -> Outcome {
        // A press that never saw its release (it went to a drag session, or
        // a tracking loop): finish it first.
        var outcome = abandon()
        outcome.verdict = .pass
        guard let kind else { return outcome }
        self.kind = kind
        origin = point
        last = point
        pressedAt = time
        traced = false
        phase = .waiting
        return outcome
    }

    /// The pointer moved with the button down.
    mutating func moved(to point: CGPoint, time: TimeInterval) -> Outcome {
        switch phase {
        case .idle, .spent:
            return Outcome()
        case .waiting:
            guard strayed(point) else { return Outcome() }
            if kind == .drag {
                // Held at the press, not at where the slop ran out, so the
                // island catches up and the grab stays under the pointer.
                phase = .carrying
                last = point
                return Outcome(verdict: .swallow, actions: [.lifted(at: origin), .carried(to: point)])
            }
            phase = .spent
            return Outcome()
        case .tracing:
            guard strayed(point) else { return Outcome() }
            phase = .spent
            return Outcome(actions: [.traceCancelled])
        case .carrying:
            last = point
            return Outcome(verdict: .swallow, actions: [.carried(to: point)])
        }
    }

    /// The button came up.
    mutating func up(at point: CGPoint, time: TimeInterval) -> Outcome {
        defer { phase = .idle }
        switch phase {
        case .idle, .waiting:
            return Outcome()
        case .tracing:
            return Outcome(verdict: .cancelPress, actions: [.traceCancelled])
        case .carrying:
            return Outcome(verdict: .cancelPress, actions: [.dropped(at: point)])
        case .spent:
            return Outcome(verdict: traced ? .cancelPress : .pass)
        }
    }

    /// The clock reached `deadline`, or something wants the press looked at
    /// again. `pointer` and `buttonDown` are read fresh rather than taken
    /// from the events: a press whose drags and release went elsewhere (a
    /// drag session, a tracking loop) would otherwise go on looking held.
    /// `holdable` is whether the island could still be taken — it's still
    /// open, nothing has claimed it since the press.
    mutating func tick(time: TimeInterval, pointer: CGPoint, buttonDown: Bool, holdable: Bool = true) -> Outcome {
        switch phase {
        case .idle:
            return Outcome()
        case .spent:
            if !buttonDown { phase = .idle }
            return Outcome()
        case .waiting:
            guard buttonDown else {
                phase = .idle
                return Outcome()
            }
            guard let timing = kind.timing, time >= pressedAt + timing.grace - Self.tolerance else {
                return Outcome()
            }
            guard holdable, !strayed(pointer) else {
                phase = .spent
                return Outcome()
            }
            phase = .tracing
            traceAt = time
            traced = true
            return Outcome(actions: [.traceBegan(run: timing.run)])
        case .tracing:
            guard buttonDown else {
                phase = .idle
                return Outcome(actions: [.traceCancelled])
            }
            guard holdable, !strayed(pointer) else {
                phase = .spent
                return Outcome(actions: [.traceCancelled])
            }
            guard let timing = kind.timing, time >= traceAt + timing.run - Self.tolerance else {
                return Outcome()
            }
            phase = .carrying
            last = pointer
            return Outcome(actions: [.lifted(at: origin)])
        case .carrying:
            // The release never arrived: put the island down where it is.
            guard !buttonDown else { return Outcome() }
            phase = .idle
            return Outcome(actions: [.dropped(at: pointer)])
        }
    }

    /// Something else is taking over (the islands are being re-placed or
    /// hidden): end whatever the press had become, the island put down
    /// where it was last carried to.
    mutating func abandon() -> Outcome {
        defer { phase = .idle }
        switch phase {
        case .idle, .waiting, .spent: return Outcome()
        case .tracing: return Outcome(actions: [.traceCancelled])
        case .carrying: return Outcome(actions: [.dropped(at: last)])
        }
    }

    private func strayed(_ point: CGPoint) -> Bool {
        hypot(point.x - origin.x, point.y - origin.y) > Self.slop
    }
}
