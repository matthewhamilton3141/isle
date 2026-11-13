//
//  island-placement-tests.swift
//
//  Tests for taking the island off its notch, compiled against the three
//  files that hold the deciding and nothing else — no app, no window, no
//  pointer, no clock:
//
//  - IslandHold.swift: one press, from button down to button up — a click
//    left alone, a hold that runs the line and lifts the island, the ways a
//    hold is called off, and a plain drag of a closed island.
//  - IslandPlacement.swift: where an island off its notch may rest and be
//    carried, how near the notch takes it back, and what's remembered.
//  - DetachTraceGeometry.swift: the line's two halves, from the bottom
//    centre of an outline to its top.
//
//  Run with scripts/test-island-placement.sh. Coordinates are screen space,
//  bottom-left origin, for the first two; the outline's own, y down, for
//  the third.
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

func near(_ a: CGFloat, _ b: CGFloat, _ tolerance: CGFloat = 0.01) -> Bool { abs(a - b) <= tolerance }
func near(_ a: CGPoint, _ b: CGPoint, _ tolerance: CGFloat = 0.01) -> Bool {
    near(a.x, b.x, tolerance) && near(a.y, b.y, tolerance)
}

// MARK: - The hold

let press = CGPoint(x: 700, y: 900)
typealias Outcome = IslandHold.Outcome

print("Hold: a click is a click")

do {
    var hold = IslandHold()
    let down = hold.down(kind: .detach, at: press, time: 10)
    check(down == Outcome(), "the press goes on to the control, and nothing shows", "\(down)")
    check(hold.deadline.map { near(CGFloat($0), 10.25) } == true, "the hold is looked at again after the grace", "\(String(describing: hold.deadline))")
    let early = hold.tick(time: 10.1, pointer: press, buttonDown: true)
    check(early == Outcome() && hold.phase == .waiting, "nothing before the grace is up")
    let up = hold.up(at: press, time: 10.12)
    check(up == Outcome(), "a release inside the grace goes on to the control: an ordinary click", "\(up)")
    check(hold.phase == .idle && hold.deadline == nil, "and the press is over")
}

do {
    var hold = IslandHold()
    _ = hold.down(kind: nil, at: press, time: 10)
    check(hold.phase == .idle && hold.deadline == nil, "a press that isn't the island's to take is never timed")
    check(hold.tick(time: 12, pointer: press, buttonDown: true) == Outcome(), "however long it's held")
    check(hold.moved(to: CGPoint(x: 900, y: 900), time: 12.1) == Outcome()
          && hold.up(at: press, time: 12.2) == Outcome(), "and its drags and release are the control's")
}

print("Hold: held still, the line runs and the island comes loose")

do {
    var hold = IslandHold()
    _ = hold.down(kind: .detach, at: press, time: 10)
    let begun = hold.tick(time: 10.25, pointer: press, buttonDown: true)
    check(begun == Outcome(verdict: .pass, actions: [.traceBegan(run: 1.1)]), "after the grace the line starts, for 1.1s", "\(begun)")
    check(hold.phase == .tracing && hold.deadline.map { near(CGFloat($0), 11.35) } == true, "and the hold is looked at again when it has gone round")
    check(hold.tick(time: 10.9, pointer: press, buttonDown: true) == Outcome(), "nothing more while it runs")
    // A hand isn't perfectly still.
    check(hold.moved(to: CGPoint(x: 702, y: 898), time: 11) == Outcome() && hold.phase == .tracing,
          "a couple of points of tremor doesn't call it off")
    let lifted = hold.tick(time: 11.35, pointer: CGPoint(x: 702, y: 898), buttonDown: true)
    check(lifted == Outcome(verdict: .pass, actions: [.lifted(at: press)]), "when the ends meet the island is lifted, held where it was pressed", "\(lifted)")
    check(hold.phase == .carrying && hold.deadline == nil, "and from there it's carried, untimed")
    let moved = hold.moved(to: CGPoint(x: 640, y: 700), time: 11.5)
    check(moved == Outcome(verdict: .swallow, actions: [.carried(to: CGPoint(x: 640, y: 700))]),
          "a drag moves the island and stops short of the views", "\(moved)")
    let up = hold.up(at: CGPoint(x: 600, y: 650), time: 12)
    check(up == Outcome(verdict: .cancelPress, actions: [.dropped(at: CGPoint(x: 600, y: 650))]),
          "letting go puts it down, and isn't a click on what was pressed", "\(up)")
    check(hold.phase == .idle, "and the press is over")
}

