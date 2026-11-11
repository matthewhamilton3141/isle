//
//  IslandPrism.swift
//
//  The numbers behind Prism (see `PanelBackground.prism`), kept free of
//  AppKit and SwiftUI so they compile on their own and can be checked
//  without an app (scripts/test-island-glass.sh):
//
//  - The lens's shape: the open panel is a lip taller than in every other
//    mode, and rounder at the bottom. The content keeps the room it has
//    everywhere else; the lip is glass with nothing on it but light.
//  - The shade: solid black over the camera housing, easing to a tint the
//    content can be read on, and clearing through the horizon — where the
//    content ends and the lip begins — to all but bare glass.
//  - The ribbon: a streak of light lying along the lip, split into a
//    fan of colours. At each point across the panel the line is lifted,
//    and the fan spread, by the music's level in one band — a crest for
//    each band, bass at the centre, treble toward the tips, mirrored — so
//    the streak is the waveform. Silent, it's a thin white line with
//    colour only at its fringes.
//  - What moves it when it isn't the music: Claude's status, as a wave, a
//    breath or a single crest.
//  - Its colours: the spectrum, or a fan made from a cover's colours or a
//    status's.
//
//  The drawing is in IslandPrism+SwiftUI.swift and PrismRibbonView.swift.
//

import CoreGraphics
import Foundation

enum IslandPrism {
    // MARK: - The lens's shape

    /// How much taller the open panel is in Prism: clear glass below the
    /// content, where the ribbon lies. Tune here.
    static let lip: CGFloat = 34

    /// How much wider the open panel is in Prism, each side: with `rim`,
    /// room for a border of clear glass down both walls, so the frosted
    /// part that holds the content sits inside a frame of lens rather than
    /// running wall to wall with glass only under it. The content keeps
    /// its width. Tune here.
    static let sideLip: CGFloat = 12

    /// How far inside each wall the frost (and the scrim) begins, and the
    /// softness of that edge, in points: the walls' border of clear glass.
    static let rim: CGFloat = 17
    static let rimFeather: CGFloat = 6

    /// The open panel's bottom corners in Prism: rounder than the other
    /// modes' 22, so the lip reads as the thick edge of a lens. Tune here.
    static let bottomCornerRadius: CGFloat = 38

    // MARK: - The shade

    /// Black over the glass across the panel's whole width once the ease
    /// from the band has run: what the glass at the side walls keeps.
    /// Light: the frost under it is the system's dark glass and does most
    /// of the darkening on its own. Tune here.
    static let edgeTint: Double = 0.06

    /// Black laid behind the content on top of that, inset from the walls
    /// with a soft edge, so text sits on `contentAlpha` while the walls stay
    /// lighter glass. The glass under it is frosted there (`PrismFrost`),
    /// so this only has to darken, not hide. Tune here.
    static let scrim: Double = 0.12

    /// How much of the frost is laid over the lens behind the content, 0
    /// (bare lens: what's behind is sharp) to 1 (fully frosted). Anything
    /// short of full lets a document's text ghost through the controls.
    static let frost: Double = 1

    /// How far below the camera housing the solid black runs before the
    /// ease to glass begins, in points: just past the hardware's edge. The
    /// panel is meant to read as glass from there down, not as a black
    /// panel with a glass lip.
    static let bandExtra: CGFloat = 3

    /// Which way the ribbon is drawn.
    enum RibbonStyle {
        /// Light: a streak split into a fan of colours.
        case light
        /// Glass: the waveform as three thin sheets of it, overlapping and
        /// swaying across one another like a twisted ribbon — each clear
        /// and dark through its middle, its colours gathered along its
        /// edges the way a film of oil carries them, a hairline of light
        /// on each edge, and a glow under the whole where the light comes
        /// out.
        case crystal
        /// A ribbon of light, twisted along its length and seen from the
        /// side: where it faces you it is a wide bright lobe, where it
        /// turns edge-on it draws to a point, and the lobes cross. One
        /// edge of each lobe is crisp and the other melts away; a soft
        /// bloom lies round the whole. The light is split into the fan's
        /// three colours, a little apart in depth, so where the ribbon is
        /// wide or turning it comes apart into them and reads as thick.
        /// The music opens the ribbon along its length and turns it.
        case twist
    }

    static let ribbonStyle: RibbonStyle = .twist

