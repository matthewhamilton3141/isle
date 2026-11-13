//
//  island-glass-tests.swift
//
//  Tests for the glass panel backgrounds' arithmetic — the black-to-glass
//  blend, the notch glow, the tints, the shared ease and compositing, the
//  legibility lifts and Prism — and the stored setting's default and its
//  reading of retired backgrounds, compiled against the SwiftUI-free
//  sources alone (see scripts/test-island-glass.sh, which runs it).
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

print("setting")
do {
    check(PanelBackground.stored(nil) == .black, "absent key (fresh install, older build) is Black")
    check(PanelBackground.stored("") == .black, "empty value is Black")
    check(PanelBackground.stored("frosted") == .black, "unknown value is Black")
    check(PanelBackground.stored("Glass") == .black, "raw values are case-sensitive")
    for b in PanelBackground.allCases {
        check(PanelBackground.stored(b.rawValue) == b, "\(b.rawValue) round-trips")
    }
    check(PanelBackground.allCases == [.black, .glass, .prism], "picker order: Black, Glass, Prism")
    check(!PanelBackground.black.isGlass, "Black isn't glass")
    check(PanelBackground.allCases.filter(\.isGlass) == [.glass, .prism], "the other two are glass")
    check(Set(PanelBackground.allCases.map(\.title)).count == 3, "titles distinct")
    check(PanelBackground.stored("prism") == .prism, "Prism is stored as \"prism\"")
    check(PanelBackground.allCases.filter(\.growsNotchGlow) == [.glass], "the notch glow is Glass's alone")
    check(PanelBackground.stored("glassNotchFade") == .black && PanelBackground.stored("glassNotchGlow") == .black, "unshipped interim values read as Black")
    // Smoked and Fade shipped and were removed: a stored one is Glass, the
    // nearest thing still on offer, not Black.
    check(PanelBackground.stored("smoked") == .glass, "a stored Smoked reads as Glass")
    check(PanelBackground.stored("fade") == .glass, "a stored Fade reads as Glass")
    check(PanelBackground(rawValue: "smoked") == nil && PanelBackground(rawValue: "fade") == nil, "neither is a background any more")
    check(PanelBackground.stored("Smoked") == .black && PanelBackground.stored("FADE") == .black, "only the exact stored values are carried over")
    check(!PanelBackground.allCases.map(\.rawValue).contains { ["smoked", "fade"].contains($0) }, "and neither is offered in the picker")
}

print("tints")
do {
    check(IslandGlass.tint(for: .black) == 0, "Black has no tint")
    check(IslandGlass.tint(for: .glass) == IslandGlass.glassTint, "Glass uses glassTint")
    check(IslandGlass.tint(for: .prism) == IslandPrism.lipTint, "Prism's tint is its lip's")
    // Prism's lens is shaded all over, the lip a little less than the walls:
    // never so much less that the lip is a pale band under a dark panel.
    check(IslandPrism.edgeTint - IslandPrism.lipTint <= 0.1 && IslandPrism.scrim <= 0.1, "Prism's shade is all but even from wall to wall and down to the lip",
          "walls \(IslandPrism.edgeTint) lip \(IslandPrism.lipTint) scrim \(IslandPrism.scrim)")
    // What holds over a bright window is the cap: white text on the lightest
    // the lens is let be reads at better than 4.5 to 1.
    let capLinear = pow((IslandPrism.capLightest + 0.055) / 1.055, 2.4)
    check(1.05 / (capLinear + 0.05) >= 4.5, "white text over a white window, under the cap, reads at 4.5 to 1 or better", "\(1.05 / (capLinear + 0.05))")
    check(IslandPrism.cap >= 0.3 && IslandPrism.capStrength < 1 && IslandPrism.capStrength >= 0.7, "the cap is no darker than it needs to be, and lets a bright window show as one")
    check(IslandPrism.contentAlpha <= 0.25, "the shade itself is light: colour behind the glass comes through")
}

print("shared arithmetic")
do {
    check(IslandGlass.ease(-1) == 0 && IslandGlass.ease(2) == 1, "the ease clamps")
    check(IslandGlass.ease(0) == 0 && near(IslandGlass.ease(0.5), 0.5) && IslandGlass.ease(1) == 1, "the ease: 0, a half, 1")
    check(IslandGlass.ease(0.001) < 1e-5 && 1 - IslandGlass.ease(0.999) < 1e-5, "no slope at either end")
    var rising = true, prev = 0.0
    for i in 0...1000 { let v = IslandGlass.ease(Double(i) / 1000); if v < prev { rising = false }; prev = v }
    check(rising, "and only ever rises between")
    check(near(IslandGlass.smoothstep(2, 4, 3), 0.5) && IslandGlass.smoothstep(2, 4, 1) == 0 && IslandGlass.smoothstep(2, 4, 5) == 1, "smoothstep is the ease between two values")
    check(near(IslandGlass.smoothstep(1, 0, 0.25), IslandGlass.ease(0.75)), "and runs backwards when asked to")
    check(IslandGlass.easeStopCount >= 8, "enough stops that a gradient holds the curve")
    check(near(IslandGlass.over(0, 0.3), 0.3) && near(IslandGlass.over(0.5, 0.5), 0.75) && IslandGlass.over(1, 0) == 1, "over composites")
    typealias C = IslandGlass.HSB
    func rgbNear(_ a: (r: Double, g: Double, b: Double), _ b: (Double, Double, Double)) -> Bool { near(a.r, b.0, 1e-9) && near(a.g, b.1, 1e-9) && near(a.b, b.2, 1e-9) }
    check(rgbNear(IslandGlass.rgb(C(h: 0, s: 1, b: 1)), (1, 0, 0)) && rgbNear(IslandGlass.rgb(C(h: 1.0 / 3, s: 1, b: 1)), (0, 1, 0))
          && rgbNear(IslandGlass.rgb(C(h: 2.0 / 3, s: 1, b: 1)), (0, 0, 1)) && rgbNear(IslandGlass.rgb(C(h: 0.5, s: 0, b: 0.4)), (0.4, 0.4, 0.4))
          && rgbNear(IslandGlass.rgb(C(h: 1, s: 1, b: 1)), (1, 0, 0)), "HSB to RGB")
}

print("blend")
do {
    check(IslandGlass.blackCover(progress: 0) == 1, "closed: all black")
    check(IslandGlass.blackCover(progress: 1) == 0, "open: no black")
    check(IslandGlass.blackCover(progress: -0.05) == 1, "a width overshoot past closed stays all black")
    check(IslandGlass.blackCover(progress: 1.04) == 0, "an open overshoot stays all glass")
    check(IslandGlass.blackCover(progress: IslandGlass.blendStart) == 1, "black until blendStart")
    check(IslandGlass.blackCover(progress: IslandGlass.blendEnd) == 0, "glass from blendEnd")
    check(IslandGlass.blendEnd < 0.65, "glass is done before the content starts fading in (0.65)")
    let mid = (IslandGlass.blendStart + IslandGlass.blendEnd) / 2
    check(near(IslandGlass.blackCover(progress: mid), 0.5), "half way through the blend, half black")
    var last = 2.0, monotonic = true, maxStep = 0.0
    for i in 0...1000 {
        let v = IslandGlass.blackCover(progress: Double(i) / 1000)
        if v > last + 1e-12 { monotonic = false }
        if last <= 1 { maxStep = max(maxStep, last - v) }
        last = v
    }
    check(monotonic, "black falls monotonically as the island opens")
    // Smoothstep's steepest slope is 1.5 over the blend's span; per 0.1% of
    // the open that's well under 1% — no pop.
    check(maxStep < 0.004, "no step in the blend", "max step \(maxStep)")
    check(!IslandGlass.showsGlass(progress: 0), "closed: glass not drawn")
    check(!IslandGlass.showsGlass(progress: IslandGlass.blendStart), "glass not drawn while fully covered")
    check(IslandGlass.showsGlass(progress: IslandGlass.blendStart + 0.001), "glass drawn once the black thins")
    check(IslandGlass.blackCover(progress: IslandGlass.blendStart + 0.001) > 0.999, "and it appears under all but full black")
}

