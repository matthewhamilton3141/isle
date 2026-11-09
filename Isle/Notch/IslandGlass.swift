//
//  IslandGlass.swift
//
//  The numbers behind the glass panel backgrounds (see `PanelBackground`),
//  kept free of AppKit and SwiftUI so they compile on their own and can be
//  checked without an app (scripts/test-island-glass.sh):
//
//  - The blend. The pill is black in every mode, so opening crossfades the
//    fill from black to glass and closing back again, on the open's progress:
//    `blackCover` is how much black still lies over the glass.
//  - The notch glow (a setting of its own, over either glass): black that
//    grows out of the physical camera housing, solid over it and fading
//    outward, wider sideways than down.
//  - The tints laid over the system material, one per mode.
//  - Fade's shade: solid black over a band as deep as the notch and a little
//    more, then easing to a light tint at the panel's bottom edge, over the
//    clear glass rather than the frosted.
//  - Fade's lens: a soft dark scrim behind the content that leaves a rim of
//    lighter glass round the sides and bottom, a specular line on that rim,
//    and a thin band of spectral light along the bottom edge — in the
//    current cover's colours while a track is up.
//  - The legibility lifts for content on glass: secondary text a little
//    brighter, artwork colours held above a lightness floor.
//
//  The drawing is in IslandGlass+SwiftUI.swift.
//

import CoreGraphics
import Foundation

enum IslandGlass {
    // MARK: - Tints

    /// Black laid over the material in `.glass`. Light:
    /// the dark system material already pulls bright windows down, and this
    /// only steadies it. Tune here.
    static let glassTint: Double = 0.25

    /// Black laid over the material in `.smoked`. The mockups' smoked look
    /// was black at ~48% over the blur. Tune here.
    static let smokedTint: Double = 0.48

    static func tint(for background: PanelBackground) -> Double {
        switch background {
        case .black: return 0
        case .glass: return glassTint
        case .smoked: return smokedTint
        case .fade: return fadeEndTint
        }
    }

    // MARK: - Fade

    /// How far below the camera housing (or, on a display without one, the
    /// band the panel's content starts under) Fade stays solid black, in
    /// points. The open panel's first row of content starts 2pt under the
    /// housing, so its top sits on black too, and the menu bar's hairline
    /// below the housing never shows a glass seam. Tune here.
    static let fadeBandExtra: CGFloat = 8

    /// Black left over the glass at the panel's bottom edge, where the fade
    /// ends, across the panel's full width: what the rim sees. Fade is drawn
    /// on the clear glass, which is lighter than the frosted under Glass and
    /// Smoked, but light is the point here: the rim is where the glass
    /// should read as glass. The content gets its darkness from the scrim
    /// on top (`fadeScrim`). Tune here.
    static let fadeEndTint: Double = 0.14

    /// The solid band's depth for a camera housing (or content band)
    /// `notchHeight` tall.
    static func fadeBand(notchHeight: CGFloat) -> CGFloat {
        max(notchHeight, 0) + fadeBandExtra
    }

    /// How much of the way from the band's foot to the bottom edge the ease
    /// takes, as a fraction: past it the shade is the end tint all the way
    /// down. Half, so the lower half of the panel is plainly glass rather
    /// than still on its way there; the content keeps its dark from the
    /// scrim. Tune here.
    static let fadeReach: Double = 0.5

    /// The ease from the band to the end tint, `t` 0 at the band's foot
    /// and 1 where it ends (`fadeReach` of the way down): smoothstep, so it
    /// leaves the band and arrives at the end tint with no slope — no
    /// visible edge at either end.
    static func fadeEase(_ t: Double) -> Double {
        let u = min(max(t, 0), 1)
        return u * u * (3 - 2 * u)
    }

    /// Fade's black at `y` points from the top of a panel `height` tall
    /// whose solid band is `band` deep: 1 down to the band's foot, then
    /// eased to `fadeEndTint` `fadeReach` of the way to the bottom edge, and
    /// that from there down. Measured against the panel's current height, so
    /// it follows the outline as it grows and shrinks rather than being
    /// stretched from a fixed one.
    static func fadeAlpha(y: CGFloat, height: CGFloat, band: CGFloat) -> Double {
        guard y > band else { return 1 }
        let span = height - band
        guard span > 0 else { return 1 }
        return 1 - (1 - fadeEndTint) * fadeEase(Double((y - band) / span) / fadeReach)
    }

    /// Stops sampled along the ease, for the gradient that draws it below
    /// the band: enough that the piecewise-linear gradient between them is
    /// within a fraction of a percent of the curve.
    static let fadeStopCount = 16

