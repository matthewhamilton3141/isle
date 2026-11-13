//
//  IslandBleed.swift
//
//  The notch's black reaching for an island that's carried toward it, and
//  letting go of one that's pulled away. Matthew: "when the detached island
//  gets closer to physical notch it could make like a little animation like
//  its start to bleed onto the island kinda, and reversed for when u detach
//  it".
//
//  Two drops coming together. Far off, nothing. Within `reach` of the
//  camera housing a drip of black swells out of the housing's foot toward
//  the island, and a smaller one rises off the island's top edge toward
//  it; they lengthen, sharpen and touch at `joinGap`. From there it is one
//  neck, the housing's foot to the island's top, thickening the closer the
//  island comes, its feet spreading along both edges, until at contact it
//  is as wide as the housing's flat bottom and the island docks. On the
//  island the black spreads from the neck's foot (`Stain`), and at contact
//  it is the docked look's own: the camera's black spread out
//  (`IslandPrism.BandStyle.spread`), anchored on the camera, so it hands
//  over to the docked panel without a change. Pulled away, the same in
//  reverse: the neck stretches, thins, snaps at its waist into two points,
//  and each drains back into the side it came from.
//
//  A function of where the island is and nothing else: no clock. If the
//  pointer stops, the black stops where it is. Docking and undocking move
//  the window (`IslandCarry`, `IslandGlide`), and the bleed follows the
//  window. Only on a display with a camera housing: on one without, there
//  is nothing physical for black to bleed from, and nothing is drawn.
//
//  All in one space: points, y down from the screen's top edge, x from the
//  housing's centre line. Kept free of AppKit and SwiftUI so it compiles on
//  its own (scripts/test-island-bleed.sh). Drawn by IslandBleed+AppKit.swift
//  (the neck, in a click-through window of its own over the gap) and
//  IslandBleed+SwiftUI.swift (the black on the island, in its fill).
//

import CoreGraphics
import Foundation

enum IslandBleed {
    // MARK: - Tunables

    /// How far from the camera housing the island starts to be reached for,
    /// in points: from the housing's foot to the island's top edge (or its
    /// nearest corner of it, off to one side). Matthew's "when the detached
    /// island gets closer to physical notch". The notch takes the island
    /// back once its top is about 18pt under the housing on this Mac
    /// (`IslandPlacementBounds.snapReach`), so this is the approach before
    /// that. Tune here.
    static let reach: CGFloat = 110

    /// Where the two drips touch and become one neck, in points of gap.
    /// Past the notch's snap reach, so the neck has formed before the notch
    /// takes the island, and is what is seen being pulled thin and snapping
    /// on the way out. Tune here.
    static let joinGap: CGFloat = 46

    /// How much of the way the notch's drip comes, against the island's
    /// (the rest): the notch is what reaches ("its start to bleed onto the
    /// island"), so most of it; it's also where the neck's waist is. Tune
    /// here.
    static let notchShare: CGFloat = 0.64

    /// The half-widths of the two drips' bases where they touch, in points:
    /// on the housing's foot, and on the island's top edge. From there the
    /// neck's feet spread to the housing's whole flat bottom at contact.
    /// Tune here.
    static let notchDrip: CGFloat = 34
    static let islandDrip: CGFloat = 26

    /// How far through the approach (0 at `reach`, 1 at `joinGap`) the drips'
    /// round tips start to draw out to the points that touch. Earlier gives
    /// longer, sharper drips; later keeps them round until just before they
    /// meet. Tune here.
    static let pointing: CGFloat = 0.8

    /// The neck's waist, as a fraction of its feet (the narrower of the two)
    /// at contact, and how it gets there: the fraction is reached as
    /// `(1 − gap / joinGap) ^ neckCurve`. Above 1 the neck stays a thread for
    /// a while after it joins and thickens fast near the end — the thicker
    /// the closer, as Matthew had it — and when pulled out it thins and lets
    /// go quickly. Tune here.
    static let neckFullness: CGFloat = 0.92
    static let neckCurve: CGFloat = 1.6

    /// How round the drips' and the neck's walls are: each wall is a curve
    /// that leaves its foot along the edge (a fillet into the housing or the
    /// island) and arrives at the tip or the waist. These are its handles,
    /// as fractions of the run along the edge and of the depth. Tune here.
    /// A drip's fillet is tighter than the neck's, so its body is a bulb
    /// hanging off the edge rather than a thorn.
    static let footHandle: CGFloat = 0.58
    static let dripFootHandle: CGFloat = 0.22
    static let waistHandle: CGFloat = 0.5
    static let tipHandle: CGFloat = 0.8

