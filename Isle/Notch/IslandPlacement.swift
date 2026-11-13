//
//  IslandPlacement.swift
//
//  Where one island is: hanging from its screen's notch, as it always has,
//  or taken off it and left somewhere on the screen.
//
//  Detached, the island is no longer drawn against the camera housing, so
//  nothing about it has to be the hardware's shape or colour: no band to
//  keep clear, no flares into the bezel, and a closed form that can be more
//  than a sliver either side of a cutout.
//
//  The layout inside the window doesn't change with the placement: the
//  island is drawn at the top centre of its window either way, and growing
//  means growing downward from there. Detaching moves the window, so that
//  top centre lands on `anchor`.
//
//  Kept free of AppKit and SwiftUI so it compiles on its own for scripts
//  (scripts/test-island-placement.sh).
//

import CoreGraphics

enum IslandPlacement: Equatable {
    /// On the notch (or, on a screen without one, where the notch would be).
    case docked

    /// Off the notch. `anchor` is the top centre of the drawn island, in
    /// global screen coordinates (AppKit's: origin bottom-left, y up).
    ///
    /// It's where the island was last put down. While it's being carried
    /// the window runs ahead of it (the window moves on every drag event;
    /// this is published when the island is lifted and when it's put down,
    /// so a drag doesn't re-evaluate the island's views per event).
    case floating(anchor: CGPoint)

    var isFloating: Bool {
        if case .floating = self { return true }
        return false
    }

    var anchor: CGPoint? {
        if case .floating(let anchor) = self { return anchor }
        return nil
    }
}

/// The room one screen gives an island that's off its notch: where it may
/// rest, where it may be carried, and how near the notch counts as back on
/// it. One screen's worth — an island stays on the screen it belongs to.
///
/// All in global screen coordinates (origin bottom-left, y up), like
/// `IslandPlacement.anchor`.
struct IslandPlacementBounds: Equatable {
    /// The screen's whole frame, and the part of it clear of the menu bar
    /// and the Dock (`NSScreen.visibleFrame`).
    var screen: CGRect
    var visible: CGRect

    /// Half the widest the island is ever drawn, and the tallest: the panel
    /// always grows downward from the anchor, so a resting anchor leaves
    /// this much room below it and this much either side.
    var halfWidth: CGFloat
    var tallest: CGFloat

    /// The anchor of a docked island: the top centre of the screen.
    var dock: CGPoint { CGPoint(x: screen.midX, y: screen.maxY) }

    // MARK: Clamping

    /// Where an island let go at `anchor` comes to rest: the nearest anchor
    /// from which the tallest panel still fits inside the visible frame.
    func resting(_ anchor: CGPoint) -> CGPoint {
        clamp(anchor, to: visible)
    }

    /// Where an island being carried toward `anchor` is drawn: kept on the
    /// screen, but allowed up over the menu bar — it starts at the very top
    /// when it's taken off the notch, and has to reach the top again to be
    /// put back. It settles into `resting` when it's let go.
    func carrying(_ anchor: CGPoint) -> CGPoint {
        clamp(anchor, to: screen)
    }

    private func clamp(_ anchor: CGPoint, to rect: CGRect) -> CGPoint {
        let minX = rect.minX + halfWidth, maxX = rect.maxX - halfWidth
        let minY = rect.minY + tallest, maxY = rect.maxY
        return CGPoint(
            // A screen too small for the panel: centred, hanging from the top.
            x: minX <= maxX ? min(max(anchor.x, minX), maxX) : rect.midX,
            y: minY <= maxY ? min(max(anchor.y, minY), maxY) : rect.maxY
        )
    }

    // MARK: The way back

    /// How near the notch an island being carried is taken back onto it:
    /// this far either side of the screen's top centre, and this far below
    /// the top edge. Deep enough to take in the menu bar, so pushing the
    /// island up against the top of the screen near the middle docks it.
    static let snapReach = CGSize(width: 70, height: 50)

    /// How much further out an island already pulled onto the notch has to
    /// be carried before it comes off again, so it doesn't flicker on and
    /// off at the edge of the zone.
    static let snapSlack: CGFloat = 14

    /// An island carried to `anchor` is close enough to the notch to dock.
    /// Anything above the top edge counts: the anchor follows the pointer,
    /// which can be pushed against the top of the screen.
    func captures(_ anchor: CGPoint) -> Bool {
        within(anchor, Self.snapReach)
    }

    /// An island already pulled onto the notch stays there while it's
    /// carried inside this slightly larger zone. Also what an island
    /// freshly taken off the notch has to leave before the notch will take
    /// it back mid-carry — it starts inside.
    func holds(_ anchor: CGPoint) -> Bool {
        within(anchor, CGSize(width: Self.snapReach.width + Self.snapSlack,
                              height: Self.snapReach.height + Self.snapSlack))
    }

    private func within(_ anchor: CGPoint, _ reach: CGSize) -> Bool {
        abs(anchor.x - dock.x) <= reach.width && dock.y - anchor.y <= reach.height
    }

    // MARK: Remembering

    /// What's remembered of a placement: how far the anchor sits from the
    /// screen's top centre, or nil on the notch. Relative to the screen, not
    /// global, so it survives the displays being rearranged — which moves
    /// every screen's origin.
    func offset(of placement: IslandPlacement) -> CGPoint? {
        guard let anchor = placement.anchor else { return nil }
        return CGPoint(x: anchor.x - dock.x, y: anchor.y - dock.y)
    }

    /// The placement a remembered offset means on this screen as it is now.
    /// The island can't be lost: an offset that isn't a point on this screen
    /// any more (a smaller display, a changed resolution, nonsense on disk)
    /// docks it, one that is but leaves too little room is brought in to
    /// where the panel fits, and one that lands on the notch is docked.
    func placement(restoring offset: CGPoint?) -> IslandPlacement {
        guard let offset, offset.x.isFinite, offset.y.isFinite else { return .docked }
        let anchor = CGPoint(x: dock.x + offset.x, y: dock.y + offset.y)
        // On the screen, its top edge included (`CGRect.contains` leaves the
        // upper bounds out).
        guard anchor.x >= screen.minX, anchor.x <= screen.maxX,
              anchor.y >= screen.minY, anchor.y <= screen.maxY,
              !captures(anchor)
        else { return .docked }
        return .floating(anchor: resting(anchor))
    }
}
