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
//  On the notch the island is drawn at the top centre of its window and
//  grows downward from there. Off it, it opens toward where there's room
//  (`IslandOpening`): down from the closed capsule while the open panel
//  fits below it, else up from the capsule's bottom edge, and shifted
//  sideways near the screen's left and right edges. The capsule itself
//  never moves for that: the window is placed for the open panel, and the
//  capsule is drawn inside it wherever `anchor` puts it.
//
//  Kept free of AppKit and SwiftUI so it compiles on its own for scripts
//  (scripts/test-island-placement.sh).
//

import CoreGraphics

enum IslandPlacement: Equatable {
    /// On the notch (or, on a screen without one, where the notch would be).
    case docked

    /// Off the notch. `anchor` is the top centre of the closed capsule, in
    /// global screen coordinates (AppKit's: origin bottom-left, y up). The
    /// open panel hangs from it, or stands on the capsule's bottom edge
    /// (`IslandOpening`).
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

/// Which way an island off its notch opens from its closed capsule.
struct IslandOpening: Equatable {
    /// Up from the capsule's bottom edge, rather than down from its top.
    var upward: Bool
    /// How far right of the capsule's centre the open panel's centre is,
    /// in points (negative: left), so the panel stays on the screen near
    /// its left and right edges. The capsule stays where it is.
    var shift: CGFloat

    /// Down from the capsule, centred on it: every island on its notch, and
    /// every one off it with room.
    static let down = IslandOpening(upward: false, shift: 0)
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

    /// Half the open panel's width, and its height at its tallest, the
    /// roof and Prism's lip included: what has to fit on the screen beside
    /// and above or below the capsule when it opens.
    var halfWidth: CGFloat
    var tallest: CGFloat

    /// The closed capsule at its widest and its height: what has to be on
    /// the screen where the island rests. Anywhere it fits, it may rest —
    /// the bottom of the screen and its corners too. (It used to be kept
    /// where the open panel fitted below it, about the bottom quarter of a
    /// laptop screen out of bounds: Matthew, "i cant drag the compacted
    /// pill around to certain spots bc it only expands one way".)
    var pill: CGSize

    /// The anchor of a docked island: the top centre of the screen.
    var dock: CGPoint { CGPoint(x: screen.midX, y: screen.maxY) }

    // MARK: Opening

    /// Which way an island resting at `anchor` opens: down while the
    /// tallest panel fits below the capsule's top inside the visible
    /// frame; else up, standing on the capsule's bottom edge, if it fits
    /// that way; and on a screen too short for either, whichever way has
    /// more room. Sideways it is centred on the capsule unless that would
    /// take it past the visible frame's left or right edge; then it is
    /// moved in just far enough (on a screen narrower than the panel, to
    /// the middle). Decided by the tallest panel, not the face showing, so
    /// a face that grows the panel never flips it over.
    func opening(at anchor: CGPoint) -> IslandOpening {
        let below = anchor.y - visible.minY
        let above = visible.maxY - (anchor.y - pill.height)
        let upward: Bool
        if below >= tallest {
            upward = false
        } else if above >= tallest {
            upward = true
        } else {
            upward = above > below
        }
        let minX = visible.minX + halfWidth, maxX = visible.maxX - halfWidth
        let centre = minX <= maxX ? min(max(anchor.x, minX), maxX) : visible.midX
        return IslandOpening(upward: upward, shift: centre - anchor.x)
    }

    /// Where an open panel `size` big lies for an island resting at
    /// `anchor` and opening as `opening`: hanging from the capsule's top,
    /// or standing on its bottom edge, centred the opening's shift from it.
    func panel(_ size: CGSize, at anchor: CGPoint, opening: IslandOpening) -> CGRect {
        let bottom = opening.upward ? anchor.y - pill.height : anchor.y - size.height
        return CGRect(x: anchor.x + opening.shift - size.width / 2, y: bottom, width: size.width, height: size.height)
    }

    /// Where an island let go at `anchor` comes to rest and which way it
    /// then opens. Open (`open`, the way it opens), it's kept whole on the
    /// screen and keeps its way. Closed — however it got that way, the
    /// grabber clicked included — its place decides (`opening(at:)`), so a
    /// capsule taken to an edge or a corner opens away from it.
    func putDown(_ anchor: CGPoint, open: IslandOpening?) -> (anchor: CGPoint, opening: IslandOpening) {
        if let open { return (resting(anchor, open: open), open) }
        let rest = resting(anchor)
        return (rest, opening(at: rest))
    }

    // MARK: Clamping

    /// Where a closed island let go at `anchor` comes to rest: the nearest
    /// anchor with the whole capsule inside the visible frame.
    func resting(_ anchor: CGPoint) -> CGPoint {
        clampPill(anchor, to: visible)
    }

    /// Where an open panel let go at `anchor` comes to rest, opening the
    /// way it already does: the nearest anchor with the whole panel inside
    /// the visible frame. It keeps its direction while open — turning it
    /// over under the pointer would put it somewhere else — and takes the
    /// one its place calls for the next time it is put down closed.
    func resting(_ anchor: CGPoint, open opening: IslandOpening) -> CGPoint {
        clampPanel(anchor, opening, to: visible)
    }

    /// Where an island being carried toward `anchor` is drawn: kept on the
    /// screen, but allowed up over the menu bar — it starts at the very top
    /// when it's taken off the notch, and has to reach the top again to be
    /// put back. It settles into `resting` when it's let go. Open, the
    /// whole panel is kept on the screen, opening the way it does.
    func carrying(_ anchor: CGPoint, open opening: IslandOpening? = nil) -> CGPoint {
        if let opening { return clampPanel(anchor, opening, to: screen) }
        return clampPill(anchor, to: screen)
    }

    private func clampPill(_ anchor: CGPoint, to rect: CGRect) -> CGPoint {
        let half = pill.width / 2
        return clamp(anchor, x: (rect.minX + half, rect.maxX - half), y: (rect.minY + pill.height, rect.maxY), in: rect)
    }

    /// The panel's centre is the anchor moved by the opening's shift, and
    /// the shift is the anchor's own (it doesn't change while the panel is
    /// open), so the panel is kept on the screen by keeping the anchor in.
    private func clampPanel(_ anchor: CGPoint, _ opening: IslandOpening, to rect: CGRect) -> CGPoint {
        let x = (rect.minX + halfWidth - opening.shift, rect.maxX - halfWidth - opening.shift)
        let y = opening.upward
            ? (rect.minY + pill.height, rect.maxY - tallest + pill.height)
            : (rect.minY + tallest, rect.maxY)
        return clamp(anchor, x: x, y: y, in: rect)
    }

    private func clamp(_ anchor: CGPoint, x: (CGFloat, CGFloat), y: (CGFloat, CGFloat), in rect: CGRect) -> CGPoint {
        CGPoint(
            // A screen too small for it: centred, hanging from the top.
            x: x.0 <= x.1 ? min(max(anchor.x, x.0), x.1) : rect.midX,
            y: y.0 <= y.1 ? min(max(anchor.y, y.0), y.1) : rect.maxY
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
    /// where the capsule fits, and one that lands on the notch is docked.
    /// It comes back closed, so it opens the way its place calls for.
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
