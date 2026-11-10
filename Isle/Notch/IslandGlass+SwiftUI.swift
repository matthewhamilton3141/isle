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
//  - Fade's lens, over its shade: the scrim behind the content, the
//    specular rim and the spectral glint along the bottom edge, which take
//    the current cover's colours while a track is up (`FadeLight`), and
//    the sweep that runs along the rim once as the island opens.
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
//  at rest it doesn't evaluate. The glow is a bitmap built once. Fade's
//  shade is laid out, not measured: a fixed band and a gradient that takes
//  whatever height is left, so it follows the outline's frame with no
//  geometry reader and nothing to redraw at rest. Its lens is the same:
//  strokes, gradients and one blur flattened to a bitmap, all static — it
//  is redrawn only while the outline's size is changing.
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
    /// Where Fade's light takes its colours: the cover's, Claude's status.
    var light: IslandLightSource = .none
    /// The closed island in glass (`ClosedIslandStyle.glass`): the camera
    /// housing to keep black over, or nil on a display without one. Nil
    /// `compact` is the black pill.
    var compact: CompactGlass? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// When the island last closed, and when Fade's sweep last started, for
    /// the rule that decides whether an open sweeps
    /// (`IslandGlass.fadeSweeps`). Kept here because this view lasts across
    /// opens and closes; the lens itself is rebuilt with every open.
    @State private var closedAt: Date?
    @State private var sweptAt: Date?
    /// The open that earned a sweep, handed to the lens to run it.
    @State private var sweepAt: Date?

    var body: some View {
        IslandGlassBlend(
            progress: opened ? 1 : 0,
            background: background,
            shape: shape,
            housing: housing,
            housingShift: housingShift,
            bandHeight: bandHeight,
            light: light,
            sweepAt: sweepAt,
            compact: compact
        )
        // The blend runs on the width's spring during a collapse — the
        // channel `expandProgress`, and so the content's fade, read off —
        // and on the transaction's own animation otherwise (the open).
        .islandCollapseChannel(.width)
        .clipShape(shape)
        // Opens and closes only: a face swipe or a height change doesn't
        // touch `opened`, so it never sweeps.
        .onChange(of: opened) { _, isOpen in
            let now = Date()
            guard isOpen else {
                closedAt = now
                return
            }
            guard background == .fade, IslandGlass.fadeSweeps(
                sinceClose: closedAt.map { now.timeIntervalSince($0) },
                sinceSweep: sweptAt.map { now.timeIntervalSince($0) },
                reduceMotion: reduceMotion
            ) else { return }
            sweptAt = now
            sweepAt = now
        }
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
    var light: IslandLightSource
    var sweepAt: Date?
    var compact: CompactGlass?

    @Environment(\.islandGlassLayer) private var layer

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
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
                    .opacity(IslandGlass.showsGlass(progress: progress) || compact != nil ? 1 : 0)
            } else if IslandGlass.showsGlass(progress: progress) {
                material
                    .overlay(alignment: .top) {
                        if layer != .materialOnly {
                            IslandGlassShade(background: background, bandHeight: bandHeight)
                        }
                    }
                    .overlay(alignment: .top) {
                        if background == .fade, layer != .materialOnly {
                            FadeLens(shape: shape, bandHeight: bandHeight, light: FadeLight.resolve(light), sweepAt: sweepAt)
                        }
                    }
                    .transition(.identity)
            }
            // Everything from here up is the panel's, never the material's
            // window's: there, under full black, there's simply no glass yet.
            if layer != .materialOnly {
                cover
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
            IslandGlassMaterial(shape: shape, clear: background == .fade)
        }
    }

    /// The notch glow and the black that blends away on the open.
    @ViewBuilder
    private var cover: some View {
        if let compact {
            compactCover(compact)
        } else {
            plainCover
        }
    }

    /// The closed island in glass, and the open blending away from it: the
    /// wings lightly tinted, the band over the camera housing solid black,
    /// both thinning to nothing on the open's progress as Fade's own shade
    /// takes over.
    private func compactCover(_ compact: CompactGlass) -> some View {
        let c = IslandGlass.blackCover(progress: progress)
        return ZStack(alignment: .top) {
            Rectangle()
                .fill(.black)
                .opacity(IslandGlass.compactTint * c)
            if let housing = compact.housing {
                HousingBand(housing: housing, shift: housingShift)
                    .opacity(c)
            }
        }
    }

    @ViewBuilder
    private var plainCover: some View {
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
                .opacity(IslandGlass.blackCover(progress: progress))
        }
    }
}

