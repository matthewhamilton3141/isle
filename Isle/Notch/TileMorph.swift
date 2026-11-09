//
//  TileMorph.swift
//
//  Home to a face and back, as one move: the tile you clicked grows into
//  its face, and the face shrinks back into its tile on the way home.
//
//  Going in, the tile's plate (its faint rounded box) widens and lengthens
//  from the tile's own frame to the face's, dimming as it goes, and the face
//  arrives inside it — clipped to it, scaled up from the tile's centre and
//  fading in — while the rest of the grid falls back a little and fades.
//  Going home runs the same thing backwards: the face draws in to its tile
//  and the grid comes forward around it.
//
//  Every moving part is a render effect — opacity, a transform, a shape's
//  path — that SwiftUI interpolates between the two ends of a transition.
//  No body runs per frame and nothing keeps a clock: the transitions are
//  the whole of it, driven by ExpandedNotchView's animation on the place.
//  The panel's height (Agenda is taller than Home) is NotchRootView's and
//  rides alongside on its own resize spring.
//

import SwiftUI

extension Animation {
    /// Home to a face and back. Critically damped, so nothing passes its
    /// mark — the plate never overshoots the face it grows into — and at the
    /// open and close springs' pace: settled in about a third of a second.
    static var tileMorph: Animation {
        .spring(response: 0.3, dampingFraction: 1.0, blendDuration: 0)
    }
}

/// Where tile `index` of `count` sits on the home grid, as HomeGridView lays
/// it out: equal tiles across `width` with the grid's gap between them, inset
/// top and bottom. `height` is the grid's (the standard content height).
struct HomeTileSlot: Equatable {
    var index: Int
    var count: Int
    var height: CGFloat

    func frame(width: CGFloat) -> CGRect {
        let gap = HomeGridView.tileGap
        let n = CGFloat(max(1, count))
        let w = max(0, (width - gap * (n - 1)) / n)
        let inset = HomeGridView.tileInset
        return CGRect(x: CGFloat(index) * (w + gap), y: inset, width: w, height: max(0, height - 2 * inset))
    }
}

/// The tile's frame at `progress` 0, the face's own bounds at 1 — reaching
/// `reach` past them by the end, for content that sits outside its box (the
/// album raised into the housing band). The reach comes in only at the very
/// end (the sixth power of progress), so for the move itself the face is cut
/// by the plate's own edge, which is lit, rather than by an unseen line
/// just outside it.
struct TileMorphShape: Shape {
    var slot: HomeTileSlot
    var reach: CGFloat = 0
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let p = max(0, progress)
        let tile = slot.frame(width: rect.width).offsetBy(dx: rect.minX, dy: rect.minY)
        let p3 = p * p * p
        let out = reach * p3 * p3
        let whole = rect.insetBy(dx: -out, dy: -out)
        let frame = CGRect(
            x: tile.minX + (whole.minX - tile.minX) * p,
            y: tile.minY + (whole.minY - tile.minY) * p,
            width: tile.width + (whole.width - tile.width) * p,
            height: tile.height + (whole.height - tile.height) * p
        )
        return Path(roundedRect: frame, cornerRadius: HomeTileStyle.cornerRadius, style: .continuous)
    }
}

/// The face's content grows out of the tile: at `progress` 0 it's
/// `HomeTileZoom.start` of its size, drawn in towards the tile's centre; at
/// 1, itself. Scaled about the tile's centre, which is inside the face, so
/// the content only ever draws in — never out past the panel's edge, as
/// carrying its centre all the way to an end tile's did. A geometry effect,
/// so the tile's place is worked out from the face's own size at render
/// time rather than a measured one.
private struct HomeTileZoom: GeometryEffect {
    var slot: HomeTileSlot
    var progress: CGFloat

    static let start: CGFloat = 0.86

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let tile = slot.frame(width: size.width)
        let s = Self.start + (1 - Self.start) * progress
        let t = CGAffineTransform(translationX: tile.midX, y: tile.midY)
            .scaledBy(x: s, y: s)
            .translatedBy(x: -tile.midX, y: -tile.midY)
        return ProjectionTransform(t)
    }
}

/// A face at `progress` along its way out of its tile (see the top of the
/// file). 1 is the face at rest, and what it keeps while it's on screen.
private struct FaceFromTile: ViewModifier {
    var slot: HomeTileSlot
    var progress: CGFloat

    /// How far past its box the face may draw once it's whole — the album
    /// rises 11pt into the housing band. The panel's outline clips beyond.
    private static let reach: CGFloat = 40

    func body(content: Content) -> some View {
        content
            .modifier(HomeTileZoom(slot: slot, progress: progress))
            // Squared: the face arrives once the grid has mostly gone (and
            // goes before it's back), so the two hardly overlap.
            .opacity(progress)
            .opacity(progress)
            .mask { TileMorphShape(slot: slot, reach: Self.reach, progress: progress) }
            .background {
                // The tile's plate, growing with the face. Lit only in the
                // middle of the move — the two opacities multiply to
                // p(1 - p) — so it's nothing at either end: it doesn't
                // double the tile it leaves, nor sit on the tile it lands
                // in once the face is gone.
                TileMorphShape(slot: slot, progress: progress)
                    .fill(.white.opacity(HomeTileStyle.restingFill * 4))
                    .opacity(progress)
                    .opacity(1 - progress)
                    .allowsHitTesting(false)
            }
    }
}

/// The home grid stepping back for a face, or coming forward again: a
/// touch smaller and fading, quickly — its opacity is `progress` cubed, so
/// it has mostly gone before the face (squared) has mostly arrived, and on
/// the way home comes in once the face has drawn in.
private struct GridAway: ViewModifier {
    var progress: CGFloat

    func body(content: Content) -> some View {
        content
            .scaleEffect(0.96 + 0.04 * progress)
            .opacity(progress)
            .opacity(progress)
            .opacity(progress)
    }
}

extension AnyTransition {
    /// A face, in from its home tile and back into it.
    static func faceFromTile(_ slot: HomeTileSlot) -> AnyTransition {
        .modifier(
            active: FaceFromTile(slot: slot, progress: 0),
            identity: FaceFromTile(slot: slot, progress: 1)
        )
    }

    /// The home grid, back and forward behind a face.
    static var homeGridAway: AnyTransition {
        .modifier(active: GridAway(progress: 0), identity: GridAway(progress: 1))
    }
}