    /// How far the black spreads onto the island at contact: along its top
    /// edge from the neck's foot, and down into it. The docked spread's own
    /// (`IslandPrism.spreadAcross`, `spreadDown`), so the bleed ends as the
    /// docked look begins. Scaled down with distance. Matthew's "start to
    /// bleed onto the island". Tune there.
    static var stainAcross: CGFloat { IslandPrism.spreadAcross }
    static var stainDown: CGFloat { IslandPrism.spreadDown }

    /// How soon in the approach the black on the island comes in at all:
    /// over the first this-much of the closeness. Tune here.
    static let stainFadeIn: CGFloat = 0.25

    /// Over the last points of gap the black on the island moves from the
    /// neck's foot to the housing above it, the docked spread's anchor.
    static let stainHug: CGFloat = 6

    /// How far each end of the neck runs on past its foot, out of sight:
    /// up under the camera housing, and down under the island's top edge, so
    /// neither join has an edge of its own. Tune here.
    static let tuck: CGFloat = 3

    /// The housing's bottom corners (nothing reports them): the neck's feet
    /// stay on the flat between them.
    static var housingCorner: CGFloat { IslandPrism.notchCornerRadius }

    /// Less gap than this and there is no neck to draw.
    static let minimumGap: CGFloat = 0.5

    // MARK: - The scene

    /// The housing and the island as they are now.
    struct Scene: Equatable {
        /// The physical camera housing, hanging from the top edge, centred.
        var housing: CGSize
        /// The island's drawn rect.
        var island: CGRect
        /// The radius of the island's top corners: the neck lands on the
        /// straight part of its top edge between them. 0 on the notch.
        var crown: CGFloat

        /// Half the housing's flat bottom.
        var housingFlat: CGFloat { max(housing.width / 2 - IslandBleed.housingCorner, 0) }

        /// The straight part of the island's top edge.
        var islandFlat: (left: CGFloat, right: CGFloat) {
            let left = island.minX + crown, right = island.maxX - crown
            return left <= right ? (left, right) : (island.midX, island.midX)
        }

        /// From the housing's foot down to the island's top edge; less than
        /// 0 when the island is up beside or under the housing.
        var gap: CGFloat { island.minY - housing.height }
    }

    /// How far the island is from the housing: from the housing's flat
    /// bottom to the flat of the island's top edge. 0 touching, and while
    /// the island is up over the housing's foot.
    static func distance(_ scene: Scene) -> CGFloat {
        let flat = scene.islandFlat, half = scene.housingFlat
        let dx = max(0, flat.left - half, -half - flat.right)
        let dy = max(scene.gap, 0)
        return (dx * dx + dy * dy).squareRoot()
    }

    /// 0 at `reach` and beyond, 1 touching.
    static func closeness(distance d: CGFloat) -> CGFloat {
        min(max(1 - d / reach, 0), 1)
    }

    /// The distance a closeness means: `closeness`'s inverse within reach.
    static func distance(closeness c: CGFloat) -> CGFloat {
        reach * (1 - min(max(c, 0), 1))
    }

    // MARK: - The neck

    /// One wall: a cubic from its foot to its tip or waist.
    struct Wall: Equatable {
        var foot: CGPoint
        var control1: CGPoint
        var control2: CGPoint
        var end: CGPoint
    }

    /// The black between the housing and the island at one distance: two
    /// drips, or one neck.
    struct Bridge: Equatable {
        /// One neck (true), or two drips that haven't touched.
        var joined: Bool
        /// The walls of the housing's side, from its feet on the housing's
        /// foot: to the drip's tip, or to the waist.
        var notchLeft: Wall
        var notchRight: Wall
        /// The walls of the island's side, from its feet on the island's top
        /// edge: to its drip's tip, or to the waist (the neck's lower half).
        var islandLeft: Wall
        var islandRight: Wall
        /// The feet: centre and half-width, on the housing and on the island.
        var notchCentre: CGFloat
        var notchHalf: CGFloat
        var islandCentre: CGFloat
        var islandHalf: CGFloat
        /// The neck's waist half-width (0 for drips).
        var waist: CGFloat
        /// The housing's foot and the island's top edge.
        var housingFoot: CGFloat
        var islandTop: CGFloat
    }