/// The closed island drawn in glass: where the camera housing is, so the
/// band over it stays black. Nil housing: a display without a notch, the
/// whole pill glass.
struct CompactGlass: Equatable {
    var housing: CGSize?
}

/// Solid black over the camera housing, easing into the glass either side
/// (`IslandGlass.compactHousingFeather`). Anchored on the camera like the
/// notch glow: moved back by the outline's shift on the same spring, so it
/// stays over the hardware while the pill is lopsided around it.
struct HousingBand: View {
    var housing: CGSize
    var shift: CGFloat

    var body: some View {
        let feather = IslandGlass.compactHousingFeather
        Color.clear.overlay(alignment: .top) {
            HStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                    .frame(width: feather)
                Rectangle().fill(.black).frame(width: housing.width)
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: feather)
            }
            .frame(height: housing.height)
            .offset(x: -shift)
            .islandCollapseChannel(.width)
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
/// draws everything else with `.withoutMaterial`: the shade, Fade's lens,
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

/// Fade's lens, drawn over its shade and under the content: what makes the
/// glass below the band read as a piece of glass rather than a tinted
/// window.
///
/// - The scrim: black behind the content (`IslandGlass.fadeScrim`), inset
///   from the walls and bottom edge with a soft edge, so text and the action
///   row near the bottom sit on enough dark over a bright or busy backdrop,
///   while a rim of lighter glass runs round them.
/// - The rim: a 1pt specular line along the outline, white at the bottom
///   corners and fainter between, fading out up the walls before the band.
/// - The glint: a thin spectral line across the middle of the bottom edge
///   and a low haze of the same colours rising a few points from it.
///
/// The rim and glint are the lens's light (`FadeLight`): spectral, or the
/// current cover's colours, cross-faded when that changes — an opacity
/// transition on the change alone, nothing running at rest.
///
/// The light is added (plus-lighter), as light on glass is. Everything is
/// static and laid out against the outline's current frame, with the band
/// as the only fixed length, so it follows the panel as it opens, collapses
/// and changes height, and the closed pill's black cover hides it all.
private struct FadeLens: View {
    var shape: NotchShape
    var bandHeight: CGFloat
    var light: FadeLight
    /// The open that earned a sweep (see `IslandGlassFill`), if any.
    var sweepAt: Date?

    var body: some View {
        let band = IslandGlass.fadeBand(notchHeight: bandHeight)
        ZStack {
            scrim(band: band)
            // Keyed by the light, so a new cover's colours come in as a new
            // view and the old fade out under them.
            //
            // Moved — a pulse, a flash — by Core Animation, in a layer of its
            // own (`StatusLightMotionHost`); still for every other state.
            StatusLightMotionHost(status: light.status) {
                ZStack {
                    ZStack {
                        if light.wraps {
                            wrapRim
                        } else {
                            rim(band: band)
                        }
                        glint
                    }
                    .id(light)
                    .transition(.opacity)
                }
                .animation(.easeInOut(duration: IslandGlass.fadeLightCrossfade), value: light)
            }
            FadeSweepRun(sweepAt: sweepAt, shape: shape, light: light)
        }
        .allowsHitTesting(false)
    }

    /// The outline's walls stand its top flare's radius in from the frame.
    private var wall: CGFloat { shape.topCornerRadius }

    /// Soft-edged black behind the content. Its top runs up under the band,
    /// where it can't be seen, so only the sides and bottom are soft.
    /// Flattened to one bitmap, so the blur costs nothing at rest.
    private func scrim(band: CGFloat) -> some View {
        let inset = wall + IslandGlass.fadeScrimInset
        let radius = max(shape.bottomCornerRadius - IslandGlass.fadeScrimInset, 0)
        return Color.clear.overlay {
            UnevenRoundedRectangle(bottomLeadingRadius: radius, bottomTrailingRadius: radius, style: .continuous)
                .fill(.black.opacity(IslandGlass.fadeScrim))
                .padding(.horizontal, inset)
                .padding(.bottom, IslandGlass.fadeScrimInset)
                .padding(.top, -2 * IslandGlass.fadeScrimFeather)
                .blur(radius: IslandGlass.fadeScrimFeather)
        }
        .drawingGroup()
    }

