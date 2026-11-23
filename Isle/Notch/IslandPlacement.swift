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
//  fits below it, else up from the capsule's bottom edge. Sideways, near
//  the screen's left or right edge it's pinned to that side: the capsule's
//  end on that side stays put, and everything it grows into — a wider
//  capsule, the swell, the open panel — grows away from it, in one motion.
//  Elsewhere it grows from its middle. Opened by a hover, it grows out
//  from the capsule every way at once, up and down as well as sideways,
//  leaning back along the way the pointer came (`IslandApproach`,
//  `IslandOpening.rise`). The capsule itself never moves for
//  any of it: the window is placed for the open panel, and the capsule is
//  drawn inside it wherever `anchor` puts it.
//
//  Kept free of AppKit and SwiftUI so it compiles on its own for scripts
//  (scripts/test-island-placement.sh).
//

import CoreGraphics

enum IslandPlacement: Equatable {
    /// On the notch (or, on a screen without one, where the notch would be).
    case docked

    /// Off the notch. `anchor` is on the closed capsule's top edge — its
    /// middle, or its left or right end where it's pinned to that side
    /// (`IslandOpening.pin`) — in global screen coordinates (AppKit's:
    /// origin bottom-left, y up). The open panel hangs from it, or stands
    /// on the capsule's bottom edge (`IslandOpening`).
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
    /// Which side of the island stays put as it grows.
    enum Pin: Equatable {
        /// Its middle: it grows both ways.
        case centre
        /// Its left end: it grows rightward, away from the screen's left
        /// edge.
        case leading
        /// Its right end: it grows leftward.
        case trailing
        /// A point `fraction` of the way along from its left end (0 to 1):
        /// it grows both ways, unevenly — `fraction` of what it gains to
        /// the left of that point, the rest to the right. How a hover from
        /// beyond one end opens it (`IslandApproach`).
        case lean(CGFloat)

        /// How far along the island, from its left end, the point that
        /// stays put is: 0 its left end, ½ its middle, 1 its right end.
        var fraction: CGFloat {
            switch self {
            case .centre: return 0.5
            case .leading: return 0
            case .trailing: return 1
            case .lean(let fraction): return fraction
            }
        }
    }

    /// How much of what the island gains in height it gains above the
    /// capsule, 0 to 1: 0 hangs it from the capsule's top edge (down), 1
    /// stands it on its bottom edge (up), and between, it grows both ways
    /// from the capsule — how a hover opens it (`IslandApproach`). The
    /// capsule itself stays where it is for any of them.
    var rise: CGFloat
    /// How far right of the anchor the window's centre is, in points
    /// (negative: left): where the widest open panel is centred. Pinned,
    /// half that panel's width, so it reaches from the anchor away from
    /// the edge; in the middle of the screen nothing.
    var shift: CGFloat
    /// What stays put (`Pin`). The anchor is that point of the capsule.
    var pin: Pin = .centre

    init(rise: CGFloat, shift: CGFloat, pin: Pin = .centre) {
        self.rise = rise
        self.shift = shift
        self.pin = pin
    }

    /// Wholly up or wholly down.
    init(upward: Bool, shift: CGFloat, pin: Pin = .centre) {
        self.init(rise: upward ? 1 : 0, shift: shift, pin: pin)
    }

    /// Standing on the capsule's bottom edge: all of it above.
    var upward: Bool { rise >= 1 }
    /// Hanging from the capsule's top edge, as on the notch.
    var hangs: Bool { rise <= 0 }

    /// How far below the top of a room `room` tall the island is drawn,
    /// `height` tall now (closed, open, or on the way), the capsule
    /// `pillHeight` tall: the room is placed so the capsule is at the
    /// anchor with `rise` of everything above it, so anything shorter than
    /// the room sits `rise` of the difference down from its top. 0 hanging;
    /// standing, on the room's floor.
    func drop(in room: CGFloat, height: CGFloat) -> CGFloat {
        rise * max(room - height, 0)
    }

    /// Down from the capsule, centred on it: every island on its notch, and
    /// every one off it with room.
    static let down = IslandOpening(upward: false, shift: 0)

