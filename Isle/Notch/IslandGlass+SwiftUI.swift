//
//  IslandGlass+SwiftUI.swift
//
//  The glass panel backgrounds as SwiftUI draws them (see `PanelBackground`;
//  the numbers are in IslandGlass.swift):
//
//  - `IslandGlassFill`, the glass half of `IslandFill`: the system material,
//    its tint (Fade's solid band and gradient, in Fade), the notch glow and
//    the black that covers it all while the island is closed, blended away
//    on the open's progress.
//  - The material: Liquid Glass on macOS 26, an `NSVisualEffectView` behind
//    the window on 14 and 15. Both are window-server effects — an offscreen
//    render draws neither — and both are forced dark, so the white content
//    stays readable whatever the light/dark setting.
//  - The content's legibility lifts on glass, read from the environment so
//    Black mode resolves to exactly the colours it always drew.
//
//  Nothing here runs on a clock. The blend is `Animatable`, interpolated by
//  the same spring that moves the outline and only for as long as it runs;
//  at rest it doesn't evaluate. The glow is a bitmap built once. Fade's
//  shade is laid out, not measured: a fixed band and a gradient that takes
//  whatever height is left, so it follows the outline's frame with no
//  geometry reader and nothing to redraw at rest.
//

import SwiftUI
import AppKit

// MARK: - The fill

/// The fill for a glass panel background, drawn by `IslandFill` in place of
/// its flat black. Closed it is that same black; opening, the black thins
/// to glass on the open's progress, and closing it thickens again.
///
/// Clipped to the outline once, outside the blend: the clip takes the
/// corner radii's own spring during a collapse, like the black fill, so the
/// glass edge is the black fill's edge to the pixel.
struct IslandGlassFill: View {
    var background: PanelBackground
    var shape: NotchShape
    /// Whether the island is open — the blend's target, 1 or 0.
    var opened: Bool
    /// The physical camera housing to grow the notch glow from; nil with
    /// the glow off, or on a display without a notch.
    var housing: CGSize?
    /// How far the outline sits right of the housing's centre (NotchRootView's
    /// `collapsedShift`), so the glow can stay on the camera.
    var housingShift: CGFloat
    /// The band the open panel's content starts under — the camera
    /// housing's height, or the fallback band without one — which Fade
    /// keeps solid black and a little more (`IslandGlass.fadeBand`).
    var bandHeight: CGFloat

    var body: some View {
        IslandGlassBlend(
            progress: opened ? 1 : 0,
            background: background,
            shape: shape,
            housing: housing,
            housingShift: housingShift,
            bandHeight: bandHeight
        )
        // The blend runs on the width's spring during a collapse — the
        // channel `expandProgress`, and so the content's fade, read off —
        // and on the transaction's own animation otherwise (the open).
        .islandCollapseChannel(.width)
        .clipShape(shape)
    }
}

/// The blend from black to glass as an animatable value, so it follows the
/// spring that moves the outline frame by frame rather than jumping to its
/// end.
private struct IslandGlassBlend: View, Animatable {
    var progress: Double
    var background: PanelBackground
    var shape: NotchShape
    var housing: CGSize?
    var housingShift: CGFloat
    var bandHeight: CGFloat

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        ZStack(alignment: .top) {
            if IslandGlass.showsGlass(progress: progress) {
                IslandGlassMaterial(shape: shape)
                    .overlay(alignment: .top) { IslandGlassShade(background: background, bandHeight: bandHeight) }
                    .transition(.identity)
            }
            if let housing {
                NotchGlow(housing: housing, shift: housingShift)
                    // Hidden rather than removed under full black, so its
                    // counter-offset keeps running with the outline's; the
                    // closed pill is then the plain black fill, edge and all.
                    .opacity(IslandGlass.showsGlass(progress: progress) ? 1 : 0)
            }
            Rectangle()
                .fill(.black)
                .opacity(IslandGlass.blackCover(progress: progress))
        }
    }
}

/// The black laid over the material: a flat tint in Glass and Smoked; in
/// Fade, solid over the band and easing to `IslandGlass.fadeEndTint` at the
/// bottom edge.
///
/// Fade's shade is a fixed-height black band over a gradient that fills the
/// rest, so the ease always spans from the band's foot to the outline's
/// current bottom edge — as the panel opens, collapses or changes height,
/// layout hands the gradient its new height and nothing is measured or
/// stretched from a stale one. In an overlay on a flexible clear view, so
/// it never sets the fill's size: while the outline is shallower than the
/// band (the first frames of an open, the last of a collapse) the band
/// simply runs past the clip, and that whole while the cover is solid
/// black anyway.
private struct IslandGlassShade: View {
    var background: PanelBackground
    var bandHeight: CGFloat

    var body: some View {
        if background == .fade {
            Color.clear.overlay(alignment: .top) {
                VStack(spacing: 0) {
                    Rectangle()
                        .fill(.black)
                        .frame(height: IslandGlass.fadeBand(notchHeight: bandHeight))
                    LinearGradient(stops: FadeStops.stops, startPoint: .top, endPoint: .bottom)
                }
            }
        } else {
            Color.black.opacity(IslandGlass.tint(for: background))
        }
    }
}

/// Fade's gradient stops, sampled from the curve once.
private enum FadeStops {
    static let stops: [Gradient.Stop] = IslandGlass.fadeStops().map {
        Gradient.Stop(color: .black.opacity($0.alpha), location: $0.location)
    }
}

/// The notch glow: black growing out of the camera housing, solid over it
/// and fading outward, wider to the sides than down (`IslandGlass.glowAlpha`).
/// Anchored on the camera, not the panel: while the outline is a lopsided
/// pill it is drawn `shift` right of the housing, and gets there on the
/// width's spring, so the glow is moved back by the same amount on the same
/// spring and stays put on screen while the panel narrows around it.
private struct NotchGlow: View {
    var housing: CGSize
    var shift: CGFloat

    var body: some View {
        let extent = IslandGlass.glowExtent(housing: housing)
        // An overlay on a flexible clear view, so the glow takes the fill's
        // size and never sets it: wider and deeper than a pill, as a frame it
        // would grow the fill, and the outline clipped to it with it.
        Color.clear.overlay(alignment: .top) {
            if let image = NotchGlowImage.image(housing: housing) {
                Image(decorative: image, scale: NotchGlowImage.scale)
                    .resizable()
                    .frame(width: extent.width, height: extent.height)
                    .offset(x: -shift)
                    .islandCollapseChannel(.width)
            }
        }
    }
}

/// The glow's falloff as an image, built once per housing size: a static
/// bitmap the compositor only has to place, rather than a field redrawn as
/// the panel moves.
@MainActor
private enum NotchGlowImage {
    static let scale: CGFloat = 2
    private static var cache: [String: CGImage] = [:]

    static func image(housing: CGSize) -> CGImage? {
        let key = "\(housing.width)x\(housing.height)"
        if let cached = cache[key] { return cached }
        let mask = IslandGlass.glowMask(housing: housing, scale: scale)
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
    /// NotchRootView on the open panel's content alone.
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

    private static func floored(_ color: Color) -> Color {
        guard let c = NSColor(color).usingColorSpace(.sRGB) else { return color }
        let f = IslandGlass.floored(r: Double(c.redComponent), g: Double(c.greenComponent), b: Double(c.blueComponent))
        return Color(.sRGB, red: f.r, green: f.g, blue: f.b, opacity: Double(c.alphaComponent))
    }
}