    /// The specular line round the lower outline.
    private func rim(band: CGFloat) -> some View {
        shape
            .stroke(LinearGradient(stops: light.rim, startPoint: .leading, endPoint: .trailing),
                    lineWidth: IslandGlass.fadeRimWidth)
            .mask {
                // Nothing over the band, then up to full by the bottom.
                VStack(spacing: 0) {
                    Color.clear.frame(height: band)
                    LinearGradient(colors: [.clear, .white], startPoint: .top, endPoint: .bottom)
                }
            }
            .blendMode(.plusLighter)
    }

    /// The rim when Claude needs you, is done or is stopped: the light's
    /// colours along the whole outline, up the sides to the top, held just
    /// off the screen's edge so the top itself isn't lit.
    private var wrapRim: some View {
        shape
            .stroke(LinearGradient(stops: light.wrap, startPoint: .leading, endPoint: .trailing),
                    lineWidth: IslandGlass.fadeRimWidth)
            .mask {
                VStack(spacing: 0) {
                    Color.clear.frame(height: StatusLight.wrapTopClearance)
                    Color.white
                }
            }
            .blendMode(.plusLighter)
    }

    /// The spectral line and its haze along the bottom edge.
    private var glint: some View {
        let colors = LinearGradient(stops: light.glint, startPoint: .leading, endPoint: .trailing)
        return ZStack(alignment: .bottom) {
            shape
                .stroke(colors, lineWidth: IslandGlass.fadeGlintWidth)
                .opacity(IslandGlass.fadeGlintAlpha)
                .mask {
                    VStack(spacing: 0) {
                        Color.clear
                        LinearGradient(colors: [.clear, .white], startPoint: .top, endPoint: .bottom)
                            .frame(height: IslandGlass.fadeGlintReach)
                    }
                }
            Rectangle()
                .fill(colors)
                .frame(height: IslandGlass.fadeHazeHeight)
                .mask(LinearGradient(colors: [.clear, .white], startPoint: .top, endPoint: .bottom))
                .opacity(IslandGlass.fadeHazeAlpha)
        }
        .blendMode(.plusLighter)
    }
}

/// Runs Fade's sweep once for the open that earned it: from nothing at the
/// centre to the corners over `IslandGlass.fadeSweepDuration`, eased out,
/// starting `fadeSweepDelay` after the open — when the outline first
/// reaches its full width. One animation of one value (`FadeSweep`'s
/// phase); before and after it, nothing is drawn and nothing runs.
private struct FadeSweepRun: View {
    var sweepAt: Date?
    var shape: NotchShape
    var light: FadeLight

    /// 1 at rest (done, or never started): nothing drawn.
    @State private var phase: Double = 1

    var body: some View {
        // On a clear view that's always there: at rest the sweep draws
        // nothing, and a view that draws nothing never appears.
        Color.clear
            .overlay { FadeSweep(phase: phase, shape: shape, light: light) }
            .onAppear(perform: start)
            .onChange(of: sweepAt) { _, _ in start() }
    }

    private func start() {
        guard let sweepAt else { return }
        // The lens is rebuilt with each open, a moment after the open that
        // set `sweepAt`; anything older is a sweep already run.
        let age = Date().timeIntervalSince(sweepAt)
        guard age >= 0, age < IslandGlass.fadeSweepDelay else { return }
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) { phase = 0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + (IslandGlass.fadeSweepDelay - age)) {
            withAnimation(.easeOut(duration: IslandGlass.fadeSweepDuration)) { phase = 1 }
        }
    }
}

/// The sweep at `phase` of its run: the light's colours, bright, along the
/// lower rim with a low haze under it, carried by two soft highlights that
/// part from the centre (`IslandGlass.fadeSweepMask`) and faded in and out
/// over the run (`fadeSweepEnvelope`). Animatable on the phase alone; at 0
/// and 1 it draws nothing at all.
private struct FadeSweep: View, Animatable {
    var phase: Double
    var shape: NotchShape
    var light: FadeLight

    var animatableData: Double {
        get { phase }
        set { phase = newValue }
    }

