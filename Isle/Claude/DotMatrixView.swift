//
//  DotMatrixView.swift
//
//  Renders a marker: a 5x5 grid of dots described by a MarkerDesign. The
//  design says which dots are lit, how they're coloured (artwork palette or a
//  fixed hue), and how they animate (solid / shimmer / pulse / blink / motion /
//  compact). Both the live notch and the marker editor use this same renderer,
//  so what you design is exactly what shows up in the island.
//
//  Drawn by Core Animation, not per-frame by us. Every one of these animations
//  is a function of wall-clock time, so instead of waking up 30 times a second
//  to draw the next frame, we hand Core Animation the whole curve once and let
//  the render server play it. The app then does nothing at all while the marker
//  animates.
//
//  That matters because the per-frame cost was never the arithmetic — 25 circles
//  is nothing. It was SwiftUI's pipeline around it: a view-graph update, a
//  display-list rebuild and a Core Animation commit, 30 times a second, for as
//  long as a marker was on screen. Measured, that was ~8% of a core; the marker
//  now animates for approximately none.
//
//  The dots still morph when the design changes — the old layout eases into the
//  new one over `morphDuration`, so dots slide on and off — which is why each
//  dot gets a short one-shot transition animation ahead of its steady loop.
//  This is an original mark, not a copy of Anthropic's.
//

import SwiftUI
import AppKit

struct DotMatrixView: View {
    var design: MarkerDesign
    var palette: ArtworkPalette
    /// Overrides the design's colour entirely, keeping its shape and animation.
    /// Used to paint the working marker warm (thinking = yellow, working =
    /// orange) without touching the user's saved marker design.
    var tint: Color?

    init(design: MarkerDesign, palette: ArtworkPalette = .fallback, tint: Color? = nil) {
        self.design = design
        self.palette = palette
        self.tint = tint
    }

    var body: some View {
        DotMatrixLayerRepresentable(design: design, palette: palette, tint: tint)
            .accessibilityHidden(true)
    }
}

// MARK: - SwiftUI bridge

private struct DotMatrixLayerRepresentable: NSViewRepresentable {
    var design: MarkerDesign
    var palette: ArtworkPalette
    var tint: Color?

    func makeNSView(context: Context) -> DotMatrixLayerView {
        let view = DotMatrixLayerView()
        view.apply(design: design, palette: palette, tint: tint, animateMorph: false)
        return view
    }

    func updateNSView(_ view: DotMatrixLayerView, context: Context) {
        // Morph only the lit-dot layout; a colour or speed change just rebuilds
        // the loop in place, matching the old renderer's behaviour of reading
        // those straight from `design` rather than easing them.
        view.apply(design: design, palette: palette, tint: tint, animateMorph: true)
    }
}

// MARK: - Curves
//
// The single source of truth for what a dot looks like at a given instant.
// Everything here is a pure function of time, which is exactly what lets the
// whole thing be handed to Core Animation as keyframes.

struct DotMatrixCurves {
    var design: MarkerDesign
    /// Base level per dot: lit dots at 1, unlit as a faint ghost (or 0).
    var levels: [Double]
    var colors: DotColors
    /// Half the grid cell, needed because the dot radius has a constant term
    /// and so isn't a pure ratio.
    var cell: Double

    static let morphDuration: Double = 0.45

    /// Target base level per dot. Bounds-checked against `dotCount` so a stale
    /// design of the wrong length (e.g. a 4x4 file loaded after the switch to
    /// 5x5) can't index out of range.
    static func levels(for design: MarkerDesign) -> [Double] {
        let ghost = design.ghost ? 0.08 : 0.0
        return (0..<MarkerDesign.dotCount).map { i in
            let lit = i < design.dots.count && design.dots[i]
            return lit ? 1.0 : ghost
        }
    }

    // MARK: Periods
    //
    // The loop each curve repeats on. These are the *exact* periods of the
    // underlying functions, so a loop is seamless — the value and slope at the
    // end match the start, and nothing jumps at the seam.

    var animationPeriod: Double {
        let speed = max(design.speed, 0.0001)
        switch design.animation {
        case .solid:
            // Driven by `breathe`, which runs at half speed.
            return 4 * .pi / speed
        case .shimmer, .pulse, .blink:
            return 2 * .pi / speed
        case .compact:
            return 1 / (speed * 0.18)
        case .motion:
            // The one curve with no short exact period: it superimposes three
            // waves whose periods don't divide into each other, which is the
            // whole point of it ("never settles into an obvious repeat"). Its
            // true period is minutes long, far too much to hand over as
            // keyframes, so it loops on a long window instead — long enough
            // that a repeat isn't something you'd catch on a 16pt marker.
            return 30
        }
    }

    /// Whether `animationPeriod` is a bake rather than the curve's own period.
    var loopIsApproximate: Bool { design.animation == .motion }

