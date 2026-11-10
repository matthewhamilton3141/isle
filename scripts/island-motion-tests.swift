//
//  island-motion-tests.swift
//
//  Tests for the island's proximity gate and collapse curves, compiled
//  against Isle/Notch/IslandMotion.swift alone — no app, no window, no
//  pointer. Run with scripts/test-island-motion.sh.
//
//  Coordinates are screen space, bottom-left origin, as the pointer monitor
//  reports them: a 1512×982 screen with a 185×32 island flush with its top.
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

let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
let island = CGRect(x: (1512 - 185) / 2, y: 982 - 32, width: 185, height: 32)

/// Feeds a path of pointer positions through a gate and counts what it did.
struct Run {
    var gate = ProximityGate()
    var publishes: [IslandProximity] = []
    var allowedAsks = 0

    mutating func feed(_ points: [CGPoint], drawn: CGRect? = island, allowed: Bool = true) {
        for p in points {
            var asks = 0
            let next = gate.update(pointer: p, island: drawn, allowed: { asks += 1; return allowed }())
            allowedAsks += asks
            if let next { publishes.append(next) }
        }
    }
}

func line(from a: CGPoint, to b: CGPoint, steps: Int) -> [CGPoint] {
    (0...steps).map { i in
        let f = CGFloat(i) / CGFloat(steps)
        return CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)
    }
}

// MARK: - Gating

print("Proximity gate: far away")

do {
    // A pointer wandering the lower two-thirds of the screen, 2,000 moves.
    var run = Run()
    var points: [CGPoint] = []
    for i in 0..<2000 {
        let x = CGFloat((i * 37) % 1512)
        let y = CGFloat((i * 53) % 640)
        points.append(CGPoint(x: x, y: y))
    }
    run.feed(points)
    check(run.publishes.isEmpty, "no reading published for 2,000 far moves", "\(run.publishes.count)")
    check(run.gate.evaluations == 0, "no reading computed while far", "\(run.gate.evaluations)")
    check(run.allowedAsks == 0, "the island's state is never asked while far", "\(run.allowedAsks)")
}

do {
    // Along the menu bar, well clear of the island either side.
    var run = Run()
    run.feed(line(from: CGPoint(x: 0, y: 970), to: CGPoint(x: island.minX - 60, y: 970), steps: 400))
    run.feed(line(from: CGPoint(x: island.maxX + 60, y: 970), to: CGPoint(x: 1512, y: 970), steps: 400))
    check(run.publishes.isEmpty, "menu bar moves beyond reach publish nothing", "\(run.publishes.count)")
    check(run.gate.evaluations == 0, "and compute nothing", "\(run.gate.evaluations)")
}

do {
    // No layout yet: nothing to be near.
    var run = Run()
    run.feed(line(from: CGPoint(x: island.midX, y: 700), to: CGPoint(x: island.midX, y: 950), steps: 200), drawn: nil)
    check(run.publishes.isEmpty && run.gate.evaluations == 0, "no drawn rect, no tracking")
}

print("Proximity gate: approach and leave")

do {
    var run = Run()
    // Straight up from 300pt below the island to its bottom edge, 1pt a move.
    let approach = line(from: CGPoint(x: island.midX, y: island.minY - 300), to: CGPoint(x: island.midX, y: island.minY), steps: 300)
    run.feed(approach)
    let levels = run.publishes.map(\.level)
    check(run.publishes.count <= IslandMotion.proximitySteps,
          "a 300-move approach publishes at most one reading per step", "\(run.publishes.count)")
    check(levels == levels.sorted(), "levels only rise on the way in", "\(levels)")
    check(run.gate.current.level == IslandMotion.proximitySteps, "touching is full swell", "\(run.gate.current)")
    check(run.gate.current.lean == 0, "straight below leans nowhere", "\(run.gate.current)")
    let farMoves = approach.filter { $0.y < island.minY - IslandMotion.proximityReach }.count
    check(run.gate.evaluations == approach.count - farMoves,
          "readings computed only inside reach", "\(run.gate.evaluations) of \(approach.count), \(farMoves) far")

    // Sitting still on the same spot (a stream of repeats) publishes nothing.
    let before = run.publishes.count
    run.feed(Array(repeating: CGPoint(x: island.midX, y: island.minY), count: 50))
    check(run.publishes.count == before, "repeats at one spot publish nothing")

    // Away again, and on out across the screen.
    run.feed(line(from: CGPoint(x: island.midX, y: island.minY), to: CGPoint(x: island.midX, y: 200), steps: 400))
    check(run.gate.current == .rest, "leaving ends at rest")
    let afterLeave = run.publishes.count
    let evals = run.gate.evaluations
    run.feed(line(from: CGPoint(x: 0, y: 200), to: CGPoint(x: 1512, y: 300), steps: 500))
    check(run.publishes.count == afterLeave, "once at rest, far moves publish nothing more")
    check(run.gate.evaluations == evals, "and compute nothing more")
}

