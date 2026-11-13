//
//  island-placement-tests.swift
//
//  Tests for taking the island off its notch, compiled against the three
//  files that hold the deciding and nothing else — no app, no window, no
//  pointer, no clock:
//
//  - IslandHold.swift: one press, from button down to button up — a click
//    left alone, a hold that runs the line and lifts the island, the ways a
//    hold is called off, a plain drag of a closed island or of an open one
//    by its header, and the click a plain drag can turn out to be.
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
    let click = hold.up(at: CGPoint(x: 702, y: 899), time: 20.1)
    check(click == Outcome(verdict: .pass, actions: [.clicked(at: press)]),
          "a click without a drag is a click: passed on, and said so, at the press", "\(click)")
    check(hold.phase == .idle, "and the press is over")

    _ = hold.down(kind: .drag, at: press, time: 30)
    _ = hold.tick(time: 35, pointer: press, buttonDown: true)
    check(hold.up(at: press, time: 35.1).actions == [.clicked(at: press)], "however long it was held still: nothing is timed, so it's still a click")

    _ = hold.down(kind: .drag, at: press, time: 40)
    _ = hold.moved(to: CGPoint(x: 760, y: 900), time: 40.1)
    check(hold.up(at: press, time: 40.2).actions == [.dropped(at: press)], "dragged and brought back: a move, not a click")

    _ = hold.down(kind: .drag, at: press, time: 50)
    _ = hold.tick(time: 50.5, pointer: press, buttonDown: false)
    check(hold.phase == .idle && hold.up(at: press, time: 50.6) == Outcome(),
          "a release seen only as the button up (it went elsewhere): no click")
}

print("Hold: an open island off the notch, by its header or its edge, is dragged at once")

