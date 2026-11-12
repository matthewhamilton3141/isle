//
//  IslandGlass+SwiftUI.swift
//
//  The glass panel backgrounds as SwiftUI draws them (see `PanelBackground`;
//  the numbers are in IslandGlass.swift):
//
//  - `IslandGlassFill`, the glass half of `IslandFill`: the system material,
//    its tint, the notch glow and the black that covers it all while the
//    island is closed, blended away on the open's progress. Off the notch
//    (`IslandPlacement.floating`) nothing covers it: glass closed and open.
//  - Prism's shade and lens are in IslandPrism+SwiftUI.swift; this file
//    draws them in the fill and asks the glass window for the lens.
//  - The material: Liquid Glass on macOS 26, an `NSVisualEffectView` behind
//    the window on 14 and 15. Both are window-server effects — an offscreen
//    render draws neither — and both are forced dark, so the white content
//    stays readable whatever the light/dark setting.
//  - Where the material is drawn (`IslandGlassLayer`): in the island's own
//    window, or, as Isle runs, in a window of its own under it that never
//    becomes key, because Liquid Glass changes its look with its window's
//    key status (see `IslandGlassWindow`).
//  - The content's legibility lifts on glass, read from the environment so
//    Black mode resolves to exactly the colours it always drew.
//
//  Nothing here runs on a clock. The blend is `Animatable`, interpolated by
//  the same spring that moves the outline and only for as long as it runs;
//  at rest it doesn't evaluate. The glow is a bitmap built once.
//

import SwiftUI
import AppKit

// MARK: - The fill