do {
    var hold = IslandHold()
    _ = hold.down(kind: .detach, at: press, time: 10)
    let begun = hold.tick(time: 10.243, pointer: press, buttonDown: true)
    check(begun.actions == [.traceBegan(run: 1.1)], "a timer landing a few milliseconds early still starts the line")
}

do {
    var hold = IslandHold()
    _ = hold.down(kind: .pickUp, at: press, time: 10)
    check(hold.deadline.map { near(CGFloat($0), 10.2) } == true, "an island already off the notch: a shorter grace")
    let begun = hold.tick(time: 10.2, pointer: press, buttonDown: true)
    check(begun.actions == [.traceBegan(run: 0.2)], "and a quick line", "\(begun)")
    let lifted = hold.tick(time: 10.4, pointer: press, buttonDown: true)
    check(lifted.actions == [.lifted(at: press)], "then it's picked up")
}

print("Hold: called off")

do {
    var hold = IslandHold()
    _ = hold.down(kind: .detach, at: press, time: 10)
    _ = hold.tick(time: 10.25, pointer: press, buttonDown: true)
    let up = hold.up(at: press, time: 10.7)
    check(up == Outcome(verdict: .cancelPress, actions: [.traceCancelled]),
          "let go while the line runs: it runs back, and the control under the pointer doesn't fire", "\(up)")
    check(hold.phase == .idle && hold.deadline == nil, "and nothing more is timed")
}

do {
    // A slider: pressed and dragged straight away.
    var hold = IslandHold()
    _ = hold.down(kind: .detach, at: press, time: 10)
    let dragged = hold.moved(to: CGPoint(x: 730, y: 900), time: 10.05)
    check(dragged == Outcome() && hold.phase == .spent, "a drag inside the grace is the control's drag")
    check(hold.deadline == nil, "and the hold is no longer timed")
    check(hold.tick(time: 10.25, pointer: CGPoint(x: 730, y: 900), buttonDown: true) == Outcome(), "the line never starts")
    check(hold.moved(to: CGPoint(x: 760, y: 900), time: 11) == Outcome(), "every later drag goes to the control")
    check(hold.up(at: CGPoint(x: 760, y: 900), time: 12) == Outcome(), "and so does the release: the line never showed")
}

do {
    var hold = IslandHold()
    _ = hold.down(kind: .detach, at: press, time: 10)
    check(hold.moved(to: CGPoint(x: 703, y: 900), time: 10.1) == Outcome() && hold.phase == .waiting,
          "three points inside the grace is still a hold")
    check(hold.moved(to: CGPoint(x: 704.5, y: 900), time: 10.15) == Outcome() && hold.phase == .spent,
          "past four it's a drag")
}

do {
    var hold = IslandHold()
    _ = hold.down(kind: .detach, at: press, time: 10)
    _ = hold.tick(time: 10.25, pointer: press, buttonDown: true)
    let strayed = hold.moved(to: CGPoint(x: 700, y: 880), time: 10.6)
    check(strayed == Outcome(verdict: .pass, actions: [.traceCancelled]),
          "moving off while the line runs: it runs back, and the drag is the control's", "\(strayed)")
    check(hold.tick(time: 11.35, pointer: CGPoint(x: 700, y: 880), buttonDown: true) == Outcome(), "the island stays put")
    check(hold.up(at: CGPoint(x: 700, y: 880), time: 12) == Outcome(verdict: .cancelPress),
          "and the release still isn't a click: the line had shown")
}

do {
    // The release went somewhere the window never saw (a drag session).
    var hold = IslandHold()
    _ = hold.down(kind: .detach, at: press, time: 10)
    let gone = hold.tick(time: 10.25, pointer: press, buttonDown: false)
    check(gone == Outcome() && hold.phase == .idle, "the button already up at the grace: no line")

    _ = hold.down(kind: .detach, at: press, time: 20)
    let away = hold.tick(time: 20.25, pointer: CGPoint(x: 500, y: 500), buttonDown: true)
    check(away == Outcome() && hold.phase == .spent, "the pointer already elsewhere at the grace: no line")
    _ = hold.tick(time: 21, pointer: CGPoint(x: 500, y: 500), buttonDown: false)
    check(hold.phase == .idle, "and the press is over once the button is seen up")

    _ = hold.down(kind: .detach, at: press, time: 30)
    _ = hold.tick(time: 30.25, pointer: press, buttonDown: true)
    let up = hold.tick(time: 31.35, pointer: press, buttonDown: false)
    check(up == Outcome(actions: [.traceCancelled]) && hold.phase == .idle,
          "the button up, unseen, by the time the line has gone round: called off, not lifted", "\(up)")

    _ = hold.down(kind: .detach, at: press, time: 40)
    _ = hold.tick(time: 40.25, pointer: press, buttonDown: true)
    let moved = hold.tick(time: 41.35, pointer: CGPoint(x: 700, y: 800), buttonDown: true)
    check(moved == Outcome(actions: [.traceCancelled]) && hold.phase == .spent,
          "the pointer moved, unseen, by then: called off")
}