print("notch glow")
do {
    let housing = CGSize(width: 185, height: 32)
    let reach = Double(IslandGlass.glowReach), k = Double(IslandGlass.glowHorizontalScale)
    func a(_ x: CGFloat, _ y: CGFloat) -> Double { IslandGlass.glowAlpha(x: x, y: y, housing: housing) }
    check(near(reach, 48) && near(k, 0.55) && near(IslandGlass.glowEase, 1.6), "mocked numbers: 48pt reach, sideways x0.55, ^1.6")
    check(a(0, 0) == 1 && a(92, 31) == 1 && a(-92.5, 32) == 1, "solid over the housing")
    check(near(a(0, 32 + 24), pow(0.5, 1.6)), "half the reach below: 0.5^1.6")
    check(a(0, 32 + 48) == 0 && a(0, 200) == 0, "clear a reach below the housing")
    let side = CGFloat(48 / 0.55)
    check(near(a(92.5 + side / 2, 10), pow(0.5, 1.6), 1e-9), "half the reach sideways (~44pt): 0.5^1.6")
    check(a(92.5 + side + 0.01, 10) == 0, "clear ~87pt to the side")
    check(a(92.5 + 30, 32) > a(0, 32 + 30), "spreads wider sideways than down")
    check(a(-140, 20) == a(140, 20), "symmetric about the camera")
    // Down the centre line and out along the housing's top row, alpha only falls.
    var mono = true, prev = 1.0
    for i in 0...400 { let v = a(0, CGFloat(i) / 4); if v > prev + 1e-12 { mono = false }; prev = v }
    prev = 1
    for i in 0...800 { let v = a(CGFloat(i) / 4, 0); if v > prev + 1e-12 { mono = false }; prev = v }
    check(mono, "falls monotonically away from the housing")
    // The corner: an ellipse, so equal alpha at (dx/0.55, 0) and (0, dy).
    check(near(a(92.5 + 20 / 0.55 * 0.6, 32 + 20 * 0.8), a(92.5, 32 + 20)), "corners fall off on an ellipse")
    let e = IslandGlass.glowExtent(housing: housing)
    check(near(Double(e.width), 185 + 2 * 48 / 0.55, 1e-9) && e.height == 80, "extent: housing + reach/0.55 each side, + reach below")
    let m = IslandGlass.glowMask(housing: housing, scale: 2)
    check(m.width == Int((e.width * 2).rounded(.up)) && m.height == 160 && m.alpha.count == m.width * m.height, "mask sized at 2x")
    check(m.alpha[0 * m.width + m.width / 2] == 255, "mask solid at the top centre")
    check(m.alpha[(m.height - 1) * m.width + m.width / 2] == 0, "mask clear at the bottom centre")
    check(m.alpha[0] == 0 && m.alpha[m.width - 1] == 0, "mask clear at the top corners (the reach's edge)")
    check(m.alpha[(m.height - 1) * m.width] == 0, "mask clear at the bottom corners")
}

print("legibility")
do {
    check(near(IslandGlass.liftedOpacity(0.5), 0.71), "0.5 → 0.71")
    check(near(IslandGlass.liftedOpacity(0.7), 0.826), "0.7 → 0.826")
    check(IslandGlass.liftedOpacity(0.7) > IslandGlass.liftedOpacity(0.5) && IslandGlass.liftedOpacity(0.5) > IslandGlass.liftedOpacity(0.4) && IslandGlass.liftedOpacity(0.7) < 0.9,
          "the tones still step down in order, short of primary")
    check(IslandGlass.liftedOpacity(1) == 1, "opaque stays opaque")
    check(IslandGlass.liftedOpacity(0.45) > 0.45, "always brighter")
    // No lightness floor on glass any more: a cover's colours there are the
    // ones on black, and what holds them off the glass is a dark edge. The
    // sum below is the reason. Glass over a white page is a mid grey
    // (about 93/255 in Prism), and a cover's deep blue is as light as that.
    func lin(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    func luminance(_ r: Double, _ g: Double, _ b: Double) -> Double { 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b) }
    func ratio(_ a: Double, _ b: Double) -> Double { (max(a, b) + 0.05) / (min(a, b) + 0.05) }
    let blue = luminance(56.0 / 255, 95.0 / 255, 242.0 / 255), glass = luminance(93.0 / 255, 93.0 / 255, 93.0 / 255)
    check(ratio(blue, glass) < 1.5, "a deep blue is all but as light as glass over a white page: its colour alone can't carry a word", "\(ratio(blue, glass))")
    // The edge is two blacks composited, the tight one over the soft one.
    let edge = IslandGlass.over(IslandGlass.tintEdge, IslandGlass.tintShade)
    check(IslandGlass.tintEdge > 0 && IslandGlass.tintEdge <= 1 && IslandGlass.tintShade > 0 && IslandGlass.tintShade <= 1, "the word's edge: two blacks, each an alpha")
    check(IslandGlass.tintEdgeRadius > 0 && IslandGlass.tintEdgeRadius < IslandGlass.tintShadeRadius, "a tight one that outlines the letters inside a soft one that settles them")
    check(IslandGlass.tintShadeRadius <= 4, "and neither a glow: within 4pt of the letters", "\(IslandGlass.tintShadeRadius)")
    // At full strength, right against a letter, the ground would be this dark.
    let ringed = luminance(93.0 / 255 * (1 - edge), 93.0 / 255 * (1 - edge), 93.0 / 255 * (1 - edge))
    check(ratio(blue, ringed) >= 2.1, "against its edge at full strength the deep blue has what the paler colour had against bare glass (2.1 to 1)", "\(ratio(blue, ringed))")
    check(IslandGlass.barEdge > 0 && IslandGlass.barEdge < 1 && IslandGlass.barEdgeWidth > 0 && IslandGlass.barEdgeWidth <= 1,
          "the bars' and the dots' edge: a dark shape under each, under a point larger all round")
}

print("prism: the shade")
do {
    // The standard panel and the tallest, each with Prism's lip under it.
    for height in [CGFloat(146) + IslandPrism.lip, 230 + IslandPrism.lip] {
        func a(_ y: CGFloat) -> Double { IslandPrism.shadeAlpha(y: y, height: height) }
        let horizon = height - IslandPrism.lip
        let top = horizon - IslandPrism.horizonFeather / 2, bottom = horizon + IslandPrism.horizonFeather / 2
        check(near(a(0), IslandPrism.edgeTint) && near(a(32), IslandPrism.edgeTint) && near(a(top), IslandPrism.edgeTint),
              "the edge tint from the top edge to the top of the horizon; any bar is PrismBand's, not the shade's (\(Int(height)))")
        check(near(a(horizon), (IslandPrism.edgeTint + IslandPrism.lipTint) / 2), "half cleared on the horizon")
        check(near(a(bottom), IslandPrism.lipTint) && near(a(height), IslandPrism.lipTint), "the lip's tint from the horizon's foot to the bottom edge")
        var falling = true
        var y: CGFloat = 0
        while y < height { if a(y + 1) > a(y) + 1e-12 { falling = false }; y += 1 }
        check(falling, "never darkens on the way down")
    }
    check(IslandPrism.lipTint < IslandPrism.edgeTint && IslandPrism.edgeTint < IslandPrism.contentAlpha, "lip lighter than the walls, walls lighter than behind the content")
    check(near(IslandPrism.contentAlpha, 1 - (1 - IslandPrism.edgeTint) * (1 - IslandPrism.scrim)), "content: the shade and the scrim composited")
    check(IslandPrism.horizonFeather / 2 <= IslandPrism.lip, "the horizon's lower half fits in the lip")
    let h = IslandPrism.horizonStops()
    check(near(h.first!.alpha, IslandPrism.edgeTint) && near(h.last!.alpha, IslandPrism.lipTint), "horizon stops: edge tint to lip tint")
}