/// The fill for a glass panel background, drawn by `IslandFill` in place of
/// its flat black. Closed it is that same black; opening, the black thins
/// to glass on the open's progress, and closing it thickens again. Off the
/// notch there is no black: the capsule is glass too, and no glow grows
/// out of a camera that isn't under it.
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
    /// housing's height, or the fallback band without one — which Prism
    /// keeps solid black (`PrismShade`).
    var bandHeight: CGFloat
    /// What Prism's ribbon follows; nil in every other mode.
    var ribbon: PrismRibbonInput? = nil
    /// Whether the island is off its notch — the lift's target, 1 or 0.
    var floating: Bool = false

    var body: some View {
        IslandGlassBlend(
            progress: opened ? 1 : 0,
            lift: floating ? 1 : 0,
            background: background,
            shape: shape,
            housing: housing,
            housingShift: housingShift,
            bandHeight: bandHeight,
            ribbon: ribbon
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
/// end — and with it the lift off the notch, which takes the black away
/// altogether (`IslandGlass.blackCover(progress:lift:)`).
private struct IslandGlassBlend: View, Animatable {
    var progress: Double
    /// 0 on the notch, 1 off it.
    var lift: Double
    var background: PanelBackground
    var shape: NotchShape
    var housing: CGSize?
    var housingShift: CGFloat
    var bandHeight: CGFloat
    var ribbon: PrismRibbonInput?

    @Environment(\.islandGlassLayer) private var layer

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(progress, lift) }
        set {
            progress = newValue.first
            lift = newValue.second
        }
    }

    var body: some View {
        let showsGlass = IslandGlass.showsGlass(progress: progress, lift: lift)
        ZStack(alignment: .top) {
            if layer == .materialOnly {
                // The glass window keeps its material in the tree the whole
                // time and shows it by opacity. Added when the open's blend
                // got under way, as it is in the panel's own tree, a view is
                // laid out at the open's final size at once rather than on
                // the outline's spring; there the panel's clip and black
                // cover hid that, but alone in its window it showed as a grey
                // block the size of the open panel for the first few frames
                // of every open. At zero opacity it isn't composited, so the
                // closed pill costs nothing for it.
                material
                    .opacity(showsGlass ? 1 : 0)
            } else if showsGlass {
                material
                    .overlay(alignment: .top) {
                        // Glass's tint. Prism's shade is drawn with the
                        // material, under its ribbon (`material`).
                        if layer != .materialOnly, background != .prism {
                            IslandGlassShade(background: background, bandHeight: bandHeight, lift: lift)
                        }
                    }
                    .overlay(alignment: .top) {
                        if background == .prism, layer != .materialOnly {
                            PrismLens(shape: shape, pane: pane)
                        }
                    }
                    .transition(.identity)
            }
            // Everything from here up is the panel's, never the material's
            // window's: there, under full black, there's simply no glass yet.
            if layer != .materialOnly {
                cover
                // Off the notch, Glass's hairline (Prism's lens has an edge
                // of its own): in with the lift, on its spring.
                if background == .glass, lift > 0 {
                    IslandRim(shape: shape, opacity: IslandFloat.glassRimOpacity)
                        .opacity(lift)
                }
            }
        }
    }

    /// The material itself, or a stand-in that takes its place in the
    /// layout when another window draws it.
    @ViewBuilder
    private var material: some View {
        if layer == .withoutMaterial {
            Color.clear
        } else {
            IslandGlassMaterial(
                shape: shape,
                clear: background == .prism,
                lens: background == .prism
            )
            .overlay(alignment: .top) {
                // Prism's shade, frost and ribbon, in the material's own
                // window with the lens: glass on glass and the light in
                // it, under everything the panel draws. The shade first, so
                // the ribbon lies on it rather than under it: over the
                // ribbon, a shade dark enough for a bright window took the
                // colour out of the light.
                if background == .prism {
                    PrismShade(bandHeight: bandHeight, lift: lift)
                    PrismCap()
                    PrismFrost(shape: shape, pane: pane)
                    PrismRibbonStrip(shape: shape, ribbon: ribbon)
                        // The ribbon is the open lip's. On the notch the
                        // black cover hides it while closed; off it, it
                        // comes and goes with the open instead.
                        .opacity(lift > 0 ? IslandGlass.openOnlyOpacity(progress: progress) : 1)
                }
            }
        }
    }

    /// Where Prism's frost and scrim lie: the docked pane, the floating
    /// one at this much of the open, or — while the island morphs between
    /// the two — the one part way from the first to the second.
    private var pane: PrismPaneInsets {
        let docked = PrismPaneInsets.docked
        guard lift > 0 else { return docked }
        return docked.mixed(with: PrismPaneInsets(IslandFloat.prismPane(progress: progress, closedHeight: IslandFloat.pillHeight)), by: lift)
    }

    /// The notch glow and the black that blends away on the open.
    @ViewBuilder
    private var cover: some View {
        ZStack(alignment: .top) {
            if let housing {
                NotchGlow(housing: housing, shift: housingShift)
                    // Hidden rather than removed under full black, so its
                    // counter-offset keeps running with the outline's; the
                    // closed pill is then the plain black fill, edge and all.
                    .opacity(IslandGlass.showsGlass(progress: progress) ? 1 : 0)
            }
            Rectangle()
                .fill(.black)
                .opacity(IslandGlass.blackCover(progress: progress, lift: lift))
        }
    }
}

// MARK: - Where the material is drawn

/// Which part of the island's fill a view tree draws.
///
/// Liquid Glass renders differently in a key window: there the system turns
/// on its full lens — the refraction layer and its sampling margin — and
/// what's behind the panel comes through nearly sharp; in a window that
/// isn't key, it's the frosted glass Isle is designed on. The panel window
/// becomes key while the reply field takes typing, which flipped the glass
/// from one to the other mid-reply. Neither the SwiftUI environment
/// (`appearsActive`, `controlActiveState`) nor `NSGlassEffectView` pins it:
/// the switch happens in `NSWindow.becomeKey()`, for the window's own glass.
///
/// So as Isle runs, the material is drawn in a window of its own that never
/// becomes key (`IslandGlassWindow`, a child of the panel, ordered just
/// below it), from the same view tree with `.materialOnly`, while the panel
/// draws everything else with `.withoutMaterial`: the shade, Prism's scrim,
/// the glow and the black that blends away on the open all lie over the
/// glass exactly as before. Both trees follow the same state on the same
/// springs, so the two windows move as one.
enum IslandGlassLayer {
    /// The material and everything over it, in one window: previews, renders.
    case all
    /// The material alone, in the outline: the glass window.
    case materialOnly
    /// Everything but the material: the panel, over the glass window.
    case withoutMaterial
}

private struct IslandGlassLayerKey: EnvironmentKey {
    static let defaultValue = IslandGlassLayer.all
}