do {
    // Something else claimed the island mid-hold: an alert closed the
    // panel, a reply took the keys.
    var hold = IslandHold()
    _ = hold.down(kind: .detach, at: press, time: 10)
    check(hold.tick(time: 10.25, pointer: press, buttonDown: true, holdable: false) == Outcome() && hold.phase == .spent,
          "no longer holdable at the grace: no line")
    _ = hold.down(kind: .detach, at: press, time: 20)
    _ = hold.tick(time: 20.25, pointer: press, buttonDown: true)
    let off = hold.tick(time: 21.35, pointer: press, buttonDown: true, holdable: false)
    check(off == Outcome(actions: [.traceCancelled]), "no longer holdable when the line has gone round: called off", "\(off)")
}

print("Hold: a closed island off the notch is dragged")

do {
    var hold = IslandHold()
    _ = hold.down(kind: .drag, at: press, time: 10)
    check(hold.deadline == nil, "nothing is timed")
    check(hold.tick(time: 13, pointer: press, buttonDown: true) == Outcome() && hold.phase == .waiting,
          "holding it still does nothing, however long")
    check(hold.moved(to: CGPoint(x: 702, y: 901), time: 13.1) == Outcome(), "a couple of points is no drag yet")
    let lifted = hold.moved(to: CGPoint(x: 706, y: 903), time: 13.2)
    check(lifted == Outcome(verdict: .swallow, actions: [.lifted(at: press), .carried(to: CGPoint(x: 706, y: 903))]),
          "past the slop it's picked up by where it was pressed, and catches up", "\(lifted)")
    let up = hold.up(at: CGPoint(x: 750, y: 880), time: 14)
    check(up == Outcome(verdict: .cancelPress, actions: [.dropped(at: CGPoint(x: 750, y: 880))]), "and put down on release")

    _ = hold.down(kind: .drag, at: press, time: 20)
    check(hold.up(at: press, time: 20.1) == Outcome(), "a click without a drag is a click")
}

print("Hold: never left carrying")

do {
    var hold = IslandHold()
    _ = hold.down(kind: .drag, at: press, time: 10)
    _ = hold.moved(to: CGPoint(x: 800, y: 800), time: 10.2)
    check(hold.tick(time: 10.3, pointer: CGPoint(x: 810, y: 790), buttonDown: true) == Outcome(), "the button still down: still carried")
    let dropped = hold.tick(time: 10.5, pointer: CGPoint(x: 820, y: 780), buttonDown: false)
    check(dropped == Outcome(actions: [.dropped(at: CGPoint(x: 820, y: 780))]) && hold.phase == .idle,
          "a release that never arrived: put down where the pointer is, once the button is seen up", "\(dropped)")

    _ = hold.down(kind: .drag, at: press, time: 20)
    _ = hold.moved(to: CGPoint(x: 800, y: 800), time: 20.2)
    let abandoned = hold.abandon()
    check(abandoned == Outcome(actions: [.dropped(at: CGPoint(x: 800, y: 800))]) && hold.phase == .idle,
          "abandoned mid-carry: put down where it was last carried to", "\(abandoned)")

    _ = hold.down(kind: .drag, at: press, time: 30)
    _ = hold.moved(to: CGPoint(x: 800, y: 800), time: 30.2)
    let again = hold.down(kind: .detach, at: press, time: 40)
    check(again == Outcome(verdict: .pass, actions: [.dropped(at: CGPoint(x: 800, y: 800))]) && hold.phase == .waiting,
          "a new press while one was still carrying: the old one is put down first", "\(again)")

    var tracing = IslandHold()
    _ = tracing.down(kind: .detach, at: press, time: 50)
    _ = tracing.tick(time: 50.25, pointer: press, buttonDown: true)
    check(tracing.abandon() == Outcome(actions: [.traceCancelled]), "abandoned while the line runs: it's called off")
}

