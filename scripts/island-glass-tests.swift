//
//  island-glass-tests.swift
//
//  Tests for the glass panel backgrounds' arithmetic — the black-to-glass
//  blend, the notch glow, the tints, Fade's band, curve and lens, and the
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
    check(PanelBackground.allCases == [.black, .glass, .smoked, .fade, .prism], "picker order: Black, Glass, Smoked, Fade, Prism")
    check(!PanelBackground.black.isGlass, "Black isn't glass")
    check(PanelBackground.allCases.filter(\.isGlass).count == 4, "the other four are glass")
    check(Set(PanelBackground.allCases.map(\.title)).count == 5, "titles distinct")
    check(PanelBackground.stored("prism") == .prism, "Prism is stored as \"prism\"")
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
    check(IslandGlass.tint(for: .prism) == IslandPrism.lipTint, "Prism's tint is its lip's")
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
    let reach = IslandGlass.fadeReach
    let easeEnd = band + (height - band) * CGFloat(reach)
    check(reach >= 0.4 && reach <= 0.8, "the ease takes a good part of the way down", "\(reach)")
    check(near(a(band + (easeEnd - band) / 2), 1 - (1 - IslandGlass.fadeEndTint) / 2), "half way down the ease, half way to the end tint")
    check(near(a(easeEnd), IslandGlass.fadeEndTint) && near(a((easeEnd + height) / 2), IslandGlass.fadeEndTint),
          "past the ease's reach, the end tint all the way down")
    // The shade's end is lighter than Glass's flat tint, so the rim reads
    // as glass…
    check(IslandGlass.fadeEndTint < IslandGlass.glassTint, "the end tint is lighter than Glass's", "\(IslandGlass.fadeEndTint)")
    // …and the content gets its dark from the scrim: with it, the content
    // sits on more black than Glass gives it, short of Smoked's.
    check(near(IslandGlass.fadeContentAlpha, IslandGlass.over(IslandGlass.fadeEndTint, IslandGlass.fadeScrim)), "content alpha: the end tint with the scrim over it")
    check(IslandGlass.fadeContentAlpha > IslandGlass.glassTint && IslandGlass.fadeContentAlpha < IslandGlass.smokedTint,
          "the content's black sits between Glass and Smoked", "\(IslandGlass.fadeContentAlpha)")
    // The action row's band, the panel's last ~30pt: never lighter than the
    // end tint, and with the scrim, darker than Glass.
    var rowOK = true
    for y in stride(from: height - 30, through: height, by: 0.5) {
        let v = a(y)
        if v < IslandGlass.fadeEndTint - 1e-12 || IslandGlass.over(v, IslandGlass.fadeScrim) <= IslandGlass.glassTint { rowOK = false }
    }
    check(rowOK, "the action row, under the scrim, sits on more black than Glass gives it", "\(a(height - 30))")
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
    check(near(a(band + (230 - band) / 3, 230), a(band + (height - band) / 3)), "the ease spans the panel's current height")
    check(a(band + 50, 230) > a(band + 50, 146), "a taller panel eases more slowly")
    check(a(20, 30) == 1 && a(40, 30) == 1, "a panel shallower than the band (mid-collapse) is all black")
    // The gradient's stops sample the curve and end at the band and bottom.
    let stops = IslandGlass.fadeStops()
    check(stops.count == IslandGlass.fadeStopCount + (reach < 1 ? 2 : 1), "stop count")
    check(stops.first!.location == 0 && stops.first!.alpha == 1, "first stop: solid at the band's foot")
    check(stops.last!.location == 1 && near(stops.last!.alpha, IslandGlass.fadeEndTint), "last stop: the end tint at the bottom")
    check(zip(stops, stops.dropFirst()).allSatisfy { $0.location < $1.location }, "stops in order")
    // The gradient between the stops, against the curve, down the whole span.
    var worst = 0.0
    for i in 0...1000 {
        let t = Double(i) / 1000
        let k = (stops.lastIndex { $0.location <= t } ?? 0)
        let s0 = stops[min(k, stops.count - 2)], s1 = stops[min(k, stops.count - 2) + 1]
        let lerp = s0.alpha + (s1.alpha - s0.alpha) * (t - s0.location) / (s1.location - s0.location)
        worst = max(worst, abs(lerp - a(band + (height - band) * CGFloat(t))))
    }
    check(worst < 0.003, "the stops' linear gradient is within 0.3% of the curve", "\(worst)")
    check(IslandGlass.fadeEase(-1) == 0 && IslandGlass.fadeEase(2) == 1, "the ease clamps")
}

