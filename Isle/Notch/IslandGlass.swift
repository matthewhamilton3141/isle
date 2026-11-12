//
//  IslandGlass.swift
//
//  The numbers behind the glass panel backgrounds (see `PanelBackground`),
//  kept free of AppKit and SwiftUI so they compile on their own and can be
//  checked without an app (scripts/test-island-glass.sh):
//
//  - The blend. On the notch the pill is black in every mode, so opening
//    crossfades the fill from black to glass and closing back again, on the
//    open's progress: `blackCover` is how much black still lies over the
//    glass. Off the notch (`IslandPlacement.floating`) none does.
//  - The notch glow (a setting of its own, over Glass): black that grows
//    out of the physical camera housing, solid over it and fading outward,
//    wider sideways than down.
//  - The tints laid over the system material, one per mode.
//  - The arithmetic the shades share: the ease, compositing, HSB.
//  - The legibility lifts for content on glass: secondary text a little
//    brighter, artwork colours held above a lightness floor.
//
//  Prism's own numbers are in IslandPrism.swift. The drawing is in
//  IslandGlass+SwiftUI.swift.
//

import CoreGraphics
import Foundation

enum IslandGlass {
    // MARK: - Tints

    /// Black laid over the material in `.glass`. Light:
    /// the dark system material already pulls bright windows down, and this
    /// only steadies it. Tune here.
    static let glassTint: Double = 0.25

    static func tint(for background: PanelBackground) -> Double {
        switch background {
        case .black: return 0
        case .glass: return glassTint
        case .prism: return IslandPrism.lipTint
        }
    }

    // MARK: - Shared arithmetic

    /// Smoothstep on 0...1, clamped: no slope at either end, so a shade
    /// that eases with it leaves and arrives with no visible edge.
    static func ease(_ t: Double) -> Double {
        let u = min(max(t, 0), 1)
        return u * u * (3 - 2 * u)
    }

    /// `ease` between `a` and `b`: 0 at `a`, 1 at `b`.
    static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        ease((x - a) / (b - a))
    }

    /// How many stops an eased shade is sampled at for the gradient that
    /// draws it: enough that the piecewise-linear gradient between them is
    /// within a fraction of a percent of the curve.
    static let easeStopCount = 16

    /// Black `a` with black `b` drawn over it, as one alpha.
    static func over(_ a: Double, _ b: Double) -> Double {
        1 - (1 - a) * (1 - b)
    }

    /// A colour as hue, saturation and brightness, each 0...1.
    struct HSB: Equatable {
        var h: Double
        var s: Double
        var b: Double
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

    // MARK: - Off the notch

    /// The blend for an island `lift` of the way off its notch (0 docked,
    /// 1 floating; between only while it morphs from one to the other).
    /// The pill is black on the notch because of the camera in the middle
    /// of it. Off the notch that reason is gone: the black is lifted, and
    /// the island is glass closed as well as open.
    static func blackCover(progress: Double, lift: Double) -> Double {
        blackCover(progress: progress) * (1 - min(max(lift, 0), 1))
    }

    /// Whether the glass needs drawing: always once the island has begun
    /// to leave the notch, else as `showsGlass(progress:)`.
    static func showsGlass(progress: Double, lift: Double) -> Bool {
        lift > 0 || showsGlass(progress: progress)
    }

    /// How much of something that belongs to the open panel alone shows
    /// at `progress` of the open — Prism's ribbon, which lies along a lip
    /// the closed capsule doesn't have. On the notch the black cover hides
    /// it while closed; off the notch there is no cover, so it is brought
    /// in on the same curve the cover would have left on.
    static func openOnlyOpacity(progress: Double) -> Double {
        1 - blackCover(progress: progress)
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

    /// How far toward opaque secondary text moves on glass: 0.5 → 0.71,
    /// 0.7 → 0.826. Black mode never calls this.
    ///
    /// Well up from the quarter it was: glass is as light as what's behind
    /// it, and over a white window grey text on it had little left to
    /// stand on (Matthew: "the more greyed out texts are less visible on
    /// lighter (whiter) backgrounds"). The tones still step down in order.
    static let secondaryLift: Double = 0.42

    /// The soft dark edge secondary text carries on glass: black's alpha
    /// and its blur, in points. Over a dark window it can't be seen; over
    /// a light one it is what the text's own lightness is read against.
    static let textShade: Double = 0.34
    static let textShadeRadius: Double = 1.6

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