// MARK: - Placement

// This Mac's built-in display: 1512×982 with a 38pt menu bar, and the
// island's widest and tallest (the 520pt panel with Prism's side lips; the
// 230pt cap with its lip).
let bounds = IslandPlacementBounds(
    screen: CGRect(x: 0, y: 0, width: 1512, height: 982),
    visible: CGRect(x: 0, y: 0, width: 1512, height: 944),
    halfWidth: 272,
    tallest: 264
)

print("Placement: where an island may be")

do {
    check(bounds.dock == CGPoint(x: 756, y: 982), "docked is the top centre of the screen")
    let free = CGPoint(x: 500, y: 600)
    check(bounds.resting(free) == free && bounds.carrying(free) == free, "an anchor with room all round is left alone")
    check(bounds.resting(CGPoint(x: 756, y: 982)) == CGPoint(x: 756, y: 944), "at rest the island sits below the menu bar")
    check(bounds.carrying(CGPoint(x: 756, y: 982)) == CGPoint(x: 756, y: 982), "carried, it may be at the very top — where it starts")
    check(bounds.carrying(CGPoint(x: 756, y: 1100)) == CGPoint(x: 756, y: 982), "but not above it")
    check(bounds.resting(CGPoint(x: -400, y: 3000)) == CGPoint(x: 272, y: 944), "off the top left: brought in to where the panel fits")
    check(bounds.resting(CGPoint(x: 9000, y: -50)) == CGPoint(x: 1240, y: 264),
          "off the bottom right: up far enough for the tallest panel to fit")
    let low = bounds.resting(CGPoint(x: 600, y: 10))
    check(low.y - bounds.tallest >= bounds.visible.minY, "the tallest panel never hangs below the visible frame", "\(low)")

    // With the Dock on the left and an auto-hidden menu bar.
    let docked = IslandPlacementBounds(screen: bounds.screen, visible: CGRect(x: 70, y: 0, width: 1442, height: 982),
                                       halfWidth: 272, tallest: 264)
    check(docked.resting(CGPoint(x: 0, y: 500)).x == 342, "the Dock's side is kept clear")

    let tiny = IslandPlacementBounds(screen: CGRect(x: 0, y: 0, width: 400, height: 200),
                                     visible: CGRect(x: 0, y: 0, width: 400, height: 180), halfWidth: 272, tallest: 264)
    check(tiny.resting(CGPoint(x: 10, y: 10)) == CGPoint(x: 200, y: 180), "a screen too small for the panel: centred, from the top")
}

print("Placement: the way back to the notch")

do {
    check(bounds.captures(bounds.dock), "on the notch is on the notch")
    check(bounds.captures(CGPoint(x: 756 + 70, y: 982 - 50)) && bounds.captures(CGPoint(x: 756 - 70, y: 982 - 50)),
          "within reach either side, and below")
    check(!bounds.captures(CGPoint(x: 756 + 71, y: 982)), "not further out sideways")
    check(!bounds.captures(CGPoint(x: 756, y: 982 - 51)), "nor further down")
    check(bounds.captures(CGPoint(x: 756, y: 1200)), "anything above the top edge counts: the pointer is pushed against it")
    check(bounds.captures(CGPoint(x: 756, y: 944)), "the reach takes in the menu bar: pushed up against it in the middle, it docks")
    let edge = CGPoint(x: 756 + 80, y: 982 - 60)
    check(!bounds.captures(edge) && bounds.holds(edge), "an island already taken back is held a little further out")
    check(!bounds.holds(CGPoint(x: 756 + 85, y: 982)) && !bounds.holds(CGPoint(x: 756, y: 982 - 65)), "but not much")
    check(!bounds.captures(bounds.resting(CGPoint(x: 756 + 71, y: 982))), "an island put down beside the zone rests outside it")
}

print("Placement: remembering")

