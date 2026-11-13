//
//  IslandPrism+SwiftUI.swift
//
//  Prism as SwiftUI draws it (the numbers are in IslandPrism.swift, the
//  ribbon's own drawing in PrismRibbonView.swift), laid over the glass
//  material by `IslandGlassFill`:
//
//  - `PrismShade`: a tint from the top edge, clearing across the horizon
//    to the lip's all but bare glass.
//  - `PrismNotchShade`: on the notch, black over the camera housing that
//    lets go a short way out from it, laid over the cap so the fade has no
//    colour of its own. Off the notch, and on a display without one,
//    there's no camera to be black over.
//  - `PrismFrost`: frosted glass behind the content, so the lens is a
//    lens only along the lip — and, off the notch, in a rim all the way
//    round, closed as well as open (`PrismPaneInsets`).
//  - `PrismRibbonStrip`: the ribbon along the lip, part of the material
//    like the frost.
//  - `PrismLens`: the scrim behind the content and — where the system has
//    no Liquid Glass to draw a lens's edge — a specular rim of Isle's own.
//
//  The shade and the scrim are laid out, not measured: fixed lengths at
//  the bottom (the horizon and the lip) with the tint taking whatever is
//  above, so they follow the outline as it opens, collapses and changes
//  height; the black over the camera is one bitmap, built once and held
//  on the camera. Nothing here runs on a clock; the ribbon moves only
//  while the music does.
//

import SwiftUI

/// Prism's shade: `IslandPrism.edgeTint` from the top edge, held to the
/// horizon and cleared across it to `IslandPrism.lipTint`, the same on the
/// notch and off it. (The black over the camera is `PrismNotchShade`.)
///
/// In an overlay on a flexible clear view, so it never sets the fill's
/// size: while the outline is shallower than the fixed parts (the first
/// frames of an open, the last of a collapse; a closed capsule off the
/// notch) they run past the clip. On the notch the cover is solid black
/// that whole while; on a capsule what shows is one or other of two tints
/// a hundredth apart.
struct PrismShade: View {
    var body: some View {
        Color.clear.overlay(alignment: .top) {
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
}

/// The black over the camera housing: solid over it and a few points
/// round it, then let go a short way out, the same to the sides, below and
/// round the corners (`IslandPrism.notchAlpha`), so what is black in the
/// glass is the camera and not a bar across the panel.
///
/// Over the cap, not under it. The cap darkens channel by channel, and
/// only what is brighter than it: under it, the fade from a coloured
/// window went through that window's colour on the way to black — once
/// the black had taken a channel below the cap the cap let go of it, the
/// strongest channel last — and the camera had a blue rim over a blue
/// toolbar. Over it, the fade is from what the cap shows straight to
/// black, whatever is behind.
///
/// Anchored on the camera, not the panel, as the notch glow is: while the
/// outline is a lopsided pill it is drawn `shift` right of the housing,
/// and gets there on the width's spring, so this is moved back by the same
/// amount on the same spring. Wider and deeper than a pill, so in an
/// overlay: it takes the fill's size and never sets it, and what of it is
/// outside the outline is clipped with everything else.
struct PrismNotchShade: View {
    /// The physical camera housing the island hangs from; nil on a display
    /// without one, where there is nothing to be black over.
    var housing: CGSize?
    /// How far the outline sits right of the housing's centre
    /// (NotchRootView's `collapsedShift`).
    var shift: CGFloat = 0
    /// 0 on the notch, 1 off it; between while the island morphs from one
    /// to the other, when this fades with it.
    var lift: Double = 0

    var body: some View {
        Color.clear.overlay(alignment: .top) {
            if let housing, lift < 1, let image = PrismNotchImage.image(housing: housing) {
                let extent = IslandPrism.notchExtent(housing: housing)
                Image(decorative: image, scale: PrismNotchImage.scale)
                    .resizable()
                    .frame(width: extent.width, height: extent.height)
                    .offset(x: -shift)
                    .islandCollapseChannel(.width)
                    .opacity(1 - lift)
            }
        }
        .allowsHitTesting(false)
    }
}

/// The camera's black as an image, built once per housing size: a static
/// bitmap the compositor only has to place.
@MainActor
private enum PrismNotchImage {
    static let scale: CGFloat = 2
    private static var cache: [String: CGImage] = [:]

    static func image(housing: CGSize) -> CGImage? {
        let key = "\(housing.width)x\(housing.height)"
        if let cached = cache[key] { return cached }
        let mask = IslandPrism.notchMask(housing: housing, scale: scale)
        guard let image = IslandBlackImage.image(width: mask.width, height: mask.height, alpha: mask.alpha) else { return nil }
        cache[key] = image
        return image
    }
}

/// Prism's cap: what is seen through the lens is brought most of the way
/// down to `IslandPrism.cap` wherever it is lighter than that.
///
/// A lens is as light as what's behind it, and white text on it needs
/// something darker than a white page. A flat black shade deep enough for
/// that dulls everything else as much: a dark, colourful window behind the
/// glass, which needed no help, loses its colour too (Matthew, of an even
/// shade: "colours are hard to see now"). This darkens only what is
/// brighter than the cap, channel by channel, and leaves the rest as the
/// lens shows it.
struct PrismCap: View {
    var body: some View {
        Color(white: IslandPrism.cap)
            .opacity(IslandPrism.capStrength)
            .blendMode(.darken)
            .allowsHitTesting(false)
    }
}

/// The shade's gradient, sampled from its curve once.
private enum PrismStops {
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
/// above the top edge, so it has no top to be seen, down to the horizon, and
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

    /// On the notch: square at the top and run up past the panel's top
    /// edge, so there is no edge of it across the band.
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