print("fade lens")
do {
    // The scrim leaves a rim of glass inside the walls, and stops short of
    // where the content starts (10pt inside them) once feathered.
    check(IslandGlass.fadeScrimInset > 0 && IslandGlass.fadeScrimInset + IslandGlass.fadeScrimFeather <= 10,
          "the scrim is full strength by the content's edge, 10pt inside the walls")
    check(IslandGlass.fadeScrim > 0 && IslandGlass.fadeScrim < 0.5, "the scrim is a scrim, not a fill", "\(IslandGlass.fadeScrim)")
    // The rim: brightest at the corners, its floor between, symmetric and
    // smooth.
    check(near(IslandGlass.fadeRimAlpha(x: 0), IslandGlass.fadeRimPeak) && near(IslandGlass.fadeRimAlpha(x: 1), IslandGlass.fadeRimPeak),
          "the rim peaks at both corners")
    check(near(IslandGlass.fadeRimAlpha(x: 0.5), IslandGlass.fadeRimFloor), "the rim sits at its floor mid-panel")
    check(IslandGlass.fadeRimPeak > IslandGlass.fadeRimFloor && IslandGlass.fadeRimPeak <= 1, "peak above floor, and a real alpha")
    var symmetric = true, rimStep = 0.0, prevRim = IslandGlass.fadeRimAlpha(x: 0)
    for i in 0...1000 {
        let x = Double(i) / 1000
        let v = IslandGlass.fadeRimAlpha(x: x)
        if !near(v, IslandGlass.fadeRimAlpha(x: 1 - x), 1e-12) { symmetric = false }
        rimStep = max(rimStep, abs(v - prevRim)); prevRim = v
    }
    check(symmetric, "the rim is symmetric")
    check(rimStep < 0.005, "no step along the rim", "\(rimStep)")
    let rimStops = IslandGlass.fadeRimStops()
    check(rimStops.first!.location == 0 && rimStops.last!.location == 1, "rim stops span the panel")
    // The glint: in order, nothing at either end (the rim's white corners
    // take over there), clear of the corners, hues and strengths in range.
    let g = IslandGlass.fadeGlintStops
    check(zip(g, g.dropFirst()).allSatisfy { $0.location < $1.location }, "glint stops in order")
    check(g.first!.strength == 0 && g.last!.strength == 0, "the glint fades to nothing at both ends")
    check(g.first!.location >= IslandGlass.fadeRimCornerSpan * 0.5 && g.last!.location <= 1 - IslandGlass.fadeRimCornerSpan * 0.5,
          "the glint stays off the corners")
    check(g.allSatisfy { (0...1).contains($0.hue) && (0...1).contains($0.strength) }, "glint hues and strengths in 0...1")
    check(Set(g.map(\.hue)).count >= 5, "the glint is spectral, not one colour")
    check(IslandGlass.fadeGlintAlpha > 0 && IslandGlass.fadeGlintAlpha <= 1, "glint alpha")
    // The haze stays under the action row's text, 8pt above the edge.
    check(IslandGlass.fadeHazeHeight <= 14 && IslandGlass.fadeHazeAlpha <= 0.25, "the haze is low and faint",
          "\(IslandGlass.fadeHazeHeight)pt at \(IslandGlass.fadeHazeAlpha)")
    check(near(IslandGlass.over(0, 0.3), 0.3) && near(IslandGlass.over(0.5, 0.5), 0.75) && IslandGlass.over(1, 0) == 1, "over composites")
}