print("prism: the black over the camera")
do {
    // This Mac's housing, and a wider, deeper one.
    for housing in [CGSize(width: 185, height: 32), CGSize(width: 204, height: 38)] {
        let tag = "(\(Int(housing.width))x\(Int(housing.height)))"
        let extra = IslandPrism.bandExtra, reach = IslandPrism.notchReach
        let half = housing.width / 2 + extra, foot = housing.height + extra
        let r = IslandPrism.notchCornerRadius + extra
        func a(_ x: CGFloat, _ y: CGFloat) -> Double { IslandPrism.notchAlpha(x: x, y: y, housing: housing) }
        // A point `d` out from the solid along the corner's diagonal.
        func corner(_ d: CGFloat) -> (x: CGFloat, y: CGFloat) {
            let k = (r + d) * CGFloat(0.5).squareRoot()
            return (half - r + k, foot - r + k)
        }
        check(a(0, 0) == 1 && a(0, housing.height) == 1 && a(housing.width / 2, 0) == 1 && a(-housing.width / 2, housing.height - r) == 1,
              "solid over the housing \(tag)")
        // The hardware's own outline — its sides, its foot, and round a
        // corner of `notchCornerRadius` — grown by `bandExtra`, less a hair.
        var covered = true
        let grown = extra - 0.01
        for i in 0...40 {
            let t = CGFloat(i) / 40
            if a(housing.width / 2 + grown, t * (housing.height - IslandPrism.notchCornerRadius)) != 1 { covered = false }
            if a(-(housing.width / 2 + grown), t * (housing.height - IslandPrism.notchCornerRadius)) != 1 { covered = false }
            if a((2 * t - 1) * (housing.width / 2 - IslandPrism.notchCornerRadius), housing.height + grown) != 1 { covered = false }
            let angle = Double(t) * Double.pi / 2
            let cx = housing.width / 2 - IslandPrism.notchCornerRadius, cy = housing.height - IslandPrism.notchCornerRadius
            let rr = IslandPrism.notchCornerRadius + grown
            if a(cx + rr * CGFloat(cos(angle)), cy + rr * CGFloat(sin(angle))) != 1 { covered = false }
            if a(-(cx + rr * CGFloat(cos(angle))), cy + rr * CGFloat(sin(angle))) != 1 { covered = false }
        }
        check(covered && extra >= 3, "and solid \(extra)pt past its sides, its foot and round its corners: no glass against the hardware")
        // A sharper corner than the guess is still inside the solid, or all but.
        check(a(housing.width / 2, housing.height) > 0.995, "even a square corner of the housing is under black within half a percent of solid", "\(a(housing.width / 2, housing.height))")
        check(a(half + 1, 10) < 1 && a(0, foot + 1) < 1 && a(corner(1).x, corner(1).y) < 1, "past that it begins to let go")
        check(a(0, foot + reach) == 0 && a(half + reach, 10) == 0 && a(corner(reach).x, corner(reach).y) == 0 && a(0, 400) == 0 && a(400, 0) == 0,
              "and has let go \(reach)pt out: below, beside, round the corner")
        var even = true
        for d in stride(from: CGFloat(1), to: reach, by: 1.5) {
            let below = a(0, foot + d)
            if !near(a(half + d, 10), below) || !near(a(-(half + d), 0), below) || !near(a(corner(d).x, corner(d).y), below, 1e-9) { even = false }
        }
        check(even, "the same distance out is the same black all the way round: the housing's outline, grown")
        check(a(-140, 20) == a(140, 20) && a(-100, 50) == a(100, 50), "symmetric about the camera")
        // Down the centre line, out along the top row and out through a
        // corner, the black only falls, and by no more than a trace a step.
        var mono = true, maxStep = 0.0
        for path in 0..<3 {
            var prev = 1.0
            for i in 0...Int((reach + 8) * 4) {
                let d = CGFloat(i) / 4
                let v = path == 0 ? a(0, foot + d) : path == 1 ? a(half + d, 0) : a(corner(d).x, corner(d).y)
                if v > prev + 1e-12 { mono = false }
                maxStep = max(maxStep, prev - v)
                prev = v
            }
        }
        check(mono, "falls monotonically away from the housing")
        check(maxStep < 0.03, "with no step in it", "max step \(maxStep) per quarter point")
        check(a(0, foot + 0.5) > 0.995 && a(0, foot + reach - 0.5) < 0.005, "and no edge where it leaves the solid or where it ends",
              "\(a(0, foot + 0.5)) \(a(0, foot + reach - 0.5))")
        check(near(a(0, foot + reach / 2), pow(0.5, IslandPrism.notchFalloff)), "half the reach out: 0.5^falloff")
        // "A little bit": the dark is close in, and the panel beside the
        // camera is glass. (The open panel is 520pt wide.)
        check(a(0, foot + reach / 2) <= 0.35, "most of the black is gone half the reach out", "\(a(0, foot + reach / 2))")
        let e = IslandPrism.notchExtent(housing: housing)
        check(near(Double(e.width), Double(housing.width + 2 * (extra + reach))) && near(Double(e.height), Double(housing.height + extra + reach)),
              "extent: the housing, the solid past it and the reach, each side and below")
        check((520 - e.width) / 2 >= 100, "camera alone: at least 100pt of the band either side of it has none of it", "\((520 - e.width) / 2)")
        check(e.height - housing.height <= 40, "and it ends within 40pt of the housing's foot", "\(e.height - housing.height)")
        let m = IslandPrism.notchMask(housing: housing, scale: 2)
        check(m.width == Int((e.width * 2).rounded(.up)) && m.height == Int((e.height * 2).rounded(.up)) && m.alpha.count == m.width * m.height, "mask sized at 2x")
        check(m.alpha[0 * m.width + m.width / 2] == 255 && m.alpha[Int(housing.height * 2) * m.width + m.width / 2] == 255, "mask solid at the top centre and at the housing's foot")
        check(m.alpha[(m.height - 1) * m.width + m.width / 2] == 0, "mask clear at the bottom centre")
        check(m.alpha[0] == 0 && m.alpha[m.width - 1] == 0, "mask clear at the top corners (the reach's edge)")
        check(m.alpha[(m.height - 1) * m.width] == 0 && m.alpha[m.height * m.width - 1] == 0, "mask clear at the bottom corners")
    }
    // No housing worth the name: nothing to divide by, nothing negative.
    let none = IslandPrism.notchAlpha(x: 0, y: 0, housing: .zero)
    check(none == 1 && IslandPrism.notchAlpha(x: 200, y: 200, housing: .zero) == 0, "a zero housing is a dot of black at the top centre, not a fault")
}

print("prism: the bar across the band")
do {
    let housing = CGSize(width: 185, height: 32)
    // Where the faces' first rows are on this Mac (measured in captures):
    // the crumb and the Claude status between 11.5 and 19.5pt down, the
    // first line under them from 37pt.
    let crumbFoot: CGFloat = 19.5, firstLine: CGFloat = 37
    check(IslandPrism.BandStyle.allCases.count == 6, "camera, eased, notched, tinted, meniscus, spread")
    check(IslandPrism.bandLook == nil || IslandPrism.bandStyle != .camera && IslandPrism.bandStyle != .spread, "a look only for a bar")
    let looks: [(String, IslandPrism.BandLook)] = [("eased", IslandPrism.easedLook), ("notched", IslandPrism.notchedLook),
                                                   ("tinted", IslandPrism.tintedLook), ("meniscus", IslandPrism.meniscusLook)]
    check(near(IslandPrism.smootherstep(0), 0) && near(IslandPrism.smootherstep(1), 1) && near(IslandPrism.smootherstep(0.5), 0.5) && near(IslandPrism.smootherstep(-1), 0) && near(IslandPrism.smootherstep(2), 1),
          "smootherstep: 0 to 1, half way at half, clamped")
    for (name, look) in looks {
        func a(_ x: CGFloat, _ y: CGFloat) -> Double {
            IslandPrism.bandAlpha(distance: IslandPrism.bandDistance(x: x, y: y, housing: housing, look: look), look: look)
        }
        func bar(_ y: CGFloat) -> Double { IslandPrism.bandAlpha(distance: y - look.depth, look: look) }
        // The crumb row, wall to wall beside the camera, on solid black.
        var crumb = true
        for x in stride(from: CGFloat(-240), through: 240, by: 4) { for y in stride(from: CGFloat(0), through: crumbFoot, by: 0.5) where a(x, y) < 0.999 { crumb = false } }
        check(crumb, "\(name): solid from wall to wall through the crumb row")
        // The camera: solid over the housing and bandExtra round it.
        // Wherever the camera's own black is solid (the housing grown by
        // bandExtra, its corners rounded), so is this.
        var camera = true
        for x in stride(from: CGFloat(-110), through: 110, by: 0.5) { for y in stride(from: CGFloat(0), through: 40, by: 0.5)
            where IslandPrism.notchDistance(x: x, y: y, housing: housing) <= 0 && a(x, y) != 1 { camera = false } }
        check(camera, "\(name): the camera housing and \(IslandPrism.bandExtra)pt round it solid")
        // Together never lighter than either alone.
        var union = true
        for x in stride(from: CGFloat(-200), through: 200, by: 5) { for y in stride(from: CGFloat(0), through: 80, by: 2.5) {
            if a(x, y) + 1e-12 < max(bar(y), IslandPrism.notchAlpha(x: x, y: y, housing: housing) > 0.999 ? 1 : 0) { union = false }
        } }
        check(union, "\(name): the bar and the camera together are at least as black as either")
        // The fade: monotone, no jump, no edge where it starts or ends.
        var mono = true, maxStep = 0.0, prev = 1.0
        for i in 0...Int((look.reach + 4) * 4) {
            let v = bar(look.depth + CGFloat(i) / 4)
            if v > prev + 1e-12 { mono = false }
            maxStep = max(maxStep, prev - v); prev = v
        }
        check(mono && maxStep < 0.1, "\(name): the foot only falls, by under a tenth a quarter point", "max step \(maxStep)")
        check(bar(look.depth + 0.5) > 0.99 && bar(look.depth + look.reach - 0.5) < 0.01 && bar(IslandPrism.bandHeight(look)) == 0,
              "\(name): no edge where the fade leaves the solid or where it ends")
        // Far from the camera the bar alone; the camera's piece adds nothing at its edges.
        let far = housing.width / 2 + IslandPrism.bandExtra + look.reach + look.fillet + 1
        check(IslandPrism.bandDistance(x: far, y: look.depth + 3, housing: housing, look: look) == look.depth + 3 - look.depth,
              "\(name): past the fillet the bar is its own")
        let m = IslandPrism.bandNotchMask(housing: housing, look: look, scale: 2)
        var edges = true
        for row in 0..<m.height { if m.alpha[row * m.width] > 1 || m.alpha[row * m.width + m.width - 1] > 1 { edges = false } }
        for col in 0..<m.width where m.alpha[(m.height - 1) * m.width + col] > 1 { edges = false }
        check(edges, "\(name): the camera's piece is clear at its sides and foot, so it meets the bar with no seam")
        // Bar column and camera piece composited make the union, to the byte.
        let c = IslandPrism.bandColumn(look: look, scale: 2)
        var exact = true
        let ext = IslandPrism.bandNotchExtent(housing: housing, look: look)
        for row in stride(from: 0, to: m.height, by: 3) { for col in stride(from: 0, to: m.width, by: 7) {
            let y = (CGFloat(row) + 0.5) / 2, x = (CGFloat(col) + 0.5) / 2 - ext.width / 2
            let b = row < c.height ? Double(c.alpha[row]) / 255 : 0
            let together = IslandGlass.over(b, Double(m.alpha[row * m.width + col]) / 255)
            if abs(together - a(x, y)) > 2.5 / 255 { exact = false }
        } }
        check(exact, "\(name): bar and camera piece composite to the shape, within a byte or two")
        // The ends: the same as the bar where they join it, the flare as the wall.
        let end = IslandPrism.bandEnd(look: look, wallInset: IslandMotion.openCorners.top, scale: 2)
        var join = true, flare = true
        for row in 0..<min(end.height, c.height) {
            if abs(Int(end.alpha[row * end.width + end.width - 1]) - Int(c.alpha[row])) > 3 { join = false }
            let y = (CGFloat(row) + 0.5) / 2
            let wallTop = IslandPrism.bandAlpha(distance: IslandPrism.bandWallDistance(u: 0, y: y, look: look), look: look)
            if abs(Double(end.alpha[row * end.width]) / 255 - wallTop) > 1 / 255 { flare = false }
        }
        check(join && end.height == c.height, "\(name): the ends meet the stretched column with no seam")
        check(flare, "\(name): the flare beside each wall is as black as the wall's top")
        if look.wallRadius > 0 {
            check(IslandPrism.bandWallDistance(u: 0, y: look.depth, look: look) > 0, "\(name): the foot turns up into the wall")
        }
        check(IslandPrism.bandWallDistance(u: look.wallRadius, y: 30, look: look) == 30 - look.depth, "\(name): a wall radius in, the bar is its own")
    }
    if let look = IslandPrism.bandLook {
        check(IslandPrism.bandHeight(look) <= firstLine, "the bar chosen has let go beside the camera by where the faces' first line begins",
              "\(IslandPrism.bandHeight(look)) > \(firstLine)")
    }
}

