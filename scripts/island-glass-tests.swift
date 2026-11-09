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
    let reach = IslandGlass.fadeReach
    let easeEnd = band + (height - band) * CGFloat(reach)
    check(reach >= 0.4 && reach <= 1, "the ease takes a good part of the way down", "\(reach)")
    check(near(a(band + (easeEnd - band) / 2), 1 - (1 - IslandGlass.fadeEndTint) / 2), "half way down the ease, half way to the end tint")
    check(near(a(easeEnd), IslandGlass.fadeEndTint) && near(a((easeEnd + height) / 2), IslandGlass.fadeEndTint),
          "past the ease's reach, the end tint all the way down")
    // Fade is clear glass: the shade's end is lighter than Glass's flat tint
    // over the frosted, so the rim reads as glass…
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

print("\n\(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