    /// The shade from the band's foot (location 0) to the bottom edge
    /// (location 1), as (location, black's alpha) stops: the ease sampled
    /// over its reach, then held at the end tint to the bottom.
    static func fadeStops() -> [(location: Double, alpha: Double)] {
        let ease = (0...fadeStopCount).map {
            let t = Double($0) / Double(fadeStopCount)
            return (t * fadeReach, 1 - (1 - fadeEndTint) * fadeEase(t))
        }
        return fadeReach < 1 ? ease + [(1, fadeEndTint)] : ease
    }

    // MARK: - Fade's lens

    /// Black laid behind the content, on top of the shade: a soft-edged
    /// panel inset from the glass's walls and bottom edge, so the content
    /// always sits on at least `fadeContentAlpha` black while a rim of
    /// lighter glass runs round it. Above, it disappears into the band.
    /// Tune here.
    static let fadeScrim: Double = 0.30

    /// How far inside the glass's side walls and bottom edge the scrim's
    /// edge sits, in points, before its feather. The walls are the open
    /// outline's flare radius in from the frame, and the content starts
    /// 10pt inside them: the scrim's edge is at the wall plus this, and is
    /// soft over `fadeScrimFeather` either side of it. Tune here.
    static let fadeScrimInset: CGFloat = 5

    /// The scrim's feather: the blur radius that softens its edge into the
    /// rim. Tune here.
    static let fadeScrimFeather: CGFloat = 5

    /// Black over the clear glass where the content sits, once the shade's
    /// ease has all but flattened: the shade's end tint and the scrim
    /// composited.
    static var fadeContentAlpha: Double { over(fadeEndTint, fadeScrim) }

    /// Black `a` with black `b` drawn over it, as one alpha.
    static func over(_ a: Double, _ b: Double) -> Double {
        1 - (1 - a) * (1 - b)
    }

    /// The specular rim: white drawn along the outline below the band,
    /// strongest at the bottom corners where a rounded edge catches the
    /// light, added to what's under it (plus-lighter). `fadeRimPeak` at the
    /// corners, `fadeRimFloor` along the bottom between them; it fades in
    /// up the walls from nothing at the band's foot. Tune here.
    static let fadeRimPeak: Double = 0.6
    static let fadeRimFloor: Double = 0.2

    /// The rim's stroke, centred on the outline and clipped to it, so half
    /// of it shows: a 1pt line.
    static let fadeRimWidth: CGFloat = 2

    /// The rim's brightness across the panel, `x` 0 at its left edge and 1
    /// at its right: the floor along the bottom, rising to the peak at each
    /// corner, smooth both ways.
    static func fadeRimAlpha(x: Double) -> Double {
        let u = min(max(x, 0), 1)
        // Distance into the corner zone at either end, 0...1.
        let edge = max(0, 1 - min(u, 1 - u) / fadeRimCornerSpan)
        return fadeRimFloor + (fadeRimPeak - fadeRimFloor) * fadeEase(edge)
    }

    /// How far in from each end, as a fraction of the panel's width, the
    /// rim stays brighter than its floor.
    static let fadeRimCornerSpan: Double = 0.16

    /// The rim's brightness as horizontal gradient stops.
    static func fadeRimStops() -> [(location: Double, alpha: Double)] {
        (0...fadeStopCount).map {
            let t = Double($0) / Double(fadeStopCount)
            return (t, fadeRimAlpha(x: t))
        }
    }

    /// The spectral glint: a thin band of split light along the bottom edge,
    /// as hues (0...1, red at 0) laid across the middle of the panel, cool
    /// on the left warming to the right, and nothing at either end where
    /// the white corners of the rim take over. Isle's own: no prism, no
    /// motion, just the colour a thick clear edge throws. Each stop is
    /// (location across the panel, hue, strength 0...1).
    static let fadeGlintStops: [(location: Double, hue: Double, strength: Double)] = [
        (0.14, 0.52, 0),
        (0.26, 0.55, 0.7),
        (0.40, 0.64, 1),
        (0.52, 0.76, 1),
        (0.64, 0.88, 1),
        (0.76, 0.02, 0.8),
        (0.86, 0.10, 0),
    ]

    /// The glint's line at full strength (added light, plus-lighter), and
    /// its stroke, half of which shows inside the outline: 1.25pt. Tune here.
    static let fadeGlintAlpha: Double = 0.85
    static let fadeGlintWidth: CGFloat = 2.5

    /// The glint's glow: the same colours as a soft haze rising from the
    /// bottom edge, `fadeHazeHeight` deep and `fadeHazeAlpha` strong at the
    /// edge, gone by its top. Stops short of the action row's text, which
    /// sits 8pt above the edge. Tune here.
    static let fadeHazeAlpha: Double = 0.2
    static let fadeHazeHeight: CGFloat = 12

    /// How far up from the bottom edge the glint's line shows before it has
    /// faded out up the walls, in points.
    static let fadeGlintReach: CGFloat = 26

