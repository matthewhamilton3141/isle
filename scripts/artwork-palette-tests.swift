//
//  artwork-palette-tests.swift
//
//  Tests for choosing a cover's colours (Isle/Components/CoverColors.swift),
//  on made-up covers: lists of pixels, no image. Run with
//  scripts/test-artwork-palette.sh.
//

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

typealias RGB = CoverColors.RGB
typealias Lab = CoverColors.Lab

func lab(_ c: RGB) -> Lab { CoverColors.lab(c) }
func hueGap(_ a: RGB, _ b: RGB) -> Double { CoverColors.hueGap(lab(a), lab(b)) * 180 / .pi }
func chroma(_ c: RGB) -> Double { lab(c).chroma }
func lightness(_ c: RGB) -> Double { lab(c).l }
func distance(_ a: RGB, _ b: RGB) -> Double {
    let p = lab(a), q = lab(b)
    return ((p.l - q.l) * (p.l - q.l) + (p.a - q.a) * (p.a - q.a) + (p.b - q.b) * (p.b - q.b)).squareRoot()
}
func slots(_ p: CoverColors.Pick) -> [RGB] { [p.primary, p.secondary, p.accent] }
func hex(_ c: RGB) -> String {
    String(format: "#%02x%02x%02x", Int((c.r * 255).rounded()), Int((c.g * 255).rounded()), Int((c.b * 255).rounded()))
}
func show(_ p: CoverColors.Pick) -> String { "primary \(hex(p.primary)) accent \(hex(p.accent)) secondary \(hex(p.secondary))" }

/// A cover as areas of flat colour: each colour, and how many pixels of it.
func cover(_ parts: [(RGB, Int)]) -> [RGB] { parts.flatMap { Array(repeating: $0.0, count: $0.1) } }

/// The same numbers every run: a small generator for noise and shuffles.
struct Dice {
    var state: UInt64
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(1 << 53)
    }
}

/// The cover with every channel of every pixel nudged by up to `amount`,
/// as a JPEG nudges them.
func noisy(_ pixels: [RGB], amount: Double = 4.0 / 255, seed: UInt64 = 7) -> [RGB] {
    var dice = Dice(state: seed)
    func nudge(_ x: Double) -> Double { min(1, max(0, x + (dice.next() * 2 - 1) * amount)) }
    return pixels.map { RGB(r: nudge($0.r), g: nudge($0.g), b: nudge($0.b)) }
}

func shuffled(_ pixels: [RGB], seed: UInt64) -> [RGB] {
    var dice = Dice(state: seed), out = pixels
    for i in stride(from: out.count - 1, to: 0, by: -1) {
        out.swapAt(i, Int(dice.next() * Double(i + 1)))
    }
    return out
}

let black = RGB(r: 0.03, g: 0.03, b: 0.035), white = RGB(r: 0.97, g: 0.97, b: 0.96)
let grey = RGB(r: 0.5, g: 0.5, b: 0.5), darkGrey = RGB(r: 0.2, g: 0.2, b: 0.2), lightGrey = RGB(r: 0.78, g: 0.78, b: 0.78)
let red = RGB(r: 0.9, g: 0.1, b: 0.12), teal = RGB(r: 0.1, g: 0.75, b: 0.7)
let beige = RGB(r: 0.78, g: 0.72, b: 0.62), navy = RGB(r: 0.0, g: 0.07, b: 0.12)
let total = 4096

print("oklab")
do {
    let w = lab(RGB(r: 1, g: 1, b: 1)), k = lab(RGB(r: 0, g: 0, b: 0))
    check(abs(w.l - 1) < 1e-3 && w.chroma < 1e-3, "white is lightness 1, no chroma")
    check(abs(k.l) < 1e-6 && k.chroma < 1e-6, "black is lightness 0")
    let r = lab(RGB(r: 1, g: 0, b: 0))
    check(abs(r.l - 0.628) < 2e-3 && abs(r.a - 0.225) < 2e-3 && abs(r.b - 0.126) < 2e-3, "pure red is where OKLab puts it", "\(r)")
    for c in [red, teal, beige, navy, grey, RGB(r: 0.2, g: 0.9, b: 0.3)] {
        let back = CoverColors.rgb(lab(c))
        check(abs(back.r - c.r) < 1e-4 && abs(back.g - c.g) < 1e-4 && abs(back.b - c.b) < 1e-4, "\(hex(c)) survives the round trip")
    }
    check(lab(grey).chroma < 1e-3, "a grey has no chroma")
    check(chroma(red) > 3 * chroma(beige), "a red is far more colourful than a beige")
}