    static func smooth(_ t: CGFloat) -> CGFloat {
        let u = min(max(t, 0), 1)
        return u * u * (3 - 2 * u)
    }

    /// The black between the housing and the island, `d` from it (normally
    /// `distance(scene)`; `IslandBleedDriver` passes more while an island
    /// picked up near the notch hasn't yet been brought closer). Nil: none.
    static func bridge(_ scene: Scene, distance d: CGFloat) -> Bridge? {
        let foot = scene.housing.height, top = scene.island.minY
        guard d < reach, top - foot > minimumGap else { return nil }
        let hf = scene.housingFlat
        let flat = scene.islandFlat
        let joined = d <= joinGap

        var notchHalf: CGFloat, islandHalf: CGFloat
        let point: CGFloat  // 0 a round tip … 1 a point (the neck's waist is one)
        var reachFraction: CGFloat = 1
        var waistFraction: CGFloat = 0
        if joined {
            let u = 1 - d / joinGap
            let e = smooth(u)
            notchHalf = notchDrip + (hf - notchDrip) * e
            islandHalf = islandDrip + (hf - islandDrip) * e
            point = 1
            waistFraction = pow(u, neckCurve)
        } else {
            let s = (reach - d) / (reach - joinGap)
            let e = smooth(s)
            notchHalf = notchDrip * e.squareRoot()
            islandHalf = islandDrip * e.squareRoot()
            point = smooth((s - pointing) / (1 - pointing))
            // Together the drips cover this much of the way; all of it at
            // the join. Never more: the gap is at least the distance.
            reachFraction = e * joinGap / max(d, joinGap)
        }
        notchHalf = min(notchHalf, hf)
        islandHalf = min(islandHalf, (flat.right - flat.left) / 2)

        // Where the two flat edges face each other, both feet stand on the
        // middle of that, so the neck runs straight down; where they don't,
        // each foot goes as far toward the other as its own edge allows.
        let lo = max(-hf, flat.left), hi = min(hf, flat.right)
        let notchCentre: CGFloat, islandCentre: CGFloat
        if lo <= hi {
            let middle = (lo + hi) / 2
            notchCentre = min(max(middle, -hf + notchHalf), hf - notchHalf)
            islandCentre = min(max(middle, flat.left + islandHalf), flat.right - islandHalf)
        } else {
            notchCentre = min(max((flat.left + flat.right) / 2, -hf + notchHalf), hf - notchHalf)
            islandCentre = min(max(notchCentre, flat.left + islandHalf), flat.right - islandHalf)
        }
        let p0 = CGPoint(x: notchCentre, y: foot)
        let p1 = CGPoint(x: islandCentre, y: top)
        let v = CGPoint(x: p1.x - p0.x, y: p1.y - p0.y)
        let length = (v.x * v.x + v.y * v.y).squareRoot()
        guard length > minimumGap else { return nil }
        let a = CGPoint(x: v.x / length, y: v.y / length)   // along the neck, down
        // Across it, left to right: level, whatever the neck's slant, so a
        // waist never rises above the housing's foot or sinks below the
        // island's edge.
        let r = CGPoint(x: 1, y: 0)
        let waist = joined ? neckFullness * min(notchHalf, islandHalf) * waistFraction : 0

        func at(_ base: CGPoint, _ along: CGFloat, _ across: CGFloat) -> CGPoint {
            CGPoint(x: base.x + a.x * along + r.x * across, y: base.y + a.y * along + r.y * across)
        }
        let waistCentre = at(p0, notchShare * length, 0)
        let notchEnd: (left: CGPoint, right: CGPoint)
        let islandEnd: (left: CGPoint, right: CGPoint)
        if joined {
            notchEnd = (at(waistCentre, 0, -waist), at(waistCentre, 0, waist))
            islandEnd = notchEnd
        } else {
            let tip = at(p0, notchShare * reachFraction * length, 0)
            let islandTip = at(p1, -(1 - notchShare) * reachFraction * length, 0)
            notchEnd = (tip, tip)
            islandEnd = (islandTip, islandTip)
        }

        let angle = point * .pi / 2
        /// A wall from `foot` to `end`, arriving moving along `arrive`.
        func wall(_ foot: CGPoint, _ end: CGPoint, arrive: CGPoint) -> Wall {
            let run = end.x - foot.x
            let along = abs((end.x - foot.x) * a.x + (end.y - foot.y) * a.y)
            let across = abs((end.x - foot.x) * r.x + (end.y - foot.y) * r.y)
            // A drip's tight fillet opens to the neck's as its tip draws to
            // a point, so the two are the same wall where they touch.
            let k1 = (dripFootHandle + (footHandle - dripFootHandle) * point) * abs(run)
            let k2 = cos(angle) * tipHandle * across + sin(angle) * waistHandle * along
            return Wall(
                foot: foot,
                // Along the edge it stands on: a fillet into it.
                control1: CGPoint(x: foot.x + (run >= 0 ? k1 : -k1), y: foot.y),
                control2: CGPoint(x: end.x - arrive.x * k2, y: end.y - arrive.y * k2),
                end: end
            )
        }
        let c = cos(angle), s = sin(angle)
        // Moving toward the far wall at a round tip, along the neck at a point.
        let downRight = CGPoint(x: c * r.x + s * a.x, y: c * r.y + s * a.y)
        let downLeft = CGPoint(x: -c * r.x + s * a.x, y: -c * r.y + s * a.y)
        let upRight = CGPoint(x: c * r.x - s * a.x, y: c * r.y - s * a.y)
        let upLeft = CGPoint(x: -c * r.x - s * a.x, y: -c * r.y - s * a.y)
        return Bridge(
            joined: joined,
            notchLeft: wall(CGPoint(x: notchCentre - notchHalf, y: foot), notchEnd.left, arrive: downRight),
            notchRight: wall(CGPoint(x: notchCentre + notchHalf, y: foot), notchEnd.right, arrive: downLeft),
            islandLeft: wall(CGPoint(x: islandCentre - islandHalf, y: top), islandEnd.left, arrive: upRight),
            islandRight: wall(CGPoint(x: islandCentre + islandHalf, y: top), islandEnd.right, arrive: upLeft),
            notchCentre: notchCentre,
            notchHalf: notchHalf,
            islandCentre: islandCentre,
            islandHalf: islandHalf,
            waist: waist,
            housingFoot: foot,
            islandTop: top
        )
    }