do {
    // Approaching from the lower left leans left; lower right, right.
    var left = Run()
    left.feed([CGPoint(x: island.minX - 10, y: island.minY - 8)])
    var right = Run()
    right.feed([CGPoint(x: island.maxX + 10, y: island.minY - 8)])
    check(left.gate.current.lean < 0, "pointer to the left leans left", "\(left.gate.current)")
    check(right.gate.current.lean > 0, "pointer to the right leans right", "\(right.gate.current)")
    check(left.gate.current.lean == -right.gate.current.lean, "and symmetrically")
}

do {
    // Not allowed (open, mid-collapse, taking a drag): near but at rest.
    var run = Run()
    run.feed(line(from: CGPoint(x: island.midX, y: island.minY - 50), to: CGPoint(x: island.midX, y: island.minY), steps: 50), allowed: false)
    check(run.publishes.isEmpty && run.gate.current == .rest, "near but not allowed stays at rest")

    // Allowed, swollen, then disallowed: one publish back to rest.
    var swollen = Run()
    swollen.feed([CGPoint(x: island.midX, y: island.minY - 4)])
    let n = swollen.publishes.count
    swollen.feed([CGPoint(x: island.midX, y: island.minY - 4)], allowed: false)
    check(swollen.publishes.count == n + 1 && swollen.gate.current == .rest, "losing permission relaxes once")
    check(swollen.gate.relax() == nil, "relax at rest is a no-op")
}

print("Proximity reading: bounds")

do {
    var worst = (swellW: CGFloat(0), swellH: CGFloat(0), leanOverSwell: CGFloat(0))
    var y = island.minY - 80
    while y <= island.maxY {
        var x = island.minX - 100
        while x <= island.maxX + 100 {
            let r = IslandProximity(pointer: CGPoint(x: x, y: y), island: island)
            worst.swellW = max(worst.swellW, r.swell.width)
            worst.swellH = max(worst.swellH, r.swell.height)
            worst.leanOverSwell = max(worst.leanOverSwell, abs(r.leanOffset) - r.swell.width)
            x += 3
        }
        y += 2
    }
    check(worst.swellW <= IslandMotion.maxSwell.width, "side swell never past \(IslandMotion.maxSwell.width)pt", "\(worst.swellW)")
    check(worst.swellH <= IslandMotion.maxSwell.height, "downward swell never past \(IslandMotion.maxSwell.height)pt", "\(worst.swellH)")
    check(worst.leanOverSwell <= 0, "lean never exceeds the side swell (resting edge stays covered)", "\(worst.leanOverSwell)")
    check(IslandProximity.rest.swell == .zero && IslandProximity.rest.leanOffset == 0, "rest is no swell, no lean")
}

// MARK: - Collapse

print("Collapse curves")

let expandedSizes = [CGSize(width: 520, height: 146), CGSize(width: 520, height: 230)]
let collapsedSizes = [CGSize(width: 185, height: 32), CGSize(width: 325, height: 32)]