    // MARK: - Fade's light, from the cover

    /// A colour as hue, saturation and brightness, each 0...1.
    struct HSB: Equatable {
        var h: Double
        var s: Double
        var b: Double
    }

    /// The spectral line's colours: full brightness, this saturated.
    static let fadeSpectralSaturation: Double = 0.75

    /// Light from an artwork colour is at least this bright. The glint is
    /// added light: a near-black cover's colours would add nothing and
    /// vanish, and a dark grey or brown would read as a smudge. Lifted,
    /// they keep their hue and become light of that hue. Tune here.
    static let fadeLightMinBrightness: Double = 0.9

    /// A colour with a hue of its own (saturation past
    /// `fadeLightHueOnset`) is lit at least this saturated, so a pale
    /// pastel still reads as its colour rather than as white. Greys, below
    /// the onset, stay neutral — silver light, not a hue made up from
    /// JPEG noise. Never more saturated than the spectral line, so a loud
    /// cover is no louder than the spectrum it replaces. Tune here.
    static let fadeLightMinSaturation: Double = 0.38
    static let fadeLightHueOnset: (from: Double, to: Double) = (0.05, 0.15)

    /// An artwork colour as Fade's light: hue kept, brightness floored,
    /// saturation lifted for colours that have a hue and capped at the
    /// spectrum's.
    static func fadeLight(_ c: HSB) -> HSB {
        let s = min(max(c.s, 0), 1)
        let onset = smoothstep(fadeLightHueOnset.from, fadeLightHueOnset.to, s)
        let lifted = max(s, fadeLightMinSaturation * onset)
        return HSB(
            h: min(max(c.h, 0), 1),
            s: min(lifted, fadeSpectralSaturation),
            b: max(min(max(c.b, 0), 1), fadeLightMinBrightness)
        )
    }