    // MARK: - As a path

    /// The bridge as points, in the one order its path is always built in,
    /// so any two outlines can be animated one into the other point by point
    /// (the drain, `IslandBleedDriver`). The housing's piece is
    /// `notchPoints` points: its left foot (tucked, then on the edge), its
    /// left wall, then — joined — the neck's lower left wall down to the
    /// island, along under the island's edge, and up the lower right wall;
    /// apart, those collapse onto the tip; then its right wall back up and
    /// its right foot. The island's piece is `islandPoints`: its drip, or,
    /// joined, nothing at its foot's centre.
    struct Outline: Equatable {
        var notch: [CGPoint]
        var island: [CGPoint]

        static let notchPoints = 18
        static let islandPoints = 9

        /// The path, moved by `offset`.
        func path(offset: CGPoint = .zero) -> CGPath {
            let p = CGMutablePath()
            func pt(_ q: CGPoint) -> CGPoint { CGPoint(x: q.x + offset.x, y: q.y + offset.y) }
            let n = notch.map(pt), i = island.map(pt)
            p.move(to: n[0]); p.addLine(to: n[1])
            p.addCurve(to: n[4], control1: n[2], control2: n[3])
            p.addCurve(to: n[7], control1: n[5], control2: n[6])
            p.addLine(to: n[8]); p.addLine(to: n[9]); p.addLine(to: n[10])
            p.addCurve(to: n[13], control1: n[11], control2: n[12])
            p.addCurve(to: n[16], control1: n[14], control2: n[15])
            p.addLine(to: n[17])
            p.closeSubpath()
            p.move(to: i[0]); p.addLine(to: i[1])
            p.addCurve(to: i[4], control1: i[2], control2: i[3])
            p.addCurve(to: i[7], control1: i[5], control2: i[6])
            p.addLine(to: i[8])
            p.closeSubpath()
            return p
        }

        /// Drawn back into where each piece came from: the housing's into
        /// its foot, the island's into its top edge. What a bridge drains
        /// to when the island is put down away from the notch.
        func retracted(housingFoot: CGFloat, islandTop: CGFloat, notchCentre: CGFloat, islandCentre: CGFloat) -> Outline {
            Outline(
                notch: notch.map { CGPoint(x: notchCentre + ($0.x - notchCentre) * 0.6, y: min($0.y, housingFoot)) },
                island: island.map { CGPoint(x: islandCentre + ($0.x - islandCentre) * 0.6, y: max($0.y, islandTop)) }
            )
        }
    }

