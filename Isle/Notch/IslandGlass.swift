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
//    more, then easing to a light tint at the panel's bottom edge.
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
    /// ends. Between Glass's 0.25 and Smoked's 0.48: the bottom reads as
    /// glass, but the action row near it (Terminal, the reply field,
    /// Approve and Deny, a question's options) sits on more than Glass gives
    /// it, because a smoothstep is already all but flat by then. Tune here.
    static let fadeEndTint: Double = 0.36

    /// The solid band's depth for a camera housing (or content band)
    /// `notchHeight` tall.
    static func fadeBand(notchHeight: CGFloat) -> CGFloat {
        max(notchHeight, 0) + fadeBandExtra
    }

    /// The ease from the band to the bottom edge, `t` 0 at the band's foot
    /// and 1 at the bottom: smoothstep, so it leaves the band and arrives at
    /// the end tint with no slope — no visible edge at either end.
    static func fadeEase(_ t: Double) -> Double {
        let u = min(max(t, 0), 1)
        return u * u * (3 - 2 * u)
    }

    /// Fade's black at `y` points from the top of a panel `height` tall
    /// whose solid band is `band` deep: 1 down to the band's foot, then
    /// eased to `fadeEndTint` at the bottom edge. Measured against the
    /// panel's current height, so it follows the outline as it grows and
    /// shrinks rather than being stretched from a fixed one.
    static func fadeAlpha(y: CGFloat, height: CGFloat, band: CGFloat) -> Double {
        guard y > band else { return 1 }
        let span = height - band
        guard span > 0 else { return 1 }
        return 1 - (1 - fadeEndTint) * fadeEase(Double((y - band) / span))
    }

    /// Stops sampled along the ease, for the gradient that draws it below
    /// the band: enough that the piecewise-linear gradient between them is
    /// within a fraction of a percent of the curve.
    static let fadeStopCount = 16

    /// The ease from the band's foot (location 0) to the bottom edge
    /// (location 1), as (location, black's alpha) stops.
    static func fadeStops() -> [(location: Double, alpha: Double)] {
        (0...fadeStopCount).map {
            let t = Double($0) / Double(fadeStopCount)
            return (t, 1 - (1 - fadeEndTint) * fadeEase(t))
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