print("prism: the camera's black, spread")
do {
    let housing = CGSize(width: 185, height: 32)
    func a(_ x: CGFloat, _ y: CGFloat) -> Double { IslandPrism.spreadAlpha(x: x, y: y, housing: housing) }
    // The hardware's outline: its sides, its foot a point down, and round
    // a corner of notchCornerRadius.
    var solid = true, corner = 1.0
    let r = IslandPrism.notchCornerRadius
    for i in 0...40 {
        let t = CGFloat(i) / 40
        if a((2 * t - 1) * housing.width / 2, t * (housing.height - r)) != 1 { solid = false }
        if a((2 * t - 1) * (housing.width / 2 - r), housing.height + IslandPrism.spreadFoot - 0.01) != 1 { solid = false }
        let angle = Double(t) * Double.pi / 2
        corner = min(corner, a(housing.width / 2 - r + r * CGFloat(cos(angle)), housing.height - r + r * CGFloat(sin(angle))))
    }
    check(solid, "solid over the housing's sides and a point below its foot")
    check(corner > 0.9999, "and round its corners, to a ten-thousandth", "\(corner)")
    check(a(housing.width / 2 + 1, 10) > 0.995 && a(0, housing.height + IslandPrism.spreadFoot + 1) > 0.97, "and all but solid a point past it (0.97 down: the quicker let-go of 2026-11-13 over the 30pt reach)", "\(a(housing.width / 2 + 1, 10)) \(a(0, housing.height + IslandPrism.spreadFoot + 1))")
    check(IslandPrism.spreadAcross > IslandPrism.spreadDown, "spreads further along the top than down")
    check(a(housing.width / 2 + IslandPrism.spreadSide + IslandPrism.spreadAcross, 10) == 0 && a(0, housing.height + IslandPrism.spreadFoot + IslandPrism.spreadDown) == 0,
          "let go at its reach: beside and below")
    var mono = true, prevB = 1.0, prevS = 1.0
    for i in 0...400 {
        let d = CGFloat(i) / 4
        let b = a(0, housing.height + IslandPrism.spreadFoot + d), s = a(housing.width / 2 + d, 8)
        if b > prevB + 1e-12 || s > prevS + 1e-12 { mono = false }
        prevB = b; prevS = s
    }
    check(mono, "falls monotonically, below and beside")
    check(a(housing.width / 2 + IslandPrism.spreadAcross / 2, 8) < 0.5, "half way out it is under half black: a gradient, not a bigger shape", "\(a(housing.width / 2 + IslandPrism.spreadAcross / 2, 8))")
    check(a(-150, 20) == a(150, 20), "symmetric about the camera")
    let m = IslandPrism.spreadMask(housing: housing, scale: 2)
    var edges = true
    for row in 0..<m.height where m.alpha[row * m.width] > 0 || m.alpha[row * m.width + m.width - 1] > 0 { edges = false }
    for col in 0..<m.width where m.alpha[(m.height - 1) * m.width + col] > 0 { edges = false }
    check(edges, "mask clear at its sides and foot")
    let e = IslandPrism.spreadExtent(housing: housing)
    check(e.width <= 520 - 2 * IslandMotion.openCorners.top, "inside the open panel's walls", "\(e.width)")
}

/// Whether the line (or the crystal's sheets) goes below its rest as well as above.
let ribbonSigned = IslandPrism.ribbonStyle != .light || IslandPrism.ribbonShape == .snake

// The ribbon's shape and style are one choice each (`IslandPrism.ribbonShape`,
// `ribbonStyle`); these are what that choice makes the resting and full
// half-heights and the full lift.
let ribbonRest: Double = {
    switch IslandPrism.ribbonStyle {
    case .light: return IslandPrism.restSpread
    case .crystal: return IslandPrism.crystalRest
    case .twist: return IslandPrism.twistFull
    // The wave isn't drawn from the profile (PrismWave.swift); what the
    // profile's own numbers come to is then the light's.
    case .wave: return IslandPrism.restSpread
    }
}()
let ribbonFull: Double = {
    if IslandPrism.ribbonStyle == .twist { return IslandPrism.twistFull }
    if IslandPrism.ribbonStyle == .crystal { return IslandPrism.mirroredSpread }
    switch IslandPrism.ribbonShape {
    case .up: return IslandPrism.fullSpread
    case .mirrored: return IslandPrism.mirroredSpread
    case .snake: return IslandPrism.snakeSpread
    }
}()
let ribbonLift: Double = {
    // The twist doesn't lift: its "lift" is what shows of it, up to its
    // full width. The crystal doesn't lift either; its sheets sway by
    // this much instead.
    if IslandPrism.ribbonStyle == .twist { return IslandPrism.twistFull }
    if IslandPrism.ribbonStyle == .crystal { return IslandPrism.crystalSway }
    switch IslandPrism.ribbonShape {
    case .up: return IslandPrism.fullLift
    case .mirrored: return 0
    case .snake: return IslandPrism.snakeLift
    }
}()

