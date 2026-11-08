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
//  - The camera cover. Closed, a gradient out of the notch: black over the
//    physical housing (so the cutout doesn't bite into the glass), then
//    each wing fading to clear glass at its end, and the top edge darkened
//    to meet the screen's bezel; without a notch, nothing.
//    Opening, it becomes the notch glow —
//    solid over the housing, fading outward, wider sideways than down — or
//    with the glow off (or no notch), clears.
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

    /// What lies over the camera on glass. Closed, on a notch display, it is
    /// the wing gradient: black over the housing, then each wing fading from
    /// black at the housing to clear (the plain glass tint) at the pill's
    /// end on that side, its top edge darkened to meet the black bezel the
    /// island hangs from. Opening, it becomes the notch glow if that's on, or
    /// clears. The glow setting never touches the closed island.
    ///
    /// Without a notch there is no cover, closed or open: the pill is plain
    /// glass. Mirrored from the centre the gradient met itself in a black
    /// crease where no camera is, which read as a smudge, not a notch.
    struct CameraCover: Equatable {
        /// A physical housing to hold black over and grow the wings from.
        var housing: Bool
        /// The open panel's cover is the notch glow; otherwise nothing.
        var openGlow: Bool
    }

    static func cameraCover(hasPhysicalNotch: Bool, glowOn: Bool) -> CameraCover {
        CameraCover(housing: hasPhysicalNotch, openGlow: hasPhysicalNotch && glowOn)
    }

    /// How far solid black reaches past the housing's sides and bottom, so
    /// the hardware's edge — the housing's measured width is whole points,
    /// its corners rounded — never meets see-through glass. Tune here.
    static let cameraClearance: CGFloat = 4

    /// The rect black is solid over: the housing, `cameraClearance` wider
    /// each side and deeper: the closed cover's solid core. The wing
    /// gradient and the glow grow from it.
    static func coveredHousing(_ housing: CGSize) -> CGSize {
        CGSize(width: housing.width + 2 * cameraClearance, height: housing.height + cameraClearance)
    }

    /// How the wing gradient eases from black at the core (t = 0) to clear
    /// at the pill's end (t = 1): (1 - t)^`wingEase`. Over 1, so it falls
    /// fast off the core and lies long and low toward the end — the content
    /// beside the camera still on dark, the artwork at the outer end on
    /// clear glass. Tune here.
    static let wingEase: Double = 1.6

    static func wingAlpha(_ t: Double) -> Double {
        pow(1 - min(max(t, 0), 1), wingEase)
    }

    /// How deep the closed cover's top edge darkens, in points: black where
    /// the island meets the screen's black bezel, eased to nothing this far
    /// down — half the 32pt pill (picked over 40% from renders: it meets
    /// the bezel more softly), so each wing's lower half, and its bottom
    /// edge, is the side gradient alone. Tune here.
    static let topDepth: CGFloat = 16

    /// The ease of the top edge's fade: (1 - y/topDepth)^this.
    static let topEase: Double = 1.6

    /// The top edge's darkening `y` points from the top of the screen.
    static func topAlpha(y: CGFloat) -> Double {
        guard topDepth > 0, y < topDepth else { return 0 }
        return pow(Double(1 - max(y, 0) / topDepth), topEase)
    }

    /// Below the core's depth the closed cover fades out over this many
    /// points. The closed pill is no deeper than the housing, so this only
    /// shows while the island opens or collapses. Tune here.
    static let closedFadeDown: CGFloat = 12

    /// Each wing's run, from the core's edge to the pill's end on that side,
    /// for a pill `width` wide drawn `shift` right of the camera (the
    /// outline as it is, mid-spring included).
    static func wingRuns(width: CGFloat, shift: CGFloat, core: CGFloat) -> (leading: CGFloat, trailing: CGFloat) {
        (max(width / 2 - shift - core / 2, 0), max(width / 2 + shift - core / 2, 0))
    }

    /// The side gradient alone at `x` points from the camera's centre line:
    /// 1 over the core, easing to 0 at each wing's end.
    static func sideAlpha(x: CGFloat, core: CGSize, runs: (leading: CGFloat, trailing: CGFloat)) -> Double {
        let side = abs(x) - core.width / 2
        let run = x < 0 ? runs.leading : runs.trailing
        return side <= 0 ? 1 : (run > 0 ? wingAlpha(Double(side / run)) : 0)
    }

    /// The closed cover's opacity `x` points from the camera's centre line
    /// and `y` from the top of the screen: the side gradient and the top
    /// edge's darkening, whichever is darker — not the two compounded, which
    /// would crush the wings near the top.
    static func closedCoverAlpha(
        x: CGFloat, y: CGFloat, core: CGSize, runs: (leading: CGFloat, trailing: CGFloat)
    ) -> Double {
        max(sideAlpha(x: x, core: core, runs: runs), topAlpha(y: y)) * closedDownAlpha(y: y, core: core)
    }

    /// The closed cover's vertical fade: whole to the core's depth, then
    /// 1 - smoothstep over `closedFadeDown`.
    static func closedDownAlpha(y: CGFloat, core: CGSize) -> Double {
        let below = y - core.height
        guard below > 0 else { return 1 }
        guard closedFadeDown > 0, below < closedFadeDown else { return 0 }
        let u = Double(below / closedFadeDown)
        return 1 - u * u * (3 - 2 * u)
    }

    /// How far the cover has gone from closed to open at `progress`: 0
    /// closed, 1 from `blendEnd`, on the blend's own curve — the curve the
    /// tint follows from its closed floor to the open tint.
    static func coverOpenness(progress: Double) -> Double {
        1 - blackCover(progress: progress)
    }

    /// The cover at a point: closed and open mixed by `coverOpenness`,
    /// pixel for pixel — `(1 - t) closed + t open`, which IslandGlassBlend
    /// draws by adding the two layers' alpha (plus-lighter on black) — so
    /// nothing solid at both ends ever thins in between.
    static func coverAlpha(
        _ cover: CameraCover, x: CGFloat, y: CGFloat, housing: CGSize,
        runs: (leading: CGFloat, trailing: CGFloat), progress: Double
    ) -> Double {
        let t = coverOpenness(progress: progress)
        let closed = cover.housing ? closedCoverAlpha(x: x, y: y, core: coveredHousing(housing), runs: runs) : 0
        let open = cover.openGlow ? glowAlpha(x: x, y: y, housing: coveredHousing(housing)) : 0
        return (1 - t) * closed + t * open
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
