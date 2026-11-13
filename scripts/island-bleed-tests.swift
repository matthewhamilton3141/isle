//
//  island-bleed-tests.swift
//
//  Tests for the notch's black reaching for an island carried near it
//  (Isle/Notch/IslandBleed.swift): the neck as a function of distance —
//  nothing out of reach, two drips that touch exactly where they become
//  one neck, a neck that only thickens as the island comes closer, feet
//  that never leave the housing's flat bottom or the island's top edge,
//  and at contact the housing's full width and the docked spread on the
//  island. Compiled against the SwiftUI-free sources alone. Run with
//  scripts/test-island-bleed.sh.
//

import CoreGraphics
import Foundation

var failures = 0
var passes = 0

func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    if ok {
        passes += 1
        print("  ok    \(name)")
    } else {
        failures += 1
        print("  FAIL  \(name) \(detail())")
    }
}

typealias B = IslandBleed

// This Mac's camera housing, and the closed capsule and the open card.
let housing = CGSize(width: 185, height: 32)
let hf = housing.width / 2 - B.housingCorner
let pill = CGSize(width: 200, height: IslandFloat.pillHeight)
let card = CGSize(width: 496, height: 154)

/// An island `gap` under the housing's foot, its centre `dx` from the
/// housing's.
func scene(_ size: CGSize, gap: CGFloat, dx: CGFloat = 0, crown: CGFloat? = nil) -> B.Scene {
    B.Scene(housing: housing,
            island: CGRect(x: dx - size.width / 2, y: housing.height + gap, width: size.width, height: size.height),
            crown: crown ?? size.height / 2)
}

func bridge(_ s: B.Scene) -> B.Bridge? { B.bridge(s, distance: B.distance(s)) }
func dist(_ p: CGPoint, _ q: CGPoint) -> CGFloat { hypot(p.x - q.x, p.y - q.y) }
let gaps: [CGFloat] = stride(from: 140, through: 0.75, by: -0.25).map { $0 }

print("how close")
do {
    check(B.closeness(distance: B.reach) == 0 && B.closeness(distance: B.reach + 40) == 0, "nothing at or past reach")
    check(B.closeness(distance: 0) == 1, "all of it touching")
    var last: CGFloat = -1, monotonic = true
    for g in gaps {
        let c = B.closeness(distance: B.distance(scene(pill, gap: g)))
        if c < last { monotonic = false }
        last = c
    }
    check(monotonic, "closer every step in")
    check(B.distance(scene(pill, gap: -20)) == 0, "up over the housing's foot is touching")
    check(B.distance(scene(pill, gap: 30, dx: 400)) > B.reach, "far to the side is out of reach, however high")
    check(B.joinGap < B.reach && B.joinGap > 50 - housing.height, "the drips meet before the notch takes the island back (its top 18pt under the housing)", "\(B.joinGap)")
    for c in stride(from: 0.0, through: 1.0, by: 0.125) {
        let d = B.distance(closeness: CGFloat(c))
        check(abs(B.closeness(distance: d) - CGFloat(c)) < 1e-9, "distance and closeness are each other's inverse at \(c)")
    }
}