print("no cover, no palette")
do {
    check(CoverColors.pick([]) == nil, "no pixels, no palette")
    check(CoverColors.swatches([]).isEmpty, "and no colours")
}

print("a small vivid subject on a dark ground")
do {
    // 3% of a strong colour, the rest near-black: what the 8×8 grid
    // averaged away.
    let p = CoverColors.pick(cover([(black, total - 123), (red, 123)]))!
    check(hueGap(p.primary, red) < 2 && distance(p.primary, red) < 0.02, "the subject is the primary, as it is on the cover", show(p))
    check(slots(p).allSatisfy { hueGap($0, red) < 2 }, "and the black isn't a colour: every slot is the subject's", show(p))
    // The same on a dull light ground.
    let q = CoverColors.pick(cover([(beige, total - 250), (red, 250)]))!
    check(distance(q.primary, red) < 0.02, "6% of a strong colour beats 94% of a dull one", show(q))
    // A dark field doesn't outvote a bright colour.
    let n = CoverColors.pick(cover([(RGB(r: 0.05, g: 0.06, b: 0.2), 3200), (teal, 896)]))!
    check(distance(n.primary, teal) < 0.02, "a bright colour beats a larger dark one", show(n))
    // But a few pixels are not a subject.
    let s = CoverColors.pick(cover([(teal, total - 3), (red, 3)]))!
    check(slots(s).allSatisfy { hueGap($0, teal) < 2 }, "three stray pixels of red don't make the palette", show(s))
    let t = CoverColors.pick(noisy(cover([(RGB(r: 0.25, g: 0.45, b: 0.8), total - 8), (red, 8)])))!
    check(distance(t.primary, RGB(r: 0.25, g: 0.45, b: 0.8)) < 0.03, "nor does a speck beat a colourful ground", show(t))
}

print("one colour")
do {
    // A sleeve in one hue: a deep, a middle and a pale red.
    let deep = RGB(r: 0.45, g: 0.05, b: 0.08), pale = RGB(r: 0.96, g: 0.55, b: 0.55)
    let p = CoverColors.pick(cover([(red, 2000), (deep, 1200), (pale, 896)]))!
    check(slots(p).allSatisfy { hueGap($0, red) < CoverColors.hueStep * 180 / .pi }, "one hue on the cover: three shades of it", show(p))
    check(distance(p.primary, red) < 0.02, "the strongest shade is the primary", show(p))
    check(distance(p.accent, pale) < 0.02, "the accent is its real lighter shade", show(p))
    check(hueGap(p.secondary, deep) < 2 && lightness(p.secondary) < lightness(p.primary), "the secondary its real darker one", show(p))
    // A flat field has no shades to give, and none are made up.
    let flat = CoverColors.pick(cover([(teal, total)]))!
    check(slots(flat).allSatisfy { distance($0, teal) < 0.01 }, "a flat cover is its colour three times", show(flat))
    // Only a darker shade: it is the secondary, never the accent.
    let two = CoverColors.pick(cover([(red, 3000), (deep, 1096)]))!
    check(distance(two.accent, two.primary) < 1e-6, "a darker shade is never the accent", show(two))
    check(lightness(two.secondary) < lightness(two.primary), "it is the secondary", show(two))
}

print("two colours")
do {
    let p = CoverColors.pick(cover([(red, 2400), (teal, 1696)]))!
    check(distance(p.primary, red) < 0.02 || distance(p.primary, teal) < 0.02, "the primary is one of the two", show(p))
    check(hueGap(p.accent, p.primary) > 90, "the accent is the other", show(p))
    check(slots(p).allSatisfy { distance($0, red) < 0.02 || distance($0, teal) < 0.02 }, "two colours on the cover, two in the palette: no third", show(p))
    // Two reds and a teal: the second colour is the teal, not red again.
    let near = CoverColors.pick(cover([(red, 1600), (RGB(r: 0.9, g: 0.16, b: 0.1), 1600), (teal, 896)]))!
    check(hueGap(near.accent, teal) < 2, "two reds and a teal: the second colour is the teal", show(near))
    // A colour too weak beside the first isn't named.
    let weak = CoverColors.pick(cover([(red, 2000), (RGB(r: 0.62, g: 0.6, b: 0.55), 2096)]))!
    check(slots(weak).allSatisfy { hueGap($0, red) < 2 }, "a greyish ground beside a strong red isn't a second colour", show(weak))
}

