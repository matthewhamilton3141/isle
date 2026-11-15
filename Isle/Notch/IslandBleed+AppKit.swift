//
//  IslandBleed+AppKit.swift
//
//  What moves the haze (`IslandBleed`).
//
//  `IslandBleedDriver` follows the island: every time its window moves
//  (each drag event of a carry, each step of a glide home, which
//  `NotchWindow.didSlide` reports), it reads where the island is drawn,
//  works out the haze and hands it to the island's fill
//  (`IslandBleedModel`). Nothing runs between moves. `IslandCarry` starts
//  it when the island is taken off the notch or picked up, and ends it:
//  once home, where the docked look takes over, or when the island is put
//  down elsewhere, when the haze fades on the close spring.
//

import AppKit
import SwiftUI

@MainActor
final class IslandBleedDriver {
    private let presentation: IslandPresentation

    /// The island as drawn, in screen coordinates; nil before a layout.
    var drawnRect: () -> CGRect? = { nil }
    var reduceMotion: () -> Bool = { false }

    /// The screen's frame and its camera housing; nil on a display with
    /// none. The island's metrics, as Isle runs.
    lazy var stage: () -> (screen: CGRect, housing: CGSize)? = { [weak self] in
        guard let metrics = self?.presentation.metrics, metrics.hasPhysicalNotch else { return nil }
        return (metrics.screen.frame, metrics.notchSize)
    }

    /// Between `engage` and `release`: following the island.
    private(set) var engaged = false

    /// The closeness the island was picked up at, when that was already
    /// within reach (put down near the notch and picked up again): the
    /// haze starts from nothing there and comes in as the island is
    /// brought closer, rather than appearing whole in the hand. 0 for an
    /// island taken off the notch, which starts merged.
    private var floor: CGFloat = 0

    /// Counts releases, so a finished fade only clears up if it's still
    /// the latest thing that happened.
    private var drainID = 0

    init(presentation: IslandPresentation) {
        self.presentation = presentation
    }

    // MARK: - Following

    /// Starts following the island: taken off the notch (`fromNotch`), or
    /// picked up, or sent home from where it was.
    func engage(fromNotch: Bool) {
        drainID &+= 1
        engaged = true
        floor = 0
        if !fromNotch, let scene = scene() {
            floor = IslandBleed.closeness(distance: IslandBleed.distance(scene))
        }
        follow()
    }

    /// The island moved (or changed): draw the haze for where it is now.
    func follow() {
        guard engaged else { return }
        guard let scene = scene() else {
            publish(nil)
            return
        }
        var c = IslandBleed.closeness(distance: IslandBleed.distance(scene))
        if floor > 0 {
            if c <= 0 {
                floor = 0
            } else {
                c = floor >= 1 ? 0 : max(0, (c - floor) / (1 - floor))
            }
        }
        publish(IslandBleed.stain(scene, distance: IslandBleed.distance(closeness: c)))
    }

    /// Stops following. `drain`: the island was put down away from the
    /// notch, and the haze fades on the close spring; otherwise it goes at
    /// once (home, where the docked look takes over, or the island
    /// re-placed or hidden).
    func release(drain: Bool) {
        let wasEngaged = engaged
        engaged = false
        floor = 0
        drainID &+= 1
        let id = drainID
        guard presentation.bleed.stain != nil else { return }
        guard wasEngaged, drain, !reduceMotion() else {
            presentation.bleed.stain = nil
            return
        }
        withAnimation(.notchClose) {
            presentation.bleed.stain?.opacity = 0
        } completion: { [weak self] in
            guard let self, self.drainID == id else { return }
            self.presentation.bleed.stain = nil
        }
    }

    // MARK: - Reading the island

    /// The island in `IslandBleed`'s space: y down from the screen's top
    /// edge, x from its centre line (the housing's).
    private func scene() -> IslandBleed.Scene? {
        guard let stage = stage(), let drawn = drawnRect(), drawn.width > 0, drawn.height > 0 else { return nil }
        let rect = CGRect(
            x: drawn.minX - stage.screen.midX,
            y: stage.screen.maxY - drawn.maxY,
            width: drawn.width,
            height: drawn.height
        )
        // The straight part of the top edge: none of a capsule's ends, and
        // on an open card the roundest of the modes' corners (Prism's). On
        // the notch the top is flat.
        let crown: CGFloat
        if !presentation.placement.isFloating {
            crown = 0
        } else if presentation.state.isExpanded {
            crown = max(IslandFloat.prismCrownRadius, IslandFloat.cornerRadius)
        } else {
            crown = drawn.height / 2
        }
        return IslandBleed.Scene(housing: stage.housing, island: rect, crown: crown)
    }

    private func publish(_ stain: IslandBleed.Stain?) {
        // Each drag event's own value, unanimated: where the island is.
        guard presentation.bleed.stain != stain else { return }
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { presentation.bleed.stain = stain }
    }
}
