//
//  IslandGlass+SwiftUI.swift
//
//  The glass panel backgrounds as SwiftUI draws them (see `PanelBackground`;
//  the numbers are in IslandGlass.swift):
//
//  - `IslandGlassFill`, the glass half of `IslandFill`: the system material,
//    its tint, the camera cover and the black that covers it all while the
//    island is an empty pill, blended away on the open's progress or as
//    content arrives beside the camera.
//  - The material: Liquid Glass on macOS 26, an `NSVisualEffectView` behind
//    the window on 14 and 15. Both are window-server effects — an offscreen
//    render draws neither — and both are forced dark, so the white content
//    stays readable whatever the light/dark setting.
//  - The content's legibility lifts on glass, read from the environment so
//    Black mode resolves to exactly the colours it always drew.
//
//  Nothing here runs on a clock. The blend is `Animatable`, interpolated by
//  the same spring that moves the outline and only for as long as it runs;
//  at rest it doesn't evaluate. The camera cover is a bitmap built once.
//

import SwiftUI
import AppKit

// MARK: - The fill

/// The fill for a glass panel background, drawn by `IslandFill` in place of
/// its flat black. The empty closed pill is that same black; opening from
/// it, the black thins to glass on the open's progress, and closing it
/// thickens again. A closed island showing something is glass already, and
/// stays glass through the open and the close.
///
/// Clipped to the outline once, outside the blend: the clip takes the
/// corner radii's own spring during a collapse, like the black fill, so the
/// glass edge is the black fill's edge to the pixel.
struct IslandGlassFill: View {
    var background: PanelBackground
    var shape: NotchShape
    /// Whether the island is open — the blend's target, 1 or 0.
    var opened: Bool
    /// Whether the island is glass when closed (`IslandGlass.closedIsGlass`)
    /// — the blend's other target, 1 or 0.
    var closedGlass: Bool
    /// What lies over the camera, and the housing it covers (the physical
    /// cutout; unused with `.none`).
    var camera: IslandGlass.CameraCover
    var housing: CGSize
    /// How far the outline sits right of the housing's centre (NotchRootView's
    /// `collapsedShift`), so the camera cover can stay on the camera.
    var housingShift: CGFloat

    var body: some View {
        IslandGlassBlend(
            progress: opened ? 1 : 0,
            closedGlass: closedGlass ? 1 : 0,
            background: background,
            shape: shape,
            camera: camera,
            housing: housing,
            housingShift: housingShift
        )
        // The blend runs on the width's spring during a collapse — the
        // channel `expandProgress`, and so the content's fade, read off —
        // and on the transaction's own animation otherwise (the open, or a
        // toast widening the pill).
        .islandCollapseChannel(.width)
        .clipShape(shape)
    }
}

/// The blend from black to glass as an animatable value, so it follows the
/// spring that moves the outline frame by frame rather than jumping to its
/// end.
private struct IslandGlassBlend: View, Animatable {
    var progress: Double
    var closedGlass: Double
    var background: PanelBackground
    var shape: NotchShape
    var camera: IslandGlass.CameraCover
    var housing: CGSize
    var housingShift: CGFloat

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(progress, closedGlass) }
        set {
            progress = newValue.first
            closedGlass = newValue.second
        }
    }

    var body: some View {
        let shows = IslandGlass.showsGlass(progress: progress, closedGlass: closedGlass)
        ZStack(alignment: .top) {
            if shows {
                IslandGlassMaterial(shape: shape)
                    .overlay(Color.black.opacity(IslandGlass.tint(for: background, progress: progress)))
                    .transition(.identity)
            }
            if camera != .none {
                CameraCoverView(
                    cover: camera,
                    housing: housing,
                    shift: housingShift,
                    bandOpacity: IslandGlass.bandOpacity(camera, progress: progress),
                    glowOpacity: IslandGlass.glowLayerOpacity(camera, progress: progress)
                )
                // Hidden rather than removed under full black, so its
                // counter-offset keeps running with the outline's; the
                // empty pill is then the plain black fill, edge and all.
                .opacity(shows ? 1 : 0)
            }
            Rectangle()
                .fill(.black)
                .opacity(IslandGlass.blackCover(progress: progress, closedGlass: closedGlass))
        }
    }
}

/// The camera cover (`IslandGlass.CameraCover`): the camera band, and over
/// it what the notch glow adds, each a cached bitmap at its own opacity —
/// closed the band alone, open the glow (or, with the glow off, nothing).
/// Anchored on the camera, not the panel: while the outline is a lopsided
/// pill it is drawn `shift` right of the housing, and gets there on the
/// width's spring, so the cover is moved back by the same amount on the same
/// spring and stays put on screen while the panel narrows around it.
private struct CameraCoverView: View {
    var cover: IslandGlass.CameraCover
    var housing: CGSize
    var shift: CGFloat
    var bandOpacity: Double
    var glowOpacity: Double