print("several colours")
do {
    let yellow = RGB(r: 0.95, g: 0.8, b: 0.2), blue = RGB(r: 0.15, g: 0.4, b: 0.9), green = RGB(r: 0.2, g: 0.7, b: 0.3)
    let parts = [(red, 1000), (yellow, 1000), (blue, 1000), (green, 1000), (black, 96)]
    let p = CoverColors.pick(cover(parts))!
    let inputs = parts.map { $0.0 }
    check(slots(p).allSatisfy { s in inputs.contains { distance(s, $0) < 0.02 } }, "every slot is a colour of the cover", show(p))
    check(hueGap(p.primary, p.accent) > 30 && hueGap(p.primary, p.secondary) > 30 && hueGap(p.accent, p.secondary) > 30, "and they are three different colours", show(p))
    // Pastels are told apart when there's nothing stronger.
    let pink = RGB(r: 0.98, g: 0.80, b: 0.86), mint = RGB(r: 0.72, g: 0.93, b: 0.82), lilac = RGB(r: 0.80, g: 0.82, b: 0.99)
    let pastel = CoverColors.pick(cover([(pink, 1600), (mint, 1200), (lilac, 1296)]))!
    check(hueGap(pastel.primary, pastel.accent) > 30 && hueGap(pastel.primary, pastel.secondary) > 30 && hueGap(pastel.accent, pastel.secondary) > 30,
          "a pastel cover: its three colours, not one cream", show(pastel))
    check(slots(pastel).allSatisfy { s in [pink, mint, lilac].contains { distance(s, $0) < 0.02 } }, "as pale as the cover has them", show(pastel))
}

print("covers with no colour")
do {
    let bw = CoverColors.pick(noisy(cover([(black, 2000), (grey, 1200), (lightGrey, 600), (white, 296)])))!
    check(slots(bw).allSatisfy { chroma($0) < 0.012 }, "a black-and-white photograph stays grey, noise and all", show(bw))
    check(lightness(bw.accent) > lightness(bw.primary) && lightness(bw.primary) > lightness(bw.secondary), "lightest on top, darkest underneath", show(bw))
    let flat = CoverColors.pick(noisy(cover([(grey, total)])))!
    check(slots(flat).allSatisfy { chroma($0) < 0.012 && abs(lightness($0) - lightness(grey)) < 0.04 }, "a grey cover is grey", show(flat))
    // A near-black with a cast: the numbers say teal, the eye says black.
    let cast = RGB(r: 0.01, g: 0.035, b: 0.045)
    let dark = CoverColors.pick(noisy(cover([(cast, total)]), amount: 2.0 / 255))!
    check(slots(dark).allSatisfy { chroma($0) < 0.012 }, "a black cover with a cast comes up grey, not teal", show(dark))
    check(lightness(dark.primary) >= CoverColors.primaryFloor - 0.01, "and light enough to see", show(dark))
    // Less than 1% of colour on a grey cover is not a colour cover.
    let hint = CoverColors.pick(cover([(grey, 2000), (darkGrey, 2076), (red, 20)]))!
    check(slots(hint).allSatisfy { chroma($0) < 0.012 }, "half a percent of red on a grey cover: still grey", show(hint))
    let more = CoverColors.pick(cover([(grey, 2000), (darkGrey, 1896), (red, 200)]))!
    check(distance(more.primary, red) < 0.02, "five percent of it: red", show(more))
    // A tint is kept as a tint.
    let sepia = RGB(r: 0.80, g: 0.74, b: 0.64), sepiaDark = RGB(r: 0.45, g: 0.40, b: 0.33)
    let toned = CoverColors.pick(cover([(sepia, 2400), (sepiaDark, 1696)]))!
    check(slots(toned).allSatisfy { hueGap($0, sepia) < 15 && chroma($0) < chroma(sepia) * 1.3 }, "a sepia cover is sepia, no stronger than it is", show(toned))
}