    var body: some View {
        let envelope = IslandGlass.fadeSweepEnvelope(phase: phase)
        if phase > 0, phase < 1, envelope > 0.001 {
            let colors = LinearGradient(stops: light.sweep, startPoint: .leading, endPoint: .trailing)
            let carry = IslandGlass.fadeSweepMask(phase: phase).map {
                Gradient.Stop(color: .white.opacity($0.alpha), location: $0.location)
            }
            ZStack(alignment: .bottom) {
                shape
                    .stroke(colors, lineWidth: IslandGlass.fadeGlintWidth)
                    .opacity(IslandGlass.fadeSweepAlpha)
                Rectangle()
                    .fill(colors)
                    .frame(height: IslandGlass.fadeHazeHeight)
                    .mask(LinearGradient(colors: [.clear, .white], startPoint: .top, endPoint: .bottom))
                    .opacity(IslandGlass.fadeSweepHazeAlpha)
            }
            .mask {
                // The lower rim only, thinning out up the walls.
                VStack(spacing: 0) {
                    Color.clear
                    LinearGradient(colors: [.clear, .white], startPoint: .top, endPoint: .bottom)
                        .frame(height: IslandGlass.fadeGlintReach)
                }
            }
            .mask(LinearGradient(stops: carry, startPoint: .leading, endPoint: .trailing))
            .opacity(envelope)
            .blendMode(.plusLighter)
        }
    }
}

/// Where Fade's light takes its colours from: the current track's cover
/// (nil with no track or no cover: the spectrum), and Claude's status with
/// its colour (nil: none, the cover's alone). See `StatusLight`.
struct IslandLightSource: Equatable {
    var palette: ArtworkPalette?
    var status: StatusLightKind?
    var statusHex: String?

    static let none = IslandLightSource()
}

/// Fade's light: the rim's and the glint's gradients, the sweep's, and the
/// status light's. Spectral with no cover; from a cover, the glint in its
/// palette's colours (`IslandGlass.fadeGlint`, each lit to a brightness
/// floor so a dark or grey cover still throws light) and the rim's white
/// faintly tinted toward its primary (`IslandGlass.fadeRimColor`). With a
/// status, every colour goes `StatusLight.mix` of the way to the status's,
/// and the rim's white is tinted toward it. Consumes the palette the view
/// model already extracted; extracts nothing.
struct FadeLight: Hashable {
    var rim: [Gradient.Stop]
    var glint: [Gradient.Stop]
    /// The sweep's colours: the glint's at full strength across the middle
    /// and the rim's colour out at the corners, where the glint fades.
    var sweep: [Gradient.Stop]
    /// The wrapped rim's colours, all the way across at full strength
    /// (`StatusLight.wrapAlpha`): the light's colours, edge to edge.
    var wrap: [Gradient.Stop]
    /// The closed island's lit lower edge: the light's colours, fading in
    /// from each end.
    var edge: [Gradient.Stop]
    /// The light's three colours — the cover's primary, secondary and
    /// accent, lit and blended — for the closed island's waveform and dots.
    var colors: [Color]
    /// The status the light shows, and its colour (nil: none).
    var status: StatusLightKind?
    var statusColor: Color?

    /// The light runs the whole outline, not just its lower edge.
    var wraps: Bool { status?.wraps ?? false }
    var motion: StatusLightMotion { status?.motion ?? .still }

    static let spectral = FadeLight(glint: IslandGlass.fadeSpectralGlint(), rim: nil, status: nil, statusRGB: nil)