print("fade light from the cover")
do {
    typealias C = IslandGlass.HSB
    let light = IslandGlass.fadeLight
    // The floor: dark and grey covers still throw light.
    let nearBlack = light(C(h: 0.6, s: 0.5, b: 0.08))
    check(nearBlack.b >= IslandGlass.fadeLightMinBrightness && near(nearBlack.h, 0.6), "a near-black colour is lit to the floor, hue kept", "\(nearBlack)")
    let grey = light(C(h: 0.3, s: 0.0, b: 0.35))
    check(grey.s == 0 && grey.b >= IslandGlass.fadeLightMinBrightness, "a grey stays neutral: silver light", "\(grey)")
    let noise = light(C(h: 0.9, s: 0.03, b: 0.5))
    check(noise.s < 0.05, "a grey with a hint of JPEG hue stays neutral", "\(noise)")
    let pastel = light(C(h: 0.85, s: 0.2, b: 0.95))
    check(pastel.s >= IslandGlass.fadeLightMinSaturation - 1e-9 && near(pastel.b, 0.95), "a pastel reads as its colour", "\(pastel)")
    let loud = light(C(h: 0.03, s: 1, b: 1))
    check(near(loud.s, IslandGlass.fadeSpectralSaturation), "a loud red is no louder than the spectrum", "\(loud)")
    let bright = light(C(h: 0.5, s: 0.5, b: 0.97))
    check(bright == C(h: 0.5, s: 0.5, b: 0.97), "an already-bright, moderate colour is unchanged")
    // Continuous in saturation: no jump where a hue sets in.
    var maxJump = 0.0, prevS = light(C(h: 0.2, s: 0, b: 1)).s, mono = true
    for i in 1...1000 {
        let v = light(C(h: 0.2, s: Double(i) / 1000, b: 1)).s
        maxJump = max(maxJump, abs(v - prevS)); if v < prevS - 1e-12 { mono = false }; prevS = v
    }
    check(maxJump < 0.01 && mono, "saturation lifts smoothly and monotonically", "\(maxJump)")
    check(IslandGlass.fadeLightMinSaturation < IslandGlass.fadeSpectralSaturation, "the lift stays under the cap")
    // The palette's glint lies where the spectrum's does.
    let spectral = IslandGlass.fadeSpectralGlint()
    let p = IslandGlass.fadeGlint(primary: C(h: 0.05, s: 0.9, b: 0.8), secondary: C(h: 0.95, s: 0.7, b: 0.4), accent: C(h: 0.12, s: 0.6, b: 0.9))
    check(p.count == spectral.count, "same stop count as the spectrum (a cross-fade lines up)")
    check(zip(p, spectral).allSatisfy { near($0.location, $1.location) && near($0.strength, $1.strength) }, "same locations and strengths")
    check(p.first!.strength == 0 && p.last!.strength == 0, "still nothing at either end")
    check(p.allSatisfy { $0.color.b >= IslandGlass.fadeLightMinBrightness && $0.color.s <= IslandGlass.fadeSpectralSaturation + 1e-12 }, "every stop lit and capped")
    check(near(p[3].color.h, 0.12) && near(p[2].color.h, 0.05) && near(p[4].color.h, 0.05) && near(p[1].color.h, 0.95),
          "accent at the centre, primary either side, secondary outside")
    check(spectral.allSatisfy { $0.color.b == 1 && near($0.color.s, IslandGlass.fadeSpectralSaturation) }, "the spectrum: full brightness, spectral saturation")
    // The rim: white with no cover, faintly tinted with one.
    let white = IslandGlass.fadeRimColor(primary: nil)
    check(white == (1, 1, 1), "no cover: a white rim")
    let warm = IslandGlass.fadeRimColor(primary: C(h: 0.05, s: 0.9, b: 0.8))
    check(warm.r > warm.b && min(warm.r, warm.g, warm.b) >= 1 - IslandGlass.fadeRimTint - 1e-9, "a red cover warms the rim, faintly", "\(warm)")
    check(IslandGlass.fadeRimTint > 0 && IslandGlass.fadeRimTint <= 0.4, "the tint is faint")
    // HSB to RGB.
    func rgbNear(_ a: (r: Double, g: Double, b: Double), _ b: (Double, Double, Double)) -> Bool { near(a.r, b.0, 1e-9) && near(a.g, b.1, 1e-9) && near(a.b, b.2, 1e-9) }
    check(rgbNear(IslandGlass.rgb(C(h: 0, s: 1, b: 1)), (1, 0, 0)) && rgbNear(IslandGlass.rgb(C(h: 1.0 / 3, s: 1, b: 1)), (0, 1, 0))
          && rgbNear(IslandGlass.rgb(C(h: 2.0 / 3, s: 1, b: 1)), (0, 0, 1)) && rgbNear(IslandGlass.rgb(C(h: 0.5, s: 0, b: 0.4)), (0.4, 0.4, 0.4))
          && rgbNear(IslandGlass.rgb(C(h: 1, s: 1, b: 1)), (1, 0, 0)), "HSB to RGB")
    check(IslandGlass.fadeLightCrossfade > 0.2 && IslandGlass.fadeLightCrossfade <= 1, "a short cross-fade")
}