do {
    check(bounds.offset(of: .docked) == nil, "nothing is remembered for an island on its notch")
    let left = IslandPlacement.floating(anchor: CGPoint(x: 400, y: 600))
    let offset = bounds.offset(of: left)
    check(offset == CGPoint(x: -356, y: -382), "off it, how far from the screen's top centre", "\(String(describing: offset))")
    check(bounds.placement(restoring: offset) == left, "which restores to where it was")
    check(bounds.placement(restoring: nil) == .docked, "nothing remembered: docked")

    // The displays rearranged: this screen now sits to the right of another.
    var moved = bounds
    moved.screen.origin.x = 1920
    moved.visible.origin.x = 1920
    check(moved.placement(restoring: offset) == .floating(anchor: CGPoint(x: 2320, y: 600)),
          "the same place on the screen after the screen's origin moves")

    check(bounds.placement(restoring: CGPoint(x: CGFloat.nan, y: -100)) == .docked
          && bounds.placement(restoring: CGPoint(x: 0, y: -CGFloat.infinity)) == .docked, "nonsense: docked")
    check(bounds.placement(restoring: CGPoint(x: 5000, y: -300)) == .docked, "off the side of the screen: docked")
    check(bounds.placement(restoring: CGPoint(x: 0, y: -2000)) == .docked, "below it: docked")
    check(bounds.placement(restoring: CGPoint(x: 0, y: 40)) == .docked, "above it: docked")
    check(bounds.placement(restoring: CGPoint(x: 30, y: -20)) == .docked, "on the notch: docked")

    // A smaller display under the same name (a changed resolution).
    let small = IslandPlacementBounds(screen: CGRect(x: 0, y: 0, width: 1147, height: 745),
                                      visible: CGRect(x: 0, y: 0, width: 1147, height: 707), halfWidth: 272, tallest: 264)
    check(small.placement(restoring: CGPoint(x: -700, y: -382)) == .docked, "a place that's no longer on the screen: docked")
    check(small.placement(restoring: CGPoint(x: -356, y: -700)) == .floating(anchor: CGPoint(x: 272, y: 264)),
          "one that is, with too little room: brought in to where the panel fits")
    let restored = small.placement(restoring: CGPoint(x: 100, y: -300))
    check(restored == .floating(anchor: CGPoint(x: 673.5, y: 445)), "one with room: as it was", "\(restored)")
}

// MARK: - The line

print("Trace: the notch's outline, 520×146")

/// The open panel's outline as NotchShape draws it: y down, flares at the
/// top corners, rounded at the bottom, starting at the top left.
func notchOutline(width: CGFloat = 520, height: CGFloat = 146, top: CGFloat = 12, bottom: CGFloat = 22) -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 0, y: 0))
    p.addQuadCurve(to: CGPoint(x: top, y: top), control: CGPoint(x: top, y: 0))
    p.addLine(to: CGPoint(x: top, y: height - bottom))
    p.addQuadCurve(to: CGPoint(x: top + bottom, y: height), control: CGPoint(x: top, y: height))
    p.addLine(to: CGPoint(x: width - top - bottom, y: height))
    p.addQuadCurve(to: CGPoint(x: width - top, y: height - bottom), control: CGPoint(x: width - top, y: height))
    p.addLine(to: CGPoint(x: width - top, y: top))
    p.addQuadCurve(to: CGPoint(x: width, y: 0), control: CGPoint(x: width - top, y: 0))
    p.closeSubpath()
    return p
}

func points(of path: CGPath) -> [CGPoint] {
    var out: [CGPoint] = []
    path.applyWithBlock { e in
        switch e.pointee.type {
        case .moveToPoint, .addLineToPoint: out.append(e.pointee.points[0])
        default: break
        }
    }
    return out
}