    var body: some View {
        let covered = IslandGlass.coveredHousing(housing)
        // An overlay on a flexible clear view, so the cover takes the fill's
        // size and never sets it: wider and deeper than a pill, as a frame it
        // would grow the fill, and the outline clipped to it with it.
        Color.clear.overlay(alignment: .top) {
            ZStack(alignment: .top) {
                layer(.band, covered: covered, extent: IslandGlass.bandExtent(covered: covered), opacity: bandOpacity)
                if cover == .bandToGlow {
                    layer(.glowOverBand, covered: covered, extent: IslandGlass.glowExtent(housing: covered), opacity: glowOpacity)
                }
            }
            .offset(x: -shift)
            .islandCollapseChannel(.width)
        }
    }

    @ViewBuilder
    private func layer(_ kind: CameraCoverImage.Kind, covered: CGSize, extent: CGSize, opacity: Double) -> some View {
        if let image = CameraCoverImage.image(kind, covered: covered) {
            Image(decorative: image, scale: CameraCoverImage.scale)
                .resizable()
                .frame(width: extent.width, height: extent.height)
                .opacity(opacity)
        }
    }
}

/// The cover's layers as images, built once per housing size: static
/// bitmaps the compositor only has to place and fade, rather than a field
/// redrawn as the panel moves.
@MainActor
private enum CameraCoverImage {
    enum Kind: String { case band, glowOverBand }

    static let scale: CGFloat = 2
    private static var cache: [String: CGImage] = [:]

    static func image(_ kind: Kind, covered: CGSize) -> CGImage? {
        let key = "\(kind.rawValue)-\(covered.width)x\(covered.height)"
        if let cached = cache[key] { return cached }
        let mask = kind == .band
            ? IslandGlass.bandMask(covered: covered, scale: scale)
            : IslandGlass.glowOverBandMask(covered: covered, scale: scale)
        // Black, premultiplied: every channel but alpha is zero.
        var pixels = [UInt8](repeating: 0, count: mask.width * mask.height * 4)
        for i in 0..<mask.alpha.count { pixels[i * 4 + 3] = mask.alpha[i] }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(
                width: mask.width, height: mask.height,
                bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: mask.width * 4,
                space: space,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
              ) else { return nil }
        cache[key] = image
        return image
    }
}

// MARK: - The material

/// Frosted glass, dark: Liquid Glass where there is any, else the HUD
/// material blurred from behind the window. Never sampled or tinted by
/// Isle from the desktop — the panel usually sits over app windows, and the
/// material reads whatever is really there.
private struct IslandGlassMaterial: View {
    /// The outline, so Liquid Glass's rim follows it. The fill clips to it
    /// as well, which is what holds the edge exact while it moves.
    var shape: NotchShape

    var body: some View {
        if #available(macOS 26.0, *) {
            Color.clear
                .glassEffect(.regular, in: shape)
                .environment(\.colorScheme, .dark)
        } else {
            IslandVisualEffect()
        }
    }
}

/// `NSVisualEffectView` for macOS 14 and 15. Behind-window blending is what
/// blurs the windows under the panel (the panel window is non-opaque with a
/// clear background, which that needs), and the state is pinned active
/// because Isle is never the active app.
private struct IslandVisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = PassThroughVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = false
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// Never the target of a click. SwiftUI draws the panel's content in the
/// hosting view's own layer, so to AppKit this subview lies on top of every
/// button in the panel; let it take a hit and the panel goes dead.
private final class PassThroughVisualEffectView: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Content on glass

private struct IslandOnGlassKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Whether the content is drawn on glass rather than black. Set by
    /// NotchRootView on the open panel's content, and on the closed
    /// island's while that is glass.
    var islandOnGlass: Bool {
        get { self[IslandOnGlassKey.self] }
        set { self[IslandOnGlassKey.self] = newValue }
    }
}

/// Secondary text: white at `opacity` on black, a little brighter on glass
/// (`IslandGlass.liftedOpacity`). On black it resolves to exactly
/// `.white.opacity(opacity)`.
struct IslandSecondaryStyle: ShapeStyle {
    var opacity: Double

    func resolve(in environment: EnvironmentValues) -> Color {
        .white.opacity(environment.islandOnGlass ? IslandGlass.liftedOpacity(opacity) : opacity)
    }
}

extension ShapeStyle where Self == IslandSecondaryStyle {
    static func islandSecondary(_ opacity: Double) -> IslandSecondaryStyle {
        IslandSecondaryStyle(opacity: opacity)
    }
}

extension ArtworkPalette {
    /// The palette with each colour held above the glass lightness floor
    /// (`IslandGlass.floored`), for content on glass only. The extraction,
    /// and the palette Black mode draws, are untouched.
    var flooredForGlass: ArtworkPalette {
        ArtworkPalette(
            primary: Self.floored(primary),
            secondary: Self.floored(secondary),
            accent: Self.floored(accent)
        )
    }

    fileprivate static func floored(_ color: Color) -> Color {
        guard let c = NSColor(color).usingColorSpace(.sRGB) else { return color }
        let f = IslandGlass.floored(r: Double(c.redComponent), g: Double(c.greenComponent), b: Double(c.blueComponent))
        return Color(.sRGB, red: f.r, green: f.g, blue: f.b, opacity: Double(c.alphaComponent))
    }
}

extension Color {
    /// This colour held above the glass lightness floor on glass, untouched
    /// on black — for a colour drawn from the palette outside it (the
    /// working tint).
    func flooredForGlass(_ onGlass: Bool) -> Color {
        onGlass ? ArtworkPalette.floored(self) : self
    }
}