    /// The twist's half-width at rest and at a full level, in points, and
    /// how wide each band's share of it is, in band spacings: wider than
    /// the spacing, so the ribbon swells where the music is without
    /// breaking into separate crests. Tune here.
    static let twistRest: Double = 1.5
    static let twistFull: Double = 12.5
    static let twistCrest: Double = 1.05

    /// How many turns the ribbon makes along its length.
    static let twistTurns: Double = 1.15

    /// How fast the ribbon turns, in radians a second: this much whenever
    /// something is moving it, and this much more at a full level. Silent,
    /// it doesn't turn at all, so a ribbon at rest draws nothing.
    static let twistIdle: Double = 0.7
    static let twistSpeed: Double = 5.5

    /// Black left over the lip: all but bare glass. It lies over the ribbon
    /// too, which is in the glass under it, so what the ribbon needs to
    /// shine against over a white window is its own bed of shade
    /// (`ribbonBed`), not this. Tune here.
    static let lipTint: Double = 0.05

    /// The horizon: how many points the shade takes to clear from the
    /// content's tint to the lip's, centred on the line where the content's
    /// bottom inset ends and the lip begins.
    static let horizonFeather: CGFloat = 18

    /// How much of the way from the band's foot to the horizon the ease
    /// from solid black takes; past it the shade is `edgeTint` down to the
    /// horizon.
    static let reach: Double = 0.3

    /// Black over the glass where the content sits: the shade and the
    /// scrim composited.
    static var contentAlpha: Double { IslandGlass.over(edgeTint, scrim) }

    /// The shade's black at `y` points from the top of a panel `height`
    /// tall (lip included) whose solid band is `band` deep, without the
    /// scrim: 1 down to the band's foot, eased to `edgeTint`, held to the
    /// horizon, and cleared to `lipTint` across it.
    static func shadeAlpha(y: CGFloat, height: CGFloat, band: CGFloat) -> Double {
        guard y > band else { return 1 }
        let horizonTop = height - lip - horizonFeather / 2
        let horizonBottom = height - lip + horizonFeather / 2
        if y >= horizonBottom { return lipTint }
        if y > horizonTop {
            let t = Double((y - horizonTop) / horizonFeather)
            return edgeTint + (lipTint - edgeTint) * IslandGlass.fadeEase(t)
        }
        let span = horizonTop - band
        guard span > 0 else { return 1 }
        return 1 - (1 - edgeTint) * IslandGlass.fadeEase(Double((y - band) / span) / reach)
    }

    /// The ease below the band as (location, alpha) stops, location 0 at
    /// the band's foot and 1 at the top of the horizon.
    static func shadeStops() -> [(location: Double, alpha: Double)] {
        let n = IslandGlass.fadeStopCount
        let ease = (0...n).map {
            let t = Double($0) / Double(n)
            return (t * reach, 1 - (1 - edgeTint) * IslandGlass.fadeEase(t))
        }
        return reach < 1 ? ease + [(1, edgeTint)] : ease
    }

    /// The horizon as (location, alpha) stops, top to bottom.
    static func horizonStops() -> [(location: Double, alpha: Double)] {
        let n = 8
        return (0...n).map {
            let t = Double($0) / Double(n)
            return (t, edgeTint + (lipTint - edgeTint) * IslandGlass.fadeEase(t))
        }
    }

    // MARK: - The ribbon

    /// The strip the ribbon is drawn in, measured up from the panel's
    /// bottom edge: the lip, and room above it for a loud band's crest to
    /// rise behind the content's bottom inset.
    static let ribbonStrip: CGFloat = 58

    /// The ribbon's line at rest, in points above the panel's bottom edge:
    /// the lip's middle, where the lens is at its clearest and the rim's
    /// own highlight doesn't crowd it.
    static let ribbonCentre: CGFloat = 17

    /// How far in from the glass's side walls the ribbon's tips sit.
    static let ribbonInset: CGFloat = 58

    /// How far a full level lifts the line off its rest, in points: the
    /// line is the waveform, a crest for each band, and the fan below is
    /// what rides on it. Tune here.
    static let fullLift: Double = 12

    /// The fan at rest and at a full level, in points either side of the
    /// line: the spectrum's first colour at the top of it, its last at the
    /// bottom. At rest the colours all but coincide and the streak is
    /// white; a loud band spreads them. Tune here.
    static let restSpread: Double = 1.1
    static let fullSpread: Double = 8.5

    /// Each colour's own softness, as a Gaussian's width in points: at
    /// rest, and what a point of spread adds.
    static let restSigma: Double = 1.05
    static let sigmaPerSpread: Double = 0.2