do {
    guard let halves = DetachTraceGeometry.halves(of: notchOutline()) else {
        check(false, "the outline splits into two halves")
        exit(1)
    }
    check(near(halves.start, CGPoint(x: 260, y: 146)), "both start at the bottom centre", "\(halves.start)")
    let left = points(of: halves.left), right = points(of: halves.right)
    check(left.first.map { near($0, halves.start) } == true && right.first.map { near($0, halves.start) } == true,
          "each path's first point is that start")
    check(near(halves.leftEnd, CGPoint(x: 260, y: 0)) && near(halves.rightEnd, CGPoint(x: 260, y: 0)),
          "with no housing, both end at the top centre: the ends meet", "\(halves.leftEnd) \(halves.rightEnd)")
    check(left.allSatisfy { $0.x <= 260.001 }, "the left half stays left of centre")
    check(right.allSatisfy { $0.x >= 259.999 }, "the right half stays right of centre")
    check(left.contains { near($0, CGPoint(x: 0, y: 0), 0.5) } && right.contains { near($0, CGPoint(x: 520, y: 0), 0.5) },
          "each goes out to its top corner, where the island meets the screen edge, on the way")
    check(near(halves.leftLength, halves.rightLength, 0.5), "the two are the same length, so they arrive together",
          "\(halves.leftLength) \(halves.rightLength)")
    // Bottom run 226, corner ~ 34.5 (a 22pt quad), wall 112, flare ~18.8, top run 260.
    check(halves.leftLength > 640 && halves.leftLength < 660, "about half the outline's length", "\(halves.leftLength)")
    // In order along the path: down at the bottom first, the top last.
    let ys = left.map(\.y)
    check(ys.first == 146 && ys.last == 0 && ys.dropFirst().prefix(3).allSatisfy { $0 > 100 },
          "it runs along the bottom first and reaches the top last")

    guard let gapped = DetachTraceGeometry.halves(of: notchOutline(), topGap: 185) else {
        check(false, "the outline splits with a housing gap")
        exit(1)
    }
    check(near(gapped.leftEnd, CGPoint(x: 260 - 92.5, y: 0)) && near(gapped.rightEnd, CGPoint(x: 260 + 92.5, y: 0)),
          "with the 185pt housing, the ends stop at its two sides", "\(gapped.leftEnd) \(gapped.rightEnd)")
    check(near(gapped.start, halves.start), "and still start at the bottom centre")
    check(near(halves.leftLength - gapped.leftLength, 92.5, 0.01), "each is shorter by half the housing")
    check(DetachTraceGeometry.halves(of: notchOutline(), topGap: 2000).map { near($0.leftEnd, CGPoint(x: 260, y: 0)) } == true,
          "a gap wider than the island is ignored")
}

print("Trace: other outlines")

do {
    // The shapes an island off its notch might take: none of them the
    // notch's, none starting at a corner.
    let pill = CGPath(roundedRect: CGRect(x: 0, y: 0, width: 300, height: 40), cornerWidth: 20, cornerHeight: 20, transform: nil)
    let card = CGPath(roundedRect: CGRect(x: 10, y: 5, width: 520, height: 230), cornerWidth: 28, cornerHeight: 28, transform: nil)
    let oval = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 200, height: 80), transform: nil)
    for (name, path, start, end) in [
        ("a pill", pill, CGPoint(x: 150, y: 40), CGPoint(x: 150, y: 0)),
        ("a rounded card, offset", card, CGPoint(x: 270, y: 235), CGPoint(x: 270, y: 5)),
        ("an ellipse", oval, CGPoint(x: 100, y: 80), CGPoint(x: 100, y: 0)),
    ] {
        guard let halves = DetachTraceGeometry.halves(of: path) else {
            check(false, "\(name) splits")
            continue
        }
        check(near(halves.start, start, 0.05), "\(name): starts at its bottom centre", "\(halves.start)")
        check(near(halves.leftEnd, end, 0.05) && near(halves.rightEnd, end, 0.05), "\(name): the ends meet at its top centre",
              "\(halves.leftEnd) \(halves.rightEnd)")
        check(near(halves.leftLength, halves.rightLength, 0.5), "\(name): the halves match",
              "\(halves.leftLength) \(halves.rightLength)")
        check(points(of: halves.left).allSatisfy { $0.x <= start.x + 0.001 }
              && points(of: halves.right).allSatisfy { $0.x >= start.x - 0.001 }, "\(name): one each side")
    }

    // An outline with a vertex exactly on the centre line, top and bottom.
    let diamond = CGMutablePath()
    diamond.addLines(between: [CGPoint(x: 50, y: 0), CGPoint(x: 100, y: 40), CGPoint(x: 50, y: 80), CGPoint(x: 0, y: 40)])
    diamond.closeSubpath()
    let d = DetachTraceGeometry.halves(of: diamond)
    check(d.map { near($0.start, CGPoint(x: 50, y: 80)) && near($0.leftEnd, CGPoint(x: 50, y: 0)) } == true,
          "a vertex on the centre line is one crossing, not two or none")

    let line = CGMutablePath()
    line.addLines(between: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)])
    check(DetachTraceGeometry.halves(of: line) == nil, "something that isn't an outline: nothing to draw")
    check(DetachTraceGeometry.halves(of: CGMutablePath()) == nil, "nor an empty path")
}

print("\n\(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