print("prism: the lens's shape")
do {
    check(IslandPrism.lip > 0 && IslandPrism.bottomCornerRadius > IslandMotion.openCorners.bottom, "a lip, and rounder than the other modes")
    do {
        // The content's own corner stands its bottom inset (8) above the lip
        // and its side inset (10) inside the side lip. It has to be inside
        // the panel's rounded corner.
        let r = IslandPrism.bottomCornerRadius
        let dx = max(0, r - (10 + IslandPrism.sideLip)), dy = max(0, r - (8 + IslandPrism.lip))
        check(dx * dx + dy * dy <= r * r * 0.25, "the bottom corners turn well clear of the content's corner", "\(dx) \(dy) of \(r)")
        check(IslandPrism.showsRibbon || IslandPrism.lip == IslandPrism.sideLip, "without the ribbon, the lip is the walls' border carried round")
    }
    check(IslandPrism.topRise >= 16, "on the notch the lens's top edge is put well above the screen's: its rim was still in view at 6pt, gone at 16", "\(IslandPrism.topRise)")
    check(IslandPrism.sideLip > 0 && IslandPrism.rim > IslandPrism.rimFeather, "a border of clear glass down each wall, wider than its soft edge")
    // The content starts 22pt inside the frame in every mode, plus the side lip here; the walls stand 12pt in.
    check(IslandPrism.rim + IslandPrism.rimFeather <= 22 + IslandPrism.sideLip - IslandMotion.openCorners.top + 2,
          "the frost is full by where the content starts", "\(IslandPrism.rim + IslandPrism.rimFeather)")
    if IslandPrism.showsRibbon {
        check(IslandPrism.ribbonCentre > 0 && IslandPrism.ribbonCentre < IslandPrism.lip, "the ribbon's resting line is in the lip")
    }
    // (The twist's geometry is its own: see "prism: the twist".)
    if IslandPrism.ribbonStyle != .twist {
        check(IslandPrism.ribbonCentre - ribbonRest > 0, "the resting ribbon stays above the bottom edge")
        check(IslandPrism.ribbonCentre - ribbonLift - ribbonFull > 0 || IslandPrism.ribbonShape == .up, "a full crest's lower edge is above the bottom edge, whichever way it goes")
        check(IslandPrism.ribbonCentre + (IslandPrism.ribbonShape == .up ? ribbonLift : 0) - ribbonFull > 0, "and a rising crest's too")
        check(IslandPrism.ribbonCentre + ribbonLift + ribbonFull < IslandPrism.ribbonStrip, "its upper edge is inside the strip")
        check(ribbonFull > ribbonRest * 2, "a full band is plainly more than rest")
    }
}

print("prism: the ribbon's profile")
do {
    let silent = [Double](repeating: 0, count: 6)
    let full = [Double](repeating: 1, count: 6)
    check(IslandPrism.mirrored(0.5) == 0 && IslandPrism.mirrored(0) == 1 && IslandPrism.mirrored(1) == 1, "mirrored: 0 at the centre, 1 at the tips")
    check(near(IslandPrism.taper(0.5), 1) && IslandPrism.taper(0) == 0 && IslandPrism.taper(1) == 0, "taper: full at the centre, nothing at the tips")
    check(near(IslandPrism.spread(at: 0.5, bands: silent), ribbonRest) && IslandPrism.lift(at: 0.5, bands: silent) == 0,
          "silent: the resting ribbon on the resting line")
    check(near(IslandPrism.spread(at: 0.5, bands: full), ribbonFull), "full: its full half-height at the centre")
    let centreLift = IslandPrism.lift(at: 0.5, bands: full)
    check(ribbonSigned && ribbonLift > 0 ? (centreLift > ribbonLift * 0.8 && centreLift <= ribbonLift) : near(centreLift, ribbonLift),
          "full: lifted (or swayed) its full amount at the centre", "\(centreLift)")
    check(near(IslandPrism.spread(at: 0.5, bands: []), ribbonRest), "no bands is silence")
    // The snake's crests go up and down in turn; the others never go below the line.
    check(near(IslandPrism.signedLevel(at: 0.5, bands: [1, 0, 0, 0, 0, 0]), 1), "signed: the centre band counts up")
    check(IslandPrism.signedLevel(at: 0.5 + IslandPrism.bandSpan / 2 / 5, bands: [0, 1, 0, 0, 0, 0]) < -0.9, "signed: the next band counts down")
    check(IslandPrism.spread(at: 0, bands: full) == 0 && IslandPrism.lift(at: 1, bands: full) == 0 && IslandPrism.glow(at: 1, bands: full) == 0,
          "nothing at the tips, however loud")
    // Bass at the centre, treble toward the tips, each a crest of its own.
    let bass = [1.0, 0, 0, 0, 0, 0], treble = [0.0, 0, 0, 0, 0, 1]
    let trebleAt = 0.5 + IslandPrism.bandSpan / 2
    check(near(IslandPrism.level(at: 0.5, bands: bass), 1) && IslandPrism.level(at: trebleAt, bands: bass) < 1e-6, "bass crests at the centre")
    check(IslandPrism.level(at: 0.5, bands: treble) < 1e-6 && near(IslandPrism.level(at: trebleAt, bands: treble), 1), "treble crests bandSpan of the way out")
    check(IslandPrism.taper(trebleAt) > 0.6, "where the streak is still most of its strength", "\(IslandPrism.taper(trebleAt))")
    // Neighbouring bands at the same level are two crests with a dip between.
    let spacing = IslandPrism.bandSpan / 2 / 5
    let pair = [0.0, 1, 1, 0, 0, 0]
    let dip = IslandPrism.level(at: 0.5 + 1.5 * spacing, bands: pair)
    check(dip > 0.4 && dip < 0.85, "a dip between two equal crests, not a gap and not a plateau", "\(dip)")
    check(IslandPrism.level(at: 0.5 + spacing, bands: [0, 1, 0, 0, 0, 0]) > IslandPrism.level(at: 0.5 + 2 * spacing, bands: [0, 1, 0, 0, 0, 0]) * 5,
          "a crest is its own band's: next to nothing a band away")
    check(IslandPrism.level(at: 0.5, bands: [0.25, 0, 0, 0, 0, 0]) > 0.25, "quiet bands are lifted")
    var mirrored = true, bounded = true, smooth = true
    let mixed = [0.9, 0.2, 0.7, 0.1, 0.6, 0.3]
    var last = IslandPrism.lift(at: 0, bands: mixed)
    var lastSpread = IslandPrism.spread(at: 0, bands: mixed)
    for k in 0...800 {
        let u = Double(k) / 800
        let s = IslandPrism.spread(at: u, bands: mixed), g = IslandPrism.glow(at: u, bands: mixed), l = IslandPrism.lift(at: u, bands: mixed)
        if !near(l, IslandPrism.lift(at: 1 - u, bands: mixed), 1e-9) || !near(s, IslandPrism.spread(at: 1 - u, bands: mixed), 1e-9) { mirrored = false }
        if s < 0 || s > ribbonFull + 1e-9 || g < 0 || g > 1 + 1e-9 || abs(l) > ribbonLift + 1e-9 { bounded = false }
        if !ribbonSigned, l < 0 { bounded = false }
        if abs(l - last) > 0.5 || abs(s - lastSpread) > 0.5 { smooth = false }
        last = l
        lastSpread = s
    }
    check(mirrored, "the line and its thickness are mirror images about the centre")
    check(bounded, "lift within the full lift, half-height within the full one, glow within 0...1")
    check(smooth, "no step in the line or its thickness (under half a point between samples 1/800 apart)")
    check(near(IslandPrism.level(at: 0.5, bands: [2, -1]), 1), "levels clamp to 0...1")
    let p = IslandPrism.profile(bands: mixed)
    let n = IslandPrism.ribbonColumns
    check(p.lift.count == n && p.spread.count == n && p.glow.count == n, "profile: one sample per column")
    check(near(Double(p.spread[0]), 0) && near(Double(p.lift[n - 1]), 0), "profile ends at the tips")
    check(near(IslandPrism.glow(at: 0.5, bands: silent), IslandPrism.restGlow) && near(IslandPrism.glow(at: 0.5, bands: full), 1), "glow: resting when silent, full when loud")
    // Columns enough that the shader's straight lines between them hold a crest's shape.
    check(Double(n) / 2 * spacing / (IslandPrism.crestWidth * spacing) >= 0 && IslandPrism.crestWidth * spacing * Double(n - 1) >= 3,
          "at least three columns across a crest's width", "\(IslandPrism.crestWidth * spacing * Double(n - 1))")
}