    /// How much of a baked loop's tail cross-fades back into its head.
    ///
    /// Without this the wrap is a hard cut. `motion` isn't periodic, so at the
    /// end of the baked window the curve is nowhere near where it started —
    /// measured, the worst dot jumps 0.50 in opacity across a single 50ms
    /// keyframe, against a 0.08 largest step anywhere else in the loop. That
    /// reads as a flick, once every 30 seconds, which is far worse than the
    /// repeat the bake was accepted for. Lengthening the window doesn't help:
    /// with no period to land on, every length lands somewhere arbitrary (0.44
    /// at 10s, 0.50 at 30s, 0.55 at 60s).
    ///
    /// Cross-fading the tail into the head makes the loop close on itself by
    /// construction, whatever the window. Both sides are the same plasma so the
    /// blend reads as more of it; measured over the whole loop it takes the seam
    /// to exactly zero and leaves the largest step unchanged at 0.08.
    var loopBlend: Double { 3 }

    /// Samples a curve at one point of the loop, cross-fading the tail back into
    /// the head when the loop is a bake. `clock` is relative to the loop start.
    func looped(_ clock: Double, _ value: (Double) -> Double) -> Double {
        let base = value(clock)
        guard loopIsApproximate else { return base }
        let fadeStart = animationPeriod - loopBlend
        guard clock > fadeStart else { return base }
        let raw = min(1, (clock - fadeStart) / loopBlend)
        let weight = raw * raw * (3 - 2 * raw)          // smoothstep
        return base * (1 - weight) + value(clock - animationPeriod) * weight
    }

    var colorPeriod: Double {
        if colors.forceFixed || design.colorMode == .fixed {
            // 0.5 + 0.5 * sin(clock * 0.9 + …)
            return 2 * .pi / 0.9
        }
        // fract(… + clock * 0.05)
        return 1 / 0.05
    }

    // MARK: Per-dot values

    /// The animation term for one dot, 0…1.
    private func animation(row: Int, col: Int, clock: Double) -> Double {
        let speed = design.speed
        switch design.animation {
        case .solid:
            let breathe = 0.5 + 0.5 * sin(clock * speed * 0.5)
            return 0.82 + 0.18 * breathe
        case .shimmer:
            let phase = Double(row) * 0.8 + Double(col) * 0.55
            return 0.30 + 0.70 * (0.5 + 0.5 * sin(clock * speed + phase))
        case .pulse:
            return 0.35 + 0.65 * (0.5 + 0.5 * sin(clock * speed))
        case .blink:
            return sin(clock * speed) > 0 ? 1.0 : 0.12
        case .motion:
            return motionValue(row: row, col: col, clock: clock, speed: speed)
        case .compact:
            return compactValue(row: row, clock: clock, speed: speed)
        }
    }

    /// `design.intensity * level * anim`, the quantity both the radius and the
    /// alpha are derived from.
    func intensity(row: Int, col: Int, clock: Double, level: Double) -> Double {
        guard level > 0.001 else { return 0 }
        return design.intensity * level * animation(row: row, col: col, clock: clock)
    }

    /// The radius a dot is drawn at. A small bump on the radius so the dots read
    /// a little chunkier (especially the small collapsed marker) without moving
    /// them.
    func radius(forIntensity intensity: Double) -> Double {
        cell * 0.5 * (0.28 + 0.55 * min(1, intensity)) + 0.5
    }

    /// The largest radius any dot reaches, which is the size the layers are
    /// built at — everything below it is a scale-down.
    var maxRadius: Double { radius(forIntensity: 1) }

    /// Final layer opacity for a dot. Zero below the cull threshold, matching
    /// the old renderer, which skipped drawing those dots outright.
    func opacity(row: Int, col: Int, clock: Double, level: Double) -> Double {
        let value = intensity(row: row, col: col, clock: clock, level: level)
        guard value > 0.02 else { return 0 }
        let alpha = 0.10 + 0.90 * min(1, value)
        // The colour's own alpha multiplies in, exactly as `Color.opacity`
        // multiplied rather than replaced it.
        return alpha * colors.alpha(row: row, col: col, clock: clock)
    }

    /// Layer scale for a dot, relative to `maxRadius`.
    func scale(row: Int, col: Int, clock: Double, level: Double) -> Double {
        let value = intensity(row: row, col: col, clock: clock, level: level)
        guard value > 0.02 else { return 0 }
        return radius(forIntensity: value) / maxRadius
    }

    /// An evolving "plasma" for the `motion` animation: a plane wave whose
    /// direction slowly rotates, a ripple radiating from the centre, and a
    /// second wave crossing the other way. Superimposed, they never settle into
    /// an obvious repeat, so the working marker does a bunch of different things
    /// instead of a flat strobe.
    private func motionValue(row: Int, col: Int, clock: Double, speed: Double) -> Double {
        let t = clock * speed * 0.32
        let x = Double(col), y = Double(row)

        let a = t * 0.8
        let w1 = sin((x * cos(a) + y * sin(a)) * 1.5 + t * 2.0)

        let dx = x - 2, dy = y - 2
        let dist = (dx * dx + dy * dy).squareRoot()
        let w2 = sin(dist * 1.7 - t * 2.6)

        let b = -a * 0.6
        let w3 = sin((x * sin(b) + y * cos(b)) * 1.1 + t * 1.3)

        let v = (w1 + w2 + w3) / 3          // -1…1
        return 0.18 + 0.82 * (0.5 + 0.5 * v)
    }

