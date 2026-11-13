//
//  NotchShape.swift
//
//  The notch outline: square at the top where it meets the bezel, rounded
//  at the bottom, with small *inverted* curves at the top corners so the
//  shape flows out of the screen edge instead of butting against it.
//  That top flare is what sells it as part of the hardware rather than a
//  rectangle parked under the menu bar.
//
//  Off the notch (`IslandPlacement.floating`) there's no bezel to flow out
//  of: the flares go and the top corners round like the bottom ones
//  (`crownRadius`), a complete form. One curve draws both, so docking and
//  undocking morph one into the other — see `path(in:)`.
//

import SwiftUI

struct NotchShape: Shape {
    /// Radius of the concave flare where the notch meets the screen edge,
    /// which is also how far the side walls stand in from the frame. Zero
    /// off the notch: the walls are the frame's edges.
    var topCornerRadius: CGFloat
    /// Radius of the convex bottom corners.
    var bottomCornerRadius: CGFloat
    /// Radius of convex top corners: zero on the notch, where the top is
    /// square against the bezel, and the island's own roundness off it.
    var crownRadius: CGFloat

    /// Set while the island is collapsing: the sizes it is collapsing from
    /// and to. The shape reads its taper (side walls drawing in toward the
    /// bottom) off how far its rect's width has come ahead of its height
    /// (`IslandMotion.taper`), so the taper exists only while the width
    /// leads and is gone once both have settled. Not animatable: the
    /// outline's width and height, each on its own spring
    /// (`IslandOutlineLength`), are what move it.
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

    /// How much clearance over the camera band the pinched wall needs
    /// before its taper may start right at the flare; below it the start
    /// slides toward the band's bottom edge.
    private static let clearanceRamp: CGFloat = 24

    /// How much straight wall the taper needs below its start to draw at
    /// full depth; on a shorter wall it draws in proportionally less.
    private static let taperRamp: CGFloat = 20

    init(topCornerRadius: CGFloat = 8, bottomCornerRadius: CGFloat = 14, crownRadius: CGFloat = 0, genie: Genie? = nil) {
        self.topCornerRadius = topCornerRadius
        self.bottomCornerRadius = bottomCornerRadius
        self.crownRadius = crownRadius
        self.genie = genie
    }

    /// Animating the radii together keeps the corners proportional while
    /// the panel resizes, instead of the bottom curve popping at the end —
    /// and takes the flares into the crown, and back, when the island
    /// leaves the notch or returns to it.
    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat> {
        get { AnimatablePair(AnimatablePair(topCornerRadius, bottomCornerRadius), crownRadius) }
        set {
            topCornerRadius = newValue.first.first
            bottomCornerRadius = newValue.first.second
            crownRadius = newValue.second
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
        // that render as a bowtie. (A spring settling the flare to nothing
        // passes a hair below it; never negative.)
        let maxRadius = min(rect.width, rect.height) / 2
        let top = min(max(topCornerRadius, 0), maxRadius)
        let bottom = min(bottomCornerRadius, maxRadius)
        let crown = min(max(crownRadius, 0), maxRadius)

        // Each top corner is one curve round the point where the wall meets
        // the top edge. On the notch it runs from the wall out along the
        // bezel, away from the island: the flare. Off it, it runs from the
        // wall in along the island's own top edge: a rounded corner. `reach`
        // is where along the top edge the curve ends, measured from the
        // wall toward the island's middle — minus the flare's radius, plus
        // the crown's — and `drop` how far down the wall it starts. Between
        // the two the flare draws in to a square corner and the corner
        // rounds off, so the one shape morphs into the other.
        let reach = crown - top
        let drop = top + crown

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
        // The pinch starts at the flare while the pinched wall clears the
        // camera band by a margin (where the band really sits, with the
        // pill's off-centre shift and 2pt to spare), and only below the band
        // once it doesn't, so nothing draws in under the cutout. Between the
        // two the start slides down, and the pinch shrinks to nothing as the
        // wall below its start does: every frame of a collapse draws this
        // shape, so neither change may happen all at once.
        let wallTop = rect.minY + drop
        let wallBottom = rect.maxY - bottom
        let taperTop: CGFloat = {
            guard let genie else { return wallTop }
            let bandBottom = max(wallTop, rect.minY + genie.band.height)
            let clearance = rect.width - 2 * (top + pinch) - (genie.band.width + 2 * (abs(genie.bandShift) + 2))
            let below = min(max(1 - clearance / Self.clearanceRamp, 0), 1)
            return wallTop + (bandBottom - wallTop) * below
        }()
        let room = wallBottom - taperTop
        let taper = room > 0 ? pinch * min(1, room / Self.taperRamp) : 0
        let ease = room * 0.45

        path.move(to: CGPoint(x: rect.minX + top + reach, y: rect.minY))

        // Top-left: the flare out to the screen edge, or the crown.
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

        // Top-right: the same curve, mirrored.
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - top - reach, y: rect.minY),
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

        // Off the notch: closed, open, and half way between docked and not.
        NotchShape(topCornerRadius: 0, bottomCornerRadius: 19, crownRadius: 19)
            .fill(.black)
            .frame(width: 200, height: 38)

        NotchShape(topCornerRadius: 0, bottomCornerRadius: 22, crownRadius: 22)
            .fill(.black)
            .frame(width: 400, height: 150)

        NotchShape(topCornerRadius: 5, bottomCornerRadius: 22, crownRadius: 11)
            .fill(.black)
            .frame(width: 410, height: 150)
    }
    .padding(40)
    .background(.white)
}
