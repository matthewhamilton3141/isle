//
//  FacePager.swift
//
//  One island's swipe between faces: takes the scroll events its window
//  offers (`NotchWindow.scrollInterceptor`), runs them through
//  `FaceSwipeTracker`, and publishes where the faces sit for
//  `ExpandedNotchView` to draw.
//
//  The faces move by a SwiftUI offset set straight from the scroll deltas —
//  one change per event, no clock of our own — and settle with one spring
//  when the gesture's own end phase arrives. Kept apart from
//  `IslandPresentation` so a publish per scroll event redraws the pager's
//  few views and not the whole island.
//

import AppKit
import SwiftUI

@MainActor
final class FacePager: ObservableObject {
    /// The face coming in behind the one on screen, and which side it's on
    /// (-1 left, the previous face; +1 right, the next).
    struct Neighbor: Equatable {
        var tab: IsleTab
        var side: Int
    }

    /// The face the offset is measured from. Nil while nothing is moving;
    /// a face that doesn't match `expandedPlace` (an interrupt took the
    /// panel mid-swipe) is drawn plain, at rest.
    @Published private(set) var current: IsleTab?

    /// How far the face on screen sits from home, in points. Negative is to
    /// the left, with the next face coming in on the right.
    @Published private(set) var offset: CGFloat = 0

    @Published private(set) var neighbor: Neighbor?

    /// From one face's home to the next: the content's width plus a gap the
    /// size of the panel's two side insets, so a face leaving the content
    /// area is exactly off the panel as its neighbour arrives.
    let page = NotchMetrics.expandedSize.width

    private lazy var tracker = FaceSwipeTracker(page: page)

    /// Bumped by every move, so a settle that finishes after a newer gesture
    /// has taken over doesn't tidy away the new gesture's neighbour.
    private var generation = 0

    /// The settle's spring: firm enough to land promptly, damped so a face
    /// doesn't bounce past its home and show the gap.
    private static let settleStiffness: Double = 300
    private static let settleDamping: Double = 31

    /// A scroll event on this island's window, while its panel is open.
    /// Returns whether it was a face swipe, which nothing else should see.
    func handle(_ event: NSEvent, content: NotchViewModel) -> Bool {
        // Only inside a face, and only with somewhere to go. Home lays every
        // face out at once, so a swipe there has nothing to do.
        guard content.showsHome, let face = content.expandedPlace.face else {
            if current != nil { reset() }
            return false
        }
        // The face changed under the fingers (an approval took the panel):
        // this gesture is over as far as paging goes.
        if let current, current != face {
            reset()
        }

        let result = tracker.handle(
            SwipeSample(event),
            canGoBack: content.neighbor(of: face, step: -1) != nil,
            canGoForward: content.neighbor(of: face, step: 1) != nil
        )

        switch result.change {
        case .track(let offset, let side)?:
            generation += 1
            current = face
            self.offset = offset
            neighbor = content.neighbor(of: face, step: side).map { Neighbor(tab: $0, side: side) }
        case .settle(let step, let velocity)?:
            settle(step: step, velocity: velocity, from: face, content: content)
        case nil:
            break
        }
        return result.verdict == .consume
    }

    /// Back to rest at once, no animation: the panel closed, or the faces
    /// changed under a gesture.
    func reset() {
        tracker.drop()
        generation += 1
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) {
            current = nil
            neighbor = nil
            offset = 0
        }
    }

    /// The gesture ended. Landing on the neighbour makes it the face *now* —
    /// the crumb and every "where am I" read it at once — with the face it
    /// pushed out kept alongside, where it was, as the spring brings the new
    /// one home.
    private func settle(step: Int, velocity: CGFloat, from face: IsleTab, content: NotchViewModel) {
        generation += 1
        let settling = generation

        if step != 0, let target = content.neighbor(of: face, step: step) {
            // In one untimed transaction: the face changes without the
            // cross-fade a tile click gets, and the offset re-bases onto the
            // new face so nothing on screen moves in this frame.
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) {
                content.selectTab(target)
                current = target
                neighbor = Neighbor(tab: face, side: -step)
                offset += CGFloat(step) * page
            }
        }

        // The spring starts at the fingers' speed, so a flick carries on
        // into the settle rather than stopping dead and restarting. Relative
        // to the distance left, as the spring wants it.
        let initial = offset == 0 ? 0 : max(-30, min(30, Double(-velocity / offset)))
        let spring = Animation.interpolatingSpring(
            mass: 1, stiffness: Self.settleStiffness, damping: Self.settleDamping, initialVelocity: initial
        )
        withAnimation(spring, completionCriteria: .logicallyComplete) {
            offset = 0
        } completion: { [weak self] in
            // The face it left is off the panel now; let it go.
            guard let self, self.generation == settling else { return }
            self.current = nil
            self.neighbor = nil
        }
    }
}

extension SwipeSample {
    /// A scroll event, with the deltas turned to follow the fingers. AppKit
    /// reports them as the content should move, which is the fingers' way
    /// round only under natural scrolling; a face is something you push, so
    /// it goes where the fingers go either way.
    init(_ event: NSEvent) {
        let sign: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
        self.init(
            phase: SwipePhase(event.phase),
            momentum: SwipePhase(event.momentumPhase),
            dx: event.scrollingDeltaX * sign,
            dy: event.scrollingDeltaY * sign,
            time: event.timestamp
        )
    }
}

extension SwipePhase {
    init(_ phase: NSEvent.Phase) {
        if phase.contains(.mayBegin) { self = .mayBegin }
        else if phase.contains(.began) { self = .began }
        else if phase.contains(.changed) { self = .changed }
        else if phase.contains(.stationary) { self = .stationary }
        else if phase.contains(.ended) { self = .ended }
        else if phase.contains(.cancelled) { self = .cancelled }
        else { self = .none }
    }
}
