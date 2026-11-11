//
//  island-float-tests.swift
//
//  Tests for the numbers behind an island taken off its notch
//  (Isle/Notch/IslandFloat.swift): the shape with no flares, the closed
//  capsule and what sizes it, the header's grabber, black's edge, the glass
//  with no black cover, and Prism's pane — compiled against the SwiftUI-free
//  sources alone. The drawn sizes against the real window are checked in
//  scripts/island-windows-tests.swift. Run with scripts/test-island-float.sh.
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

func near(_ a: Double, _ b: Double, _ eps: Double = 1e-9) -> Bool { abs(a - b) <= eps }

typealias F = IslandFloat
typealias Pill = IslandFloat.Pill

// This Mac's camera band, and the docked open panel (NotchMetrics.expandedSize).
let band = CGSize(width: 185, height: 32)
let dockedOpen = CGSize(width: 520, height: 146)
// The least the window is, whatever the notch: the open panel with Prism's
// side lips and the stay-open pads, the tallest panel with Prism's lip
// (NotchMetrics.maximumFrame).
let windowFloor = CGSize(width: 520 + 2 * (16 + IslandPrism.sideLip), height: 230 + IslandPrism.lip)

print("the open panel's shape")
do {
    let flare = IslandMotion.openCorners.top
    let open = F.openSize(docked: dockedOpen, wallInset: flare)
    check(open.width == dockedOpen.width - 2 * flare && open.height == dockedOpen.height, "the docked panel less its flares, as tall")
    check((dockedOpen.width - open.width) / 2 == flare, "so the walls are where they were, and the content with them")
    check(F.openSize(docked: CGSize(width: 10, height: 40), wallInset: 12).width == 0, "never a negative width")
    let plain = F.corners(open: true, prism: false, closedHeight: F.pillHeight)
    check(plain.top == 0, "no flare off the notch")
    check(plain.crown == plain.bottom && plain.bottom == F.cornerRadius, "the same corner all four ways round")
    check(F.cornerRadius > IslandMotion.openCorners.bottom, "rounder than the docked panel's bottom corners: a card, not the notch panel moved")
    check(F.cornerRadius > F.pillHeight / 2, "and rounder than the capsule's ends, as a larger thing of the same family")
    let prism = F.corners(open: true, prism: true, closedHeight: F.pillHeight)
    check(prism.top == 0 && prism.bottom == IslandPrism.bottomCornerRadius, "Prism keeps its lens's bottom corners")
    check(prism.crown > plain.crown && prism.crown < prism.bottom, "and is rounder on top than the others, less than at its lip")
    // The header's first mark is the content's 10pt inside the wall (plus
    // Prism's side lip) and 8pt down: inside the corner's curve, with air.
    // The outline's corners are quadratic curves round the corner point.
    func clearance(x: CGFloat, y: CGFloat, r: CGFloat) -> CGFloat {
        // Distance from (x, y) to the curve from (0, r) to (r, 0) with control (0, 0).
        var best = CGFloat.infinity
        for i in 0...400 {
            let t = CGFloat(i) / 400
            let px = r * t * t, py = r * (1 - t) * (1 - t)
            best = min(best, ((px - x) * (px - x) + (py - y) * (py - y)).squareRoot())
        }
        return best
    }
    check(clearance(x: 10, y: 8, r: plain.crown) >= 2.5, "the header's first mark clears the corner in Black and Glass", "\(clearance(x: 10, y: 8, r: plain.crown))")
    check(clearance(x: 10 + IslandPrism.sideLip, y: 8, r: prism.crown) >= 6, "and in Prism", "\(clearance(x: 10 + IslandPrism.sideLip, y: 8, r: prism.crown))")
}

