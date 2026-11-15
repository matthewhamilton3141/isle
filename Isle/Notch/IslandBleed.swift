//
//  IslandBleed.swift
//
//  The notch's black seeping into an island that's carried toward it, and
//  draining out of one that's pulled away. Matthew: "when the detached
//  island gets closer to physical notch it could make like a little
//  animation like its start to bleed onto the island kinda, and reversed
//  for when u detach it". The first version drew liquid drips and a neck in
//  the gap between them; he called it "kind of buns" and asked for it
//  "within the isle thing", as a soft haze. So nothing is drawn outside the
//  island.
//
//  Far off, nothing. Within `reach` of the camera housing a soft dark haze
//  comes up on the island's top edge, under the camera, and spreads along
//  that edge and down into the island the closer it comes. At contact it is
//  the docked look's own black, the camera's black spread out
//  (`IslandPrism.BandStyle.spread`), so it hands over to the docked panel
//  without a change. Pulled away, the same in reverse.
//
//  A function of where the island is and nothing else: no clock. If the
//  pointer stops, the haze stops where it is. Docking and undocking move
//  the window (`IslandCarry`, `IslandGlide`), and the haze follows the
//  window. Only on a display with a camera housing: on one without, there
//  is nothing physical for black to bleed from, and nothing is drawn.
//
//  All in one space: points, y down from the screen's top edge, x from the
//  housing's centre line. Kept free of AppKit and SwiftUI so it compiles on
//  its own (scripts/test-island-bleed.sh). Drawn by IslandBleed+SwiftUI.swift
//  in the island's fill and moved by IslandBleed+AppKit.swift.
//

import CoreGraphics
import Foundation

enum IslandBleed {
    // MARK: - Tunables

    /// How far from the camera housing the haze starts, in points: from the
    /// housing's foot to the island's top edge (or its nearest corner of it,
    /// off to one side). Matthew's "when the detached island gets closer to
    /// physical notch". The notch takes the island back once its top is
    /// about 18pt under the housing on this Mac
    /// (`IslandPlacementBounds.snapReach`), so this is the approach before
    /// that. Tune here.
    static let reach: CGFloat = 110

    /// How far the haze spreads on the island at contact: along its top edge
    /// from under the camera, and down into it. The docked spread's own
    /// (`IslandPrism.spreadAcross`, `spreadDown`), so the haze ends as the
    /// docked look begins. Scaled down with distance. Tune there.
    static var stainAcross: CGFloat { IslandPrism.spreadAcross }
    static var stainDown: CGFloat { IslandPrism.spreadDown }

    /// How the haze darkens on the way in: its strength is the closeness to
    /// this power, so it stays faint for most of the approach and is only
    /// fully black at contact. Full black early read as a dark band across
    /// the island's top, too near the bar Matthew rejected ("the bar looks
    /// horrible"). Higher is fainter for longer. Tune here.
    static let stainDarkening: CGFloat = 2.2

    /// The housing's bottom corners (nothing reports them).
    static var housingCorner: CGFloat { IslandPrism.notchCornerRadius }

    // MARK: - The scene

    /// The housing and the island as they are now.
    struct Scene: Equatable {
        /// The physical camera housing, hanging from the top edge, centred.
        var housing: CGSize
        /// The island's drawn rect.
        var island: CGRect
        /// The radius of the island's top corners: distance is measured to
        /// the straight part of its top edge between them. 0 on the notch.
        var crown: CGFloat

        /// Half the housing's flat bottom.
        var housingFlat: CGFloat { max(housing.width / 2 - IslandBleed.housingCorner, 0) }

        /// The straight part of the island's top edge.
        var islandFlat: (left: CGFloat, right: CGFloat) {
            let left = island.minX + crown, right = island.maxX - crown
            return left <= right ? (left, right) : (island.midX, island.midX)
        }

