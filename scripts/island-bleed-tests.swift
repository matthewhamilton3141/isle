//
//  island-bleed-tests.swift
//
//  Tests for the notch's black reaching for an island carried near it
//  (Isle/Notch/IslandBleed.swift): the haze on the island as a function of
//  distance — nothing out of reach, a haze under the camera that only
//  grows as the island comes closer and never shows a hard edge, and at
//  contact the docked spread. Compiled against the SwiftUI-free sources
//  alone. Run with
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

func stain(_ s: B.Scene) -> B.Stain? { B.stain(s, distance: B.distance(s)) }
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
    for c in stride(from: 0.0, through: 1.0, by: 0.125) {
        let d = B.distance(closeness: CGFloat(c))
        check(abs(B.closeness(distance: d) - CGFloat(c)) < 1e-9, "distance and closeness are each other's inverse at \(c)")
    }
}

print("the haze on the island")
do {
    check(stain(scene(pill, gap: B.reach + 5)) == nil, "none out of reach")
    var across: CGFloat = 0, down: CGFloat = 0, half: CGFloat = 0, opacity = 0.0, grows = true
    var noSolid = true, underCamera = true, faint = true
    for g in gaps {
        for dx in [CGFloat(0), 60, -140] {
            let s = scene(pill, gap: g, dx: dx)
            guard let st = stain(s) else { continue }
            if dx == 0 {
                if st.across < across - 1e-6 || st.down < down - 1e-6 || st.halfWidth < half - 1e-6 || st.opacity < opacity - 1e-9 { grows = false }
                across = st.across; down = st.down; half = st.halfWidth; opacity = st.opacity
            }
            // Clear of the housing: nothing solid, so no band or bar.
            if g > IslandPrism.spreadFoot + 1e-6 && st.foot > 0 { noSolid = false }
            if abs(st.centre - (-s.island.midX)) > 1e-6 { underCamera = false }
        }
    }
    check(grows, "it only grows the closer the island comes: wider, further, darker")
    check(noSolid, "clear of the housing nothing on the island is solid black")
    check(underCamera, "always centred under the camera, wherever the island is")
    // Just inside reach it is faint and small: it comes in, it doesn't appear.
    if let first = stain(scene(pill, gap: B.reach - 5)) {
        if first.opacity > 0.05 || first.halfWidth > 4 { faint = false }
    }
    check(faint, "at the edge of reach barely there")
    // At the snap, about 18pt under the housing, most of the way to the docked look.
    let snap = stain(scene(pill, gap: 18))!
    check(snap.opacity > 0.6 && snap.opacity < 1 && snap.halfWidth > 0.85 * housing.width / 2, "by the snap it is nearly the docked look, and only black at contact", "\(snap)")
    let halfway = stain(scene(pill, gap: B.reach / 2))!
    check(halfway.opacity < 0.3, "half way in it is still a faint haze, not a band", "\(halfway.opacity)")
    // No hard top edge across the island: the darkest point is right under
    // the camera, and a pill's width away to the side it has let go.
    let mid = stain(scene(pill, gap: 50))!
    check(B.stainAlpha(x: mid.centre + mid.halfWidth + mid.across + 1, y: 0, stain: mid) == 0, "it lets go along the top edge")
    check(B.stainAlpha(x: mid.centre, y: mid.down + 1, stain: mid) == 0, "and down into the island")

    // Taken off the notch: the island's top is the screen's, the housing
    // over it. The haze is the docked spread, so the docked panel hands
    // over to it unchanged.
    let lifted = scene(card, gap: -housing.height, crown: IslandFloat.prismCrownRadius)
    let st = stain(lifted)!
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
    // (0.25: with the shorter spread of 2026-11-13, 90 by 30, the same 3pt
    // shift is a little more alpha, 0.21, for the one frame of the handover.)
    check(worstDiagonal < 0.25, "and within a 3pt shift of it off the housing's corners", "\(worstDiagonal)")
    check(B.falloff(0) == 1 && B.falloff(1) == 0 && B.falloff(0.5) > 0 && B.falloff(0.5) < 1, "lets go from solid to nothing")
}

print("\n\(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
