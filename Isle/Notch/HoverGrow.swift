//
//  HoverGrow.swift
//
//  A control on the open island grows a little while the pointer is on
//  it, so it's plain what a click there would press.
//
//  This file is the rule alone: which control the pointer is on
//  (`HoverTargets`) and how much it grows (`HoverGrow.scale`). No SwiftUI,
//  no AppKit, so it can be tested on its own (scripts/test-hover-grow.sh).
//  The views and the tracker that runs it are in HoverGrow+SwiftUI.swift.
//
//  Nothing here is timed: a control grows the moment the pointer is on it
//  and settles the moment it leaves.
//

import CoreGraphics
import Foundation

/// One control that grows: where it is, in the island's top-left space
/// (the hosting view's, where the pointer is given too).
struct HoverTarget: Equatable {
    var id: UUID
    var rect: CGRect
}

/// Which control the pointer is on.
struct HoverTargets {
    private(set) var targets: [HoverTarget] = []
    private(set) var hovered: UUID?
    private var pointer: CGPoint?

    /// The pointer moved, in the island's top-left space.
    mutating func move(to point: CGPoint) {
        pointer = point
        hovered = target(at: point)
    }

    /// The pointer is on another display, or the island has closed.
    mutating func leave() {
        pointer = nil
        hovered = nil
    }

    /// The controls on show, as laid out now. What's under a still pointer
    /// is whatever is under it now: a control that has moved away from it
    /// settles, one that has moved under it grows.
    mutating func setTargets(_ targets: [HoverTarget]) {
        self.targets = targets
        hovered = pointer.flatMap { target(at: $0) }
    }

    /// The control under `point`. Where two overlap (a row that's a button
    /// round a smaller one), the smaller: it's the one the pointer is on.
    func target(at point: CGPoint) -> UUID? {
        targets
            .filter { $0.rect.contains(point) }
            .min { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height }?
            .id
    }
}

enum HoverGrow {
    /// How far a control's edge moves out, in points, at most: small keys
    /// grow by about this much on every side.
    static let reach: CGFloat = 2

    /// And at most this much, as a scale, however small the control: a 12pt
    /// chevron at the full reach would jump by a third.
    static let maxScale: CGFloat = 1.15

    /// The scale for a control of `size`: the same few points for every
    /// control, so a key and a pill look to grow alike rather than the big
    /// ones lunging and the small ones barely moving.
    static func scale(for size: CGSize) -> CGFloat {
        let side = max(size.width, size.height)
        guard side > 0 else { return 1 }
        return min(maxScale, 1 + 2 * reach / side)
    }
}