    /// How far right of the window's centre the island is drawn centred,
    /// `width` wide (closed or `open`): pinned, so its pinned end is at the
    /// anchor whatever the width, which the width's spring then keeps there
    /// as it changes — the outline's offset and its width move together.
    /// In the middle the capsule is centred on the anchor and the open
    /// panel on the window.
    func offset(width: CGFloat, open: Bool) -> CGFloat {
        if pin == .centre { return open ? 0 : -shift }
        return width * (0.5 - pin.fraction) - shift
    }

    /// The drawn island's top centre less its anchor, `size` big (closed
    /// or `open`), the capsule `pillHeight` tall: what the notch takes
    /// back when it reaches it. Only centred and opening down is that the
    /// anchor itself; opening up the anchor is the capsule's top under the
    /// panel, and pinned it's one end.
    func topCentre(of size: CGSize, open: Bool, pillHeight: CGFloat) -> CGPoint {
        CGPoint(x: shift + offset(width: size.width, open: open), y: rise * (size.height - pillHeight))
    }

    /// The left end of a capsule `width` wide anchored at `x`.
    func pillMinX(anchor x: CGFloat, width: CGFloat) -> CGFloat {
        x - width * pin.fraction
    }
}

/// Where the pointer came onto a closed capsule from, when a hover opens
/// it: the island then grows out from the capsule in every direction,
/// leaning back along the way the pointer came (Matthew, 2026-11-14:
/// "makes it try to open in the direction the mouse comes from more";
/// 2026-11-22: "it literally grows outwards in all directions but with
/// bias from the negative vector the mouse comes in at").
/// `IslandPlacementBounds.approachLean` says how far it leans.
struct IslandApproach: Equatable {
    /// A unit vector from where the pointer reached the island back
    /// toward where it came from, y up: the way the island leans.
    var dx: CGFloat
    var dy: CGFloat

    /// Normalises `dx`, `dy`; nil for no direction at all.
    init?(dx: CGFloat, dy: CGFloat) {
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 0, length.isFinite else { return nil }
        self.dx = dx / length
        self.dy = dy / length
    }

    /// The approach of a pointer that went through `trail` (oldest first,
    /// the newest where it is now) onto the capsule drawn at `pill`: the
    /// way it was moving, reversed. Too short a trail to say (a pointer
    /// that hardly moved), the way from the capsule's nearest point to
    /// where the pointer was last outside it. Nil when neither says.
    init?(trail: [CGPoint], onto pill: CGRect) {
        if let first = trail.first, let last = trail.last,
           hypot(first.x - last.x, first.y - last.y) >= Self.leastTravel {
            self.init(dx: first.x - last.x, dy: first.y - last.y)
            return
        }
        guard let origin = trail.last(where: { !pill.contains($0) }) else { return nil }
        let nearest = CGPoint(x: min(max(origin.x, pill.minX), pill.maxX),
                              y: min(max(origin.y, pill.minY), pill.maxY))
        self.init(dx: origin.x - nearest.x, dy: origin.y - nearest.y)
    }

    /// How far the trail has to reach for its heading to count: a few
    /// points is jitter, not a way of arriving.
    static let leastTravel: CGFloat = 4
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

    // MARK: Pinning

    /// How far either side of its middle an island grows at most: half the
    /// widest open panel or the widest capsule, whichever is wider. Where
    /// that much room isn't there on one side, it's pinned to the other.
    var room: CGFloat { max(halfWidth, pill.width / 2) }

    /// Whether the visible frame is wide enough to pin at all: an island
    /// pinned near one edge reaches `room` in from it and grows the whole
    /// panel's width further. On anything narrower (no Mac display is) the
    /// island grows from its middle and the panel is moved in to fit.
    var pinsToEdges: Bool { visible.width >= 3 * room }

    /// What stays put for an island anchored at `x`: its left end within
    /// `room` of the visible frame's left edge, its right end within
    /// `room` of its right, else its middle. A function of the anchor
    /// alone, so a remembered anchor comes back the same.
    func pin(at x: CGFloat) -> IslandOpening.Pin {
        guard pinsToEdges else { return .centre }
        if x < visible.minX + room { return .leading }
        if x > visible.maxX - room { return .trailing }
        return .centre
    }

    // MARK: Opening