print("the closed capsule's shape")
do {
    check(F.pillHeight >= 36 && F.pillHeight <= 44, "36 to 44 points tall", "\(F.pillHeight)")
    check(F.pillHeight > band.height, "taller than the camera band")
    let closed = F.corners(open: false, prism: false, closedHeight: F.pillHeight)
    check(closed.top == 0 && closed.crown == F.pillHeight / 2 && closed.bottom == F.pillHeight / 2, "a capsule: half its height at every corner, no flare")
    check(F.corners(open: false, prism: true, closedHeight: F.pillHeight).crown == closed.crown, "in every mode")
    let bead = F.corners(open: false, prism: false, closedHeight: F.bead.height)
    check(bead.crown == F.bead.height / 2 && bead.bottom == F.bead.height / 2, "the bead is a capsule too")
    check(F.bead.height < F.pillHeight && F.bead.width < 80, "the bead is small")
    check(F.bead.height >= 22 && F.bead.width >= 48, "and still a target a pointer can find", "\(F.bead)")
    check(F.beadGrabber.width <= F.bead.width - F.bead.height && F.beadGrabber.height < F.bead.height / 3, "its grabber sits between its round ends")
}

print("what sizes the capsule")
do {
    check(Pill().isBead && Pill().size == F.bead, "nothing live: the bead")
    check(Pill().clusters == 0, "with no clusters")
    let music = Pill(music: .init(label: 80, wave: true))
    check(!music.isBead && music.clusters == 1 && music.size.height == F.pillHeight, "music: a capsule")
    let lead = F.leadingInset(mark: F.cover)
    check(music.size.width == (lead + F.cover + F.markGap + 80 + F.waveGap + F.wave.width + F.trailingInset).rounded(.up),
          "inset, cover, gap, label, gap, waveform, inset", "\(music.size.width)")
    let noWave = Pill(music: .init(label: 80, wave: false))
    check(music.size.width - noWave.size.width == F.waveGap + F.wave.width, "the waveform off gives its seat back")
    let claude = Pill(claude: 70)
    check(claude.size.width == (F.leadingInset(mark: F.marker) + F.marker + F.markGap + 70 + F.trailingInset).rounded(.up), "Claude: marker, gap, status")
    let both = Pill(music: .init(label: 80, wave: true), claude: 70)
    check(both.clusters == 2, "both: two clusters")
    check(both.clusterWidths == [music.clusterWidths[0], claude.clusterWidths[0]], "music leading, Claude trailing, each as wide as on its own")
    check(both.size.width == (lead + both.clusterWidths.reduce(0, +) + 2 * F.clusterGap + F.divider.width + F.trailingInset).rounded(.up),
          "a hairline and its air between them")
    check(both.leadingMark == F.cover, "the cover leads")
    let all = Pill(music: .init(label: 80, wave: true), claude: 70, timer: 40)
    check(all.clusters == 3 && all.clusterWidths.count == 3 && all.size.width > both.size.width, "the timer after Claude")
    check(Pill(claude: 70, timer: 40).leadingMark == F.marker && Pill(timer: 40).leadingMark == F.ring, "the first cluster's mark sets the leading inset")
    let toast = Pill(toast: 150, music: .init(label: 80, wave: true), claude: 70)
    check(toast.clusters == 0 && !toast.isBead && toast.clusterWidths == [F.toastGlyph + F.markGap + 150], "a toast borrows the whole capsule")
    check(toast.size.width == (F.leadingInset(mark: F.toastGlyph) + F.toastGlyph + F.markGap + 150 + F.trailingInset).rounded(.up), "glyph, gap, message")
    var growing = true
    var last = CGFloat(0)
    for w in stride(from: CGFloat(0), through: 200, by: 7) { let s = Pill(claude: w).size.width; if s < last { growing = false }; last = s }
    check(growing, "wider text never makes a narrower capsule")
    check(music.size.width == music.size.width.rounded() && toast.size.width == toast.size.width.rounded(), "whole points")
    // Labels.
    check(F.labelWidth(natural: 10, alone: true) == F.labelMin, "a short title still gets a label's least width")
    check(F.labelWidth(natural: 90.2, alone: true) == 91, "a title that fits gets its own width, rounded up")
    check(F.labelWidth(natural: 900, alone: true) == F.labelMaxAlone && F.labelWidth(natural: 900, alone: false) == F.labelMaxShared, "a long one its cap, and scrolls")
    check(F.labelMaxShared < F.labelMaxAlone, "less room when the capsule is shared")
}