        /// From the housing's foot down to the island's top edge; less than
        /// 0 when the island is up beside or under the housing.
        var gap: CGFloat { island.minY - housing.height }
    }

    /// How far the island is from the housing: from the housing's flat
    /// bottom to the flat of the island's top edge. 0 touching, and while
    /// the island is up over the housing's foot.
    static func distance(_ scene: Scene) -> CGFloat {
        let flat = scene.islandFlat, half = scene.housingFlat
        let dx = max(0, flat.left - half, -half - flat.right)
        let dy = max(scene.gap, 0)
        return (dx * dx + dy * dy).squareRoot()
    }

    /// 0 at `reach` and beyond, 1 touching.
    static func closeness(distance d: CGFloat) -> CGFloat {
        min(max(1 - d / reach, 0), 1)
    }

    /// The distance a closeness means: `closeness`'s inverse within reach.
    static func distance(closeness c: CGFloat) -> CGFloat {
        reach * (1 - min(max(c, 0), 1))
    }

    static func smooth(_ t: CGFloat) -> CGFloat {
        let u = min(max(t, 0), 1)
        return u * u * (3 - 2 * u)
    }

    // MARK: - On the island

    /// The black on the island: solid over `halfWidth` either side of
    /// `centre` down to `foot`, and let go from there over `across` to the
    /// sides and `down` below, round its corners the ellipse between,
    /// which is the docked spread's shape (`IslandPrism.spreadAlpha`). In
    /// the island's own space: x from its horizontal centre (which a change
    /// of width leaves where it is), y from its top edge.
    struct Stain: Equatable {
        var centre: CGFloat
        var halfWidth: CGFloat
        var foot: CGFloat
        var across: CGFloat
        var down: CGFloat
        var opacity: Double
    }

    /// The haze on the island at `d` (normally `distance(scene)`;
    /// `IslandBleedDriver` passes more while an island picked up near the
    /// notch hasn't yet been brought closer). Nil: none.
    ///
    /// Always under the camera, wherever the island is, so it reads as the
    /// notch's black reaching in. Clear of the housing nothing is solid
    /// (`foot` is 0): the top edge is darkest right under the camera and
    /// fades from there. It starts as a small soft patch and widens to the
    /// housing's width, its fade lengthening to the docked spread's.
    static func stain(_ scene: Scene, distance d: CGFloat) -> Stain? {
        let c = closeness(distance: d)
        guard c > 0 else { return nil }
        let k = smooth(c)
        let housingHalf = scene.housing.width / 2
        // Where it reaches over the island's top, as deep as the docked
        // spread is solid (the housing and a point).
        let foot = max(scene.housing.height + IslandPrism.spreadFoot - scene.island.minY, 0)
        return Stain(
            centre: -scene.island.midX,
            halfWidth: housingHalf * k,
            foot: foot,
            across: stainAcross * k,
            down: stainDown * k,
            opacity: Double(pow(c, stainDarkening))
        )
    }

    /// The docked spread's let-go: 1 at `t` 0 (the solid's edge), 0 at 1
    /// (its reach), as `IslandPrism.spreadAlpha` lets go.
    static func falloff(_ t: Double) -> Double {
        guard t > 0 else { return 1 }
        guard t < 1 else { return 0 }
        let lightness = 1 - pow(1 - t, IslandPrism.spreadEase)
        return 1 - pow(lightness, IslandPrism.spreadLightness)
    }

    /// The stain's black at a point of the island's space.
    static func stainAlpha(x: CGFloat, y: CGFloat, stain s: Stain) -> Double {
        let qx = max(abs(x - s.centre) - s.halfWidth, 0)
        let qy = max(y - s.foot, 0)
        if qx == 0, qy == 0 { return s.opacity }
        if s.across <= 0 || s.down <= 0 { return 0 }
        let tx = Double(qx / s.across), ty = Double(qy / s.down)
        return falloff((tx * tx + ty * ty).squareRoot()) * s.opacity
    }
}