print("prism: the twist")
do {
    let silent = [Double](repeating: 0, count: 6), full = [Double](repeating: 1, count: 6)
    // Three lobes from six bands: the louder of each pair.
    check(IslandPrism.twistGroups([0.2, 0.9, 0.1, 0.3, 0.7, 0.4]) == [0.9, 0.3, 0.7], "bass, mids, treble: the louder band of each pair")
    check(IslandPrism.twistGroups([]) == [0, 0, 0] && IslandPrism.twistGroups([0.5]) == [0.5, 0, 0] && IslandPrism.twistGroups([2, -1]) == [1, 0, 0],
          "missing bands are silence; levels clamp")
    // Where each lobe sits, and which face it shows.
    let mid = 0.5 + IslandPrism.bandSpan / 4, out = 0.5 + IslandPrism.bandSpan / 2
    func facing(_ u: Double, _ b: [Double]) -> Double { IslandPrism.twistFacing(at: u, bands: b) }
    check(near(facing(0.5, [1, 0, 0, 0, 0, 0]), 1) && facing(mid, [1, 0, 0, 0, 0, 0]) < 0.1, "bass turns the centre lobe to face you, and little else")
    check(facing(mid, [0, 0, 1, 0, 0, 0]) < -0.95 && abs(facing(0.5, [0, 0, 1, 0, 0, 0])) < 0.1, "mids turn the lobes either side, on the far face")
    check(facing(out, [0, 0, 0, 0, 0, 1]) > 0.95, "treble turns the outer lobes, on the near face again")
    check(near(facing(0.5 - IslandPrism.bandSpan / 4, [0, 0, 1, 0, 0, 0]), facing(mid, [0, 0, 1, 0, 0, 0]), 1e-12), "the same either side of the centre")
    // Silent: edge-on everywhere. Nothing shows but the resting sliver.
    check((0...100).allSatisfy { facing(Double($0) / 100, silent) == 0 }, "silent: edge-on everywhere")
    check((0...100).allSatisfy { IslandPrism.twistShown(at: Double($0) / 100, bands: silent) == 0 }, "and nothing of its face shows: the shader's sliver is all there is")
    // A lobe stands as tall as its part of the music is loud.
    let half = abs(IslandPrism.twistShown(at: 0.5, bands: [0.5, 0, 0, 0, 0, 0])), whole = abs(IslandPrism.twistShown(at: 0.5, bands: full))
    check(whole > IslandPrism.twistFull * 0.9 && whole <= IslandPrism.twistFull, "a full bass lobe stands all but the ribbon's whole width", "\(whole)")
    check(half > whole * 0.5 && half < whole * 0.75, "half as loud stands lower, lifted a little as every level is", "\(half)")
    var rising = true
    var last = 0.0
    for k in 1...20 { let s = abs(IslandPrism.twistShown(at: 0.5, bands: [Double(k) / 20, 0, 0, 0, 0, 0])); if s < last - 1e-12 { rising = false }; last = s }
    check(rising, "louder never stands lower")
    // Neighbours at the same level cross half way between them.
    let between = 0.5 + IslandPrism.bandSpan / 8
    check(abs(facing(between, full)) < 0.03, "two neighbouring lobes at the same level turn edge-on half way between them", "\(facing(between, full))")
    check(facing(0.5, full) > 0.9 && facing(mid, full) < -0.75 && facing(out, full) > 0.45, "all three lobes show at full, on alternate faces")
    // One lobe moving doesn't move the others: a kick is the centre's alone.
    check(near(facing(out, [1, 1, 0, 0, 0, 0.4]), facing(out, [0, 0, 0, 0, 0, 0.4]), 0.01), "the bass doesn't reach the treble's lobe")
    // The drawing's inputs.
    // What the profile hands the shader: the twist's own, while the twist is the style drawn.
    if IslandPrism.ribbonStyle == .twist {
        check(near(IslandPrism.spread(at: 0.5, bands: silent), IslandPrism.twistFull) && near(IslandPrism.spread(at: 0.5, bands: full), IslandPrism.twistFull),
              "spread is the ribbon's own width, whatever the music")
        check(near(IslandPrism.lift(at: 0.5, bands: full), IslandPrism.twistShown(at: 0.5, bands: full)), "lift is what shows of it")
    }
    var smooth = true
    var prev = IslandPrism.twistFacing(at: 0, bands: [0.9, 0.2, 0.7, 0.1, 0.6, 0.3])
    for k in 1...800 { let f = IslandPrism.twistFacing(at: Double(k) / 800, bands: [0.9, 0.2, 0.7, 0.1, 0.6, 0.3]); if abs(f - prev) > 0.03 { smooth = false }; prev = f }
    check(smooth, "the turn has no step in it along the ribbon")
    check(IslandPrism.twistFull + 0.2 * IslandPrism.twistFull < Double(IslandPrism.ribbonCentre), "a full lobe, riding above or below the axis, stays above the bottom edge")
}

print("prism: the twist, travelling")
do {
    typealias Trace = IslandPrism.TwistTrace
    let dt = 1.0 / 40
    // Silence writes nothing.
    var quiet = Trace()
    check((0..<200).allSatisfy { _ in quiet.step(0, dt: dt) == 0 }, "silence writes a line")
    // A beat: bursts with dips between them. Each burst is a lobe, and
    // successive lobes are on alternate faces, with nothing between.
    var beat = Trace()
    var written: [Double] = []
    for k in 0..<400 {
        let t = Double(k) * dt
        let phase = t.truncatingRemainder(dividingBy: 0.5)
        written.append(beat.step(0.15 + 0.8 * exp(-phase / 0.11), dt: dt))
    }
    let late = Array(written[120...])
    var lobes: [(face: Double, peak: Double)] = []
    var current: (face: Double, peak: Double)? = nil
    var jumped = false
    for (a, b) in zip(late, late.dropFirst()) where a * b < 0 { _ = (a, b); jumped = true }
    for v in late {
        if v == 0 { if let c = current { lobes.append(c); current = nil } }
        else if let c = current { current = (c.face, max(c.peak, abs(v))) }
        else { current = (v > 0 ? 1 : -1, abs(v)) }
    }
    check(lobes.count >= 10, "a beat every half second writes a lobe for each", "\(lobes.count)")
    check(zip(lobes, lobes.dropFirst()).allSatisfy { $0.face == -$1.face }, "each lobe on the other face from the last")
    check(!jumped, "the ribbon passes through edge-on between them: it never jumps face to face")
    check(lobes.allSatisfy { $0.peak > 0.6 }, "a strong beat fills most of the ribbon", "\(lobes.map(\.peak).min() ?? 0)")
    check(late.allSatisfy { abs($0) <= 1 }, "never more than full face-on")
    // Music that never drops to silence still dips to edge-on between beats.
    var dense = Trace()
    var crossings = 0, was = 0.0
    for k in 0..<400 {
        let t = Double(k) * dt
        let v = dense.step(0.5 + 0.4 * exp(-t.truncatingRemainder(dividingBy: 0.5) / 0.1), dt: dt)
        if k > 120, v == 0, was != 0 { crossings += 1 }
        was = v
    }
    check(crossings >= 8, "over a loud bed the ribbon still turns edge-on between beats", "\(crossings)")
    // A held note stands up, then thins away: a waveform shows change.
    var held = Trace()
    var first = 0.0, last = 0.0
    for k in 0..<600 { last = held.step(0.7, dt: dt); if k == 0 { first = last } }
    check(abs(first) > 0.8 && abs(last) < 0.02, "a held note stands up at once and thins to a line", "\(first) \(last)")
    // Louder is taller.
    func peak(_ level: Double) -> Double { var tr = Trace(); return (0..<8).map { _ in abs(tr.step(level, dt: dt)) }.max()! }
    check(peak(0.9) > peak(0.5) && peak(0.5) > peak(0.2) && peak(0.2) > 0, "a louder burst stands taller")
    // A layer each for bass, mids and treble, moved only by its own part.
    check(IslandPrism.twistLayerEnergy([]) == [0, 0, 0], "no sound, nothing in any layer")
    let kick = IslandPrism.twistLayerEnergy([0.9, 0.4, 0, 0, 0, 0])
    check(kick[0] > 0.9 && kick[1] == 0 && kick[2] == 0, "a kick is the bass layer's alone")
    let hat = IslandPrism.twistLayerEnergy([0, 0, 0, 0, 0.2, 0.7])
    check(hat[0] == 0 && hat[1] == 0 && hat[2] > 0.7, "a hat is the treble layer's alone")
    check(IslandPrism.twistLayerEnergy([1, 1, 1, 1, 1, 1]) == [1, 1, 1], "everything at full fills all three")
    // Standing still, the three layers are the three lobes, and sum to the whole.
    for u in [0.5, 0.62, 0.8, 0.3] {
        let layers = IslandPrism.twistLayers(at: u, bands: [0.9, 0.2, 0.7, 0.1, 0.6, 0.3])
        check(layers.count == 3 && near(layers.reduce(0, +), IslandPrism.twistFacing(at: u, bands: [0.9, 0.2, 0.7, 0.1, 0.6, 0.3]), 1e-9), "three layers that sum to the standing ribbon at \(u)")
    }
    check(IslandPrism.twistLayers(at: 0.5, bands: [1, 0, 0, 0, 0, 0])[0] > 0.99 && IslandPrism.twistLayers(at: 0.5, bands: [0, 0, 1, 0, 0, 0])[0] == 0, "the bass layer's lobe is the bass's")
    // A travelling lobe comes in at the right, and shrinks away before the left end.
    func env(_ u: Double) -> Double { IslandPrism.travelEnvelope(u) }
    check(env(1) == 0, "nothing at the right tip, where a burst comes in")
    check(near(env(1 - IslandPrism.travelEnter), 1), "full a little way in")
    check(env(IslandPrism.travelGone) == 0 && env(0) == 0 && env(IslandPrism.travelGone / 2) == 0, "gone before the left end")
    var shrinking = true
    var u = 1 - IslandPrism.travelEnter
    while u > 0 { if env(u - 0.01) > env(u) + 1e-12 { shrinking = false }; u -= 0.01 }
    check(shrinking, "and shrinking all the way across, never growing again")
    check(env(0.5) > 0.3 && env(0.5) < 0.7, "about half its size half way across", "\(env(0.5))")
    check(env(0.25) < 0.3, "small by three quarters of the way", "\(env(0.25))")
    // The profile the drawing takes.
    let n = IslandPrism.ribbonColumns
    var bass = [Double](repeating: 0, count: n), treble = [Double](repeating: 0, count: n)
    bass[n / 2] = 1; treble[n / 4] = -0.5
    let p = IslandPrism.profile(layers: [bass, [], treble], travelling: true)
    check(p.layers.count == 3 && p.layers.allSatisfy { $0.count == n } && p.width.count == n, "three layers and a width, a sample per column")
    check(p.layers[0][n / 2] == 1 && p.layers[2][n / 4] == -0.5 && p.layers[1].allSatisfy { $0 == 0 }, "each layer's turn as written, signed; a missing layer is edge-on")
    check(near(Double(p.width[n / 2]), IslandPrism.twistFull * env(Double(n / 2) / Double(n - 1)), 1e-4), "travelling, the width is the envelope's")
    check(p.width[0] == 0 && p.width[n - 1] == 0, "nothing at either end")
    let standing = IslandPrism.profile(layers: [bass, [], treble], travelling: false)
    check(near(Double(standing.width[n / 2]), IslandPrism.twistWidth(at: Double(n / 2) / Double(n - 1)), 1e-4), "standing, the width is the ribbon's taper")
    check(IslandPrism.profile(layers: [[3, -3]], travelling: false).layers[0][0] == 1 && IslandPrism.profile(layers: [[3, -3]], travelling: false).layers[0][1] == -1, "turns clamp to face-on")
    // The layers cross at different speeds, the treble quickest.
    let windows = IslandPrism.twistWindows
    check(windows.count == 3 && windows[0] > windows[1] && windows[1] > windows[2], "bass slowest, treble quickest")
    check(windows.allSatisfy { $0 > 1.2 && $0 < 4 }, "each takes a couple of seconds to cross")
}