    /// The streak's brightness at rest, as a fraction of its brightness at
    /// a full level: a lens catching a little light, not a lamp. Tune here.
    static let restGlow: Double = 0.5

    /// How much of its own light the ribbon covers what's under it with, 0
    /// (pure added light, invisible over white) to 1, and the shade it
    /// lies on at full brightness, as black's alpha. Tune here.
    static let ribbonCover: Double = 1.0
    static let ribbonBed: Double = 0.7

    /// How many points across the panel the profile is sampled at for the
    /// drawing. The shader interpolates between them.
    static let ribbonColumns = 96

    /// How much of the way from the centre to a tip the bands are laid
    /// over: bass at the centre, the top band here, and the rest of the
    /// way out only the taper. Well short of the tip, so the top bands
    /// crest where the streak is still near its full strength rather than
    /// in its point.
    static let bandSpan: Double = 0.74

    /// How wide each band's crest is, as a Gaussian's width in band
    /// spacings. Narrower than the spacing, so neighbouring bands are
    /// separate crests with a dip between them and each moves on its own;
    /// laid edge to edge they ran together into one slow swell. Tune here.
    static let crestWidth: Double = 0.46

    /// A level's shape before it is drawn: quiet bands are lifted (the
    /// capture's levels are scaled for bars an island tall, and a ribbon a
    /// few points deep needs more of the low end). Tune here.
    static let levelGamma: Double = 0.72

    /// 0 at the ribbon's centre, 1 at either tip, for `u` 0...1 across it.
    static func mirrored(_ u: Double) -> Double {
        abs(2 * min(max(u, 0), 1) - 1)
    }

    /// The streak's taper: 1 at the centre, 0 at the tips — full for most
    /// of its length and drawn to a point.
    static func taper(_ u: Double) -> Double {
        let m = mirrored(u)
        return pow(1 - pow(m, 4), 1.3)
    }

    /// The level at `u` across the ribbon, from `bands` (0...1 each, bass
    /// first): a crest for each band, laid from the centre outward and
    /// mirrored, the highest of them at each point (their soft maximum, so
    /// the dips between crests have no corner). No bands is silence.
    static func level(at u: Double, bands: [Double], crest: Double = crestWidth) -> Double {
        guard !bands.isEmpty else { return 0 }
        let p = mirrored(u) / bandSpan * Double(max(bands.count - 1, 1))
        // Sum of the fourth powers, fourth-rooted: near the maximum where
        // one crest dominates, smooth where two meet.
        var sum = 0.0
        for (i, band) in bands.enumerated() {
            let d = (p - Double(i)) / crest
            let crest = pow(min(max(band, 0), 1), levelGamma) * exp(-d * d / 2)
            sum += crest * crest * crest * crest
        }
        return min(pow(sum, 0.25), 1)
    }

    /// Which way the waveform goes from its resting line.
    enum RibbonShape {
        /// Crests rise: the line is lifted by the level, the fan on it.
        case up
        /// Both ways at once: the line stays put and the fan opens above
        /// and below it by the level, a waveform's mirrored outline.
        case mirrored
        /// Both ways in turn: the line snakes, one band's crest above the
        /// rest line and the next band's below.
        case snake
    }

    static let ribbonShape: RibbonShape = .mirrored

    /// The mirrored shape's fan at a full level, and the snake's lift and
    /// fan, in points. Each keeps a full crest inside the lip.
    static let mirroredSpread: Double = 11
    static let snakeLift: Double = 9
    static let snakeSpread: Double = 4.5

    /// The level at `u` with each band's crest counted up or down in turn
    /// (the centre band up), for the snake: -1...1.
    static func signedLevel(at u: Double, bands: [Double]) -> Double {
        guard !bands.isEmpty else { return 0 }
        let p = mirrored(u) / bandSpan * Double(max(bands.count - 1, 1))
        var sum = 0.0
        for (i, band) in bands.enumerated() {
            let d = (p - Double(i)) / crestWidth
            sum += (i % 2 == 0 ? 1 : -1) * pow(min(max(band, 0), 1), levelGamma) * exp(-d * d / 2)
        }
        return min(max(sum, -1), 1)
    }

