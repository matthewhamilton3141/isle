//
//  NotchShape.swift
//
//  The notch outline: square at the top where it meets the bezel, rounded
//  at the bottom, with small *inverted* curves at the top corners so the
//  shape flows out of the screen edge instead of butting against it.
//  That top flare is what sells it as part of the hardware rather than a
//  rectangle parked under the menu bar.
//

import SwiftUI

struct NotchShape: Shape {
    /// Radius of the concave flare where the notch meets the screen edge.
    var topCornerRadius: CGFloat
    /// Radius of the convex bottom corners.
    var bottomCornerRadius: CGFloat

    init(topCornerRadius: CGFloat = 8, bottomCornerRadius: CGFloat = 14) {
        self.topCornerRadius = topCornerRadius
        self.bottomCornerRadius = bottomCornerRadius
    }

    /// Animating the two radii together keeps the corners proportional while
    /// the panel resizes, instead of the bottom curve popping at the end.
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topCornerRadius, bottomCornerRadius) }
        set {
            topCornerRadius = newValue.first
            bottomCornerRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()

        // Clamp so a small collapsed height can't produce overlapping arcs
        // that render as a bowtie.
        let maxRadius = min(rect.width, rect.height) / 2
        let top = min(topCornerRadius, maxRadius)
        let bottom = min(bottomCornerRadius, maxRadius)

        path.move(to: CGPoint(x: rect.minX, y: rect.minY))

        // Top-left: concave quarter-circle flaring out to the screen edge.
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + top, y: rect.minY + top),
            control: CGPoint(x: rect.minX + top, y: rect.minY)
        )

        // Left edge down to the bottom-left curve.
        path.addLine(to: CGPoint(x: rect.minX + top, y: rect.maxY - bottom))

        // Bottom-left: convex.
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + top + bottom, y: rect.maxY),
            control: CGPoint(x: rect.minX + top, y: rect.maxY)
        )

        // Across the bottom.
        path.addLine(to: CGPoint(x: rect.maxX - top - bottom, y: rect.maxY))

        // Bottom-right: convex.
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - top, y: rect.maxY - bottom),
            control: CGPoint(x: rect.maxX - top, y: rect.maxY)
        )

        // Right edge back up.
        path.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY + top))

        // Top-right: concave.
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - top, y: rect.minY)
        )

        path.closeSubpath()
        return path
    }
}

#Preview("Notch shapes") {
    VStack(spacing: 24) {
        NotchShape()
            .fill(.black)
            .frame(width: 200, height: 32)

        NotchShape(topCornerRadius: 10, bottomCornerRadius: 22)
            .fill(.black)
            .frame(width: 420, height: 150)
    }
    .padding(40)
    .background(.white)
}