do {
    // IslandCarry gives a press on the grabber, the band round it or the
    // panel's bare edge `.drag`, and one on its content `.pickUp`.
    var hold = IslandHold()
    _ = hold.down(kind: .drag, at: press, time: 10)
    check(hold.deadline == nil, "no grace, no line: nothing to wait for")
    let lifted = hold.moved(to: CGPoint(x: 690, y: 896), time: 10.03)
    check(lifted == Outcome(verdict: .swallow, actions: [.lifted(at: press), .carried(to: CGPoint(x: 690, y: 896))]),
          "the first drag past the slop, 30ms in, picks it up", "\(lifted)")
    check(hold.moved(to: CGPoint(x: 600, y: 850), time: 10.1) == Outcome(verdict: .swallow, actions: [.carried(to: CGPoint(x: 600, y: 850))]),
          "and it follows the pointer")
    check(hold.up(at: CGPoint(x: 600, y: 850), time: 10.2) == Outcome(verdict: .cancelPress, actions: [.dropped(at: CGPoint(x: 600, y: 850))]),
          "and is put down on release, which the views don't take for a click")

    // On its content the hold stays: a scrub there is the scrubber's.
    var content = IslandHold()
    _ = content.down(kind: .pickUp, at: press, time: 10)
    check(content.moved(to: CGPoint(x: 760, y: 900), time: 10.05) == Outcome() && content.phase == .spent,
          "on the content a drag straight away is still the control's")
    check(content.up(at: CGPoint(x: 760, y: 900), time: 10.3) == Outcome(), "and so is its release")
    _ = content.down(kind: .pickUp, at: press, time: 20)
    check(content.up(at: press, time: 20.1) == Outcome(), "a click on the content is the content's, and nothing of the island's")

    // The on-notch hold is untouched.
    check(IslandHold.Kind.detach.timing.map { $0.grace == 0.25 && $0.run == 1.1 } == true, "taking it off the notch still takes the 0.25 + 1.1s hold")
    check(IslandHold.Kind.drag.timing == nil, "a plain drag is never timed")
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
// island's widest and tallest off the notch (the 520pt card: the docked
// panel with Prism's side lips, less its flares; the 230pt cap with its lip
// and the roof), and about the widest closed capsule.
let pill = CGSize(width: 330, height: 38)
let bounds = IslandPlacementBounds(
    screen: CGRect(x: 0, y: 0, width: 1512, height: 982),
    visible: CGRect(x: 0, y: 0, width: 1512, height: 944),
    halfWidth: 260,
    tallest: 250,
    pill: pill
)

/// Where the widest, tallest open panel lies for an island at `anchor`
/// opening as `opening`.
func panel(_ anchor: CGPoint, _ opening: IslandOpening, in b: IslandPlacementBounds) -> CGRect {
    b.panel(CGSize(width: 2 * b.halfWidth, height: b.tallest), at: anchor, opening: opening)
}

/// Where a closed capsule `width` wide lies for an island at `anchor`
/// opening (and so pinned) as `opening`: what NotchRootView draws.
func capsule(_ anchor: CGPoint, _ width: CGFloat, _ opening: IslandOpening, in b: IslandPlacementBounds) -> CGRect {
    CGRect(x: opening.pillMinX(anchor: anchor.x, width: width), y: anchor.y - b.pill.height, width: width, height: b.pill.height)
}

/// The same, at the widest the capsule gets.
func capsule(_ anchor: CGPoint, in b: IslandPlacementBounds) -> CGRect {
    capsule(anchor, b.pill.width, b.opening(at: anchor), in: b)
}

func inside(_ r: CGRect, _ outer: CGRect) -> Bool {
    r.minX >= outer.minX - 0.01 && r.maxX <= outer.maxX + 0.01 && r.minY >= outer.minY - 0.01 && r.maxY <= outer.maxY + 0.01
}

/// The drawn outline's centre for an island at `anchor`, `width` wide:
/// the window's centre (the anchor and the shift) and the offset in it.
func drawnMid(_ anchor: CGPoint, _ width: CGFloat, open: Bool, _ o: IslandOpening) -> CGFloat {
    anchor.x + o.shift + o.offset(width: width, open: open)
}

print("Placement: where an island may be")

do {
    check(bounds.dock == CGPoint(x: 756, y: 982), "docked is the top centre of the screen")
    check(bounds.room == 260 && bounds.pinsToEdges, "room for the widest panel either side, and a screen wide enough to pin")
    let free = CGPoint(x: 500, y: 600)
    check(bounds.resting(free) == free && bounds.carrying(free) == free, "an anchor with room all round is left alone")
    check(bounds.resting(CGPoint(x: 756, y: 982)) == CGPoint(x: 756, y: 944), "at rest the island sits below the menu bar")
    check(bounds.carrying(CGPoint(x: 756, y: 982)) == CGPoint(x: 756, y: 982), "carried, it may be at the very top — where it starts")
    check(bounds.carrying(CGPoint(x: 756, y: 1100)) == CGPoint(x: 756, y: 982), "but not above it")
    check(bounds.resting(CGPoint(x: -400, y: 3000)) == CGPoint(x: 0, y: 944),
          "a remembered anchor off the top left: to the corner, where it's the capsule's left end")
    check(bounds.resting(CGPoint(x: 9000, y: -50)) == CGPoint(x: 1512, y: 38),
          "off the bottom right: into the corner, its right end on the edge, its bottom on the screen's")
    let low = bounds.resting(CGPoint(x: 600, y: 10))
    check(low == CGPoint(x: 600, y: 38), "the bottom of the screen is somewhere to rest, not out of bounds", "\(low)")

    // With the Dock on the left and an auto-hidden menu bar.
    let docked = IslandPlacementBounds(screen: bounds.screen, visible: CGRect(x: 70, y: 0, width: 1442, height: 982),
                                       halfWidth: 260, tallest: 250, pill: pill)
    check(docked.resting(CGPoint(x: 0, y: 500)).x == 70, "the Dock's side is kept clear: the wall is the Dock's edge")

    let tiny = IslandPlacementBounds(screen: CGRect(x: 0, y: 0, width: 400, height: 200),
                                     visible: CGRect(x: 0, y: 0, width: 400, height: 180), halfWidth: 260, tallest: 250, pill: pill)
    check(!tiny.pinsToEdges, "a screen narrower than an island pinned near one edge can grow to: no pinning")
    check(tiny.resting(CGPoint(x: 10, y: 10)) == CGPoint(x: 165, y: 38), "and the widest capsule is kept on it, centred")
    let sliver = IslandPlacementBounds(screen: CGRect(x: 0, y: 0, width: 200, height: 30),
                                       visible: CGRect(x: 0, y: 0, width: 200, height: 30), halfWidth: 260, tallest: 250, pill: pill)
    check(sliver.resting(CGPoint(x: 10, y: 10)) == CGPoint(x: 100, y: 30), "one too small even for that: centred, from the top")
}

print("Placement: pinned near an edge, it grows away from it")

do {
    check(bounds.pin(at: 0) == .leading && bounds.pin(at: 259) == .leading, "within reach of the left edge: its left end stays put")
    check(bounds.pin(at: 260) == .centre && bounds.pin(at: 1252) == .centre, "with room either side: its middle")
    check(bounds.pin(at: 1253) == .trailing && bounds.pin(at: 1512) == .trailing, "within reach of the right edge: its right end")

    // A capsule of any width against the left edge, and the open panel,
    // all have their left ends at the anchor.
    let left = bounds.opening(at: CGPoint(x: 0, y: 600))
    check(left == IslandOpening(upward: false, shift: 260, pin: .leading), "against the left edge: pinned, the window reaching right", "\(left)")
    for w: CGFloat in [60, 132, 330, 471] {
        let mid = drawnMid(CGPoint(x: 0, y: 600), w, open: false, left)
        check(near(mid - w / 2, 0), "closed \(Int(w))pt wide: its left end on the edge")
    }
    for w: CGFloat in [496, 520] {
        check(near(drawnMid(CGPoint(x: 0, y: 600), w, open: true, left) - w / 2, 0), "open \(Int(w))pt wide: its left wall on the edge, no slide")
    }
    let right = bounds.opening(at: CGPoint(x: 1512, y: 600))
    check(right == IslandOpening(upward: false, shift: -260, pin: .trailing), "against the right edge: the same, mirrored", "\(right)")
    for (w, open) in [(CGFloat(60), false), (132, false), (471, false), (496, true), (520, true)] {
        check(near(drawnMid(CGPoint(x: 1512, y: 600), w, open: open, right) + w / 2, 1512), "\(open ? "open" : "closed") \(Int(w))pt wide: its right end on the edge")
    }
    // The middle: the capsule centred on the anchor, the panel on the window.
    let mid = bounds.opening(at: CGPoint(x: 756, y: 600))
    check(mid == .down, "in the middle: down, centred")
    check(near(drawnMid(CGPoint(x: 756, y: 600), 60, open: false, mid), 756) && near(drawnMid(CGPoint(x: 756, y: 600), 496, open: true, mid), 756),
          "capsule and panel on the same middle")

    // Wherever a capsule of any width rests and is anchored again for its
    // place, every form the island takes there is on the screen and grows
    // out of the capsule as it rests.
    var everywhere = true, overCapsule = true, inPlace = true
    for x in stride(from: CGFloat(-100), through: 1700, by: 23) {
        for y in stride(from: CGFloat(-50), through: 1050, by: 41) {
            for w: CGFloat in [60, 132, 330] {
                let anchor = bounds.restingPill(CGPoint(x: x, y: y), width: w, carried: .down)
                let o = bounds.opening(at: anchor)
                let c = capsule(anchor, w, o, in: bounds)
                // Carried centred to `x`; put down, it's where it was, moved in only as far as it had to be.
                let wantMinX = min(max(x - w / 2, 0), 1512 - w)
                if !near(c.minX, wantMinX) { inPlace = false }
                let widest = capsule(anchor, 471, o, in: bounds)
                let p = panel(anchor, o, in: bounds)
                if !inside(c, bounds.visible) || !inside(widest, bounds.visible) || !inside(p, bounds.visible) { everywhere = false }
                if !(p.minX <= c.minX + 0.01 && p.maxX >= c.maxX - 0.01 && (o.upward ? near(p.minY, c.minY) : near(p.maxY, c.maxY))) { overCapsule = false }
            }
        }
    }
    check(inPlace, "a capsule put down stays where it was let go, moved in only to be wholly on the screen")
    check(everywhere, "and wherever it rests, the widest capsule and the open panel fit on the screen")
    check(overCapsule, "the panel stands on the capsule's bottom or hangs from its top, over the whole of it")
}

print("Placement: which way it opens")

do {
    let mid = CGPoint(x: 756, y: 600)
    check(bounds.opening(at: mid) == .down, "with room below: down, centred on the capsule")
    check(bounds.opening(at: CGPoint(x: 756, y: 250)) == .down, "down for as long as the tallest panel fits below")
    let justUnder = bounds.opening(at: CGPoint(x: 756, y: 249))
    check(justUnder.upward && justUnder.shift == 0, "a point lower and it opens up, from the capsule's bottom edge")

    // A display shorter than the open panel: it opens the way with more room.
    let short = IslandPlacementBounds(screen: CGRect(x: 0, y: 0, width: 800, height: 220),
                                      visible: CGRect(x: 0, y: 0, width: 800, height: 200), halfWidth: 260, tallest: 250, pill: pill)
    let nearTop = short.resting(CGPoint(x: 400, y: 190)), nearBottom = short.resting(CGPoint(x: 400, y: 50))
    check(!short.opening(at: nearTop).upward && short.opening(at: nearBottom).upward,
          "a display shorter than the panel: down from near the top, up from near the bottom")
    check(inside(capsule(nearBottom, in: short), short.visible), "and the capsule itself still rests wholly on it")
    // Narrower than the panel: the panel is centred on the screen.
    let narrow = IslandPlacementBounds(screen: CGRect(x: 0, y: 0, width: 500, height: 900),
                                       visible: CGRect(x: 0, y: 0, width: 500, height: 900), halfWidth: 260, tallest: 250, pill: pill)
    check(near(narrow.opening(at: CGPoint(x: 180, y: 600)).shift, 70), "a screen narrower than the panel: it opens over the screen's middle")

    // Carried open, the panel stays on the screen opening the way it does.
    let up = IslandOpening(upward: true, shift: 260, pin: .leading)
    let held = bounds.carrying(CGPoint(x: -300, y: 2000), open: up)
    check(inside(panel(held, up, in: bounds), bounds.screen) && held.x == 0, "an open panel pinned left, carried up and left, stays on the screen, against its edge", "\(held)")
    let put = bounds.resting(CGPoint(x: 3000, y: -500), open: .down)
    check(inside(panel(put, .down, in: bounds), bounds.visible), "and put down, rests where it fits the way it opens", "\(put)")
}

print("Placement: carried closed, the capsule itself goes to the wall")

do {
    // Carried as it was put down — centred, here — the capsule as drawn is
    // what's kept on the screen, not the widest it could be.
    for w: CGFloat in [60, 132, 330] {
        let l = bounds.carrying(CGPoint(x: -500, y: 600), pillWidth: w, carried: .down)
        let r = bounds.carrying(CGPoint(x: 5000, y: 600), pillWidth: w, carried: .down)
        check(near(l.x - w / 2, 0) && near(r.x + w / 2, 1512), "\(Int(w))pt wide: carried against either edge, right up to it", "\(l) \(r)")
    }
    let pinned = IslandOpening(upward: false, shift: 260, pin: .leading)
    let fromLeft = bounds.carrying(CGPoint(x: 5000, y: 600), pillWidth: 60, carried: pinned)
    check(near(fromLeft.x + 60, 1512), "pinned left and carried right across the screen, it still goes all the way", "\(fromLeft)")
    check(bounds.carrying(CGPoint(x: 400, y: -80), pillWidth: 60, carried: .down).y == 38, "down to the bottom edge")
}

print("Placement: closed by the grabber, carried to an edge, opened")

do {
    // An open card in the middle of the screen, opening down. The grabber
    // is clicked: it closes to its capsule where it is, and keeps the way
    // it opened until it's put down (IslandCarry's `keptOpening` is nil
    // from the moment it's closed).
    let card = CGSize(width: 520, height: 154)
    let start = CGPoint(x: 756, y: 700)
    let before = bounds.putDown(start, open: .down, pillWidth: 132, carried: .down)
    check(before.anchor == start && before.opening == .down, "put down open, it keeps its way")
    check(bounds.panel(card, at: start, opening: .down).contains(CGPoint(x: 756, y: 700 - 24)),
          "the grabber it was closed by is over the capsule that's left: the pointer is still on it")

    // Then carried, closed, past each edge and corner, and let go, for the
    // bead, Claude alone and the widest capsule.
    let targets: [(String, CGPoint, Bool, IslandOpening.Pin)] = [
        ("right edge", CGPoint(x: 5000, y: 600), false, .trailing),
        ("left edge", CGPoint(x: -5000, y: 600), false, .leading),
        ("top edge", CGPoint(x: 400, y: 5000), false, .centre),
        ("bottom edge", CGPoint(x: 900, y: -5000), true, .centre),
        ("top right", CGPoint(x: 5000, y: 5000), false, .trailing),
        ("top left", CGPoint(x: -5000, y: 5000), false, .leading),
        ("bottom right", CGPoint(x: 5000, y: -5000), true, .trailing),
        ("bottom left", CGPoint(x: -5000, y: -5000), true, .leading),
    ]
    for w: CGFloat in [60, 132, 471] {
        for (name, wanted, upward, pin) in targets {
            let carried = bounds.carrying(wanted, pillWidth: w, carried: .down)
            let down = bounds.putDown(carried, open: nil, pillWidth: w, carried: .down)
            let o = down.opening
            let c = capsule(down.anchor, w, o, in: bounds)
            let label = "\(name), \(Int(w))pt"
            check(inside(c, bounds.visible), "\(label): it rests there, whole", "\(c)")
            switch pin {
            case .leading: check(near(c.minX, 0), "\(label): flush against the left edge", "\(c)")
            case .trailing: check(near(c.maxX, 1512), "\(label): flush against the right edge", "\(c)")
            case .centre: break
            }
            if upward { check(near(c.minY, 0), "\(label): flush on the bottom edge", "\(c)") }
            if name.hasPrefix("top") { check(near(c.maxY, 944), "\(label): flush under the menu bar", "\(c)") }
            check(o.upward == upward && o.pin == pin,
                  "\(label): opens \(upward ? "up" : "down"), \(pin == .centre ? "centred" : pin == .leading ? "growing right" : "growing left")", "\(o)")
            for size in [card, CGSize(width: 496, height: 146), CGSize(width: 520, height: bounds.tallest)] {
                let p = bounds.panel(size, at: down.anchor, opening: o)
                check(inside(p, bounds.visible), "\(label): the \(Int(size.width))×\(Int(size.height)) panel opens on the screen", "\(p)")
                let still = pin == .leading ? near(p.minX, c.minX) : pin == .trailing ? near(p.maxX, c.maxX) : near(p.midX, c.midX)
                check(still && (o.upward ? near(p.minY, c.minY) : near(p.maxY, c.maxY)),
                      "\(label): out of the capsule, its \(pin == .centre ? "middle" : "wall side") where the capsule's was: one motion, no slide", "\(p) from \(c)")
            }
        }
    }

    // Had it been carried open instead, it would have kept its way down,
    // and so been kept out of the bottom of the screen: why it's closed first.
    let openToCorner = bounds.putDown(CGPoint(x: 5000, y: -5000), open: .down, pillWidth: 132, carried: .down)
    check(openToCorner.opening == .down && openToCorner.anchor.y == bounds.tallest,
          "carried open into the bottom right it stays opening down, a panel's height up", "\(openToCorner)")
    check(bounds.putDown(CGPoint(x: 5000, y: -5000), open: nil, pillWidth: 132, carried: .down).anchor.y == bounds.pill.height,
          "closed, it goes right into the corner")

    // The room it's held compact in is the panel it would open into, so the
    // capsule — wherever the opening has put it — is inside it.
    for anchor in [CGPoint(x: 1512, y: 38), CGPoint(x: 0, y: 944), CGPoint(x: 756, y: 500)] {
        let o = bounds.opening(at: anchor)
        check(bounds.panel(card, at: anchor, opening: o).insetBy(dx: -0.01, dy: -0.01).contains(capsule(anchor, 132, o, in: bounds).insetBy(dx: 1, dy: 1)),
              "held compact at \(Int(anchor.x)),\(Int(anchor.y)): the capsule is in the room it's held in")
    }
}

print("Placement: put down where there's room, it's where it was let go")

do {
    // A bead let go 100pt in from the left edge: pinned there, not pulled
    // to the wall, and still growing rightward.
    let bead = bounds.putDown(CGPoint(x: 130, y: 600), open: nil, pillWidth: 60, carried: .down)
    check(bead.anchor.x == 100 && bead.opening.pin == .leading, "a bead 100pt from the left edge stays 100pt from it, growing right", "\(bead)")
    // Pinned, then carried into the middle: anchored by its middle again,
    // where it is.
    let back = bounds.putDown(CGPoint(x: 700, y: 600), open: nil, pillWidth: 60, carried: bead.opening)
    check(back.anchor.x == 730 && back.opening.pin == .centre, "a pinned bead carried to the middle is centred there, where it was drawn", "\(back)")
    // At the boundary nothing jumps: the capsule is where it was either way.
    for x in stride(from: CGFloat(240), through: 290, by: 1) {
        let d = bounds.putDown(CGPoint(x: x, y: 600), open: nil, pillWidth: 60, carried: .down)
        if !near(capsule(d.anchor, 60, d.opening, in: bounds).midX, x) { check(false, "the bead let go at \(x) is drawn there", "\(d)") }
    }
    check(true, "either side of where pinning starts, a capsule is drawn where it was let go")
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

    // Left near the bottom of the screen: back where it was, opening up.
    let lowLeft = bounds.placement(restoring: CGPoint(x: -500, y: -930))
    check(lowLeft == .floating(anchor: CGPoint(x: 256, y: 52)), "left near the bottom, it comes back there", "\(lowLeft)")
    check(lowLeft.anchor.map { bounds.opening(at: $0).upward } == true, "and opens upward")

    // A smaller display under the same name (a changed resolution).
    let small = IslandPlacementBounds(screen: CGRect(x: 0, y: 0, width: 1147, height: 745),
                                      visible: CGRect(x: 0, y: 0, width: 1147, height: 707), halfWidth: 260, tallest: 250, pill: pill)
    check(small.placement(restoring: CGPoint(x: -700, y: -382)) == .docked, "a place that's no longer on the screen: docked")
    check(small.placement(restoring: CGPoint(x: -456, y: -730)) == .floating(anchor: CGPoint(x: 117.5, y: 38)),
          "one that is, with too little room below: brought up to where the capsule fits, pinned left where it was")
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
