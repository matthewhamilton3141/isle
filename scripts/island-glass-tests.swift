//
//  island-glass-tests.swift
//
//  Tests for the glass panel backgrounds' arithmetic — the black-to-glass
//  blend, the notch glow, the tints and the legibility lifts — and the
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
    check(PanelBackground.allCases == [.black, .glass, .smoked], "picker order: Black, Glass, Smoked")
    check(!PanelBackground.black.isGlass, "Black isn't glass")
    check(PanelBackground.allCases.filter(\.isGlass).count == 2, "the other two are glass")
    check(Set(PanelBackground.allCases.map(\.title)).count == 3, "titles distinct")
    check(PanelBackground.stored("glassNotchFade") == .black && PanelBackground.stored("glassNotchGlow") == .black, "unshipped interim values read as Black")
}

print("tints")
do {
    check(IslandGlass.tint(for: .black) == 0, "Black has no tint")
    check(IslandGlass.tint(for: .glass) == IslandGlass.glassTint, "Glass uses glassTint")
    check(IslandGlass.tint(for: .smoked) == IslandGlass.smokedTint, "Smoked uses smokedTint")
    check(near(IslandGlass.smokedTint, 0.48), "Smoked is the mockups' 48%")
    check(IslandGlass.smokedTint > IslandGlass.glassTint, "Smoked is darker than Glass")
    // The closed island's floor, thinning to the open tint as it opens.
    check(IslandGlass.tint(for: .black, progress: 0) == 0 && IslandGlass.tint(for: .black, progress: 1) == 0, "Black: no tint open or closed")
    check(near(IslandGlass.tint(for: .glass, progress: 0), IslandGlass.closedTintFloor), "Glass closed: held at the floor")
    check(near(IslandGlass.tint(for: .glass, progress: 1), IslandGlass.glassTint), "Glass open: its own tint")
    check(near(IslandGlass.tint(for: .glass, progress: IslandGlass.blendEnd), IslandGlass.glassTint), "Glass: open tint by blendEnd")
    check(near(IslandGlass.tint(for: .smoked, progress: 0), IslandGlass.smokedTint) && near(IslandGlass.tint(for: .smoked, progress: 1), IslandGlass.smokedTint),
          "Smoked: already past the floor, the same open and closed")
    check(IslandGlass.closedTintFloor > IslandGlass.glassTint && IslandGlass.closedTintFloor <= IslandGlass.smokedTint,
          "the floor sits between Glass and Smoked")
    var tmono = true, tlast = 2.0
    for i in -5...105 {
        let v = IslandGlass.tint(for: .glass, progress: Double(i) / 100)
        if v > tlast + 1e-12 { tmono = false }
        tlast = v
    }
    check(tmono, "Glass tint thins monotonically as the island opens, overshoot included")
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

print("closed island")
do {
    // Which closed states go glass: only a glass mode with something showing.
    for b in PanelBackground.allCases {
        check(!IslandGlass.closedIsGlass(background: b, showsContent: false), "\(b.rawValue): the empty pill stays black")
    }
    check(!IslandGlass.closedIsGlass(background: .black, showsContent: true), "Black: the wings stay black")
    check(IslandGlass.closedIsGlass(background: .glass, showsContent: true), "Glass: the wings go glass")
    check(IslandGlass.closedIsGlass(background: .smoked, showsContent: true), "Smoked: the wings go glass")

    // The blend with the closed island's glass as its second input.
    check(IslandGlass.blackCover(progress: 0, closedGlass: 0) == 1, "empty pill: all black")
    check(IslandGlass.blackCover(progress: 0, closedGlass: 1) == 0, "wings: no black")
    check(!IslandGlass.showsGlass(progress: 0, closedGlass: 0), "empty pill: glass not drawn (Black-identical)")
    check(IslandGlass.showsGlass(progress: 0, closedGlass: 1), "wings: glass drawn")
    check(IslandGlass.showsGlass(progress: 0, closedGlass: 0.01), "glass drawn as soon as content starts to arrive")
    var same = true
    for i in 0...100 {
        let p = Double(i) / 100
        if IslandGlass.blackCover(progress: p, closedGlass: 0) != IslandGlass.blackCover(progress: p) { same = false }
    }
    check(same, "opening from the empty pill is the blend it always was")
    var neverBlack = true
    for i in -5...105 {
        let p = Double(i) / 100   // a spring's overshoot either side included
        if IslandGlass.blackCover(progress: p, closedGlass: 1) != 0 { neverBlack = false }
    }
    check(neverBlack, "open from the wings and collapse back: never any black over the glass")
    check(IslandGlass.blackCover(progress: 0, closedGlass: 1.08) == 0 && IslandGlass.blackCover(progress: 0, closedGlass: -0.05) == 1,
          "closed-glass overshoot clamps")
    check(near(IslandGlass.blackCover(progress: 0, closedGlass: 0.5), 0.5), "content arriving: black thins with it")
    var mono = true, last = 2.0
    for i in 0...100 {
        let v = IslandGlass.blackCover(progress: 0, closedGlass: Double(i) / 100)
        if v > last + 1e-12 { mono = false }
        last = v
    }
    check(mono, "black falls monotonically as the wings arrive")
    check(IslandGlass.blackCover(progress: 1, closedGlass: 0) == 0 && IslandGlass.blackCover(progress: 1, closedGlass: 1) == 0,
          "open is glass whatever the closed island")
}

print("camera cover")
do {
    typealias C = IslandGlass.CameraCover
    check(IslandGlass.cameraCover(hasPhysicalNotch: false, glowOn: true) == .none, "no notch, glow on: no cover, all glass")
    check(IslandGlass.cameraCover(hasPhysicalNotch: false, glowOn: false) == .none, "no notch, glow off: no cover, all glass")
    check(IslandGlass.cameraCover(hasPhysicalNotch: true, glowOn: true) == .bandToGlow, "notch, glow on: band closed, glow open")
    check(IslandGlass.cameraCover(hasPhysicalNotch: true, glowOn: false) == .bandToClear, "notch, glow off: band closed, clear open")

    let housing = CGSize(width: 185, height: 32)
    let c = IslandGlass.coveredHousing(housing)
    check(IslandGlass.cameraClearance >= 4, "at least 4pt of clearance")
    check(c.width == 185 + 2 * IslandGlass.cameraClearance && c.height == 32 + IslandGlass.cameraClearance, "covered: housing plus clearance each side and below")
    func band(_ x: CGFloat, _ y: CGFloat) -> Double { IslandGlass.bandAlpha(x: x, y: y, covered: c) }
    func glow(_ x: CGFloat, _ y: CGFloat) -> Double { IslandGlass.glowAlpha(x: x, y: y, housing: c) }
    func cover(_ k: C, _ x: CGFloat, _ y: CGFloat, _ p: Double) -> Double { IslandGlass.coverAlpha(k, x: x, y: y, covered: c, progress: p) }
    let edge: CGFloat = 185.0 / 2   // the housing's side, from the camera's centre line

    // Closed: the band, whatever the glow setting — glass right up to the camera.
    var closedIsBand = true
    for k in [C.bandToGlow, .bandToClear] {
        for x in stride(from: CGFloat(0), through: 200, by: 0.5) {
            for y in stride(from: CGFloat(0), through: 32, by: 4) where abs(cover(k, x, y, 0) - band(x, y)) > 1e-9 { closedIsBand = false }
        }
    }
    check(closedIsBand, "closed: the cover is the band, glow on or off")
    check(cover(.bandToGlow, edge + 4, 16, 0) == 1 && cover(.bandToClear, -edge - 4, 16, 0) == 1, "closed: solid 4pt past the housing")
    check(cover(.bandToGlow, edge + 4 + IslandGlass.bandFade, 16, 0) == 0, "closed: clear \(Int(4 + IslandGlass.bandFade))pt past the housing")
    // The Claude glyph's slot starts CollapsedSize.cutoutGap (6pt) from the camera.
    check(cover(.bandToGlow, edge + 6, 16, 0) <= 0.5, "closed: the glyph 6pt from the camera starts over half glass at most", "\(cover(.bandToGlow, edge + 6, 16, 0))")
    check(cover(.bandToGlow, edge + 7, 16, 0) < 0.2, "closed: and is all but clear of black a point further")
    // The wings, 20pt out: glass, not black (the glow alone left them ~60% black).
    check(cover(.bandToGlow, edge + 20, 16, 0) == 0 && glow(edge + 20, 16) > 0.5, "closed: a wing 20pt out is glass (the glow there was > 50% black)")

    // Open: the glow exactly with it on, nothing with it off.
    var openIsGlow = true, openIsClear = true, maxOver = 0.0
    for x in stride(from: CGFloat(0), through: 300, by: 0.5) {
        for y in stride(from: CGFloat(0), through: 90, by: 1) {
            let o = cover(.bandToGlow, x, y, 1), g = glow(x, y), b = band(x, y)
            if abs(o - max(g, b)) > 0.002 { openIsGlow = false }
            maxOver = max(maxOver, o - g)
            if cover(.bandToClear, x, y, 1) != 0 { openIsClear = false }
        }
    }
    check(openIsGlow, "open, glow on: the band and the glow layer together are the glow")
    check(maxOver < 0.01, "open, glow on: never more than the glow alone by a hair", "\(maxOver)")
    check(openIsClear, "open, glow off: no cover at all, the open panel as it was")
    check(cover(.bandToGlow, 0, 0, IslandGlass.blendEnd) == 1 && abs(cover(.bandToGlow, edge + 30, 40, IslandGlass.blendEnd) - glow(edge + 30, 40)) < 0.002,
          "the glow is whole by blendEnd")

    // In between: a per-pixel mix, no dip anywhere it's solid both ends,
    // and continuous on the open's progress (the genie collapse runs it back).
    var noDip = true, mono = true, maxStep = 0.0
    for x in stride(from: CGFloat(0), through: 200, by: 1) {
        for y in stride(from: CGFloat(0), through: 80, by: 2) {
            var last = -1.0
            for i in 0...200 {
                let p = Double(i) / 200
                let v = cover(.bandToGlow, x, y, p)
                if min(band(x, y), glow(x, y)) == 1 && v < 1 - 1e-12 { noDip = false }
                // From band to glow is a mix: it moves one way only.
                if last >= 0 {
                    let up = glow(x, y) >= band(x, y)
                    if up ? v < last - 1e-9 : v > last + 1e-9 { mono = false }
                    maxStep = max(maxStep, abs(v - last))
                }
                last = v
            }
        }
    }
    check(noDip, "band to glow: no dip where both are solid")
    check(mono, "band to glow: each pixel moves one way only")
    // The blend's steepest slope is 1.5 over its 0.5 span, so per 0.5% of
    // the open no pixel can move more than 0.015 — the cover adds no step
    // of its own.
    check(maxStep <= 0.015 + 1e-9, "band to glow: no step beyond the blend's own slope", "\(maxStep)")
    var clearMono = true, clast = 2.0
    for i in 0...200 {
        let v = cover(.bandToClear, 0, 10, Double(i) / 200)
        if v > clast + 1e-12 { clearMono = false }
        clast = v
    }
    check(clearMono && cover(.bandToClear, 0, 10, 0) == 1, "band to clear: thins monotonically from whole")
    check(IslandGlass.coverOpenness(progress: 0) == 0 && IslandGlass.coverOpenness(progress: 1) == 1, "cover openness: 0 closed, 1 open")
    var sameCurve = true
    for i in 0...100 {
        let p = Double(i) / 100
        let t = IslandGlass.coverOpenness(progress: p)
        let tint = IslandGlass.tint(for: .glass, progress: p)
        let expect = IslandGlass.closedTintFloor + (IslandGlass.glassTint - IslandGlass.closedTintFloor) * t
        if abs(tint - expect) > 1e-12 { sameCurve = false }
    }
    check(sameCurve, "the cover moves on the same curve as the tint floor")
    check(IslandGlass.bandOpacity(.none, progress: 0) == 0 && IslandGlass.glowLayerOpacity(.none, progress: 1) == 0, "none: nothing drawn")

    // The band's own shape.
    check(near(band(edge + 4 + IslandGlass.bandFade / 2, 16), 0.5), "band: half way through its fade, half")
    check(band(-150, 12) == band(150, 12), "band symmetric about the camera")
    let e = IslandGlass.bandExtent(covered: c)
    check(e.width == c.width + 2 * IslandGlass.bandFade && e.height == c.height + IslandGlass.bandFade, "band extent: fade each side and below")
    let m = IslandGlass.bandMask(covered: c, scale: 2)
    check(m.width == Int((e.width * 2).rounded(.up)) && m.height == Int((e.height * 2).rounded(.up)), "band mask sized at 2x")
    // The outermost pixel centres sit a quarter point inside the fade's end.
    check(m.alpha[m.width / 2] == 255 && m.alpha[0] <= 4 && m.alpha[m.width - 1] <= 4, "band mask solid at the top centre, clear at the corners")
    let gm = IslandGlass.glowOverBandMask(covered: c, scale: 2)
    let ge = IslandGlass.glowExtent(housing: c)
    check(gm.width == Int((ge.width * 2).rounded(.up)) && gm.height == Int((ge.height * 2).rounded(.up)), "glow layer sized like the glow")
    check(gm.alpha[gm.width / 2] == 0, "glow layer adds nothing over the solid band")
    check(gm.alpha[(gm.height - 1) * gm.width + gm.width / 2] == 0 && gm.alpha[0] == 0, "glow layer clear at its reach")
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