    static func outline(_ b: Bridge) -> Outline {
        let tuck = IslandBleed.tuck
        func up(_ q: CGPoint) -> CGPoint { CGPoint(x: q.x, y: q.y - tuck) }
        func down(_ q: CGPoint) -> CGPoint { CGPoint(x: q.x, y: q.y + tuck) }
        let nl = b.notchLeft, nr = b.notchRight, il = b.islandLeft, ir = b.islandRight
        var notch = [up(nl.foot), nl.foot, nl.control1, nl.control2, nl.end]
        if b.joined {
            notch += [il.control2, il.control1, il.foot, down(il.foot), down(ir.foot), ir.foot, ir.control1, ir.control2, ir.end]
        } else {
            notch += Array(repeating: nl.end, count: 9)
        }
        notch += [nr.control2, nr.control1, nr.foot, up(nr.foot)]
        let island: [CGPoint]
        if b.joined {
            island = Array(repeating: CGPoint(x: b.islandCentre, y: b.islandTop), count: Outline.islandPoints)
        } else {
            island = [down(il.foot), il.foot, il.control1, il.control2, il.end, ir.control2, ir.control1, ir.foot, down(ir.foot)]
        }
        return Outline(notch: notch, island: island)
    }

    // MARK: - On the island

    /// The black on the island: solid over `halfWidth` either side of
    /// `centre` down to `foot`, and let go from there over `across` to the
    /// sides and `down` below, round its corners the ellipse between —
    /// the docked spread's shape (`IslandPrism.spreadAlpha`), drawn from the
    /// neck's foot instead of the camera while the island is clear of it.
    /// In the island's own space: x from its horizontal centre (which a
    /// change of width leaves where it is), y from its top edge.
    struct Stain: Equatable {
        var centre: CGFloat
        var halfWidth: CGFloat
        var foot: CGFloat
        var across: CGFloat
        var down: CGFloat
        var opacity: Double
    }

    /// The black on the island at `d` (see `bridge`), given the bridge
    /// drawn there.
    static func stain(_ scene: Scene, distance d: CGFloat, bridge: Bridge?) -> Stain? {
        let c = closeness(distance: d)
        guard c > 0 else { return nil }
        let k = smooth(c)
        let mid = scene.island.midX
        // Anchored on the housing: its centre, its width, and — where it
        // reaches over the island's top — as deep as the docked spread is
        // solid (the housing and a point).
        let housingCentre = -mid
        let housingHalf = scene.housing.width / 2
        let foot = max(scene.housing.height + IslandPrism.spreadFoot - scene.island.minY, 0)
        var centre = housingCentre, half = housingHalf
        if let bridge {
            // Clear of the housing: from the neck's foot, moving over to the
            // housing in the last points before contact.
            let t = min(max(scene.gap / stainHug, 0), 1)
            centre = housingCentre + (bridge.islandCentre - mid - housingCentre) * t
            half = housingHalf + (bridge.islandHalf - housingHalf) * t
        }
        return Stain(
            centre: centre,
            halfWidth: half,
            foot: foot,
            across: stainAcross * k,
            down: stainDown * k,
            opacity: Double(smooth(c / stainFadeIn))
        )
    }

    /// The docked spread's let-go: 1 at `t` 0 (the solid's edge), 0 at 1
    /// (its reach), as `IslandPrism.spreadAlpha` lets go.
    static func falloff(_ t: Double) -> Double {
        guard t > 0 else { return 1 }
        guard t < 1 else { return 0 }
        let lightness = 1 - pow(1 - t, IslandPrism.spreadEase)
        return 1 - pow(lightness, IslandPrism.spreadLightness)
    }

    /// The stain's black at a point of the island's space.
    static func stainAlpha(x: CGFloat, y: CGFloat, stain s: Stain) -> Double {
        let qx = max(abs(x - s.centre) - s.halfWidth, 0)
        let qy = max(y - s.foot, 0)
        if qx == 0, qy == 0 { return s.opacity }
        if s.across <= 0 || s.down <= 0 { return 0 }
        let tx = Double(qx / s.across), ty = Double(qy / s.down)
        return falloff((tx * tx + ty * ty).squareRoot()) * s.opacity
    }
}
