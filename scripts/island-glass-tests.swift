//
//  island-glass-tests.swift
//
//  Tests for the glass panel backgrounds' arithmetic — the black-to-glass
//  blend, the notch glow, the tints, Fade's band and curve, and the
//  legibility lifts — and the
//  stored setting's default, compiled against Isle/Notch/IslandGlass.swift
//  and Isle/Core/PanelBackground.swift alone. Run with
//  scripts/test-island-glass.sh.
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
    check(PanelBackground.allCases == [.black, .glass, .smoked, .fade], "picker order: Black, Glass, Smoked, Fade")
    check(!PanelBackground.black.isGlass, "Black isn't glass")
    check(PanelBackground.allCases.filter(\.isGlass).count == 3, "the other three are glass")
    check(Set(PanelBackground.allCases.map(\.title)).count == 4, "titles distinct")
    check(PanelBackground.stored("fade") == .fade, "Fade is stored as \"fade\"")
    check(PanelBackground.allCases.filter(\.growsNotchGlow) == [.glass, .smoked], "the notch glow is Glass's and Smoked's alone")
    check(PanelBackground.stored("glassNotchFade") == .black && PanelBackground.stored("glassNotchGlow") == .black, "unshipped interim values read as Black")
}

print("tints")
do {
    check(IslandGlass.tint(for: .black) == 0, "Black has no tint")
    check(IslandGlass.tint(for: .glass) == IslandGlass.glassTint, "Glass uses glassTint")
    check(IslandGlass.tint(for: .smoked) == IslandGlass.smokedTint, "Smoked uses smokedTint")
    check(near(IslandGlass.smokedTint, 0.48), "Smoked is the mockups' 48%")
    check(IslandGlass.smokedTint > IslandGlass.glassTint, "Smoked is darker than Glass")
    check(IslandGlass.tint(for: .fade) == IslandGlass.fadeEndTint, "Fade's tint is the one at its bottom edge")
}

print("fade")
do {
    let notch: CGFloat = 32, height: CGFloat = 146
    let band = IslandGlass.fadeBand(notchHeight: notch)
    func a(_ y: CGFloat, _ h: CGFloat = height) -> Double { IslandGlass.fadeAlpha(y: y, height: h, band: band) }
    check(band >= notch + 4, "the solid band reaches past the camera housing", "band \(band)")
    check(band == notch + IslandGlass.fadeBandExtra, "band: the housing plus fadeBandExtra")
    check(IslandGlass.fadeBand(notchHeight: 24) < band, "a shallower housing (or none) gets a shallower band")
    check(a(0) == 1 && a(notch) == 1 && a(band) == 1, "solid black over the housing and down to the band's foot")
    check(near(a(height), IslandGlass.fadeEndTint), "the end tint at the bottom edge")
    check(near(a(band + (height - band) / 2), 1 - (1 - IslandGlass.fadeEndTint) / 2), "half way down the ease, half way to the end tint")
    // Legible at the bottom: never lighter than Glass, which is legible on
    // its own, and lighter than Smoked, or it wouldn't read as glass.
    check(IslandGlass.fadeEndTint > IslandGlass.glassTint && IslandGlass.fadeEndTint < IslandGlass.smokedTint,
          "the end tint sits between Glass and Smoked", "\(IslandGlass.fadeEndTint)")
    // The action row's band, the panel's last ~30pt: everywhere darker
    // than Glass and no lighter than the end tint.
    var rowOK = true
    for y in stride(from: height - 30, through: height, by: 0.5) {
        let v = a(y)
        if v < IslandGlass.fadeEndTint - 1e-12 || v <= IslandGlass.glassTint { rowOK = false }
    }
    check(rowOK, "the action row sits on more black than Glass gives it", "\(a(height - 30))")
    var mono = true, prev = 2.0, maxStep = 0.0
    for i in 0...1460 {
        let v = a(CGFloat(i) / 10)
        if v > prev + 1e-12 { mono = false }
        if prev <= 1 { maxStep = max(maxStep, prev - v) }
        prev = v
    }
    check(mono, "only ever lightens toward the bottom")
    check(maxStep < 0.005, "no step anywhere down the panel (per 0.1pt)", "max step \(maxStep)")
    // No slope where the band ends or at the bottom: smoothstep's ends.
    let eps: CGFloat = 0.01
    check((1 - a(band + eps)) < 1e-5, "leaves the band with no edge")
    check(abs(a(height - eps) - a(height)) < 1e-5, "arrives at the bottom with no edge")
    // It follows the panel's height: the same fraction of the ease at any
    // height, never a fixed-height gradient stretched.
    check(near(a(band + (230 - band) / 2, 230), a(band + (height - band) / 2)), "the ease spans the panel's current height")
    check(a(band + 50, 230) > a(band + 50, 146), "a taller panel eases more slowly")
    check(a(20, 30) == 1 && a(40, 30) == 1, "a panel shallower than the band (mid-collapse) is all black")
    // The gradient's stops sample the curve and end at the band and bottom.
    let stops = IslandGlass.fadeStops()
    check(stops.count == IslandGlass.fadeStopCount + 1, "stop count")
    check(stops.first!.location == 0 && stops.first!.alpha == 1, "first stop: solid at the band's foot")
    check(stops.last!.location == 1 && near(stops.last!.alpha, IslandGlass.fadeEndTint), "last stop: the end tint at the bottom")
    var worst = 0.0
    for i in 0...1000 {
        let t = Double(i) / 1000
        let k = min(Int(t * Double(IslandGlass.fadeStopCount)), IslandGlass.fadeStopCount - 1)
        let s0 = stops[k], s1 = stops[k + 1]
        let lerp = s0.alpha + (s1.alpha - s0.alpha) * (t - s0.location) / (s1.location - s0.location)
        worst = max(worst, abs(lerp - (1 - (1 - IslandGlass.fadeEndTint) * IslandGlass.fadeEase(t))))
    }
    check(worst < 0.003, "the stops' linear gradient is within 0.3% of the curve", "\(worst)")
    check(IslandGlass.fadeEase(-1) == 0 && IslandGlass.fadeEase(2) == 1, "the ease clamps")
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
    check(near(IslandGlass.liftedOpacity(0.5), 0.625), "0.5 → 0.625")
    check(near(IslandGlass.liftedOpacity(0.72), 0.79), "0.72 → 0.79")
    check(IslandGlass.liftedOpacity(1) == 1, "opaque stays opaque")
    check(IslandGlass.liftedOpacity(0.45) > 0.45, "always brighter")
    // The floor: a deep accent comes up to it, keeping its hue order.
    let deep = IslandGlass.floored(r: 0.30, g: 0.05, b: 0.45)
    let l = IslandGlass.luma(r: deep.r, g: deep.g, b: deep.b)
    check(near(l, IslandGlass.paletteLumaFloor, 1e-9), "deep purple raised to the floor", "\(l)")
    check(deep.b > deep.r && deep.r > deep.g, "hue order kept")
    let bright = IslandGlass.floored(r: 0.9, g: 0.7, b: 0.2)
    check(bright.r == 0.9 && bright.g == 0.7 && bright.b == 0.2, "already-light colours untouched")
    let black = IslandGlass.floored(r: 0, g: 0, b: 0)
    check(near(black.r, IslandGlass.paletteLumaFloor) && near(black.g, black.r) && near(black.b, black.r), "black lifts to a grey at the floor")
}

print("\n\(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