print("fade sweep on open")
do {
    let sweeps = IslandGlass.fadeSweeps
    // The trigger rules.
    check(sweeps(nil, nil, false), "the first open sweeps")
    check(!sweeps(nil, nil, true), "never with Reduce Motion")
    check(sweeps(5, 30, false), "an open after a while closed sweeps")
    check(!sweeps(0.4, 30, false), "re-opening within a moment of closing doesn't")
    check(!sweeps(IslandGlass.fadeSweepRearm - 0.01, nil, false) && sweeps(IslandGlass.fadeSweepRearm, nil, false),
          "re-arms after fadeSweepRearm closed")
    check(!sweeps(2, 2.5, false), "not within the cooldown of the last sweep (an alert's open landing between hovers)")
    check(sweeps(2, IslandGlass.fadeSweepCooldown, false), "and again once the cooldown has passed")
    check(IslandGlass.fadeSweepRearm >= 1 && IslandGlass.fadeSweepRearm <= 2, "re-arm about a second", "\(IslandGlass.fadeSweepRearm)")
    check(IslandGlass.fadeSweepCooldown > IslandGlass.fadeSweepRearm, "the cooldown outlasts the re-arm")
    // An alert's auto-open cycling open/closed every second or two sweeps
    // once, not every time.
    var lastClose: Double? = nil, lastSweep: Double? = nil, count = 0
    for cycle in 0..<6 {
        let openAt = Double(cycle) * 1.6
        if sweeps(lastClose.map { openAt - $0 }, lastSweep.map { openAt - $0 }, false) { count += 1; lastSweep = openAt }
        lastClose = openAt + 0.5
    }
    check(count <= 3, "an open/close cycle every 1.6s sweeps at most every other time", "\(count)")
    // Timing: from the open spring's arrival at full width.
    check(near(IslandGlass.fadeSweepDelay, IslandMotion.open.reach(1)), "starts as the outline first reaches full width")
    check(IslandGlass.fadeSweepDelay > 0.15 && IslandGlass.fadeSweepDelay < 0.25, "about 0.2s after the open", "\(IslandGlass.fadeSweepDelay)")
    check(near(IslandGlass.fadeSweepDuration, 0.6), "runs 0.6s")
    // Symmetric, from the centre to the edges.
    let c0 = IslandGlass.fadeSweepCentres(phase: 0), c1 = IslandGlass.fadeSweepCentres(phase: 1)
    check(c0.left == 0.5 && c0.right == 0.5, "starts together at the centre")
    check(c1.left == 0 && c1.right == 1, "ends at both edges, past the corners")
    var symmetric = true, parting = true, prevGap = -1.0
    for i in 0...100 {
        let c = IslandGlass.fadeSweepCentres(phase: Double(i) / 100)
        if !near(c.left, 1 - c.right, 1e-12) { symmetric = false }
        if c.right - c.left < prevGap { parting = false }
        prevGap = c.right - c.left
        let m = IslandGlass.fadeSweepMask(phase: Double(i) / 100)
        for (a, b) in zip(m, m.reversed()) where !near(a.alpha, b.alpha, 1e-9) { symmetric = false }
    }
    check(symmetric, "mirror images, centres and mask")
    check(parting, "the highlights only move apart")
    let m = IslandGlass.fadeSweepMask(phase: 0.5)
    check(m.first!.location == 0 && m.last!.location == 1 && m.count == IslandGlass.fadeSweepMaskSamples + 1, "mask stops span the panel")
    check(m.allSatisfy { (0...1).contains($0.alpha) }, "mask alphas in range")
    check(m.first { near($0.location, 0.25) }!.alpha > 0.99 && m.first { near($0.location, 0.5) }!.alpha < 0.01,
          "half way: lit a quarter of the way in, dark at the centre")
    // In from nothing, out to nothing: no pop at either end.
    check(IslandGlass.fadeSweepEnvelope(phase: 0) == 0 && IslandGlass.fadeSweepEnvelope(phase: 1) == 0, "no light at the start or end")
    check(IslandGlass.fadeSweepEnvelope(phase: 0.3) == 1, "full through the middle of the run")
    var envStep = 0.0, prevEnv = 0.0
    for i in 0...1000 { let v = IslandGlass.fadeSweepEnvelope(phase: Double(i) / 1000); envStep = max(envStep, abs(v - prevEnv)); prevEnv = v }
    check(envStep < 0.02, "the envelope has no step", "\(envStep)")
    check(IslandGlass.fadeSweepAlpha <= 1 && IslandGlass.fadeSweepHazeAlpha <= 0.5, "bright, not blinding")
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

print("prism: the shade")
do {
    let notch: CGFloat = 32
    let band = IslandGlass.fadeBand(notchHeight: notch)
    // The standard panel and the tallest, each with Prism's lip under it.
    for height in [CGFloat(146) + IslandPrism.lip, 230 + IslandPrism.lip] {
        func a(_ y: CGFloat) -> Double { IslandPrism.shadeAlpha(y: y, height: height, band: band) }
        let horizon = height - IslandPrism.lip
        let top = horizon - IslandPrism.horizonFeather / 2, bottom = horizon + IslandPrism.horizonFeather / 2
        check(a(0) == 1 && a(band) == 1, "solid black over the housing and to the band's foot (\(Int(height)))")
        check(near(a(top), IslandPrism.edgeTint), "the edge tint by the top of the horizon")
        check(near(a(horizon), (IslandPrism.edgeTint + IslandPrism.lipTint) / 2), "half cleared on the horizon")
        check(near(a(bottom), IslandPrism.lipTint) && near(a(height), IslandPrism.lipTint), "the lip's tint from the horizon's foot to the bottom edge")
        var falling = true
        var y = band
        while y < height { if a(y + 1) > a(y) + 1e-12 { falling = false }; y += 1 }
        check(falling, "never darkens on the way down")
    }
    check(IslandPrism.lipTint < IslandPrism.edgeTint && IslandPrism.edgeTint < IslandPrism.contentAlpha, "lip lighter than the walls, walls lighter than behind the content")
    check(near(IslandPrism.contentAlpha, 1 - (1 - IslandPrism.edgeTint) * (1 - IslandPrism.scrim)), "content: the shade and the scrim composited")
    check(IslandPrism.horizonFeather / 2 <= IslandPrism.lip, "the horizon's lower half fits in the lip")
    let stops = IslandPrism.shadeStops()
    check(stops.first!.location == 0 && near(stops.first!.alpha, 1) && stops.last!.location == 1 && near(stops.last!.alpha, IslandPrism.edgeTint),
          "shade stops: black at the band's foot, the edge tint at the horizon")
    check(zip(stops, stops.dropFirst()).allSatisfy { $0.location < $1.location }, "shade stops ascend")
    let h = IslandPrism.horizonStops()
    check(near(h.first!.alpha, IslandPrism.edgeTint) && near(h.last!.alpha, IslandPrism.lipTint), "horizon stops: edge tint to lip tint")
}

/// Whether the line (or the crystal's sheets) goes below its rest as well as above.
let ribbonSigned = IslandPrism.ribbonStyle == .crystal || IslandPrism.ribbonShape == .snake

// The ribbon's shape and style are one choice each (`IslandPrism.ribbonShape`,
// `ribbonStyle`); these are what that choice makes the resting and full
// half-heights and the full lift.
let ribbonRest: Double = {
    switch IslandPrism.ribbonStyle {
    case .light: return IslandPrism.restSpread
    case .crystal: return IslandPrism.crystalRest
    case .twist: return IslandPrism.twistRest
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
    // The twist stays on its line. The crystal doesn't lift either; its
    // sheets sway by this much instead.
    if IslandPrism.ribbonStyle == .twist { return 0 }
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
    check(IslandPrism.bottomCornerRadius <= IslandPrism.lip + 8, "the bottom corners turn inside the lip and the content's bottom inset")
    check(IslandPrism.sideLip > 0 && IslandPrism.rim > IslandPrism.rimFeather, "a border of clear glass down each wall, wider than its soft edge")
    // The content starts 22pt inside the frame in every mode, plus the side lip here; the walls stand 12pt in.
    check(IslandPrism.rim + IslandPrism.rimFeather <= 22 + IslandPrism.sideLip - IslandMotion.openCorners.top + 2,
          "the frost is full by where the content starts", "\(IslandPrism.rim + IslandPrism.rimFeather)")
    check(IslandPrism.ribbonCentre > 0 && IslandPrism.ribbonCentre < IslandPrism.lip, "the ribbon's resting line is in the lip")
    check(IslandPrism.ribbonCentre - ribbonRest > 0, "the resting ribbon stays above the bottom edge")
    check(IslandPrism.ribbonCentre - ribbonLift - ribbonFull > 0 || IslandPrism.ribbonShape == .up, "a full crest's lower edge is above the bottom edge, whichever way it goes")
    check(IslandPrism.ribbonCentre + (IslandPrism.ribbonShape == .up ? ribbonLift : 0) - ribbonFull > 0, "and a rising crest's too")
    check(IslandPrism.ribbonCentre + ribbonLift + ribbonFull < IslandPrism.ribbonStrip, "its upper edge is inside the strip")
    check(ribbonFull > ribbonRest * 2, "a full band is plainly more than rest")
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

print("prism: the reflection")
do {
    check(near(IslandPrism.reflectionAlpha(x: 0), 1) && near(IslandPrism.reflectionAlpha(x: 1), 1), "full in both bottom corners")
    check(near(IslandPrism.reflectionAlpha(x: 0.5), IslandPrism.reflectionFloor), "its floor along the bottom between them")
    check(near(IslandPrism.reflectionAlpha(x: IslandPrism.reflectionCornerSpan), IslandPrism.reflectionFloor)
          && near(IslandPrism.reflectionAlpha(x: 1 - IslandPrism.reflectionCornerSpan), IslandPrism.reflectionFloor), "a corner's share ends at its span")
    var symmetric = true, falling = true
    for k in 0...200 {
        let x = Double(k) / 200
        if !near(IslandPrism.reflectionAlpha(x: x), IslandPrism.reflectionAlpha(x: 1 - x), 1e-12) { symmetric = false }
        if x < 0.5, IslandPrism.reflectionAlpha(x: x + 0.005) > IslandPrism.reflectionAlpha(x: x) + 1e-12 { falling = false }
    }
    check(symmetric, "the same in both corners")
    check(falling, "falls from a corner toward the middle, never rising again")
    check(IslandPrism.reflectionAlpha(x: -1) == IslandPrism.reflectionAlpha(x: 0) && IslandPrism.reflectionAlpha(x: 2) == IslandPrism.reflectionAlpha(x: 1), "clamps outside the panel")
    let stops = IslandPrism.reflectionStops()
    check(stops.first!.location == 0 && stops.last!.location == 1 && zip(stops, stops.dropFirst()).allSatisfy { $0.location < $1.location }, "stops span the panel, ascending")
    check(IslandPrism.reflectionFloor > 0 && IslandPrism.reflectionFloor < 0.6, "the bottom edge is lit, and plainly less than the corners")
    check(IslandPrism.reflectionInner < IslandPrism.reflectionEdge, "the inner line is fainter than the one on the outline")
    check(IslandPrism.reflectionInnerOffset * 2 < IslandPrism.reflectionBevelWidth, "and runs inside the soft band")
    check(IslandPrism.reflectionReach > IslandPrism.lip + IslandPrism.bottomCornerRadius / 2, "the reflection reaches past the lip, round the corners")
    check(IslandPrism.reflectionReach < 146 - 40, "and is gone before the band, on the standard panel")
}

print("prism: the twist")
do {
    // The twist's outline swells where the music is but doesn't break into crests.
    let pair = [0.0, 1, 1, 0, 0, 0]
    let spacing = IslandPrism.bandSpan / 2 / 5
    let between = IslandPrism.level(at: 0.5 + 1.5 * spacing, bands: pair, crest: IslandPrism.twistCrest)
    let on = IslandPrism.level(at: 0.5 + spacing, bands: pair, crest: IslandPrism.twistCrest)
    check(between >= on * 0.97, "two neighbouring bands are one swell, with no dip between", "\(between) vs \(on)")
    check(IslandPrism.level(at: 0.5, bands: [1, 0, 0, 0, 0, 0], crest: IslandPrism.twistCrest) > IslandPrism.level(at: 0.5 + 3 * spacing, bands: [1, 0, 0, 0, 0, 0], crest: IslandPrism.twistCrest) * 20,
          "and still where the music is: bass at the centre, not three bands out")
    check(IslandPrism.twistFull + 0.34 * IslandPrism.twistFull * 0.34 < Double(IslandPrism.ribbonCentre) || IslandPrism.twistFull * 1.06 < Double(IslandPrism.ribbonCentre),
          "a full lobe, with its axis riding up and down, stays above the bottom edge")
    check(IslandPrism.energy([]) == 0 && IslandPrism.energy([0, 0, 0]) == 0 && near(IslandPrism.energy([1, 1, 1]), 1) && near(IslandPrism.energy([0.5, 0, 1, 2]), 0.625),
          "energy: the bands' mean, each clamped to 0...1")
    check(IslandPrism.twistIdle > 0 && IslandPrism.twistSpeed > IslandPrism.twistIdle, "it turns a little whenever it moves, and faster the louder it is")
    check((IslandPrism.twistIdle + IslandPrism.twistSpeed) / (2 * .pi) < 1.2, "under about one turn a second at its fastest")
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

print("the colourful pick")
do {
    typealias RGB = VividPalette.RGB
    func hue(_ c: RGB) -> Double { VividPalette.hue(c) }
    func hueGap(_ a: Double, _ b: Double) -> Double { let d = abs(a - b); return min(d, 1 - d) }
    func chroma(_ c: RGB) -> Double { max(c.r, c.g, c.b) - min(c.r, c.g, c.b) }
    let beige = RGB(r: 0.78, g: 0.72, b: 0.62), red = RGB(r: 0.9, g: 0.1, b: 0.12), teal = RGB(r: 0.1, g: 0.75, b: 0.7)
    let navy = RGB(r: 0.05, g: 0.06, b: 0.2), grey = RGB(r: 0.5, g: 0.5, b: 0.5)
    func cover(_ parts: [(RGB, Int)]) -> [RGB] { parts.flatMap { Array(repeating: $0.0, count: $0.1) } }
    check(VividPalette.pick([]) == nil, "no pixels, no palette")
    check(VividPalette.pick(cover([(grey, 900), (RGB(r: 0.1, g: 0.1, b: 0.1), 124)])) == nil, "a black-and-white cover has none")
    // A small vivid subject on a large dull ground: the subject wins.
    let small = VividPalette.pick(cover([(beige, 900), (red, 60), (teal, 64)]))!
    check(hueGap(hue(small.primary), hue(red)) < 0.03 || hueGap(hue(small.primary), hue(teal)) < 0.03, "6% of a strong colour beats 88% of a dull one")
    let found = [small.primary, small.secondary, small.accent]
    check(found.contains { hueGap(hue($0), hue(red)) < 0.03 } && found.contains { hueGap(hue($0), hue(teal)) < 0.03 }, "both strong colours are in the palette")
    check(found.contains { hueGap(hue($0), hue(beige)) < 0.04 }, "and the ground is its third, not left out")
    // Dark doesn't outvote bright: a deep navy field and a bright accent.
    let dark = VividPalette.pick(cover([(navy, 800), (teal, 224)]))!
    check(hueGap(hue(dark.primary), hue(teal)) < 0.03, "a bright colour beats a larger dark one")
    // One colour: the others are its shades, never a new hue.
    let mono = VividPalette.pick(cover([(red, 500), (grey, 524)]))!
    check(hueGap(hue(mono.secondary), hue(red)) < 0.02 && hueGap(hue(mono.accent), hue(red)) < 0.02, "one hue on the cover: three shades of it")
    check(mono.secondary != mono.primary && mono.accent != mono.primary, "and three different shades")
    // The second colour is a different colour, not the first again.
    let near = VividPalette.pick(cover([(red, 400), (RGB(r: 0.9, g: 0.16, b: 0.1), 400), (teal, 224)]))!
    check(hueGap(hue(near.secondary), hue(red)) > 0.06, "two reds and a teal: the second colour is the teal")
    // Pastels are told apart when there's nothing stronger.
    let pink = RGB(r: 0.98, g: 0.86, b: 0.90), mint = RGB(r: 0.80, g: 0.95, b: 0.88), lilac = RGB(r: 0.86, g: 0.88, b: 0.99)
    let pastel = VividPalette.pick(cover([(pink, 400), (mint, 300), (lilac, 324)]))!
    let hues = [pastel.primary, pastel.secondary, pastel.accent].map(hue)
    check(hueGap(hues[0], hues[1]) > 0.08 && hueGap(hues[1], hues[2]) > 0.08 && hueGap(hues[0], hues[2]) > 0.08, "a pastel cover: its three hues, not one cream")
    // The same pixels in any order give the same palette.
    let pixels = cover([(beige, 300), (red, 200), (teal, 200), (navy, 324)])
    let a = VividPalette.pick(pixels)!, b = VividPalette.pick(pixels.reversed())!
    check(a.primary == b.primary || (abs(a.primary.r - b.primary.r) < 1e-9 && abs(a.primary.g - b.primary.g) < 1e-9), "order doesn't change the pick")
    check(chroma(a.primary) >= chroma(beige), "the pick is at least as colourful as the ground")
    let shade = VividPalette.shade(red, brightness: 0.5, saturation: 1)
    check(hueGap(hue(shade), hue(red)) < 1e-6 && max(shade.r, shade.g, shade.b) < 0.5, "a shade keeps its hue")
}

print("\n\(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