    /// How far the line is lifted off its rest at `u`, in points.
    static func lift(at u: Double, bands: [Double]) -> Double {
        // The twist stays on its line; its turning is what moves.
        if ribbonStyle == .twist { return 0 }
        // The crystal doesn't lift: this is its sheets' sway instead.
        if ribbonStyle == .crystal { return taper(u) * crystalSway * signedLevel(at: u, bands: bands) }
        switch ribbonShape {
        case .up: return taper(u) * fullLift * level(at: u, bands: bands)
        case .mirrored: return 0
        case .snake: return taper(u) * snakeLift * signedLevel(at: u, bands: bands)
        }
    }

    /// The fan's half-height at `u`, in points.
    static func spread(at u: Double, bands: [Double]) -> Double {
        if ribbonStyle == .twist {
            return taper(u) * (twistRest + (twistFull - twistRest) * level(at: u, bands: bands, crest: twistCrest))
        }
        var full: Double
        switch ribbonShape {
        case .up: full = fullSpread
        case .mirrored: full = mirroredSpread
        case .snake: full = snakeSpread
        }
        // The crystal is always the mirrored outline: sheets of glass
        // opening above and below the line.
        if ribbonStyle == .crystal { full = mirroredSpread }
        let rest = ribbonStyle == .crystal ? crystalRest : restSpread
        return taper(u) * (rest + (full - rest) * level(at: u, bands: bands))
    }

    /// The crystal's half-thickness at rest, in points: a slim rod of
    /// glass, where the light style rests as a hairline.
    static let crystalRest: Double = 2.3

    /// How far the crystal's sheets sway apart at a full level, in points:
    /// one up and one down, by turns from band to band, so their edges
    /// cross and the ribbon looks twisted rather than stacked.
    static let crystalSway: Double = 3

    /// How much is going on across the bands, 0...1: what turns the twist.
    static func energy(_ bands: [Double]) -> Double {
        guard !bands.isEmpty else { return 0 }
        return min(max(bands.reduce(0) { $0 + min(max($1, 0), 1) } / Double(bands.count), 0), 1)
    }

    /// The streak's brightness at `u`, 0...1.
    static func glow(at u: Double, bands: [Double]) -> Double {
        let lift = min(level(at: u, bands: bands, crest: ribbonStyle == .twist ? twistCrest : crestWidth) * 1.25, 1)
        return pow(taper(u), 0.6) * (restGlow + (1 - restGlow) * lift)
    }

    /// The profile the drawing takes: the line's lift, the fan's spread
    /// and the brightness at `ribbonColumns` points across the ribbon.
    static func profile(bands: [Double]) -> (lift: [Float], spread: [Float], glow: [Float]) {
        var l = [Float](repeating: 0, count: ribbonColumns)
        var s = [Float](repeating: 0, count: ribbonColumns)
        var g = [Float](repeating: 0, count: ribbonColumns)
        for k in 0..<ribbonColumns {
            let u = Double(k) / Double(ribbonColumns - 1)
            l[k] = Float(lift(at: u, bands: bands))
            s[k] = Float(spread(at: u, bands: bands))
            g[k] = Float(glow(at: u, bands: bands))
        }
        return (l, s, g)
    }

    // MARK: - The ribbon's motion

    /// How fast a band follows the music up and lets go of it, as time
    /// constants in seconds. The capture publishes about thirty levels a
    /// second, already smoothed for six bars; this only carries them
    /// between publishes at the display's rate, so it is quick — any
    /// slower and a beat reads as a swell. Tune here.
    static let attack: Double = 0.028
    static let release: Double = 0.095

    /// A band's next value, `dt` seconds on, on its way to `target`.
    static func follow(_ value: Double, toward target: Double, dt: Double) -> Double {
        let tau = target > value ? attack : release
        guard dt > 0, tau > 0 else { return value }
        return value + (target - value) * (1 - exp(-dt / tau))
    }

    /// Closer than this to their targets, the bands are there: the ribbon
    /// stops drawing until something changes.
    static let settled: Double = 0.002

    /// What moves the ribbon.
    enum Motion: Equatable {
        /// The music: the capture's levels, or the bars' own pattern when
        /// the waveform is set to Animated.
        case music
        /// Claude is working: a low wave running from the centre out to
        /// the tips, over and over.
        case working
        /// Claude needs an answer — an approval, a question: the whole
        /// ribbon swelling and ebbing, slowly, like a breath held.
        case attention
        /// Claude has finished: one crest running from the centre out to
        /// the tips, then the resting streak.
        case done
        /// Something to notice that isn't moving — an error: the streak a
        /// little fuller than at rest, still.
        case steady
        /// Nothing to show: the resting streak.
        case rest
    }