print("what the capsule's content fits in")
do {
    check(F.titleLine + F.detailLine <= F.pillHeight - 2 * 5, "two lines of text with five points above and below", "\(F.titleLine + F.detailLine)")
    check(F.titleSize > F.detailSize && F.titleLine > F.titleSize && F.detailLine > F.detailSize, "a title and a smaller line under it, each in its line height")
    for (name, mark) in [("the cover", F.cover), ("the marker", F.marker), ("the ring", F.ring), ("a toast's glyph", F.toastGlyph)] {
        check(mark <= F.pillHeight - 2 * 6, "\(name) has six points above and below", "\(mark)")
        // A square mark at the leading inset, its outer corners against the capsule's round end.
        let inset = F.leadingInset(mark: mark), r = F.pillHeight / 2
        let dx = r - inset, dy = mark / 2
        check(dx <= 0 || (dx * dx + dy * dy).squareRoot() <= r - 1.5, "\(name)'s corners are inside the capsule's round end", "\((dx * dx + dy * dy).squareRoot()) of \(r)")
    }
    check(F.wave.height <= F.pillHeight - 2 * 6 && F.divider.height < F.pillHeight / 2, "the waveform and the hairline fit")
    check(F.coverRadius < F.cover / 2, "the cover is a rounded square, not a disc")
}

print("the capsule in the window")
do {
    // The widest it gets: three clusters, capped labels, a clock with hours.
    let widest = F.widestPill(status: 400, clock: 60)
    check(widest.width > F.Pill(music: .init(label: F.labelMaxShared, wave: true)).size.width, "three clusters are wider than one")
    check(widest.width + 2 * F.shadowReach.side <= windowFloor.width, "the widest capsule and its shadow fit across the window",
          "\(widest.width) + 2 × \(F.shadowReach.side) in \(windowFloor.width)")
    check(F.pillHeight + F.shadowReach.below <= windowFloor.height, "and down it")
    check(F.widestPill(status: 30, clock: 30).width < widest.width, "a shorter status and clock make a narrower one")
}

print("the header's grabber")
do {
    check(F.grabberGap == F.grabber.width + 2 * F.grabberClearance, "the gap the faces leave: the grabber and its clearance either side")
    check(F.grabberGap < band.width, "narrower than the camera it stands in for, so the header has more room than the band had")
    check(F.grabber.height < band.height / 4 && F.grabber.width > F.grabber.height * 4, "a short bar, not a button")
    check(F.grabberOpacity > 0.15 && F.grabberOpacity < 0.5, "quiet, and there", "\(F.grabberOpacity)")
    check(F.beadGrabber.width < F.grabber.width, "the bead's is the same mark, smaller")
}

print("the edge")
do {
    check(F.rimOpacity > 0.1 && F.rimOpacity <= 0.3, "black's hairline: visible over a dark window, not a border", "\(F.rimOpacity)")
    check(F.glassRimOpacity > 0 && F.glassRimOpacity < F.rimOpacity, "Glass's is fainter")
    check(F.rimWidth / 2 <= 0.5, "half the stroke shows: a hairline")
    check(F.shadowOpacity <= 0.5 && F.shadowRadius <= 16, "a soft shadow, restrained")
    check(F.shadowDrop > 0 && F.shadowDrop < F.shadowRadius, "cast downward, and still round the sides")
    check(F.shadowReach.side == 2 * F.shadowRadius && F.shadowReach.below == 2 * F.shadowRadius + F.shadowDrop, "room for the blur, and the drop below")
    check(F.shadowRise >= F.shadowRadius, "nothing of it at the top edge, where the window ends")
    // The open panel and its shadow in the window: Black is the mode with
    // one, and its panel has no lip.
    let open = F.openSize(docked: CGSize(width: dockedOpen.width, height: 230), wallInset: IslandMotion.openCorners.top)
    check(open.width + 2 * F.shadowReach.side <= windowFloor.width, "the open panel's shadow fits across the window")
    check(open.height + F.shadowReach.below <= windowFloor.height, "and under the tallest panel", "\(open.height) + \(F.shadowReach.below) in \(windowFloor.height)")
}

