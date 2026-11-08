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
    let notchGlow = IslandGlass.cameraCover(hasPhysicalNotch: true, glowOn: true)
    let notchPlain = IslandGlass.cameraCover(hasPhysicalNotch: true, glowOn: false)
    let flat = IslandGlass.cameraCover(hasPhysicalNotch: false, glowOn: true)
    check(notchGlow == C(housing: true, openGlow: true), "notch, glow on: housing held black, glow open")
    check(notchPlain == C(housing: true, openGlow: false), "notch, glow off: housing held black, nothing open")
    check(flat == C(housing: false, openGlow: false) && IslandGlass.cameraCover(hasPhysicalNotch: false, glowOn: false) == flat,
          "no notch: nothing to hold, no glow, glow on or off")

    let housing = CGSize(width: 185, height: 32)
    let c = IslandGlass.coveredHousing(housing)
    check(IslandGlass.cameraClearance >= 4, "at least 4pt of clearance")
    check(c.width == 185 + 2 * IslandGlass.cameraClearance && c.height == 32 + IslandGlass.cameraClearance, "covered: housing plus clearance each side and below")
    let core = c

    // The wings follow the island's own sizing: NotchRootView makes the pill
    // notch + leading + trailing + 28 wide, shifted (trailing - leading) / 2.
    func pill(_ leading: CGFloat, _ trailing: CGFloat, notch: CGFloat = 185) -> (width: CGFloat, shift: CGFloat) {
        (notch + leading + trailing + 28, (trailing - leading) / 2)
    }
    let music = pill(28, 32)                          // music solo: album | waveform slot
    let claudeToast = pill(28, 140)                   // one side widened: a toast, or Claude and the timer
    for (name, p) in [("music", music), ("lopsided", claudeToast)] {
        let runs = IslandGlass.wingRuns(width: p.width, shift: p.shift, core: core.width)
        let leftEnd = p.width / 2 - p.shift, rightEnd = p.width / 2 + p.shift   // camera to each end
        check(abs(runs.leading - (leftEnd - core.width / 2)) < 1e-9 && abs(runs.trailing - (rightEnd - core.width / 2)) < 1e-9,
              "\(name): each wing runs from the core to its own end")
        func a(_ x: CGFloat, _ y: CGFloat = 16) -> Double { IslandGlass.closedCoverAlpha(x: x, y: y, core: core, runs: runs) }
        check(a(0) == 1 && a(c.width / 2) == 1 && a(-c.width / 2) == 1, "\(name): solid over the housing and 4pt past it")
        check(a(-leftEnd) == 0 && a(rightEnd) == 0, "\(name): clear (the plain tint) at both ends")
        var mono = true
        for side in [-1.0, 1.0] {
            var last = 2.0
            for i in 0...400 {
                let x = CGFloat(side) * (c.width / 2 + (side < 0 ? runs.leading : runs.trailing) * CGFloat(i) / 400)
                let v = a(x)
                if v > last + 1e-12 { mono = false }
                last = v
            }
        }
        check(mono, "\(name): falls monotonically along each wing")
    }
    // Lopsided: the short side's gradient isn't stretched by the long one.
    let lr = IslandGlass.wingRuns(width: claudeToast.width, shift: claudeToast.shift, core: core.width)
    check(lr.trailing > lr.leading * 3, "a widened side gets its own longer run")

    // The ease: dark beside the camera, clear glass at the outer end.
    check(near(IslandGlass.wingEase, 1.6), "wing ease (1 - t)^1.6")
    check(IslandGlass.wingAlpha(0) == 1 && IslandGlass.wingAlpha(1) == 0, "black at the core, clear at the end")
    check(IslandGlass.wingAlpha(0.15) > 0.7, "content just beside the camera stays on dark")
    check(IslandGlass.wingAlpha(0.6) < 0.25, "the outer end, where the artwork sits, is mostly glass")
    check(IslandGlass.wingAlpha(0.5) < 0.5, "eased, not linear: under half by half way")

    // Vertical: whole to the core's depth, gone closedFadeDown below.
    let runs = IslandGlass.wingRuns(width: music.width, shift: music.shift, core: core.width)
    check(IslandGlass.closedCoverAlpha(x: 0, y: c.height, core: core, runs: runs) == 1, "solid to the core's depth")
    check(IslandGlass.closedCoverAlpha(x: 0, y: c.height + IslandGlass.closedFadeDown, core: core, runs: runs) == 0, "clear closedFadeDown below it")

    // Open: the glow exactly with it on; nothing with it off or no notch.
    func cover(_ k: C, _ x: CGFloat, _ y: CGFloat, _ p: Double) -> Double {
        IslandGlass.coverAlpha(k, x: x, y: y, housing: housing, runs: runs, progress: p)
    }
    var openIsGlow = true, openIsClear = true, closedIsGradient = true
    for x in stride(from: CGFloat(-300), through: 300, by: 1) {
        for y in stride(from: CGFloat(0), through: 90, by: 2) {
            if abs(cover(notchGlow, x, y, 1) - IslandGlass.glowAlpha(x: x, y: y, housing: c)) > 1e-12 { openIsGlow = false }
            if cover(notchPlain, x, y, 1) != 0 || cover(flat, x, y, 1) != 0 { openIsClear = false }
            let g = IslandGlass.closedCoverAlpha(x: x, y: y, core: core, runs: runs)
            if cover(notchGlow, x, y, 0) != g || cover(notchPlain, x, y, 0) != g { closedIsGradient = false }
        }
    }
    check(closedIsGradient, "closed: the gradient, whatever the glow setting")
    var flatClear = true
    for x in stride(from: CGFloat(-300), through: 300, by: 1) {
        for p in [0.0, 0.3, 1.0] where cover(flat, x, 10, p) != 0 { flatClear = false }
    }
    check(flatClear, "no notch: no cover closed, opening or open — plain glass")
    check(openIsGlow, "open, glow on: the glow exactly")
    check(openIsClear, "open, glow off or no notch: no cover, the open panel as it was")

    // In between: a per-pixel mix — no dip where both ends are solid, each
    // pixel moving one way, nothing past the blend's own slope.
    var noDip = true, oneWay = true, maxStep = 0.0
    for x in stride(from: CGFloat(-200), through: 200, by: 2) {
        for y in stride(from: CGFloat(0), through: 80, by: 4) {
            let a0 = cover(notchGlow, x, y, 0), a1 = cover(notchGlow, x, y, 1)
            var last = -1.0
            for i in -10...210 {
                let v = cover(notchGlow, x, y, Double(i) / 200)
                if a0 == 1 && a1 == 1 && v < 1 { noDip = false }
                if last >= 0 {
                    if a1 >= a0 ? v < last - 1e-12 : v > last + 1e-12 { oneWay = false }
                    maxStep = max(maxStep, abs(v - last))
                }
                last = v
            }
        }
    }
    check(noDip, "closed to open: no dip where both are solid (the housing and its clearance)")
    check(oneWay, "closed to open: each pixel moves one way only, overshoot included")
    check(maxStep <= 0.015 + 1e-9, "closed to open: no step beyond the blend's own slope", "\(maxStep)")
    var sameCurve = true
    for i in 0...100 {
        let p = Double(i) / 100
        let t = IslandGlass.coverOpenness(progress: p)
        let expect = IslandGlass.closedTintFloor + (IslandGlass.glassTint - IslandGlass.closedTintFloor) * t
        if abs(IslandGlass.tint(for: .glass, progress: p) - expect) > 1e-12 { sameCurve = false }
    }
    check(sameCurve, "the cover moves on the same curve as the tint floor")
    check(IslandGlass.coverOpenness(progress: 0) == 0 && IslandGlass.coverOpenness(progress: 1) == 1, "cover openness: 0 closed, 1 open")
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