    /// The bands `motion` asks for, `t` seconds after it began. `music` has
    /// none of its own here (its levels are the capture's); with
    /// `reduceMotion` the moving ones hold a still shape instead.
    static func pattern(_ motion: Motion, band: Int, at t: Double, reduceMotion: Bool = false) -> Double {
        switch motion {
        case .music, .rest:
            return 0
        case .working:
            if reduceMotion { return 0.22 }
            // A crest every `workingPeriod`, a band's width behind for each
            // band out from the centre.
            let phase = 2 * Double.pi * (t / workingPeriod - Double(band) / 5)
            return 0.1 + 0.34 * pow((1 + cos(phase)) / 2, 2)
        case .attention:
            if reduceMotion { return 0.34 }
            let breath = (1 - cos(2 * Double.pi * t / attentionPeriod)) / 2
            return (0.12 + 0.4 * breath) * (1 - 0.1 * Double(band))
        case .done:
            if reduceMotion { return 0 }
            // One crest leaving the centre `doneDelay` in, reaching the
            // last band `doneRun` later, each band up and down as it passes.
            let run = t - doneDelay
            guard run > 0 else { return 0 }
            let at = run / doneRun * 5 - Double(band)
            return 0.75 * exp(-at * at / 0.9) * max(0, 1 - run / (doneRun * 1.6))
        case .steady:
            return 0.14
        }
    }

    /// The working wave's period, the attention breath's, and how long the
    /// done crest takes to run out to the tips, in seconds. Tune here.
    static let workingPeriod: Double = 1.9
    static let attentionPeriod: Double = 2.4
    static let doneRun: Double = 0.8

    /// How long the done crest waits before it leaves the centre. A motion
    /// begins as the panel opens, and the glass is under black for the
    /// first part of the open: started at once, the crest was half way out
    /// before there was anything to see it on.
    static let doneDelay: Double = 0.35

    /// Whether `motion` is still moving `t` seconds after it began — the
    /// ribbon draws frames only while this holds (or a band hasn't
    /// settled). `music` is the caller's to judge.
    static func isMoving(_ motion: Motion, at t: Double, reduceMotion: Bool = false) -> Bool {
        switch motion {
        case .working, .attention: return !reduceMotion
        case .done: return !reduceMotion && t < doneDelay + doneRun * 1.6
        case .music, .steady, .rest: return false
        }
    }

    /// The pattern when the waveform is set to Animated (no capture), or
    /// the capture has nothing to say: each band its own slow sine, the
    /// frequencies the bars use so the two never disagree about the beat
    /// they aren't following. `t` in seconds.
    static func procedural(band: Int, at t: Double) -> Double {
        let frequencies: [Double] = [1.00, 1.37, 0.83, 1.61, 1.13, 0.71]
        let phases: [Double] = [0.0, 0.9, 1.8, 0.45, 2.3, 1.35]
        let f = frequencies[band % frequencies.count], p = phases[band % phases.count]
        return 0.18 + (sin(t * f * 3.1 + p) + 1) / 2 * 0.62
    }

    // MARK: - The ribbon's colours

    /// A colour as sRGB, each channel 0...1.
    struct RGB: Equatable {
        var r: Double
        var g: Double
        var b: Double
    }

    /// How many colours the fan is drawn through, top to bottom.
    static let stopCount = 8

    /// The ribbon with nothing to take its colours from: the spectrum,
    /// red uppermost to violet, lighter and less green than a true rainbow.
    static let spectrum: [RGB] = [
        RGB(r: 1.00, g: 0.16, b: 0.20),
        RGB(r: 1.00, g: 0.45, b: 0.10),
        RGB(r: 1.00, g: 0.80, b: 0.22),
        RGB(r: 0.62, g: 1.00, b: 0.55),
        RGB(r: 0.18, g: 0.90, b: 1.00),
        RGB(r: 0.20, g: 0.48, b: 1.00),
        RGB(r: 0.50, g: 0.28, b: 1.00),
        RGB(r: 0.95, g: 0.30, b: 0.90),
    ]

