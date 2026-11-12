//
//  IslandPrism+SwiftUI.swift
//
//  Prism as SwiftUI draws it (the numbers are in IslandPrism.swift, the
//  ribbon's own drawing in PrismRibbonView.swift), laid over the glass
//  material by `IslandGlassFill`:
//
//  - `PrismShade`: solid black over the camera housing, easing to a tint,
//    and clearing across the horizon to the lip's all but bare glass. Off
//    the notch there's no camera to be black over: the tint from the top.
//  - `PrismFrost`: frosted glass behind the content, so the lens is a
//    lens only along the lip — and, off the notch, in a rim all the way
//    round, closed as well as open (`PrismPaneInsets`).
//  - `PrismRibbonStrip`: the ribbon along the lip, part of the material
//    like the frost.
//  - `PrismLens`: the scrim behind the content and — where the system has
//    no Liquid Glass to draw a lens's edge — a specular rim of Isle's own.
//
//  The shade and the scrim are laid out, not measured: fixed
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
    /// 0 on the notch, 1 off it; between while the island morphs from one
    /// to the other, when the two shades cross-fade.
    var lift: Double = 0

    var body: some View {
        Color.clear.overlay(alignment: .top) {
            ZStack(alignment: .top) {
                if lift < 1 {
                    docked.opacity(1 - lift)
                }
                if lift > 0 {
                    floating.opacity(lift)
                }
            }
        }
    }

    private var docked: some View {
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

    /// Off the notch: the walls' tint from the top edge down, with no
    /// black band, and the same horizon and lip. On a closed capsule,
    /// shallower than the horizon and the lip together, the fixed parts
    /// run past the clip; what shows is one or other of two tints a
    /// hundredth apart.
    private var floating: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(.black.opacity(IslandPrism.edgeTint))
            LinearGradient(stops: PrismStops.horizon, startPoint: .top, endPoint: .bottom)
                .frame(height: IslandPrism.horizonFeather)
            Rectangle()
                .fill(.black.opacity(IslandPrism.lipTint))
                .frame(height: IslandPrism.lip - IslandPrism.horizonFeather / 2)
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
    var pane: PrismPaneInsets = .docked

    var body: some View {
        ZStack {
            scrim
            if #unavailable(macOS 26.0) {
                rim
            }
        }
        .allowsHitTesting(false)
    }

    /// Soft-edged black behind the content, over the frost and to the same
    /// outline (`PrismPane`).
    private var scrim: some View {
        Color.black.opacity(IslandPrism.scrim).mask { PrismPane(shape: shape, insets: pane) }
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
/// Off as Isle ships (`IslandPrism.frost` is 0, and says why); kept so the
/// amount can be turned back up.
///
/// A lens shows what's behind it nearly sharp, and a line of someone's
/// document running through the controls can't be tinted away without
/// tinting the glass to black. Frosted, the part of the panel that holds
/// content is the system's regular glass laid over the clear lens,
/// masked to end across the horizon, and the lip below is left a lens.
/// Part of the material: drawn in the glass window, under the shade.
/// Before Liquid Glass the material is already frosted throughout, and
/// this draws nothing.
struct PrismFrost: View {
    var shape: NotchShape
    var pane: PrismPaneInsets = .docked

    var body: some View {
        // No frost, no glass view: an effect masked to nothing is still
        // an effect the window server composites.
        if #available(macOS 26.0, *), IslandPrism.frost > 0 {
            Color.clear
                .glassEffect(.regular, in: Rectangle())
                .environment(\.colorScheme, .dark)
                .mask { PrismPane(shape: shape, insets: pane).opacity(IslandPrism.frost) }
        }
    }
}

/// The part of the panel that holds content, as a soft-edged shape: from
/// under the band, where its top can't be seen, down to the horizon, and
/// `IslandPrism.rim` inside each wall. The frost is masked to it and the
/// scrim drawn in it, so both stop short of the walls and the lip and
/// leave them clear glass. Flattened to one bitmap, so its blur costs
/// nothing at rest.
///
/// Off the notch its top can be seen, so it has a top rim and top corners
/// too, and closed it is the capsule's own shape a little way inside it
/// (`IslandFloat.prismPane`).
struct PrismPane: View {
    var shape: NotchShape
    var insets: PrismPaneInsets = .docked

    var body: some View {
        Color.clear.overlay {
            UnevenRoundedRectangle(
                topLeadingRadius: insets.topRadius,
                bottomLeadingRadius: insets.bottomRadius,
                bottomTrailingRadius: insets.bottomRadius,
                topTrailingRadius: insets.topRadius,
                style: .continuous
            )
            .fill(.white)
            // The walls stand the top flare's radius in from the frame.
            .padding(.horizontal, shape.topCornerRadius + insets.side)
            .padding(.bottom, insets.bottom)
            .padding(.top, insets.top)
            .blur(radius: insets.feather)
        }
        .drawingGroup()
    }
}

/// Where the pane lies inside the outline: how far inside the walls, the
/// bottom edge and the top edge, how round, and how soft.
struct PrismPaneInsets: Equatable {
    var top: CGFloat
    var side: CGFloat
    var bottom: CGFloat
    var topRadius: CGFloat
    var bottomRadius: CGFloat
    var feather: CGFloat

    /// On the notch: square at the top and run up under the black band,
    /// where its edge can't be seen.
    static let docked = PrismPaneInsets(
        top: -3 * IslandPrism.rimFeather,
        side: IslandPrism.rim,
        bottom: IslandPrism.lip,
        topRadius: 0,
        bottomRadius: IslandFloat.prismPaneRadius,
        feather: IslandPrism.rimFeather
    )

    init(top: CGFloat, side: CGFloat, bottom: CGFloat, topRadius: CGFloat, bottomRadius: CGFloat, feather: CGFloat) {
        self.top = top
        self.side = side
        self.bottom = bottom
        self.topRadius = topRadius
        self.bottomRadius = bottomRadius
        self.feather = feather
    }

    /// Off the notch (`IslandFloat.prismPane`).
    init(_ pane: IslandFloat.PrismPane) {
        self.init(top: pane.top, side: pane.side, bottom: pane.bottom,
                  topRadius: pane.topRadius, bottomRadius: pane.bottomRadius, feather: pane.feather)
    }

    /// This pane `t` of the way to `other`: the island leaving the notch,
    /// or returning to it.
    func mixed(with other: PrismPaneInsets, by t: Double) -> PrismPaneInsets {
        let t = CGFloat(min(max(t, 0), 1))
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * t }
        return PrismPaneInsets(
            top: mix(top, other.top), side: mix(side, other.side), bottom: mix(bottom, other.bottom),
            topRadius: mix(topRadius, other.topRadius), bottomRadius: mix(bottomRadius, other.bottomRadius),
            feather: mix(feather, other.feather)
        )
    }
}