print("prism: the wave")
do {
    typealias W = PrismWave
    let silence = W.Features()
    let loud = W.Features(level: 0.8, bands: [0.8, 0.5, 0.3])

    // Reading the bands.
    check(W.groups([0.2, 0.9, 0.1, 0.3, 0.6, 0.4]) == [0.9, 0.3, 0.6], "bass, mids, treble: each the louder of a pair")
    check(W.groups([0.5]) == [0.5, 0, 0] && W.groups([]) == [0, 0, 0], "fewer bands fold the same way")
    var shaper = W.Shaper()
    let hit = shaper.features(of: [1, 1, 0, 0, 0, 0], dt: 1.0 / 60)
    var held = hit
    for _ in 0..<240 { held = shaper.features(of: [1, 1, 0, 0, 0, 0], dt: 1.0 / 60) }
    check(hit.bands[0] > held.bands[0] + 0.3, "a hit pulls harder than the same note held", "\(hit.bands[0]) vs \(held.bands[0])")
    check(near(held.bands[0], W.held, 0.02) && held.bands[1] == 0, "held, a band pulls by where it stands; a silent band not at all")
    check(near(hit.level, 1.0 / 3) && W.Shaper.standing([1, 1, 0, 0, 0, 0]).bands[0] == W.held, "the level is the three's mean; standing levels have no hits")

    // At rest: a still streak, and nothing left to draw.
    var m = W.Motion()
    for _ in 0..<120 { m.step(dt: 1.0 / 60, input: silence) }
    check(!m.isMoving && m.openness == 0 && m.phase == 0 && m.clock == 0, "silent from the start: closed, not travelling, settled")
    check(m.amps.allSatisfy { near($0.x, W.restAmp, 1e-6) }, "its ribbons at the resting streak's height")

    // Sound opens it, lifts the ribbons, and sets it travelling.
    for _ in 0..<60 { m.step(dt: 1.0 / 60, input: loud) }
    check(m.isMoving && m.openness > 0.9 && m.phase > 0, "sound opens it and it travels", "open \(m.openness) phase \(m.phase)")
    check(m.amps[0].x > m.amps[1].x && m.amps[1].x > m.amps[2].x && m.amps[2].x > W.restAmp + 0.2, "each ribbon as tall as its band")
    check(near(m.level, 0.8, 0.01), "the level is followed up at once")

    // Loose springs: a hit overshoots where it will settle.
    var spring = W.Motion()
    var peak = 0.0
    for _ in 0..<180 { spring.step(dt: 1.0 / 60, input: loud); peak = max(peak, spring.amps[0].x) }
    // Past where the hit alone would hold it (the open wave's body is still
    // on its way in), and back down after.
    let pulled = W.restAmp + W.levelPull * loud.level + W.bandPull * loud.bands[0]
    check(peak > pulled + 0.1 && spring.amps[0].x < peak - 0.02, "a hit overshoots and settles", "peak \(peak) pulled \(pulled) settled \(spring.amps[0].x)")

    // Louder travels faster.
    var quiet = W.Motion(), strong = W.Motion()
    for _ in 0..<120 {
        quiet.step(dt: 1.0 / 60, input: W.Features(level: 0.2, bands: [0.2, 0.2, 0.2]))
        strong.step(dt: 1.0 / 60, input: W.Features(level: 0.9, bands: [0.9, 0.9, 0.9]))
    }
    check(strong.phase > quiet.phase * 2, "louder sound travels faster", "\(strong.phase) vs \(quiet.phase)")

    // It stays open through a gap, and closes to stillness after one.
    for _ in 0..<48 { m.step(dt: 1.0 / 60, input: silence) }      // 0.8s
    check(m.openness > 0.9 && m.isMoving, "0.8s of silence: still open")
    for _ in 0..<600 { m.step(dt: 1.0 / 60, input: silence) }
    let phase = m.phase
    check(!m.isMoving && m.openness < 0.01 && m.amps.allSatisfy { near($0.x, W.restAmp, 0.01) }, "10s of silence: closed and settled", "open \(m.openness)")
    m.step(dt: 1.0 / 60, input: silence)
    check(m.phase == phase, "and a closed wave doesn't travel")

    // Held still: it stands as tall as the sound, travels nowhere, and settles.
    var stillWave = W.Motion()
    for _ in 0..<600 { stillWave.step(dt: 1.0 / 60, input: loud, travels: false) }
    check(stillWave.phase == 0 && stillWave.clock == 0 && !stillWave.isMoving && stillWave.amps[0].x > 0.9, "asked not to travel, it stands and settles")

    // The clocks come round without a jump in anything drawn.
    for k in [0.8, -0.7, 1.15, 1.3, -0.9] {
        let turns = k * W.phaseWrap / (2 * Double.pi)
        check(near(turns, turns.rounded(), 1e-9), "wrapping the phase is a whole number of turns at \(k)")
    }
    for k in [0.31, 0.23, 0.41, 0.8] {
        let turns = k * W.clockWrap / (2 * Double.pi)
        check(near(turns, turns.rounded(), 1e-9), "wrapping the clock is a whole number of turns at \(k)")
    }
    var long = W.Motion()
    for _ in 0..<(60 * 60) { long.step(dt: 0.1, input: loud) }     // six minutes
    check(long.phase < W.phaseWrap && long.clock < W.clockWrap && long.time < W.clockWrap && long.openness > 0.9, "a long song: the clocks stay small and the wave open")

    // Standing levels, for the gallery.
    let standing = W.Motion.standing(W.Shaper.standing([0.8, 0.8, 0.4, 0.4, 0.1, 0.1]))
    check(standing.openness == 1 && standing.amps[0].x > standing.amps[2].x, "fixed levels stand open, bass tallest")
    check(W.Motion.standing(silence).openness == 0, "and no levels are the resting streak")

    // The tallest it stands stays inside the strip below the line.
    let tallest = (0.30 * 1.3 + W.openThick + W.thickPerLevel) * W.unit
    check(tallest <= Double(IslandPrism.ribbonStrip - IslandPrism.ribbonCentre), "a loud ribbon stays inside its strip above the line", "\(tallest)")
}