print("the same cover, the same palette")
do {
    let yellow = RGB(r: 0.95, g: 0.8, b: 0.2)
    let pixels = noisy(cover([(beige, 1200), (red, 800), (teal, 800), (navy, 1000), (yellow, 296)]), amount: 10.0 / 255)
    let a = CoverColors.pick(pixels)!
    check(CoverColors.pick(pixels)! == a, "the same pixels twice give the same palette")
    for seed in [1, 2, 3] as [UInt64] {
        check(CoverColors.pick(shuffled(pixels, seed: seed))! == a, "and in any order (shuffle \(seed)): identical, not just close")
    }
    check(CoverColors.pick(Array(pixels.reversed()))! == a, "and back to front")
    check(CoverColors.swatches(pixels) == CoverColors.swatches(shuffled(pixels, seed: 9)), "the colours found are the same too")
    let shares = CoverColors.swatches(pixels).reduce(0) { $0 + $1.share }
    check(abs(shares - 1) < 1e-9, "every pixel is in exactly one colour", "\(shares)")
    check(CoverColors.swatches(pixels).count <= CoverColors.clusterCount, "at most \(CoverColors.clusterCount) colours")
    check(CoverColors.swatches(cover([(teal, total)])).count == 1, "a flat cover is one colour, not sixteen")
}

print("lifting off black")
do {
    // A deep navy lifted to where the island can show it: the same hue.
    let deep = lab(navy)
    for floor in [CoverColors.secondaryFloor, CoverColors.primaryFloor, CoverColors.accentFloor] {
        let up = CoverColors.lifted(deep, to: floor)
        check(abs(up.l - floor) < 1e-9, "lifted to \(floor)")
        check(CoverColors.hueGap(up, deep) < 1e-6, "with its hue kept")
        check(up.chroma >= deep.chroma, "and no greyer than it was")
        let c = CoverColors.rgb(up), back = lab(c)
        check(abs(back.l - floor) < 0.01 && CoverColors.hueGap(back, deep) < 0.03, "a colour sRGB can show", "\(hex(c))")
    }
    let light = lab(teal)
    check(CoverColors.lifted(light, to: CoverColors.accentFloor) == light, "a colour already above the floor is left alone")
    let grown = CoverColors.lifted(Lab(l: 0.2, a: 0.01, b: 0.01), to: 0.9)
    check(grown.chroma <= Lab(l: 0.2, a: 0.01, b: 0.01).chroma * CoverColors.maxChromaGrowth + 1e-9, "chroma grows no more than \(CoverColors.maxChromaGrowth)×")
    let ink = CoverColors.lifted(Lab(l: 0.08, a: 0.02, b: -0.03), to: CoverColors.primaryFloor)
    check(ink.chroma < 1e-9, "a black's cast doesn't come up with it")
    // The whole way through: a cover that is all navy.
    let p = CoverColors.pick(cover([(navy, total)]))!
    check(hueGap(p.primary, navy) < 3, "a navy cover is blue, not grey and not another blue", show(p))
    check(lightness(p.primary) >= CoverColors.primaryFloor - 0.01 && lightness(p.accent) >= CoverColors.accentFloor - 0.01
          && lightness(p.secondary) >= CoverColors.secondaryFloor - 0.01, "each slot at or above its floor", show(p))
    check(chroma(p.primary) >= chroma(navy), "and at least as colourful as the navy it came from", show(p))
    // The old floor scaled RGB and clipped: a deep blue came up as a
    // different blue. Here a saturated colour that can't go lighter at
    // full strength gives up chroma, not hue.
    let ultra = CoverColors.lifted(lab(RGB(r: 0, g: 0, b: 0.6)), to: 0.7)
    check(CoverColors.hueGap(ultra, lab(RGB(r: 0, g: 0, b: 0.6))) < 1e-6, "out of gamut: chroma gives way, hue doesn't")
    let shown = CoverColors.rgb(ultra)
    check(min(shown.r, shown.g, shown.b) >= 0 && max(shown.r, shown.g, shown.b) <= 1, "and it fits in sRGB")
}

print("\n\(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
