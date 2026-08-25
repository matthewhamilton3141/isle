//
//  BreathingShapeView.swift
//
//  A reusable "breathing" pulse animation (scale + opacity, looping)
//  for any vector shape, driven by TimelineView + Canvas.
//
//  Because it's driven by wall-clock time (timeline.date) rather than
//  a toggled @State value, the animation is frame-accurate, never
//  drifts, and needs no start/stop management — it just runs for as
//  long as the view is on screen.
//

import SwiftUI

// MARK: - Breathing Shape View

struct BreathingShapeView: View {

    /// Builds the path to animate, given the view's current bounding rect.
    /// Matches SwiftUI's `Shape.path(in:)` signature so you can pass any
    /// `Shape` in directly (see the `Shape`-based initializer below).
    var pathBuilder: (CGRect) -> Path

    var color: Color = .accentColor

    /// Full cycle length in seconds (min -> max -> min).
    var period: Double = 1.6

    var minScale: CGFloat = 0.85
    var maxScale: CGFloat = 1.0
    var minOpacity: Double = 0.55
    var maxOpacity: Double = 1.0

    /// Inset from the view's edges, so the shape has room to scale up
    /// without clipping.
    var padding: CGFloat = 4

    init(
        color: Color = .accentColor,
        period: Double = 1.6,
        minScale: CGFloat = 0.85,
        maxScale: CGFloat = 1.0,
        minOpacity: Double = 0.55,
        maxOpacity: Double = 1.0,
        padding: CGFloat = 4,
        path: @escaping (CGRect) -> Path
    ) {
        self.pathBuilder = path
        self.color = color
        self.period = period
        self.minScale = minScale
        self.maxScale = maxScale
        self.minOpacity = minOpacity
        self.maxOpacity = maxOpacity
        self.padding = padding
    }

    /// Convenience initializer accepting any SwiftUI `Shape`.
    init<S: Shape>(
        shape: S,
        color: Color = .accentColor,
        period: Double = 1.6,
        minScale: CGFloat = 0.85,
        maxScale: CGFloat = 1.0,
        minOpacity: Double = 0.55,
        maxOpacity: Double = 1.0,
        padding: CGFloat = 4
    ) {
        self.init(
            color: color,
            period: period,
            minScale: minScale,
            maxScale: maxScale,
            minOpacity: minOpacity,
            maxOpacity: maxOpacity,
            padding: padding,
            path: { rect in shape.path(in: rect) }
        )
    }

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let now = timeline.date.timeIntervalSinceReferenceDate

                // Sine wave in [0, 1] gives a free, smooth ease-in-out
                // loop with no explicit animation curve bookkeeping.
                let phase = (sin(now * 2 * .pi / period - .pi / 2) + 1) / 2

                let scale = minScale + (maxScale - minScale) * phase
                let opacity = minOpacity + (maxOpacity - minOpacity) * phase

                let bounds = CGRect(origin: .zero, size: size)
                    .insetBy(dx: padding, dy: padding)

                var shapePath = pathBuilder(bounds)

                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                var transform = CGAffineTransform(translationX: center.x, y: center.y)
                transform = transform.scaledBy(x: scale, y: scale)
                transform = transform.translatedBy(x: -center.x, y: -center.y)
                shapePath = shapePath.applying(transform)

                context.opacity = opacity
                context.fill(shapePath, with: .color(color))
            }
        }
        .accessibilityHidden(true) // it's decorative/status-only; pair with a text status if needed
    }
}

// MARK: - Placeholder mark

/// A generic 4-point spark/sparkle shape as a stand-in for your own logo.
/// Swap this out for your real mark — pass any `Shape` (or raw `Path`
/// closure) into `BreathingShapeView` instead.
struct SparkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width, h = rect.height
        let cx = rect.midX, cy = rect.midY

        // Four-pointed star: alternating long (tip) and short (waist) radii.
        let longR: CGFloat = min(w, h) / 2
        let shortR: CGFloat = longR * 0.32

        let points: [(CGFloat, CGFloat)] = [
            (0, -longR), (shortR, -shortR),
            (longR, 0), (shortR, shortR),
            (0, longR), (-shortR, shortR),
            (-longR, 0), (-shortR, -shortR)
        ]

        for (i, pt) in points.enumerated() {
            let x = cx + pt.0, y = cy + pt.1
            if i == 0 { p.move(to: CGPoint(x: x, y: y)) }
            else { p.addLine(to: CGPoint(x: x, y: y)) }
        }
        p.closeSubpath()
        return p
    }
}

// MARK: - Example usage

struct BreathingSparkExample: View {
    var body: some View {
        BreathingShapeView(
            shape: SparkShape(),
            color: .orange,
            period: 1.6,
            minScale: 0.8,
            maxScale: 1.0,
            minOpacity: 0.5,
            maxOpacity: 1.0
        )
        .frame(width: 32, height: 32)
    }
}

#Preview {
    BreathingSparkExample()
        .padding(40)
}