    /// "Compacting": a full box collapses one line at a time from the top, down
    /// to a single row, then refills back to full — a triangle over the cycle so
    /// it loops without a hard snap. Rows are lit from the bottom up; the number
    /// lit tracks `fillCount`, and each row's edge is softened over ~one row so
    /// lines fade in/out rather than blink. Only the row matters (every dot in a
    /// line shares the level), so a filled marker reads as lines being compacted.
    private func compactValue(row: Int, clock: Double, speed: Double) -> Double {
        let n = Double(MarkerDesign.dimension)
        let frac = fract(clock * speed * 0.18)
        let tri = abs(2 * frac - 1)            // 1 → 0 → 1  (full, compact, full)
        let fillCount = 1 + tri * (n - 1)      // 1…n rows lit, from the bottom
        let cutoff = n - fillCount             // rows with index ≥ cutoff are lit

        // Soft one-row edge at the cutoff so a line eases off instead of blinking.
        let e = Double(row) - (cutoff - 0.5)
        let t = min(1, max(0, e))
        let on = t * t * (3 - 2 * t)           // smoothstep
        return 0.10 + 0.90 * on
    }
}

// MARK: - Colour

/// The frame-invariant colours a marker is drawn from, resolved once.
///
/// Turning a SwiftUI `Color` into components means bridging to NSColor and
/// converting colour space, and `fixedColorHex` means parsing a string — none of
/// which changes over the life of a design, so none of it belongs anywhere near
/// a per-frame path.
struct DotColors: Equatable {
    var primary: RGBA
    var accent: RGBA
    var secondary: RGBA
    /// A tint overrides the design colour but keeps its shape/animation, so the
    /// dots read as a single chosen hue with the same lively brightness
    /// variation the fixed path already gives.
    var fixed: RGBA
    var fixedLift: RGBA
    var forceFixed: Bool
    var colorMode: MarkerDesign.ColorMode

    init(design: MarkerDesign, palette: ArtworkPalette, tint: Color?) {
        primary = RGBA(palette.primary)
        accent = RGBA(palette.accent)
        secondary = RGBA(palette.secondary)
        fixed = RGBA(tint ?? Color(hex: design.fixedColorHex))
        fixedLift = fixed.lightened(0.35)
        forceFixed = tint != nil
        colorMode = design.colorMode
    }

    /// The hue for one dot at one instant, before the intensity alpha.
    func rgba(row: Int, col: Int, clock: Double) -> RGBA {
        // A tint forces the fixed path regardless of the design's colour mode.
        if forceFixed || colorMode == .fixed {
            // Subtle per-dot brightness variation so a fixed colour still lives.
            let u = 0.5 + 0.5 * sin(clock * 0.9 + Double(row + col) * 0.5)
            return fixed.lerp(to: fixedLift, u * 0.6)
        }
        // A colour that drifts along the palette and differs per dot, so
        // different circles show different colours changing over time.
        let u = fract(Double(row) * 0.19 + Double(col) * 0.13 + clock * 0.05)
        return paletteRamp(u)
    }

    func alpha(row: Int, col: Int, clock: Double) -> Double {
        rgba(row: row, col: col, clock: clock).a
    }

    private func paletteRamp(_ u: Double) -> RGBA {
        let stops = [primary, accent, secondary]
        let seg = u * Double(stops.count)
        let i = Int(floor(seg)) % stops.count
        return stops[i].lerped(to: stops[(i + 1) % stops.count], seg - floor(seg))
    }
}

/// Straight-line RGBA colour so dots can interpolate between hues.
struct RGBA: Equatable {
    var r, g, b, a: Double

    init(_ r: Double, _ g: Double, _ b: Double, _ a: Double) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
        self.init(Double(ns.redComponent), Double(ns.greenComponent),
                  Double(ns.blueComponent), Double(ns.alphaComponent))
    }

    func lerped(to other: RGBA, _ t: Double) -> RGBA {
        RGBA(r + (other.r - r) * t,
             g + (other.g - g) * t,
             b + (other.b - b) * t,
             a + (other.a - a) * t)
    }

    func lerp(to other: RGBA, _ t: Double) -> RGBA { lerped(to: other, t) }

    func lightened(_ amount: Double) -> RGBA {
        RGBA(r + (1 - r) * amount, g + (1 - g) * amount, b + (1 - b) * amount, a)
    }

    /// Opaque on purpose: the alpha travels on the layer's `opacity` instead, so
    /// the intensity curve and the hue curve can loop on their own periods.
    var opaqueCGColor: CGColor {
        CGColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }
}

func fract(_ x: Double) -> Double { x - floor(x) }
