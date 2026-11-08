//
//  IslandGlass.swift
//
//  The numbers behind the glass panel backgrounds (see `PanelBackground`),
//  kept free of AppKit and SwiftUI so they compile on their own and can be
//  checked without an app (scripts/test-island-glass.sh):
//
//  - Which states are glass. The open panel, and the closed island while it
//    shows something beside the camera (music, Claude, the timer, a toast).
//    The empty pill, which only fills the camera's own cutout, stays black.
//  - The blend. Opening from the empty pill crossfades the fill from black
//    to glass and closing back again, on the open's progress; the closed
//    island's glass, coming and going with its content, is the blend's
//    second input. `blackCover` is how much black still lies over the glass.
//  - The camera cover, on a display with a notch: black over the physical
//    housing so the cutout doesn't bite into the glass. With the notch glow
//    on it is the glow — solid over the housing, fading outward, wider
//    sideways than down. With it off it is the camera band, solid over the
//    housing and gone a few points past it, drawn only while closed.
//  - The tints laid over the system material, one per mode, with a floor
//    for the closed island's small coloured content.
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
        }
    }

    /// The least black over the material while the island is closed. Its
    /// content is small and coloured — artwork, the equalizer, a status
    /// word in the artwork's accent — not the open panel's white text, and
    /// over a bright window `glassTint` left it faint. Smoked is already
    /// past it. Tune here.
    static let closedTintFloor: Double = 0.4

    /// The tint at `progress` (0 closed, 1 open): the closed island's
    /// (`tint(for:)` held at least at `closedTintFloor`) thinning to the
    /// open panel's on the blend's own curve, so it is the open panel's by
    /// `blendEnd` and the closed island's below `blendStart`.
    static func tint(for background: PanelBackground, progress: Double) -> Double {
        let open = tint(for: background)
        guard background.isGlass else { return open }
        let closed = max(open, closedTintFloor)
        return open + (closed - open) * blackCover(progress: progress)
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

    // MARK: - The closed island

    /// Whether the closed island is glass: in a glass mode, and only while
    /// it shows something beside the camera. The empty pill is exactly the
    /// camera's cutout, so as glass it would be a rim of glass round a black
    /// hole; black, it disappears into the hardware as it always has.
    static func closedIsGlass(background: PanelBackground, showsContent: Bool) -> Bool {
        background.isGlass && showsContent
    }

    /// How much black covers the glass at `progress` (0 closed, 1 open) with
    /// the closed island `closedGlass` of the way to glass (0 the empty
    /// pill's black, 1 glass; animated between the two as content comes and
    /// goes). A closed island that is glass stays glass all the way open and
    /// all the way closed again: nothing in an open or a close goes back
    /// through black.
    static func blackCover(progress: Double, closedGlass: Double) -> Double {
        let g = min(max(closedGlass, 0), 1)
        return blackCover(progress: progress) * (1 - g)
    }

    /// Whether the glass needs drawing at all: anywhere the black doesn't
    /// cover it completely.
    static func showsGlass(progress: Double, closedGlass: Double) -> Bool {
        blackCover(progress: progress, closedGlass: closedGlass) < 1
    }

    // MARK: - The camera cover

    /// What lies over the physical camera housing on glass.
    enum CameraCover: Equatable {
        /// No notch: nothing to cover, the glass runs edge to edge.
        case none
        /// The notch glow, open and closed.
        case glow
        /// The glow switched off: black over the housing and a few points
        /// past it, while closed only — open, the housing hangs into the
        /// glass as the setting says.
        case band
    }

    static func cameraCover(hasPhysicalNotch: Bool, glowOn: Bool) -> CameraCover {
        guard hasPhysicalNotch else { return .none }
        return glowOn ? .glow : .band
    }

    /// How far solid black reaches past the housing's sides and bottom, so
    /// the hardware's edge — the housing's measured width is whole points,
    /// its corners rounded — never meets see-through glass. Tune here.
    static let cameraClearance: CGFloat = 4

    /// The rect black is solid over: the housing, `cameraClearance` wider
    /// each side and deeper. Both covers grow from it.
    static func coveredHousing(_ housing: CGSize) -> CGSize {
        CGSize(width: housing.width + 2 * cameraClearance, height: housing.height + cameraClearance)
    }

    /// How much of the camera cover shows at `progress`. The glow is the
    /// same open and closed. The band is the closed island's alone: whole
    /// closed, gone by the time the panel is glass (`blendEnd`), on the
    /// blend's own curve, so it thins as the panel grows past the camera.
    static func cameraOpacity(_ cover: CameraCover, progress: Double) -> Double {
        switch cover {
        case .none: return 0
        case .glow: return 1
        case .band: return blackCover(progress: progress)
        }
    }

    /// How far the band takes to fade out past the covered rect, in points.
    /// Short: it only has to soften the edge. Tune here.
    static let bandFade: CGFloat = 8

    /// The band's opacity `x` points from the housing's centre line and `y`
    /// from the top of the screen, around a `covered` rect
    /// (`coveredHousing`): 1 over it, then 1 - smoothstep(d / bandFade) over
    /// the distance d to it, clear from `bandFade` out.
    static func bandAlpha(x: CGFloat, y: CGFloat, covered: CGSize) -> Double {
        let dx = max(abs(x) - covered.width / 2, 0)
        let dy = max(y - covered.height, 0)
        let d = (dx * dx + dy * dy).squareRoot()
        if d <= 0 { return 1 }
        guard bandFade > 0, d < bandFade else { return 0 }
        let u = Double(d / bandFade)
        return 1 - u * u * (3 - 2 * u)
    }

    static func bandExtent(covered: CGSize) -> CGSize {
        CGSize(width: covered.width + 2 * bandFade, height: covered.height + bandFade)
    }

    /// The band sampled like `glowMask`.
    static func bandMask(covered: CGSize, scale: CGFloat) -> (width: Int, height: Int, alpha: [UInt8]) {
        sample(extent: bandExtent(covered: covered), scale: scale) { x, y in
            bandAlpha(x: x, y: y, covered: covered)
        }
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
        sample(extent: glowExtent(housing: housing), scale: scale) { x, y in
            glowAlpha(x: x, y: y, housing: housing)
        }
    }

    /// `alpha` over `extent`, anchored top-centre, at `scale` pixels per
    /// point: row major from the top, sampled at pixel centres.
    private static func sample(
        extent: CGSize, scale: CGFloat, _ alphaAt: (CGFloat, CGFloat) -> Double
    ) -> (width: Int, height: Int, alpha: [UInt8]) {
        let w = max(Int((extent.width * scale).rounded(.up)), 1)
        let h = max(Int((extent.height * scale).rounded(.up)), 1)
        var alpha = [UInt8](repeating: 0, count: w * h)
        for row in 0..<h {
            let y = (CGFloat(row) + 0.5) / scale
            for col in 0..<w {
                let x = (CGFloat(col) + 0.5) / scale - extent.width / 2
                alpha[row * w + col] = UInt8((alphaAt(x, y) * 255).rounded())
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
