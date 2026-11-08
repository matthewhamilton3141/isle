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
//  at rest it doesn't evaluate. The camera cover is a Canvas redrawn only
//  while a spring moves it, over a glow bitmap built once.
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
    /// cutout; unused without one).
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
/// end. The outline's shift right of the camera is animated with it, on the
/// same channel as NotchRootView's offset, so the camera cover can find the
/// camera inside a moving outline.
private struct IslandGlassBlend: View, Animatable {
    var progress: Double
    var closedGlass: Double
    var background: PanelBackground
    var shape: NotchShape
    var camera: IslandGlass.CameraCover
    var housing: CGSize
    var housingShift: CGFloat

    var animatableData: AnimatablePair<AnimatablePair<Double, Double>, CGFloat> {
        get { AnimatablePair(AnimatablePair(progress, closedGlass), housingShift) }
        set {
            progress = newValue.first.first
            closedGlass = newValue.first.second
            housingShift = newValue.second
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
            CameraCoverCanvas(
                cover: camera,
                housing: housing,
                shift: housingShift,
                openness: IslandGlass.coverOpenness(progress: progress)
            )
            // Hidden under full black: the empty pill is then the plain
            // black fill, edge and all.
            .opacity(shows ? 1 : 0)
            Rectangle()
                .fill(.black)
                .opacity(IslandGlass.blackCover(progress: progress, closedGlass: closedGlass))
        }
    }
}

/// The camera cover (`IslandGlass.CameraCover`), drawn at the outline's
/// live size: the closed wing gradient at 1 - `openness`, and the notch
/// glow (a cached bitmap) at `openness`, their alpha added — so the two
/// mix pixel for pixel, as `IslandGlass.coverAlpha` says, with no dip
/// where both are solid.
///
/// A Canvas, redrawn only when its inputs change: at rest, never; while a
/// spring runs, once a frame, at the in-between size and shift the outline
/// itself is laid out at. Each wing's gradient runs from the core to the
/// outline's end on that side, so it follows a toast widening one side, the
/// width spring of a collapse, and the shift that keeps the camera centred.
private struct CameraCoverCanvas: View {
    var cover: IslandGlass.CameraCover
    var housing: CGSize
    var shift: CGFloat
    var openness: Double

    /// Stops across a wing, for the eased fade. Enough that the steps of a
    /// piecewise-linear ramp don't show over a wing of a hundred points.
    private static let stops = 24

    private static let wingStops: [Double] = (0...stops).map {
        IslandGlass.wingAlpha(Double($0) / Double(stops))
    }

    var body: some View {
        let covered = IslandGlass.coveredHousing(housing)
        let core = covered
        let glow = cover.openGlow ? CameraGlowImage.image(covered: covered) : nil
        let t = min(max(openness, 0), 1)
        Canvas { context, size in
            let camera = size.width / 2 - shift
            let runs = IslandGlass.wingRuns(width: size.width, shift: shift, core: core.width)
            let depth = core.height + IslandGlass.closedFadeDown
            context.drawLayer { all in
                if t < 1, cover.housing {
                    all.opacity = 1 - t
                    all.drawLayer { closed in
                        closed.fill(
                            Path(CGRect(x: camera - core.width / 2, y: 0, width: core.width, height: depth)),
                            with: .color(.black)
                        )
                        Self.wings(&closed, camera: camera, core: core.width, runs: runs, depth: depth)
                        // The fade below the core's depth.
                        closed.blendMode = .destinationIn
                        let down = core.height / depth
                        closed.fill(
                            Path(CGRect(x: 0, y: 0, width: size.width, height: depth)),
                            with: .linearGradient(
                                Gradient(stops: [.init(color: .black, location: 0)] + (0...8).map { i in
                                    let y = core.height + IslandGlass.closedFadeDown * CGFloat(i) / 8
                                    return .init(
                                        color: .black.opacity(IslandGlass.closedDownAlpha(y: y, core: core)),
                                        location: down + (1 - down) * CGFloat(i) / 8
                                    )
                                }),
                                startPoint: .zero, endPoint: CGPoint(x: 0, y: depth)
                            )
                        )
                    }
                }
                if let glow, t > 0 {
                    let extent = IslandGlass.glowExtent(housing: covered)
                    all.opacity = t
                    all.blendMode = .plusLighter
                    all.draw(
                        Image(decorative: glow, scale: CameraGlowImage.scale),
                        in: CGRect(x: camera - extent.width / 2, y: 0, width: extent.width, height: extent.height)
                    )
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// Both wings: black at the core, easing to clear at each end, and
    /// under the top edge's darkening, whichever is darker at each point
    /// (`IslandGlass.closedCoverAlpha`). Through the top edge's depth the
    /// wings are drawn a row a pixel tall at a time, each row's stops raised
    /// to that row's top alpha; below it, one gradient each.
    private static func wings(
        _ context: inout GraphicsContext, camera: CGFloat, core: CGFloat,
        runs: (leading: CGFloat, trailing: CGFloat), depth: CGFloat
    ) {
        // Whole rows, so every edge lands on a pixel boundary: a fractional
        // row antialiases against its neighbour and shows as a seam.
        let rows = Int((min(IslandGlass.topDepth, depth) / rowHeight).rounded(.up))
        let top = CGFloat(rows) * rowHeight
        for row in 0..<rows {
            let y = CGFloat(row) * rowHeight
            let floor = IslandGlass.topAlpha(y: y + rowHeight / 2)
            wing(&context, from: camera - core / 2, run: -runs.leading, y: y, height: rowHeight, floor: floor)
            wing(&context, from: camera + core / 2, run: runs.trailing, y: y, height: rowHeight, floor: floor)
        }
        wing(&context, from: camera - core / 2, run: -runs.leading, y: top, height: depth - top, floor: 0)
        wing(&context, from: camera + core / 2, run: runs.trailing, y: top, height: depth - top, floor: 0)
    }

    /// A row of the top edge: a device pixel at 2x.
    private static let rowHeight: CGFloat = 0.5

    /// One wing's band from `y`, `height` deep: black at `from`, easing to
    /// clear `run` points away (negative runs to the left), never lighter
    /// than `floor`.
    private static func wing(
        _ context: inout GraphicsContext, from x: CGFloat, run: CGFloat,
        y: CGFloat, height: CGFloat, floor: Double
    ) {
        guard abs(run) > 0.5, height > 0 else { return }
        let rect = CGRect(x: min(x, x + run), y: y, width: abs(run), height: height)
        let stops = wingStops.enumerated().map { i, a in
            Gradient.Stop(color: .black.opacity(max(a, floor)), location: CGFloat(i) / CGFloat(Self.stops))
        }
        context.fill(
            Path(rect),
            with: .linearGradient(
                Gradient(stops: stops),
                startPoint: CGPoint(x: x, y: 0), endPoint: CGPoint(x: x + run, y: 0)
            )
        )
    }
}

/// The notch glow's falloff as an image, built once per housing size: a
/// static bitmap the canvas only has to place.
@MainActor
private enum CameraGlowImage {
    static let scale: CGFloat = 2
    private static var cache: [String: CGImage] = [:]

    static func image(covered: CGSize) -> CGImage? {
        let key = "\(covered.width)x\(covered.height)"
        if let cached = cache[key] { return cached }
        let mask = IslandGlass.glowMask(housing: covered, scale: scale)
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