print("the neck as the island comes in")
do {
    check(bridge(scene(pill, gap: B.reach + 1)) == nil, "out of reach: nothing")
    check(bridge(scene(pill, gap: B.reach - 10))?.joined == false, "within reach: two drips")
    check(bridge(scene(pill, gap: B.joinGap - 1))?.joined == true, "past the join: one neck")
    check(bridge(scene(pill, gap: 0.2)) == nil, "no gap: nothing between them to draw")

    // The drips touch exactly where they become a neck.
    let before = bridge(scene(pill, gap: B.joinGap + 0.01))!
    let after = bridge(scene(pill, gap: B.joinGap - 0.01))!
    check(!before.joined && after.joined, "the join is at joinGap")
    check(dist(before.notchLeft.end, before.islandLeft.end) < 0.05, "the drips' tips meet at the join", "\(before.notchLeft.end) \(before.islandLeft.end)")
    check(dist(before.notchLeft.end, after.notchLeft.end) < 0.05 && after.waist < 0.01, "where the neck's waist begins, as a thread")
    for (a, b, name) in [(before.notchLeft, after.notchLeft, "notch left"), (before.notchRight, after.notchRight, "notch right"),
                         (before.islandLeft, after.islandLeft, "island left"), (before.islandRight, after.islandRight, "island right")] {
        let worst = [dist(a.foot, b.foot), dist(a.control1, b.control1), dist(a.control2, b.control2), dist(a.end, b.end)].max()!
        check(worst < 0.2, "the \(name) wall is the same wall either side of the join", "\(worst)")
    }

    // Monotonic: in the neck, nothing gets thinner as the island comes closer.
    var waist: CGFloat = 0, notchHalf: CGFloat = 0, islandHalf: CGFloat = 0
    var thickens = true, spreads = true, lastJoined = false, joinsOnce = true
    var tip: CGFloat = 0, dripsGrow = true
    for g in gaps {
        guard let b = bridge(scene(pill, gap: g)) else { continue }
        if lastJoined && !b.joined { joinsOnce = false }
        lastJoined = b.joined
        if b.joined {
            if b.waist < waist - 1e-6 { thickens = false }
            waist = b.waist
        } else {
            let reachDown = b.notchLeft.end.y - b.housingFoot
            if reachDown < tip - 1e-6 { dripsGrow = false }
            tip = reachDown
        }
        if b.notchHalf < notchHalf - 1e-6 || b.islandHalf < islandHalf - 1e-6 { spreads = false }
        notchHalf = b.notchHalf; islandHalf = b.islandHalf
    }
    check(dripsGrow, "the notch's drip only lengthens as the island comes")
    check(joinsOnce, "once joined it stays joined on the way in")
    check(thickens, "the neck only thickens as the island comes")
    check(spreads, "its feet only spread")

    // At contact: the housing's whole flat bottom, and a waist nearly as wide.
    let touching = bridge(scene(pill, gap: 0.6))!
    check(abs(touching.notchHalf - hf) < 1, "at contact its foot is the housing's flat bottom", "\(touching.notchHalf) vs \(hf)")
    let pillFlat = (pill.width - pill.height) / 2
    check(abs(touching.islandHalf - min(hf, pillFlat)) < 1, "and as much of the island's top edge as it can stand on")
    check(touching.waist > 0.85 * min(touching.notchHalf, touching.islandHalf), "a waist nearly as wide: the drops merged")
}

print("the feet stay on the edges")
do {
    var onHousing = true, onIsland = true, noLoop = true
    for size in [pill, card, IslandFloat.bead] {
        for dx in stride(from: CGFloat(-320), through: 320, by: 20) {
            for g in stride(from: CGFloat(120), through: 1, by: -3) {
                let crown = size == card ? IslandFloat.prismCrownRadius : size.height / 2
                let s = scene(size, gap: g, dx: dx, crown: crown)
                guard let b = bridge(s) else { continue }
                let flat = s.islandFlat
                for w in [b.notchLeft, b.notchRight] where abs(w.foot.y - housing.height) > 1e-6 || abs(w.foot.x) > hf + 1e-6 {
                    onHousing = false
                }
                for w in [b.islandLeft, b.islandRight] where abs(w.foot.y - s.island.minY) > 1e-6 || w.foot.x < flat.left - 1e-6 || w.foot.x > flat.right + 1e-6 {
                    onIsland = false
                }
                // The waist and tips stay between the housing's foot and the island.
                for w in [b.notchLeft, b.notchRight, b.islandLeft, b.islandRight]
                where w.end.y < housing.height - 1e-6 || w.end.y > s.island.minY + 1e-6 {
                    noLoop = false
                }
            }
        }
    }
    check(onHousing, "the neck never leaves the housing's flat bottom: never a frame where it hangs free of the camera")
    check(onIsland, "and lands on the island's straight top edge, not its corners")
    check(noLoop, "its waist and tips never rise above the housing's foot or sink into the island")
}