print("glass with no black over it")
do {
    for p in [0.0, 0.05, IslandGlass.blendStart, 0.3, 1] {
        check(IslandGlass.blackCover(progress: p, lift: 0) == IslandGlass.blackCover(progress: p), "on the notch, the cover is what it was (\(p))")
        check(IslandGlass.blackCover(progress: p, lift: 1) == 0, "off it, none at any point of the open (\(p))")
        check(IslandGlass.showsGlass(progress: p, lift: 0) == IslandGlass.showsGlass(progress: p), "on the notch, glass is drawn when it was (\(p))")
        check(IslandGlass.showsGlass(progress: p, lift: 1), "off it, always (\(p))")
    }
    check(near(IslandGlass.blackCover(progress: 0, lift: 0.5), 0.5), "half way off, half the black")
    check(IslandGlass.blackCover(progress: 0, lift: 1.04) == 0 && IslandGlass.blackCover(progress: 0, lift: -0.02) == 1, "a spring's overshoot clamps")
    check(IslandGlass.showsGlass(progress: 0, lift: 0.001), "the glass is there from the first of the lift")
    var falling = true
    var last = 2.0
    for i in 0...100 { let v = IslandGlass.blackCover(progress: 0, lift: Double(i) / 100); if v > last { falling = false }; last = v }
    check(falling, "the black only thins as the island lifts")
    check(IslandGlass.openOnlyOpacity(progress: 0) == 0 && IslandGlass.openOnlyOpacity(progress: 1) == 1, "the ribbon: gone closed, whole open")
    check(IslandGlass.openOnlyOpacity(progress: IslandGlass.blendEnd) == 1, "and whole before the content comes in")
}

print("prism's pane")
do {
    let closed = F.prismPane(progress: 0, closedHeight: F.pillHeight)
    check(closed.top == F.prismPillRim && closed.side == F.prismPillRim && closed.bottom == F.prismPillRim, "closed: the same slim rim of lens all round")
    check(closed.topRadius == F.pillHeight / 2 - F.prismPillRim && closed.bottomRadius == closed.topRadius, "the capsule's shape, that far inside it")
    check(closed.feather < F.prismPillRim && closed.feather < IslandPrism.rimFeather, "with an edge crisper than the open pane's, inside the rim")
    // The capsule's content starts 7pt down and 9pt in: on full frost.
    check(F.prismPillRim + F.prismPillFeather <= (F.pillHeight - F.cover) / 2, "the frost is whole by where the cover starts")
    let open = F.prismPane(progress: 1, closedHeight: F.pillHeight)
    check(open.side == IslandPrism.rim && open.bottom == IslandPrism.lip && open.feather == IslandPrism.rimFeather, "open: the docked pane's walls, lip and softness")
    check(open.top == F.prismTopRim && open.top > 0, "and a rim along the top, where the notch had black")
    check(open.top + open.feather <= 14, "the frost is whole by the header's marks, some 10pt down", "\(open.top + open.feather)")
    check(open.bottomRadius == F.prismPaneRadius && open.topRadius == F.prismCrownRadius - IslandPrism.rim, "its top corners follow the outline's, a rim inside")
    let mid = F.prismPane(progress: 0.5, closedHeight: F.pillHeight)
    check(mid.side > closed.side && mid.side < open.side && mid.bottom > closed.bottom && mid.bottom < open.bottom, "between, part way")
    check(F.prismPane(progress: -0.1, closedHeight: F.pillHeight) == closed && F.prismPane(progress: 1.05, closedHeight: F.pillHeight) == open, "an overshoot clamps")
    check(F.prismPane(progress: 0, closedHeight: 4).topRadius == 0, "never a negative radius")
}

print("\n\(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