for e in expandedSizes {
    for c in collapsedSizes {
        let label = "\(Int(e.width))×\(Int(e.height)) → \(Int(c.width))×\(Int(c.height))"
        var minHeight = CGFloat.infinity
        var minWidth = CGFloat.infinity
        var widthLeads = true
        var maxTaper: CGFloat = 0
        var t = 0.0
        while t <= 0.6 {
            let f = IslandMotion.collapse(at: t, from: e, to: c)
            minHeight = min(minHeight, f.size.height)
            minWidth = min(minWidth, f.size.width)
            let wp = (e.width - f.size.width) / (e.width - c.width)
            let hp = (e.height - f.size.height) / (e.height - c.height)
            if t > 0, wp < hp - 1e-9 { widthLeads = false }
            maxTaper = max(maxTaper, f.taper)
            t += 0.001
        }
        check(minHeight >= c.height - 1e-6, "\(label): height never undershoots the housing", "\(minHeight)")
        let undershoot = c.width - minWidth
        check(undershoot > 0.5 && undershoot <= 0.03 * (e.width - c.width),
              "\(label): width overshoots a little (\(String(format: "%.1f", undershoot))pt)", "\(undershoot)")
        check(widthLeads, "\(label): width is never behind height")
        check(maxTaper > 3 && maxTaper <= IslandMotion.maxTaper, "\(label): taper peaks at \(String(format: "%.1f", maxTaper))pt", "\(maxTaper)")

        let start = IslandMotion.collapse(at: 0, from: e, to: c)
        check(start.size == e && start.taper == 0, "\(label): t=0 is the open panel, untapered")
        let settled = IslandMotion.collapse(at: IslandMotion.collapseDuration, from: e, to: c)
        check(abs(settled.size.height - c.height) <= 0.01 * (e.height - c.height),
              "\(label): height within 1% by the collapse lock", "\(settled.size.height)")
        check(abs(settled.size.width - c.width) <= 0.01 * (e.width - c.width),
              "\(label): width within 1% by the collapse lock", "\(settled.size.width)")
        let late = IslandMotion.collapse(at: 0.6, from: e, to: c)
        check(late.taper < 0.25, "\(label): taper gone once settled", "\(late.taper)")
    }
}

do {
    let corners = IslandMotion.collapseCorners.value(at: 0.1)
    let width = IslandMotion.collapseWidth.value(at: 0.1)
    let height = IslandMotion.collapseHeight.value(at: 0.1)
    check(corners > width && width > height, "at 0.1s: corners ahead of width ahead of height",
          "\(corners) \(width) \(height)")
    check(IslandMotion.taper(rect: CGSize(width: 185, height: 32), expanded: CGSize(width: 520, height: 146),
                             collapsed: CGSize(width: 185, height: 32)) == 0, "settled pill has no taper")
    check(IslandMotion.taper(rect: CGSize(width: 520, height: 146), expanded: CGSize(width: 520, height: 146),
                             collapsed: CGSize(width: 185, height: 32)) == 0, "open panel has no taper")
    // A collapsed pill widening for a toast (width past its target) mustn't taper.
    check(IslandMotion.taper(rect: CGSize(width: 260, height: 32), expanded: CGSize(width: 520, height: 146),
                             collapsed: CGSize(width: 300, height: 32)) == 0, "a pill growing for a toast has no taper")
}

print("Open spring")
do {
    let open = IslandMotion.open
    check(open.response == 0.34 && open.dampingFraction == 0.76, "the open spring is notchOpen's (0.34, 0.76)")
    let reach = open.reach(1)
    check(reach > 0.15 && reach < 0.25, "the open first reaches full size about 0.2s in", "\(reach)")
    check(open.value(at: reach) >= 1 && open.value(at: reach - 0.002) < 1, "reach(1) is the first crossing", "\(reach)")
    check(open.reach(0.5) < reach, "half way before all the way")
    var peak = 0.0
    for i in 0...1000 { peak = max(peak, open.value(at: Double(i) / 1000)) }
    check(peak > 1 && peak < 1.12, "it overshoots a little after reaching", "\(peak)")
    check(IslandMotion.collapseHeight.reach(1.5) == 3, "a spring that never gets there stops looking at 3s")
}

print("\n\(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