print("one outline, the same shape of path in every state")
do {
    var counts = Set<[Int]>()
    for g in gaps {
        guard let b = bridge(scene(pill, gap: g)) else { continue }
        let o = B.outline(b)
        counts.insert([o.notch.count, o.island.count])
        let r = o.retracted(housingFoot: b.housingFoot, islandTop: b.islandTop, notchCentre: b.notchCentre, islandCentre: b.islandCentre)
        counts.insert([r.notch.count, r.island.count])
        if r.notch.contains(where: { $0.y > b.housingFoot + 1e-6 }) || r.island.contains(where: { $0.y < b.islandTop - 1e-6 }) {
            check(false, "drained back into where each came from at gap \(g)")
        }
    }
    check(counts == [[B.Outline.notchPoints, B.Outline.islandPoints]], "drips, neck and drained: always the same points, so one animates into another", "\(counts)")
    let b = bridge(scene(pill, gap: 20))!
    let o = B.outline(b)
    check(o.notch[0].y < b.housingFoot && o.notch[17].y < b.housingFoot, "tucked up under the housing")
    check(o.notch[8].y > b.islandTop && o.notch[9].y > b.islandTop, "and under the island's top edge: neither join has an edge of its own")
}

print("the black on the island")
do {
    check(B.stain(scene(pill, gap: B.reach + 5), distance: B.reach + 5, bridge: nil) == nil, "none out of reach")
    var across: CGFloat = 0, down: CGFloat = 0, grows = true
    for g in gaps {
        let s = scene(pill, gap: g)
        let d = B.distance(s)
        guard let st = B.stain(s, distance: d, bridge: B.bridge(s, distance: d)) else { continue }
        if st.across < across - 1e-6 || st.down < down - 1e-6 { grows = false }
        across = st.across; down = st.down
    }
    check(grows, "it spreads further the closer the island comes")
    // Taken off the notch: the island's top is the screen's, the housing
    // over it. The black is the docked spread, so the docked panel hands
    // over to it unchanged.
    let lifted = scene(card, gap: -housing.height, crown: IslandFloat.prismCrownRadius)
    let st = B.stain(lifted, distance: B.distance(lifted), bridge: nil)!
    check(st.centre == 0 && st.halfWidth == housing.width / 2, "lifted: on the camera, as wide as it")
    check(st.foot == housing.height + IslandPrism.spreadFoot, "solid as deep as the docked spread is")
    check(st.across == IslandPrism.spreadAcross && st.down == IslandPrism.spreadDown && st.opacity == 1, "and let go over the docked spread's reach")
    // Below the housing and beside it, the same; diagonally off its
    // corners the docked spread fades from a corner rounded 8pt and the
    // stain from a square one, a fade some 3pt further out there.
    var worst = 0.0, worstDiagonal = 0.0
    for x in stride(from: CGFloat(0), through: 360, by: 3) {
        for y in stride(from: CGFloat(0), through: 90, by: 3) {
            let qx = abs(x) - (housing.width / 2 - IslandPrism.notchCornerRadius)
            let qy = y - (housing.height + 1 - IslandPrism.notchCornerRadius)
            let diff = abs(B.stainAlpha(x: x, y: y, stain: st) - IslandPrism.spreadAlpha(x: x, y: y, housing: housing))
            if qx > 0 && qy > 0 { worstDiagonal = max(worstDiagonal, diff) } else { worst = max(worst, diff) }
        }
    }
    check(worst < 0.01, "point for point the docked spread below and beside the housing", "\(worst)")
    check(worstDiagonal < 0.2, "and within a 3pt shift of it off the housing's corners", "\(worstDiagonal)")
    // Clear of the housing, the black is solid where the neck lands.
    let s = scene(pill, gap: 20)
    let b = bridge(s)!
    let near = B.stain(s, distance: B.distance(s), bridge: b)!
    check(abs(B.stainAlpha(x: b.islandCentre - s.island.midX, y: 0.25, stain: near) - near.opacity) < 0.02, "solid under the neck's foot, so the two are one")
    check(near.opacity == 1, "and wholly there by then")
    check(B.falloff(0) == 1 && B.falloff(1) == 0 && B.falloff(0.5) > 0 && B.falloff(0.5) < 1, "lets go from solid to nothing")
}

print("\n\(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