extension EnvironmentValues {
    /// Which part of the fill this tree draws (`IslandGlassLayer`).
    var islandGlassLayer: IslandGlassLayer {
        get { self[IslandGlassLayerKey.self] }
        set { self[IslandGlassLayerKey.self] = newValue }
    }
}

/// The black laid over the material: a flat tint in Glass, Prism's shade
/// (`PrismShade`) in Prism.
private struct IslandGlassShade: View {
    var background: PanelBackground
    var bandHeight: CGFloat
    /// 0 on the notch, 1 off it, where Prism has no black over a camera.
    var lift: Double

    var body: some View {
        if background == .prism {
            PrismShade(bandHeight: bandHeight, lift: lift)
        } else {
            Color.black.opacity(IslandGlass.tint(for: background))
        }
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

/// Glass, dark: Liquid Glass where there is any, else the HUD material
/// blurred from behind the window. Never sampled or tinted by Isle from the
/// desktop — the panel usually sits over app windows, and the material
/// reads whatever is really there.
///
/// Glass draws the frosted `.regular` variant; Prism the `.clear`, which
/// lets more of the backdrop's colour and light through, and asks for it
/// as a lens. In the window it's drawn in, which never becomes key
/// (`IslandGlassLayer`), Glass stays frosted: the backdrop's shapes and
/// colours come through, its detail doesn't. (In a key window the system
/// lenses the backdrop nearly sharp — which is what a focused reply field
/// used to show for as long as it was focused, and what Prism asks for on
/// purpose.)
/// It is never tinted through `Glass.tint` — black there lightens the glass
/// to grey rather than darkening it — so the shade over it does that. Not
/// `.interactive()`: the panel is a surface with buttons on it, not a
/// control, and shouldn't flex under a click.
private struct IslandGlassMaterial: View {
    /// The outline, so Liquid Glass's rim follows it. The fill clips to it
    /// as well, which is what holds the edge exact while it moves.
    var shape: NotchShape
    /// Liquid Glass's clear variant rather than the frosted.
    var clear: Bool = false
    /// Drawn as a lens (Prism): asks the glass window for the look Liquid
    /// Glass keeps for key windows (`IslandGlassWindow.lensed`). Only that
    /// window answers, so in a preview or a render, where the material is
    /// in the panel's own window, this is the frosted clear glass.
    var lens: Bool = false

    var body: some View {
        if #available(macOS 26.0, *) {
            Color.clear
                .glassEffect(clear ? .clear : .regular, in: shape)
                .environment(\.colorScheme, .dark)
                .background(IslandGlassLensSwitch(lens: lens))
        } else {
            IslandVisualEffect()
        }
    }
}

/// Tells the window the material is drawn in whether its glass is a lens.
/// In every mode, so leaving Prism for another puts the frosted look back.
private struct IslandGlassLensSwitch: NSViewRepresentable {
    var lens: Bool

    func makeNSView(context: Context) -> SwitchView {
        let view = SwitchView()
        view.lens = lens
        return view
    }

    func updateNSView(_ view: SwitchView, context: Context) {
        view.lens = lens
    }

    final class SwitchView: NSView {
        var lens = false { didSet { apply() } }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        private func apply() {
            (window as? IslandGlassWindow)?.lensed = lens
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

private struct IslandHasRibbonKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Whether the panel has Prism's ribbon along its lip. The ribbon is
    /// the waveform there, so the Music face leaves its own bars out.
    var islandHasRibbon: Bool {
        get { self[IslandHasRibbonKey.self] }
        set { self[IslandHasRibbonKey.self] = newValue }
    }
}

/// Secondary text: white at `opacity` on black; on glass brighter
/// (`IslandGlass.liftedOpacity`) and with a soft dark edge
/// (`IslandGlass.textShade`), so it holds over a light window. On black it
/// resolves to exactly `.white.opacity(opacity)`.
struct IslandSecondaryStyle: ShapeStyle {
    var opacity: Double

    func resolve(in environment: EnvironmentValues) -> AnyShapeStyle {
        guard environment.islandOnGlass else { return AnyShapeStyle(Color.white.opacity(opacity)) }
        return AnyShapeStyle(
            Color.white.opacity(IslandGlass.liftedOpacity(opacity))
                .shadow(.drop(color: .black.opacity(IslandGlass.textShade), radius: IslandGlass.textShadeRadius))
        )
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