print("prism: the ribbon's motion")
do {
    check(IslandPrism.follow(0.3, toward: 0.3, dt: 1) == 0.3, "at its target, it stays")
    check(IslandPrism.follow(0, toward: 1, dt: 0) == 0, "no time, no movement")
    let up = IslandPrism.follow(0, toward: 1, dt: 1.0 / 60), down = 1 - IslandPrism.follow(1, toward: 0, dt: 1.0 / 60)
    check(up > 0 && up < 1 && down > 0 && down < 1, "a frame moves it part of the way")
    check(up > down, "rises faster than it falls")
    check(near(IslandPrism.follow(0, toward: 1, dt: IslandPrism.attack), 1 - exp(-1)), "one attack constant: 63% of the way")
    check(IslandPrism.follow(0, toward: 1, dt: 1.0 / 30) > 0.6, "most of the way to a new level by the capture's next publish")
    // Frame-rate independent: two half steps are one whole step.
    let whole = IslandPrism.follow(0, toward: 1, dt: 1.0 / 30)
    let halves = IslandPrism.follow(IslandPrism.follow(0, toward: 1, dt: 1.0 / 60), toward: 1, dt: 1.0 / 60)
    check(near(whole, halves, 1e-12), "the same at 30 and 60 frames a second")
    var v = 1.0, frames = 0
    while abs(v) > IslandPrism.settled, frames < 600 { v = IslandPrism.follow(v, toward: 0, dt: 1.0 / 60); frames += 1 }
    check(frames < 60, "silence settles, and the drawing stops, within a second", "\(frames) frames")
    var inRange = true
    for band in 0..<6 { for k in 0..<600 { let l = IslandPrism.procedural(band: band, at: Double(k) / 30); if l < 0.15 || l > 0.85 { inRange = false } } }
    check(inRange, "the animated pattern stays between a low and a high level")
}

print("prism: Claude's status in the ribbon")
do {
    typealias M = IslandPrism.Motion
    func bands(_ m: M, _ t: Double, reduce: Bool = false) -> [Double] { (0..<6).map { IslandPrism.pattern(m, band: $0, at: t, reduceMotion: reduce) } }
    func ranged(_ m: M) -> Bool { stride(from: 0.0, to: 8, by: 1.0 / 60).allSatisfy { t in bands(m, t).allSatisfy { $0 >= 0 && $0 <= 1 } } }
    check([M.working, .attention, .done, .steady, .rest, .music].allSatisfy(ranged), "every pattern stays within 0...1")
    check(bands(.rest, 3).allSatisfy { $0 == 0 } && bands(.music, 3).allSatisfy { $0 == 0 }, "rest is the resting streak; music has no pattern of its own")
    // Working: a crest that travels outward, and comes round again.
    let period = IslandPrism.workingPeriod
    func crestBand(_ t: Double) -> Int { let b = bands(.working, t); return b.firstIndex(of: b.max()!)! }
    check(crestBand(0) == 0 && crestBand(period * 0.2) == 1 && crestBand(period * 0.6) == 3, "working: the crest moves from the centre outward")
    check(zip(bands(.working, 0.4), bands(.working, 0.4 + period)).allSatisfy { near($0, $1, 1e-9) }, "and repeats each period")
    check(bands(.working, 0).max()! < 0.5, "working stays low: it's ambient")
    // Attention: the whole ribbon up and down together.
    let breath = IslandPrism.attentionPeriod
    check(zip(bands(.attention, 0), bands(.attention, breath / 2)).allSatisfy { $0 < $1 }, "attention: every band swells together")
    check(zip(bands(.attention, 0.3), bands(.attention, 0.3 + breath)).allSatisfy { near($0, $1, 1e-9) }, "and ebbs back each period")
    check(bands(.attention, breath / 2)[0] > bands(.attention, breath / 2)[5], "fullest at the centre")
    check(bands(.attention, breath / 2).max()! > bands(.working, 0).max()!, "attention swells higher than working runs")
    // Done: nothing while the panel opens, one crest out, then rest.
    let delay = IslandPrism.doneDelay, run = IslandPrism.doneRun
    check(bands(.done, delay * 0.9).allSatisfy { $0 == 0 }, "done: waits for the panel to open")
    check(bands(.done, delay + 0.01)[0] > 0.5, "then crests at the centre")
    let mid = bands(.done, delay + run * 0.5)
    check(mid.firstIndex(of: mid.max()!)! >= 2 && mid.firstIndex(of: mid.max()!)! <= 3, "the crest half way out, half way through its run")
    check(bands(.done, delay + run * 1.6).allSatisfy { $0 == 0 }, "and gone when the run is over")
    check(IslandPrism.isMoving(.done, at: delay + run) && !IslandPrism.isMoving(.done, at: delay + run * 1.6 + 0.01), "done moves for its run and no longer")
    check(IslandPrism.isMoving(.working, at: 100) && IslandPrism.isMoving(.attention, at: 100), "working and attention keep moving")
    check(!IslandPrism.isMoving(.steady, at: 0) && !IslandPrism.isMoving(.rest, at: 0) && !IslandPrism.isMoving(.music, at: 0), "steady and rest never do")
    let steady = bands(.steady, 0)
    check(steady.allSatisfy { $0 == steady[0] && $0 > 0 } && steady == bands(.steady, 5), "steady: a little fuller than rest, and still")
    // Reduce Motion: a still shape for each, no motion at all.
    for m in [M.working, .attention, .done] {
        check(!IslandPrism.isMoving(m, at: 0.5, reduceMotion: true) && bands(m, 0.2, reduce: true) == bands(m, 1.7, reduce: true), "\(m): still under Reduce Motion")
    }
}

print("prism: the ribbon's colours")
do {
    typealias RGB = IslandPrism.RGB
    func hue(_ c: RGB) -> Double { IslandPrism.hsb(c).h }
    func sat(_ c: RGB) -> Double { IslandPrism.hsb(c).s }
    func hueGap(_ a: Double, _ b: Double) -> Double { let d = abs(a - b); return min(d, 1 - d) }
    check(IslandPrism.spectrum.count == IslandPrism.stopCount, "the spectrum has a colour per stop")
    check(IslandPrism.stops(from: []) == IslandPrism.spectrum, "no colours: the spectrum")
    for c in [RGB(r: 1, g: 0, b: 0), RGB(r: 0.2, g: 0.6, b: 0.9), RGB(r: 0.9, g: 0.8, b: 0.1), RGB(r: 0.4, g: 0.1, b: 0.7)] {
        let back = IslandPrism.rgb(IslandPrism.hsb(c))
        check(near(back.r, c.r, 1e-9) && near(back.g, c.g, 1e-9) && near(back.b, c.b, 1e-9), "rgb → hsb → rgb round-trips")
    }
    // One colour (a status): a fan round its hue, never another colour.
    let green = RGB(r: 0.20, g: 0.78, b: 0.35)
    let one = IslandPrism.stops(from: [green])
    check(one.count == IslandPrism.stopCount, "a stop for each of the fan's colours")
    check(one.allSatisfy { hueGap(hue($0), hue(green)) <= IslandPrism.minHueFan / 2 + 1e-6 }, "one colour: every stop within the minimum fan of its hue")
    check(hueGap(hue(one[1]), hue(one[IslandPrism.stopCount - 2])) > IslandPrism.minHueFan * 0.5, "and fanned out, not flat")
    check(sat(one[0]) < sat(one[3]), "a paler tip at the top")
    // Three colours (a cover): each of them in the fan, in hue order.
    let cover = [RGB(r: 0.85, g: 0.15, b: 0.55), RGB(r: 1.0, g: 0.6, b: 0.2), RGB(r: 0.45, g: 0.2, b: 0.8)]
    let three = IslandPrism.stops(from: cover)
    for c in cover {
        check(three.contains { hueGap(hue($0), hue(c)) < 0.04 }, "the cover's colour is in the fan (hue \(hue(c)))")
    }
    // Hues run one way round the wheel down the fan: no doubling back.
    var offsets = three.map { h -> Double in var d = hue(h) - hue(three[0]); if d > 0.5 { d -= 1 }; if d < -0.5 { d += 1 }; return d }
    offsets = offsets.map { $0 - offsets[0] }
    check(zip(offsets, offsets.dropFirst()).allSatisfy { $1 >= $0 - 1e-6 } || zip(offsets, offsets.dropFirst()).allSatisfy { $1 <= $0 + 1e-6 },
          "hues run one way down the fan", "\(offsets)")
    check(three.dropFirst().dropLast().allSatisfy { max($0.r, $0.g, $0.b) > 0.75 }, "the fan's colours are light: bright whatever the cover")
    // A dark, dusty colour still throws light of its own hue; a grey stays grey.
    let dusty = IslandPrism.light(RGB(r: 0.25, g: 0.18, b: 0.15))
    check(dusty.b >= IslandPrism.lightMinBrightness && dusty.s >= IslandPrism.lightMinSaturation * 0.9, "a dark brown is lit and saturated")
    check(near(dusty.h, IslandPrism.hsb(RGB(r: 0.25, g: 0.18, b: 0.15)).h), "with its hue kept")
    let grey = IslandPrism.light(RGB(r: 0.5, g: 0.5, b: 0.5))
    check(grey.s == 0 && grey.b >= IslandPrism.lightMinBrightness, "a grey is silver light, no hue made up")
    check(IslandPrism.stops(from: [RGB(r: 0.6, g: 0.6, b: 0.6)]).allSatisfy { sat($0) < 0.02 }, "a grey cover's fan is white")
}

print("\n\(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