    private init(glint: [IslandGlass.GlintStop], rim primary: IslandGlass.HSB?, status: StatusLightKind?, statusRGB: StatusLight.RGB?) {
        func color(_ c: StatusLight.RGB) -> Color { Color(.sRGB, red: c.r, green: c.g, blue: c.b) }
        // Every colour of the light: lit, then blended with the status.
        let lit = glint.map { stop -> StatusLight.RGB in
            let c = IslandGlass.rgb(stop.color)
            return StatusLight.blend(StatusLight.RGB(c.r, c.g, c.b), status: statusRGB)
        }
        let rimRGB: StatusLight.RGB = {
            if let statusRGB { return StatusLight.RGB(1, 1, 1).mixed(toward: statusRGB, by: StatusLight.rimTint) }
            let c = IslandGlass.fadeRimColor(primary: primary)
            return StatusLight.RGB(c.r, c.g, c.b)
        }()
        let rimColor = color(rimRGB)
        rim = IslandGlass.fadeRimStops().map {
            Gradient.Stop(color: rimColor.opacity($0.alpha), location: $0.location)
        }
        // Under a wrap, the glint steps back so the bottom doesn't outshine
        // the sides (`StatusLight.wrapGlintScale`).
        let glintScale = (status?.wraps ?? false) ? StatusLight.wrapGlintScale : 1
        self.glint = zip(glint, lit).map { stop, c in
            Gradient.Stop(color: color(c).opacity(stop.strength * glintScale), location: stop.location)
        }
        sweep = [Gradient.Stop(color: rimColor, location: 0)]
            + zip(glint, lit).map { stop, c in Gradient.Stop(color: color(c), location: stop.location) }
            + [Gradient.Stop(color: rimColor, location: 1)]
        // Across the whole width: the glint's colours, its first and last
        // carried out to the edges.
        let a = StatusLight.wrapAlpha
        wrap = [Gradient.Stop(color: color(lit[1]).opacity(a), location: 0)]
            + zip(glint, lit).dropFirst().dropLast().map { stop, c in Gradient.Stop(color: color(c).opacity(a), location: stop.location) }
            + [Gradient.Stop(color: color(lit[lit.count - 2]).opacity(a), location: 1)]
        let e = StatusLight.edgeAlpha, f = StatusLight.edgeFade
        edge = [
            Gradient.Stop(color: color(lit[1]).opacity(0), location: 0),
            Gradient.Stop(color: color(lit[1]).opacity(e), location: f),
            Gradient.Stop(color: color(lit[3]).opacity(e), location: 0.5),
            Gradient.Stop(color: color(lit[5]).opacity(e), location: 1 - f),
            Gradient.Stop(color: color(lit[5]).opacity(0), location: 1),
        ]
        // The glint lays secondary, secondary, primary, accent, primary, …
        colors = [color(lit[2]), color(lit[1]), color(lit[3])]
        self.status = status
        statusColor = statusRGB.map(color)
    }

    init(source: IslandLightSource) {
        let statusRGB = source.status.flatMap { kind in
            StatusLight.RGB(hex: source.statusHex ?? kind.defaultHex) ?? StatusLight.RGB(hex: kind.defaultHex)
        }
        let status = statusRGB == nil ? nil : source.status
        if let palette = source.palette {
            let primary = Self.hsb(palette.primary)
            self.init(
                glint: IslandGlass.fadeGlint(primary: primary, secondary: Self.hsb(palette.secondary), accent: Self.hsb(palette.accent)),
                rim: primary, status: status, statusRGB: statusRGB
            )
        } else {
            self.init(glint: IslandGlass.fadeSpectralGlint(), rim: nil, status: status, statusRGB: statusRGB)
        }
    }

    /// The light for a source. The last one is kept, since the lens is laid
    /// out on every frame of an open or resize and the source changes only
    /// with the cover or Claude's status.
    @MainActor
    static func resolve(_ source: IslandLightSource) -> FadeLight {
        if source == .none { return spectral }
        if let last, last.source == source { return last.light }
        let light = FadeLight(source: source)
        last = (source, light)
        return light
    }

    @MainActor private static var last: (source: IslandLightSource, light: FadeLight)?

    private static func hsb(_ color: Color) -> IslandGlass.HSB {
        guard let c = NSColor(color).usingColorSpace(.sRGB) else { return IslandGlass.HSB(h: 0, s: 0, b: 1) }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return IslandGlass.HSB(h: Double(h), s: Double(s), b: Double(b))
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
/// Glass and Smoked draw the frosted `.regular` variant; Fade the
/// `.clear`, which lets more of the backdrop's colour and light through. In
/// the window it's drawn in, which never becomes key (`IslandGlassLayer`),
/// both stay frosted: the backdrop's shapes and colours come through, its
/// detail doesn't. (In a key window the system lenses the backdrop nearly
/// sharp, `.clear` most of all — which is what a focused reply field used
/// to show for as long as it was focused.)
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

    var body: some View {
        if #available(macOS 26.0, *) {
            Color.clear
                .glassEffect(clear ? .clear : .regular, in: shape)
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