    static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        fadeEase((x - a) / (b - a))
    }

    /// One stop of the glint: where across the panel, its colour, and its
    /// strength (0...1, times `fadeGlintAlpha`).
    struct GlintStop: Equatable {
        var location: Double
        var color: HSB
        var strength: Double
    }

    /// The glint with no cover: the spectral line.
    static func fadeSpectralGlint() -> [GlintStop] {
        fadeGlintStops.map {
            GlintStop(location: $0.location, color: HSB(h: $0.hue, s: fadeSpectralSaturation, b: 1), strength: $0.strength)
        }
    }

    /// The glint from a cover's palette, laid where the spectrum's stops
    /// are, at their strengths: the secondary colour at the ends, the
    /// primary either side of the middle, the accent at the centre — so the
    /// cover's main colour carries the line and the accent is its brightest
    /// point. Each colour lit by `fadeLight`.
    static func fadeGlint(primary: HSB, secondary: HSB, accent: HSB) -> [GlintStop] {
        let order = [secondary, secondary, primary, accent, primary, secondary, secondary].map(fadeLight)
        return zip(fadeGlintStops, order).map {
            GlintStop(location: $0.location, color: $1, strength: $0.strength)
        }
    }

    /// How far the rim's white is tinted toward the cover's primary colour
    /// (lit). Faint: the corners still read as a white highlight, warmed or
    /// cooled by the cover. Tune here.
    static let fadeRimTint: Double = 0.3

    /// The rim's colour, as sRGB 0...1: white with no cover, else white
    /// mixed `fadeRimTint` of the way toward the primary colour's light.
    static func fadeRimColor(primary: HSB?) -> (r: Double, g: Double, b: Double) {
        guard let primary else { return (1, 1, 1) }
        let c = rgb(fadeLight(primary))
        return (1 + (c.r - 1) * fadeRimTint, 1 + (c.g - 1) * fadeRimTint, 1 + (c.b - 1) * fadeRimTint)
    }

    /// HSB to sRGB, each 0...1.
    static func rgb(_ c: HSB) -> (r: Double, g: Double, b: Double) {
        let h = (c.h - c.h.rounded(.down)) * 6
        let i = Int(h) % 6
        let f = h - Double(Int(h))
        let p = c.b * (1 - c.s), q = c.b * (1 - c.s * f), t = c.b * (1 - c.s * (1 - f))
        switch i {
        case 0: return (c.b, t, p)
        case 1: return (q, c.b, p)
        case 2: return (p, c.b, t)
        case 3: return (p, q, c.b)
        case 4: return (t, p, c.b)
        default: return (c.b, p, q)
        }
    }

    /// How long the light takes to cross-fade to a new cover's colours, in
    /// seconds: a short implicit animation, run only on the change.
    static let fadeLightCrossfade: Double = 0.6

    // MARK: - The blend

    /// Below this much of the open, the fill is all black; the glass is not
    /// even drawn.
    static let blendStart: Double = 0.1

    /// From this much of the open, the black is gone and the fill is all
    /// glass — before the content starts fading in at 0.65, so the content
    /// never appears over a fill still turning.
    static let blendEnd: Double = 0.6

    /// How much black covers the glass at `progress` (0 collapsed, 1 open):
    /// 1 up to `blendStart`, 0 from `blendEnd`, smoothstepped between. Out
    /// of range values (a spring's overshoot) clamp.
    static func blackCover(progress: Double) -> Double {
        let u = min(max((progress - blendStart) / (blendEnd - blendStart), 0), 1)
        return 1 - u * u * (3 - 2 * u)
    }

    /// Whether the glass needs drawing at all at `progress`. Under full
    /// black it doesn't, and leaving it out keeps the collapsed pill exactly
    /// the black fill it is in Black mode.
    static func showsGlass(progress: Double) -> Bool {
        progress > blendStart
    }

    // MARK: - The notch glow

    /// How far the glow reaches below the housing before it is clear, in
    /// points. Tune here.
    static let glowReach: CGFloat = 48

    /// Sideways distance counts for this much of vertical distance, so the
    /// glow spreads 1/0.55 ≈ 1.8 times as far to the sides as it does down
    /// (~87pt at a 48pt reach). Tune here.
    static let glowHorizontalScale: CGFloat = 0.55

    /// The falloff's ease: alpha = (1 - d/reach)^this.
    static let glowEase: Double = 1.6

    /// The glow's opacity at a point `x` points from the housing's centre
    /// line and `y` from the top of the screen: 1 over the housing, then
    /// clamp(1 - d/reach, 0, 1)^1.6, where d is the distance to the housing's
    /// rect with the sideways part scaled down by `glowHorizontalScale`.
    static func glowAlpha(x: CGFloat, y: CGFloat, housing: CGSize) -> Double {
        let dx = max(abs(x) - housing.width / 2, 0) * glowHorizontalScale
        let dy = max(y - housing.height, 0)
        let d = (dx * dx + dy * dy).squareRoot()
        if d <= 0 { return 1 }
        guard glowReach > 0, d < glowReach else { return 0 }
        return pow(Double(1 - d / glowReach), glowEase)
    }

    /// The box the glow occupies, anchored top-centre on the housing: past
    /// it the glow is clear.
    static func glowExtent(housing: CGSize) -> CGSize {
        CGSize(
            width: housing.width + 2 * glowReach / glowHorizontalScale,
            height: housing.height + glowReach
        )
    }

    /// The glow sampled over its extent at `scale` pixels per point: row
    /// major from the top, one 0...255 alpha per pixel, sampled at pixel
    /// centres.
    static func glowMask(housing: CGSize, scale: CGFloat) -> (width: Int, height: Int, alpha: [UInt8]) {
        let extent = glowExtent(housing: housing)
        let w = max(Int((extent.width * scale).rounded(.up)), 1)
        let h = max(Int((extent.height * scale).rounded(.up)), 1)
        var alpha = [UInt8](repeating: 0, count: w * h)
        for row in 0..<h {
            let y = (CGFloat(row) + 0.5) / scale
            for col in 0..<w {
                let x = (CGFloat(col) + 0.5) / scale - extent.width / 2
                alpha[row * w + col] = UInt8((glowAlpha(x: x, y: y, housing: housing) * 255).rounded())
            }
        }
        return (w, h, alpha)
    }

    // MARK: - Legibility on glass

    /// How far toward opaque secondary text moves on glass: 0.5 → 0.625,
    /// 0.72 → 0.79. Black mode never calls this.
    static let secondaryLift: Double = 0.25

    static func liftedOpacity(_ opacity: Double) -> Double {
        let o = min(max(opacity, 0), 1)
        return o + (1 - o) * secondaryLift
    }

    /// The lightness floor for artwork colours on glass, as gamma-space
    /// luma (Rec. 709 weights over sRGB-encoded channels). Glass is tinted
    /// by whatever is behind it, so a deep accent of a similar hue can all
    /// but vanish into it; held at least this light, it can't. Black mode
    /// never applies it, and the extraction itself is untouched.
    static let paletteLumaFloor: Double = 0.62

    static func luma(r: Double, g: Double, b: Double) -> Double {
        0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    /// The colour mixed toward white just enough to reach the floor — hue
    /// kept, nothing changed if it's already there. Channels 0...1, sRGB.
    static func floored(r: Double, g: Double, b: Double) -> (r: Double, g: Double, b: Double) {
        let l = luma(r: r, g: g, b: b)
        guard l < paletteLumaFloor else { return (r, g, b) }
        // Mixing by t toward white moves luma by (1 - l)t.
        let t = (paletteLumaFloor - l) / max(1 - l, 1e-9)
        return (r + (1 - r) * t, g + (1 - g) * t, b + (1 - b) * t)
    }
}
