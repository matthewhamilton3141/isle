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
//  - `PrismReflection`: the ribbon's colours as bands across the edge of
//    the lens's two bottom corners.
//  - `PrismLens`: the scrim behind the content, that reflection, and — where the system has
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
                    .frame(height: max(bandHeight, 0) + IslandPrism.bandExtra)
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
    /// The ribbon's colours, for the reflection along the lens's edge.
    var stops: [IslandPrism.RGB] = IslandPrism.spectrum

    var body: some View {
        ZStack {
            scrim
            if #unavailable(macOS 26.0) {
                rim
            }
            // Keyed by its colours, so a new cover's come in as a new view
            // and the old fade out under them: a transition on the change
            // alone, nothing running at rest.
            ZStack {
                PrismReflection(shape: shape, stops: stops)
                    .id(stops)
                    .transition(.opacity)
            }
            .animation(.easeInOut(duration: IslandPrism.reflectionCrossfade), value: stops)
        }
        .allowsHitTesting(false)
    }

    /// Soft-edged black behind the content, over the frost and to the same
    /// outline (`PrismPane`).
    private var scrim: some View {
        Color.black.opacity(IslandPrism.scrim).mask { PrismPane(shape: shape) }
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
    var shape: NotchShape

    var body: some View {
        if #available(macOS 26.0, *) {
            Color.clear
                .glassEffect(.regular, in: Rectangle())
                .environment(\.colorScheme, .dark)
                .mask { PrismPane(shape: shape).opacity(IslandPrism.frost) }
        }
    }
}

/// The part of the panel that holds content, as a soft-edged shape: from
/// under the band, where its top can't be seen, down to the horizon, and
/// `IslandPrism.rim` inside each wall. The frost is masked to it and the
/// scrim drawn in it, so both stop short of the walls and the lip and
/// leave them clear glass. Flattened to one bitmap, so its blur costs
/// nothing at rest.
struct PrismPane: View {
    var shape: NotchShape

    var body: some View {
        let radius: CGFloat = 18
        Color.clear.overlay {
            UnevenRoundedRectangle(bottomLeadingRadius: radius, bottomTrailingRadius: radius, style: .continuous)
                .fill(.white)
                // The walls stand the top flare's radius in from the frame.
                .padding(.horizontal, shape.topCornerRadius + IslandPrism.rim)
                .padding(.bottom, IslandPrism.lip)
                .padding(.top, -3 * IslandPrism.rimFeather)
                .blur(radius: IslandPrism.rimFeather)
        }
        .drawingGroup()
    }
}

/// The reflection in the lens's two bottom corners (see the numbers in
/// IslandPrism.swift): the ribbon's colours as bands across the thickness
/// of the edge, the first on the outline and each of the others inside
/// the last, following the corner's curve and fading as they go in. Both
/// corners carry all of them. Added light, static, and laid out against
/// the outline's current frame, so it follows the panel as it opens,
/// collapses and changes height; the black that covers the closed island
/// hides it.
struct PrismReflection: View {
    var shape: NotchShape
    var stops: [IslandPrism.RGB]

    var body: some View {
        let count = stops.count
        // A band `k` in from the outline is what shows of a stroke that
        // reaches that far in, once the narrower strokes are laid over it.
        // Centred on the outline and clipped to it, half of each shows.
        func width(_ k: Int) -> CGFloat {
            2 * IslandPrism.reflectionDepth * CGFloat(k + 1) / CGFloat(max(count, 1))
        }
        return ZStack {
            ForEach(Array(stops.enumerated()).reversed(), id: \.offset) { k, c in
                shape.stroke(Color(.sRGB, red: c.r, green: c.g, blue: c.b), lineWidth: width(k))
            }
        }
        .compositingGroup()
        .blur(radius: IslandPrism.reflectionSoftness)
        // Fading as it goes in: the same strokes as an alpha, each a share
        // of the whole, so the outline has them all and the innermost
        // band one.
        .mask {
            ZStack {
                ForEach(0..<count, id: \.self) { k in
                    shape.stroke(.white.opacity(1 / Double(max(count, 1))), lineWidth: width(k))
                }
            }
            .blur(radius: IslandPrism.reflectionSoftness)
        }
        .opacity(IslandPrism.reflectionStrength)
        // The two bottom corners only: a round patch on the middle of each
        // turn, fading out before the edge has run far along the bottom or
        // up the wall.
        .mask {
            let reach = IslandPrism.reflectionReach
            // The walls stand the top flare's radius in from the frame.
            let inWall = shape.topCornerRadius + IslandPrism.reflectionCentre(radius: shape.bottomCornerRadius)
            let up = IslandPrism.reflectionCentre(radius: shape.bottomCornerRadius)
            ZStack {
                Color.clear.overlay(alignment: .bottomLeading) {
                    patch.offset(x: inWall - reach, y: reach - up)
                }
                Color.clear.overlay(alignment: .bottomTrailing) {
                    patch.offset(x: reach - inWall, y: reach - up)
                }
            }
        }
        .drawingGroup()
        .blendMode(.plusLighter)
    }

    /// One corner's patch: full at its centre, gone at the reach.
    private var patch: some View {
        RadialGradient(stops: PrismReflectionStops.out, center: .center, startRadius: 0, endRadius: IslandPrism.reflectionReach)
            .frame(width: 2 * IslandPrism.reflectionReach, height: 2 * IslandPrism.reflectionReach)
    }
}

private enum PrismReflectionStops {
    static let out: [Gradient.Stop] = IslandPrism.reflectionStops().map {
        Gradient.Stop(color: .white.opacity($0.alpha), location: $0.location)
    }
}
