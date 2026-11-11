//
//  IslandPrism+SwiftUI.swift
//
//  Prism as SwiftUI draws it (the numbers are in IslandPrism.swift, the
//  ribbon's own drawing in PrismRibbonView.swift), laid over the glass
//  material by `IslandGlassFill`:
//
//  - `PrismShade`: solid black over the camera housing, easing to a tint,
//    and clearing across the horizon to the lip's all but bare glass.
//  - `PrismFrost`: frosted glass behind the content, so the lens is a
//    lens only along the lip.
//  - `PrismRibbonStrip`: the ribbon along the lip, part of the material
//    like the frost.
//  - `PrismLens`: the scrim behind the content and — where the system has
//    no Liquid Glass to draw a lens's edge — a specular rim of Isle's own.
//
//  Like Fade's, the shade and the scrim are laid out, not measured: fixed
//  lengths at the top (the band) and the bottom (the horizon and the lip)
//  with a gradient taking whatever is between, so they follow the outline
//  as it opens, collapses and changes height. Nothing here runs on a
//  clock; the ribbon moves only while the music does.
//

import SwiftUI

/// Prism's shade: black over the band, eased to `IslandPrism.edgeTint`,
/// held to the horizon and cleared across it to `IslandPrism.lipTint`.
///
/// In an overlay on a flexible clear view, so it never sets the fill's
/// size: while the outline is shallower than the fixed parts (the first
/// frames of an open, the last of a collapse) they run past the clip, and
/// that whole while the cover is solid black anyway.
struct PrismShade: View {
    var bandHeight: CGFloat

    var body: some View {
        Color.clear.overlay(alignment: .top) {
            VStack(spacing: 0) {
                Rectangle()
                    .fill(.black)
                    .frame(height: IslandGlass.fadeBand(notchHeight: bandHeight))
                LinearGradient(stops: PrismStops.shade, startPoint: .top, endPoint: .bottom)
                LinearGradient(stops: PrismStops.horizon, startPoint: .top, endPoint: .bottom)
                    .frame(height: IslandPrism.horizonFeather)
                Rectangle()
                    .fill(.black.opacity(IslandPrism.lipTint))
                    .frame(height: IslandPrism.lip - IslandPrism.horizonFeather / 2)
            }
        }
    }
}

/// The shade's gradients, sampled from their curves once.
private enum PrismStops {
    static let shade: [Gradient.Stop] = IslandPrism.shadeStops().map {
        Gradient.Stop(color: .black.opacity($0.alpha), location: $0.location)
    }
    static let horizon: [Gradient.Stop] = IslandPrism.horizonStops().map {
        Gradient.Stop(color: .black.opacity($0.alpha), location: $0.location)
    }
}

/// Prism's ribbon where it lies: along the bottom of the outline, inset
/// from the walls.
///
/// Part of the material, drawn in the glass window, not the panel. The
/// ribbon is an AppKit view, and one of those inside a SwiftUI tree is
/// composited over everything SwiftUI draws in that window — in the panel
/// it lay over the buttons above the lip and over the black that covers
/// the glass while the island opens. Under the panel's window it is under
/// all of that: the shade's tint over the lip dims it a little, the cover
/// brings it in with the glass, and it can never be in the way of a click.
struct PrismRibbonStrip: View {
    var shape: NotchShape
    /// What the ribbon follows; nil draws none.
    var ribbon: PrismRibbonInput?

    var body: some View {
        if let ribbon {
            Color.clear.overlay(alignment: .bottom) {
                PrismRibbon(input: ribbon)
                    .frame(height: IslandPrism.ribbonStrip)
                    .padding(.horizontal, shape.topCornerRadius + IslandPrism.ribbonInset)
            }
            .allowsHitTesting(false)
        }
    }
}

/// Prism's lens, over its shade and under the content.
struct PrismLens: View {
    var shape: NotchShape

    var body: some View {
        ZStack {
            scrim
            if #unavailable(macOS 26.0) {
                rim
            }
        }
        .allowsHitTesting(false)
    }

    /// The outline's walls stand its top flare's radius in from the frame.
    private var wall: CGFloat { shape.topCornerRadius }

    /// Soft-edged black behind the content: from under the band, where it
    /// can't be seen, down to the horizon, inset from the walls. Flattened
    /// to one bitmap, so the blur costs nothing at rest.
    private var scrim: some View {
        let inset = wall + IslandPrism.scrimInset
        let radius: CGFloat = 14
        return Color.clear.overlay {
            UnevenRoundedRectangle(bottomLeadingRadius: radius, bottomTrailingRadius: radius, style: .continuous)
                .fill(.black.opacity(IslandPrism.scrim))
                .padding(.horizontal, inset)
                .padding(.bottom, IslandPrism.lip + IslandPrism.scrimFeather / 2)
                .padding(.top, -2 * IslandPrism.scrimFeather)
                .blur(radius: IslandPrism.scrimFeather)
        }
        .drawingGroup()
    }

    /// Before Liquid Glass there's no lens and no edge to it: a thin white
    /// line round the lip, brightest along the bottom, stands in.
    private var rim: some View {
        shape
            .stroke(.white.opacity(0.5), lineWidth: 2)
            .mask {
                VStack(spacing: 0) {
                    Color.clear
                    LinearGradient(colors: [.clear, .white], startPoint: .top, endPoint: .bottom)
                        .frame(height: IslandPrism.lip + 20)
                }
            }
            .blendMode(.plusLighter)
    }
}

/// Prism's frost: frosted glass over the lens, behind the content only.
///
/// A lens shows what's behind it nearly sharp, and a line of someone's
/// document running through the controls can't be tinted away without
/// tinting the glass to black. So the part of the panel that holds content
/// is frosted — the system's regular glass laid over the clear lens,
/// masked to end across the horizon — and the lip below is left a lens.
/// Part of the material: drawn in the glass window, under the shade.
/// Before Liquid Glass the material is already frosted throughout, and
/// this draws nothing.
struct PrismFrost: View {
    var body: some View {
        if #available(macOS 26.0, *) {
            Color.clear
                .glassEffect(.regular, in: Rectangle())
                .environment(\.colorScheme, .dark)
                .mask {
                    VStack(spacing: 0) {
                        Color.white
                        LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .bottom)
                            .frame(height: IslandPrism.horizonFeather)
                        Color.clear.frame(height: IslandPrism.lip - IslandPrism.horizonFeather / 2)
                    }
                }
        }
    }
}
