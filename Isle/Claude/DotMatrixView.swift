//
//  DotMatrixView.swift
//
//  Renders a marker: a 4x4 grid of dots described by a MarkerDesign. The
//  design says which dots are lit, how they're coloured (artwork palette or a
//  fixed hue), and how they animate (solid / shimmer / pulse / blink). Both
//  the live notch and the marker editor use this same renderer, so what you
//  design is exactly what shows up in the island.
//
//  Time-driven, like the waveform: a TimelineView feeds wall-clock time to a
//  Canvas, so animation never drifts and needs no start/stop bookkeeping. When
//  the lit dots change (a state change, or a keystroke in the editor) the grid
//  morphs — the old layout eases into the new one — so dots slide on and off.
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

    private static let morphDuration: Double = 0.45

    @State private var fromLevels: [Double]
    @State private var toLevels: [Double]
    @State private var transitionStart: Date = .distantPast

    init(design: MarkerDesign, palette: ArtworkPalette = .fallback, tint: Color? = nil) {
        self.design = design
        self.palette = palette
        self.tint = tint
        let levels = Self.levels(for: design)
        _fromLevels = State(initialValue: levels)
        _toLevels = State(initialValue: levels)
    }

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                render(into: &context, size: size, now: timeline.date)
            }
        }
        .onChange(of: design) { _, newDesign in
            // Only the lit-dot layout morphs; colour/animation changes are read
            // straight from `design` each frame, so they update instantly.
            let next = Self.levels(for: newDesign)
            if next != toLevels {
                fromLevels = currentLevels(at: Date())
                toLevels = next
                transitionStart = Date()
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: - Morph

    /// Target base level per dot: lit dots at 1, unlit as a faint ghost (or 0).
    /// Bounds-checked against `dotCount` so a stale design of the wrong length
    /// (e.g. a 4x4 file loaded after the switch to 5x5) can't index out of range.
    private static func levels(for design: MarkerDesign) -> [Double] {
        let ghost = design.ghost ? 0.08 : 0.0
        return (0..<MarkerDesign.dotCount).map { i in
            let lit = i < design.dots.count && design.dots[i]
            return lit ? 1.0 : ghost
        }
    }

    private func morphProgress(at now: Date) -> Double {
        let raw = min(1, max(0, now.timeIntervalSince(transitionStart) / Self.morphDuration))
        return raw * raw * (3 - 2 * raw)   // smoothstep
    }

    private func currentLevels(at now: Date) -> [Double] {
        let t = morphProgress(at: now)
        return (0..<MarkerDesign.dotCount).map {
            fromLevels[$0] + (toLevels[$0] - fromLevels[$0]) * t
        }
    }

    // MARK: - Rendering

    private func render(into context: inout GraphicsContext, size: CGSize, now: Date) {
        let n = MarkerDesign.dimension
        let cell = min(size.width, size.height) / CGFloat(n)
        let ox = (size.width - cell * CGFloat(n)) / 2
        let oy = (size.height - cell * CGFloat(n)) / 2

        let base = currentLevels(at: now)
        let clock = now.timeIntervalSinceReferenceDate
        let speed = design.speed

        let primary = RGBA(palette.primary)
        let accent = RGBA(palette.accent)
        let secondary = RGBA(palette.secondary)
        // A tint overrides the design colour but keeps its shape/animation, so
        // the dots read as a single chosen hue with the same lively brightness
        // variation the fixed path already gives.
        let fixed = RGBA(tint ?? Color(hex: design.fixedColorHex))
        let fixedLift = fixed.lightened(0.35)
        let forceFixed = tint != nil

        // Whole-grid animation drivers shared by the non-shimmer modes.
        let pulse = 0.5 + 0.5 * sin(clock * speed)
        let breathe = 0.5 + 0.5 * sin(clock * speed * 0.5)
        let blinkOn = sin(clock * speed) > 0

        for row in 0..<n {
            for col in 0..<n {
                let index = row * n + col
                let level = base[index]
                guard level > 0.001 else { continue }

                let anim: Double
                switch design.animation {
                case .solid:
                    anim = 0.82 + 0.18 * breathe
                case .shimmer:
                    let phase = Double(row) * 0.8 + Double(col) * 0.55
                    anim = 0.30 + 0.70 * (0.5 + 0.5 * sin(clock * speed + phase))
                case .pulse:
                    anim = 0.35 + 0.65 * pulse
                case .blink:
                    anim = blinkOn ? 1.0 : 0.12
                case .motion:
                    anim = motionValue(row: row, col: col, clock: clock, speed: speed)
                case .compact:
                    anim = compactValue(row: row, clock: clock, speed: speed)
                }

                let intensity = design.intensity * level * anim
                guard intensity > 0.02 else { continue }

                // A small bump on the radius so the dots read a little chunkier
                // (especially the small collapsed marker) without moving them.
                let radius = cell * 0.5 * (0.28 + 0.55 * min(1, intensity)) + 0.5
                let cx = ox + (Double(col) + 0.5) * cell
                let cy = oy + (Double(row) + 0.5) * cell
                let rect = CGRect(x: cx - radius, y: cy - radius, width: radius * 2, height: radius * 2)

                let color = dotColor(
                    row: row, col: col, clock: clock,
                    primary: primary, accent: accent, secondary: secondary,
                    fixed: fixed, fixedLift: fixedLift, forceFixed: forceFixed
                )
                .opacity(0.10 + 0.90 * min(1, intensity))

                context.fill(Path(ellipseIn: rect), with: .color(color))
            }
        }
    }

    private func dotColor(
        row: Int, col: Int, clock: Double,
        primary: RGBA, accent: RGBA, secondary: RGBA,
        fixed: RGBA, fixedLift: RGBA, forceFixed: Bool
    ) -> Color {
        // A tint forces the fixed path regardless of the design's colour mode.
        if forceFixed {
            let u = 0.5 + 0.5 * sin(clock * 0.9 + Double(row + col) * 0.5)
            return fixed.lerp(to: fixedLift, u * 0.6)
        }
        switch design.colorMode {
        case .palette:
            // A colour that drifts along the palette and differs per dot, so
            // different circles show different colours changing over time.
            let u = fract(Double(row) * 0.19 + Double(col) * 0.13 + clock * 0.05)
            return paletteRamp(u, primary, accent, secondary)
        case .fixed:
            // Subtle per-dot brightness variation so a fixed colour still lives.
            let u = 0.5 + 0.5 * sin(clock * 0.9 + Double(row + col) * 0.5)
            return fixed.lerp(to: fixedLift, u * 0.6)
        }
    }

    private func paletteRamp(_ u: Double, _ primary: RGBA, _ accent: RGBA, _ secondary: RGBA) -> Color {
        let stops = [primary, accent, secondary]
        let seg = u * Double(stops.count)
        let i = Int(floor(seg)) % stops.count
        return stops[i].lerp(to: stops[(i + 1) % stops.count], seg - floor(seg))
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

// MARK: - Colour helpers

/// Straight-line RGBA colour so dots can interpolate between hues each frame.
private struct RGBA {
    var r, g, b, a: Double

    init(_ r: Double, _ g: Double, _ b: Double, _ a: Double) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
        self.init(Double(ns.redComponent), Double(ns.greenComponent),
                  Double(ns.blueComponent), Double(ns.alphaComponent))
    }

    func lerp(to other: RGBA, _ t: Double) -> Color {
        Color(
            .sRGB,
            red: r + (other.r - r) * t,
            green: g + (other.g - g) * t,
            blue: b + (other.b - b) * t,
            opacity: a + (other.a - a) * t
        )
    }

    func lightened(_ amount: Double) -> RGBA {
        RGBA(r + (1 - r) * amount, g + (1 - g) * amount, b + (1 - b) * amount, a)
    }
}

private func fract(_ x: Double) -> Double { x - floor(x) }