    /// Which way an island resting at `anchor` opens: down while the
    /// tallest panel fits below the capsule's top inside the visible
    /// frame; else up, standing on the capsule's bottom edge, if it fits
    /// that way; and on a screen too short for either, whichever way has
    /// more room. Decided by the tallest panel, not the face showing, so a
    /// face that grows the panel never flips it over.
    ///
    /// Sideways, pinned near an edge (`pin(at:)`) it grows from the
    /// anchored end away from the edge; in the middle, centred on the
    /// capsule, where there's room for that by the same rule. On a display
    /// too narrow to pin, centred unless that would take it past the
    /// visible frame's left or right edge, then moved in just far enough
    /// (narrower than the panel, to the middle).
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
        switch pin(at: anchor.x) {
        case .leading: return IslandOpening(upward: upward, shift: halfWidth, pin: .leading)
        case .trailing: return IslandOpening(upward: upward, shift: -halfWidth, pin: .trailing)
        case .centre, .lean:  // `pin(at:)` never leans: only a pointer does
            guard !pinsToEdges else { return IslandOpening(upward: upward, shift: 0) }
            let minX = visible.minX + halfWidth, maxX = visible.maxX - halfWidth
            let centre = minX <= maxX ? min(max(anchor.x, minX), maxX) : visible.midX
            return IslandOpening(upward: upward, shift: centre - anchor.x)
        }
    }

    /// Where an open panel `size` big lies for an island resting at
    /// `anchor` and opening as `opening`: hanging from the capsule's top,
    /// standing on its bottom edge, or between (`IslandOpening.rise`),
    /// centred the opening's shift from it.
    func panel(_ size: CGSize, at anchor: CGPoint, opening: IslandOpening) -> CGRect {
        let bottom = anchor.y - pill.height - (1 - opening.rise) * (size.height - pill.height)
        let mid = anchor.x + opening.shift + opening.offset(width: size.width, open: true)
        return CGRect(x: mid - size.width / 2, y: bottom, width: size.width, height: size.height)
    }

    /// Where an island let go at `anchor` comes to rest and which way it
    /// then opens. Open (`open`, the way it opens), it's kept whole on the
    /// screen and keeps its way. Closed — however it got that way, the
    /// grabber clicked included — it's the capsule as it is, `pillWidth`
    /// wide and carried as `carried` says, that's put down: anywhere it is
    /// wholly on the visible frame, right up against its edges, and its
    /// place decides the rest (`pin(at:)`, `opening(at:)`), so a capsule
    /// taken to an edge or a corner grows away from it.
    func putDown(_ anchor: CGPoint, open: IslandOpening?, pillWidth: CGFloat, carried: IslandOpening) -> (anchor: CGPoint, opening: IslandOpening) {
        if let open { return (resting(anchor, open: open), open) }
        return forPlace(anchor, pillWidth: pillWidth, was: carried)
    }

    /// A closed capsule `pillWidth` wide, anchored at `anchor` as `was`
    /// says, anchored again and opening the way its place calls for now —
    /// whichever way it opened before, wherever it was put down open.
    /// Where it's wholly on the visible frame it doesn't move for this.
    /// What's remembered of where it rests; it opens by `forOpen`.
    func forPlace(_ anchor: CGPoint, pillWidth: CGFloat, was: IslandOpening) -> (anchor: CGPoint, opening: IslandOpening) {
        let rest = restingPill(anchor, width: pillWidth, carried: was)
        return (rest, opening(at: rest))
    }

    /// The same capsule, anchored and opening the way it opens *now*,
    /// whatever opens it — a hover, a click, a shortcut, an alert: out from
    /// the capsule every way at once, evenly (Matthew, 2026-11-22: "we want
    /// outwards perfectly"), and on a hover leaning back along the
    /// pointer's way in (`approach`): up and down by `rise`, sideways by a
    /// lean (`IslandOpening.Pin.lean`), each held in to what keeps the
    /// tallest, widest panel on the visible frame. Near a screen edge the
    /// edge's pin stands; the capsule itself doesn't move for any of it.
    func forOpen(_ anchor: CGPoint, pillWidth: CGFloat, was: IslandOpening,
                 approach: IslandApproach?) -> (anchor: CGPoint, opening: IslandOpening) {
        var (rest, opened) = forPlace(anchor, pillWidth: pillWidth, was: was)
        let dx = approach?.dx ?? 0, dy = approach?.dy ?? 0

        // Up and down: `rise` of the growth above the capsule's top, the
        // rest below its bottom. The anchor is the capsule's top either way.
        let tall = tallest - pill.height
        if tall > 0 {
            let most = min((visible.maxY - rest.y) / tall, 1)
            let least = max(1 - (rest.y - pill.height - visible.minY) / tall, 0)
            if least <= most {
                opened.rise = min(max(0.5 + Self.approachLean * dy, least), most)
            }
        }

        guard pinsToEdges, opened.pin == .centre else { return (rest, opened) }
        // Sideways: centred, the anchor is the capsule's middle; leaning
        // it's the point `fraction` along it. The island grows by `gain`
        // (to the widest it gets) around that point, `fraction` of it
        // leftward: held in to what keeps that on the visible frame.
        let w = min(pillWidth, visible.width)
        let left = rest.x - w / 2
        let gain = 2 * room - w
        guard gain > 0 else { return (rest, opened) }
        let most = (left - visible.minX) / gain
        let least = (left + 2 * room - visible.maxX) / gain
        let fraction = min(max(0.5 - Self.approachLean * dx, least), most)
        guard abs(fraction - 0.5) > 0.001, least <= most else { return (rest, opened) }
        return (CGPoint(x: left + fraction * w, y: rest.y),
                IslandOpening(rise: opened.rise, shift: halfWidth * (1 - 2 * fraction), pin: .lean(fraction)))
    }

    /// How far a hover leans the island back along the pointer's way in,
    /// as a share of its growth moved from the far side to the near: a
    /// sixth, so straight along one axis two thirds of it goes toward
    /// where the pointer came from and one third away; on a slant each
    /// axis leans by its part of that. 0 would grow it evenly every way;
    /// ½ would pin it at its far side, as it did (2026-11-14) until
    /// Matthew said "direction shouldnt matter" (2026-11-22).
    static let approachLean: CGFloat = 1.0 / 6

    /// Where a capsule `width` wide, anchored at `anchor` as `carried` says,
    /// comes to rest: moved in until it's wholly on the visible frame, and
    /// anchored again for where it is — its middle, or its end nearer an
    /// edge it hasn't the room to grow toward. It doesn't move for that.
    func restingPill(_ anchor: CGPoint, width: CGFloat, carried: IslandOpening) -> CGPoint {
        guard pinsToEdges else { return resting(anchor) }
        let w = min(width, visible.width)
        let minX = min(max(carried.pillMinX(anchor: anchor.x, width: w), visible.minX), visible.maxX - w)
        let mid = minX + w / 2
        let x: CGFloat
        if mid < visible.minX + room {
            x = minX
        } else if mid > visible.maxX - room {
            x = minX + w
        } else {
            x = mid
        }
        return CGPoint(x: x, y: resting(anchor).y)
    }

    // MARK: Clamping

    /// Where a closed island anchored at `anchor` rests, its width not
    /// known (a remembered place): the nearest anchor on the visible frame
    /// whatever the capsule's width — pinned within reach of an edge, it
    /// grows away from it, and in the middle there's room either side.
    /// On a display too narrow to pin, the nearest with the widest capsule
    /// inside the visible frame.
    func resting(_ anchor: CGPoint) -> CGPoint {
        let clamped = clampPill(anchor, to: visible)
        guard pinsToEdges else { return clamped }
        return CGPoint(x: min(max(anchor.x, visible.minX), visible.maxX), y: clamped.y)
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

    /// Where a closed capsule `width` wide, anchored as `carried` says
    /// (the way it was resting when it was picked up), is carried toward
    /// `anchor`: the capsule itself kept on the screen, right up to its
    /// edges, rather than the widest it could be.
    func carrying(_ anchor: CGPoint, pillWidth width: CGFloat, carried: IslandOpening) -> CGPoint {
        let y = clampPill(anchor, to: screen).y
        let w = min(width, screen.width)
        let minX = min(max(carried.pillMinX(anchor: anchor.x, width: w), screen.minX), screen.maxX - w)
        return CGPoint(x: anchor.x + minX - carried.pillMinX(anchor: anchor.x, width: w), y: y)
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
        // The panel's top is `rise` of its growth above the capsule's top
        // (the anchor), and its bottom the rest below the capsule's bottom.
        let tall = tallest - pill.height
        let y = (rect.minY + pill.height + (1 - opening.rise) * tall, rect.maxY - opening.rise * tall)
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
