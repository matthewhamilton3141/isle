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

    /// Set while the island is collapsing: the sizes it is collapsing from
    /// and to. The shape reads its taper (side walls drawing in toward the
    /// bottom) off how far its rect's width has come ahead of its height
    /// (`IslandMotion.taper`), so the taper exists only while the width
    /// leads and is gone once both have settled. Not animatable: the frame's
    /// own springs are what move it.
    var genie: Genie?

    struct Genie: Equatable {
        var expanded: CGSize
        var collapsed: CGSize
        /// The camera housing. A collapse never draws narrower than it, and
        /// never pinches its waist into it: the cutout's bottom corners are
        /// rounded, so an outline drawn inside the band would show the menu
        /// bar between the hardware and the island for a frame or two.
        var band: CGSize
        /// How far the collapsed pill sits off-centre over the band
        /// (NotchRootView's `collapsedShift`), so the waist is judged against
        /// where the band really is.
        var bandShift: CGFloat = 0
    }

    init(topCornerRadius: CGFloat = 8, bottomCornerRadius: CGFloat = 14, genie: Genie? = nil) {
        self.topCornerRadius = topCornerRadius
        self.bottomCornerRadius = bottomCornerRadius
        self.genie = genie
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

    func path(in frame: CGRect) -> Path {
        var path = Path()

        // A collapsing island's width settles a few points past its target.
        // For a bare island the target is the camera band itself, so hold the
        // outline at the band's width and let the overshoot happen out of
        // sight under the hardware.
        var rect = frame
        if let genie, rect.width < genie.band.width {
            rect = rect.insetBy(dx: (rect.width - genie.band.width) / 2, dy: 0)
        }

        // Clamp so a small collapsed height can't produce overlapping arcs
        // that render as a bowtie.
        let maxRadius = min(rect.width, rect.height) / 2
        let top = min(topCornerRadius, maxRadius)
        let bottom = min(bottomCornerRadius, maxRadius)

        // How far each wall draws in by the bottom. Zero unless collapsing,
        // and capped so the two bottom corners never meet.
        let pinch: CGFloat = {
            guard let genie else { return 0 }
            let t = IslandMotion.taper(rect: frame.size, expanded: genie.expanded, collapsed: genie.collapsed)
            return min(t, max(0, (rect.width - 2 * (top + bottom)) / 2))
        }()

        // With a taper the wall is an S-curve rather than a line: vertical
        // where it leaves the flare and vertical where it meets the corner,
        // so the outline stays smooth at both joins and only the waist moves.
        // The pinch starts at the flare when the pinched wall still clears
        // the camera band (where it really sits, with the pill's off-centre
        // shift and 2pt to spare); otherwise only below the band, so nothing
        // draws in under the cutout.
        let wallTop = rect.minY + top
        let wallBottom = rect.maxY - bottom
        let taperTop: CGFloat = {
            guard let genie else { return wallTop }
            let clear = rect.width - 2 * (top + pinch) >= genie.band.width + 2 * (abs(genie.bandShift) + 2)
            return clear ? wallTop : max(wallTop, rect.minY + genie.band.height)
        }()
        let taper = taperTop < wallBottom ? pinch : 0
        let ease = (wallBottom - taperTop) * 0.45

        path.move(to: CGPoint(x: rect.minX, y: rect.minY))

        // Top-left: concave quarter-circle flaring out to the screen edge.
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + top, y: wallTop),
            control: CGPoint(x: rect.minX + top, y: rect.minY)
        )

        // Left edge down to the bottom-left curve.
        if taper > 0 {
            if taperTop > wallTop {
                path.addLine(to: CGPoint(x: rect.minX + top, y: taperTop))
            }
            path.addCurve(
                to: CGPoint(x: rect.minX + top + taper, y: wallBottom),
                control1: CGPoint(x: rect.minX + top, y: taperTop + ease),
                control2: CGPoint(x: rect.minX + top + taper, y: wallBottom - ease)
            )
        } else {
            path.addLine(to: CGPoint(x: rect.minX + top, y: wallBottom))
        }

        // Bottom-left: convex.
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + top + taper + bottom, y: rect.maxY),
            control: CGPoint(x: rect.minX + top + taper, y: rect.maxY)
        )

        // Across the bottom.
        path.addLine(to: CGPoint(x: rect.maxX - top - taper - bottom, y: rect.maxY))

        // Bottom-right: convex.
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - top - taper, y: wallBottom),
            control: CGPoint(x: rect.maxX - top - taper, y: rect.maxY)
        )

        // Right edge back up.
        if taper > 0 {
            path.addCurve(
                to: CGPoint(x: rect.maxX - top, y: taperTop),
                control1: CGPoint(x: rect.maxX - top - taper, y: wallBottom - ease),
                control2: CGPoint(x: rect.maxX - top, y: taperTop + ease)
            )
            if taperTop > wallTop {
                path.addLine(to: CGPoint(x: rect.maxX - top, y: wallTop))
            }
        } else {
            path.addLine(to: CGPoint(x: rect.maxX - top, y: wallTop))
        }

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