    static func hsb(_ c: RGB) -> IslandGlass.HSB {
        let mx = max(c.r, c.g, c.b), mn = min(c.r, c.g, c.b), d = mx - mn
        var h = 0.0
        if d > 0 {
            if mx == c.r { h = ((c.g - c.b) / d).truncatingRemainder(dividingBy: 6) }
            else if mx == c.g { h = (c.b - c.r) / d + 2 }
            else { h = (c.r - c.g) / d + 4 }
            h /= 6
            if h < 0 { h += 1 }
        }
        return IslandGlass.HSB(h: h, s: mx > 0 ? d / mx : 0, b: mx)
    }

    static func rgb(_ c: IslandGlass.HSB) -> RGB {
        let v = IslandGlass.rgb(c)
        return RGB(r: v.r, g: v.g, b: v.b)
    }

    /// A colour as the ribbon's light: its hue kept, bright, and — if it
    /// has a hue at all — at least `lightMinSaturation` saturated, so a
    /// dark or dusty colour still throws light of its own colour. Greys
    /// stay grey: silver light, not a hue made up from noise.
    static func light(_ c: RGB) -> IslandGlass.HSB {
        let v = hsb(c)
        let hued = IslandGlass.smoothstep(0.06, 0.18, v.s)
        return IslandGlass.HSB(h: v.h, s: max(v.s, lightMinSaturation * hued), b: max(v.b, lightMinBrightness))
    }

    static let lightMinSaturation: Double = 0.62
    static let lightMinBrightness: Double = 0.95

    /// How far apart, as a fraction of the colour wheel, the fan's two
    /// ends are held when the colours it's given are closer than that: a
    /// prism splits even one colour a little.
    static let minHueFan: Double = 0.07

    /// The fan's colours from up to three of a cover's (or an accent's):
    /// each as light, ordered round the colour wheel the short way from the
    /// first, so neighbours in the fan are neighbours in hue, then laid
    /// top to bottom with a paler tip above the first and a deeper one
    /// below the last. Colours closer in hue than `minHueFan` are fanned
    /// out to it. No colours is the spectrum.
    static func stops(from colors: [RGB]) -> [RGB] {
        guard !colors.isEmpty else { return spectrum }
        let lit = colors.prefix(3).map(light)
        let base = lit[0].h
        // Each hue as an offset from the first's, -0.5...0.5, ascending.
        var keyed = lit.map { c -> (offset: Double, color: IslandGlass.HSB) in
            var d = c.h - base
            if d > 0.5 { d -= 1 }
            if d < -0.5 { d += 1 }
            return (c.s < 0.06 ? 0 : d, c)
        }
        keyed.sort { $0.offset < $1.offset }
        var lo = keyed.first!.offset, hi = keyed.last!.offset
        if hi - lo < minHueFan {
            let mid = (lo + hi) / 2
            lo = mid - minHueFan / 2
            hi = mid + minHueFan / 2
            if keyed.count == 1 { keyed = [keyed[0], keyed[0]] }
            keyed[0].offset = lo
            keyed[keyed.count - 1].offset = hi
        }
        func color(_ k: (offset: Double, color: IslandGlass.HSB)) -> IslandGlass.HSB {
            var h = base + k.offset
            h -= h.rounded(.down)
            return IslandGlass.HSB(h: h, s: k.color.s, b: k.color.b)
        }
        let top = color(keyed.first!), bottom = color(keyed.last!)
        // Keys along the fan: a paler tip, the colours, a deeper tip.
        var keys: [(at: Double, color: RGB)] = [(0, rgb(IslandGlass.HSB(h: top.h, s: top.s * 0.55, b: 1)))]
        for (i, k) in keyed.enumerated() {
            let at = keyed.count == 1 ? 0.5 : 0.16 + 0.68 * Double(i) / Double(keyed.count - 1)
            keys.append((at, rgb(color(k))))
        }
        keys.append((1, rgb(IslandGlass.HSB(h: bottom.h, s: min(1, bottom.s * 1.15), b: bottom.b * 0.82))))
        return (0..<stopCount).map { n in
            let t = Double(n) / Double(stopCount - 1)
            let j = max(1, keys.firstIndex { $0.at >= t } ?? keys.count - 1)
            let a = keys[j - 1], b = keys[j]
            let f = b.at > a.at ? (t - a.at) / (b.at - a.at) : 0
            return RGB(r: a.color.r + (b.color.r - a.color.r) * f,
                       g: a.color.g + (b.color.g - a.color.g) * f,
                       b: a.color.b + (b.color.b - a.color.b) * f)
        }
    }

    /// How long the ribbon takes to turn from one set of colours to the
    /// next, as a time constant in seconds.
    static let colorTurn: Double = 0.18
}
