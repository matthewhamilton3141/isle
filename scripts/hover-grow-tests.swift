//
//  hover-grow-tests.swift
//
//  Tests for which control grows under the pointer (`HoverTargets`) and by
//  how much (`HoverGrow.scale`), compiled against Isle/Notch/HoverGrow.swift
//  alone. Run with scripts/test-hover-grow.sh.
//
//  Coordinates are the island's top-left space: two 28×28 keys side by side
//  with a 16pt gap, like the transport row.
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

let play = UUID()
let next = UUID()
let row = UUID()
let keys = [
    HoverTarget(id: play, rect: CGRect(x: 100, y: 150, width: 28, height: 28)),
    HoverTarget(id: next, rect: CGRect(x: 144, y: 150, width: 28, height: 28)),
]

print("Which control")

do {
    var t = HoverTargets()
    t.setTargets(keys)
    t.move(to: CGPoint(x: 110, y: 160))
    check(t.hovered == play, "on a key: that key, at once")
    t.move(to: CGPoint(x: 136, y: 160))
    check(t.hovered == nil, "in the gap between keys: none")
    t.move(to: CGPoint(x: 150, y: 160))
    check(t.hovered == next, "on the next key: that one")
    t.leave()
    check(t.hovered == nil, "the pointer gone: none")
}

do {
    var t = HoverTargets()
    t.move(to: CGPoint(x: 110, y: 160))
    check(t.hovered == nil, "no controls laid out yet: none")
    t.setTargets(keys)
    check(t.hovered == play, "laid out under a still pointer: the one under it")
    t.setTargets([HoverTarget(id: play, rect: CGRect(x: 300, y: 150, width: 28, height: 28)), keys[1]])
    check(t.hovered == nil, "moved out from under a still pointer: none")
    t.setTargets([])
    check(t.hovered == nil, "the panel closed: none")
}

do {
    // A row button round a smaller one: the smaller is the one pointed at.
    var t = HoverTargets()
    t.setTargets([
        HoverTarget(id: row, rect: CGRect(x: 0, y: 100, width: 300, height: 24)),
        HoverTarget(id: next, rect: CGRect(x: 270, y: 104, width: 24, height: 16)),
    ])
    t.move(to: CGPoint(x: 280, y: 112))
    check(t.hovered == next, "overlapping: the smaller control")
    t.move(to: CGPoint(x: 200, y: 112))
    check(t.hovered == row, "off the smaller one: the row")
}

print("How much")

do {
    let key = HoverGrow.scale(for: CGSize(width: 28, height: 28))
    check(abs(key * 28 - 28 - 2 * HoverGrow.reach) < 0.001, "a key grows by the reach on each side", "\(key)")
    let tile = HoverGrow.scale(for: CGSize(width: 110, height: 96))
    check(abs(tile * 110 - 110 - 2 * HoverGrow.reach) < 0.001, "a tile by the same few points, so a smaller scale", "\(tile)")
    check(tile < key, "the bigger the control, the smaller the scale")
    let chevron = HoverGrow.scale(for: CGSize(width: 14, height: 14))
    check(chevron == HoverGrow.maxScale, "a tiny control is capped", "\(chevron)")
    check(HoverGrow.scale(for: .zero) == 1, "no size: no growth")
}

print("\n\(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
