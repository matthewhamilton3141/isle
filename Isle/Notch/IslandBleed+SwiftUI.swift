//
//  IslandBleed+SwiftUI.swift
//
//  The notch's black on the island itself (`IslandBleed.Stain`): drawn in
//  the island's fill, over its material and its rim and under its content,
//  clipped to its outline. In Black it hides the rim where the neck lands,
//  so the neck and the island are one shape; on glass it is the black
//  spreading onto the glass from the neck's foot, and at contact it is the
//  docked spread, so the panel takes over from it unchanged.
//
//  Six pieces, each placed and sized, none redrawn: a solid block, and the
//  spread's let-go as three bitmaps built once (down, along, and round a
//  corner) stretched to the reach. Positions are whole pixels, so where two
//  pieces meet neither has an edge, and the pieces are flattened before
//  the island's swell scales them. The model changes on the carry's drag
//  events and only this view watches it.
//

import SwiftUI

/// One island's stain, published on its own so a change re-evaluates the
/// stain and nothing else (like `IslandProximityModel`). Set only by
/// `IslandBleedDriver`.
@MainActor
final class IslandBleedModel: ObservableObject {
    @Published var stain: IslandBleed.Stain?
}

struct IslandBleedStain: View {
    @ObservedObject var model: IslandBleedModel
    var shape: NotchShape
    /// Off the notch. The stain comes and goes with the placement, on its
    /// spring, as the island's other floating looks do; on the notch the
    /// docked spread is the black.
    var floating: Bool

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            if let stain = model.stain {
                GeometryReader { proxy in
                    pieces(stain, width: proxy.size.width)
                }
                .drawingGroup()
            }
        }
        .clipShape(shape)
        .opacity(model.stain?.opacity ?? 0)
        .opacity(floating ? 1 : 0)
        .allowsHitTesting(false)
    }

    private func snap(_ v: CGFloat) -> CGFloat {
        let s = max(displayScale, 1)
        return (v * s).rounded() / s
    }

    @ViewBuilder
    private func pieces(_ s: IslandBleed.Stain, width: CGFloat) -> some View {
        let images = IslandBleedImages.shared
        let left = snap(width / 2 + s.centre - s.halfWidth)
        let right = snap(width / 2 + s.centre + s.halfWidth)
        let foot = snap(s.foot)
        let across = snap(s.across), down = snap(s.down)
        ZStack(alignment: .topLeading) {
            if foot > 0, right > left {
                Rectangle().fill(.black)
                    .frame(width: right - left, height: foot)
                    .offset(x: left)
            }
            if let images, across > 0, down > 0 {
                if right > left {
                    piece(images.down, width: right - left, height: down, x: left, y: foot)
                }
                if foot > 0 {
                    piece(images.along, width: across, height: foot, x: right, y: 0)
                    piece(images.along, width: across, height: foot, x: left - across, y: 0, mirrored: true)
                }
                piece(images.corner, width: across, height: down, x: right, y: foot)
                piece(images.corner, width: across, height: down, x: left - across, y: foot, mirrored: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func piece(_ image: CGImage, width: CGFloat, height: CGFloat, x: CGFloat, y: CGFloat, mirrored: Bool = false) -> some View {
        Image(decorative: image, scale: IslandBleedImages.scale)
            .resizable()
            .frame(width: width, height: height)
            .scaleEffect(x: mirrored ? -1 : 1, y: 1)
            .offset(x: x, y: y)
    }
}

/// The spread's let-go (`IslandBleed.falloff`) as three bitmaps, built once:
/// down from an edge, along from an edge, and out from a corner (the
/// ellipse between), each from full black at its leading edge to nothing.
@MainActor
final class IslandBleedImages {
    static let scale: CGFloat = 1
    private static let size = 128

    let down: CGImage
    let along: CGImage
    let corner: CGImage

    static let shared = IslandBleedImages()

    private init?() {
        let n = Self.size
        func t(_ i: Int) -> Double { (Double(i) + 0.5) / Double(n) }
        func a(_ v: Double) -> UInt8 { UInt8((v * 255).rounded()) }
        let column = (0..<n).map { a(IslandBleed.falloff(t($0))) }
        var quad = [UInt8](repeating: 0, count: n * n)
        for row in 0..<n {
            for col in 0..<n {
                let x = t(col), y = t(row)
                quad[row * n + col] = a(IslandBleed.falloff((x * x + y * y).squareRoot()))
            }
        }
        guard let down = IslandBlackImage.image(width: 1, height: n, alpha: column),
              let along = IslandBlackImage.image(width: n, height: 1, alpha: column),
              let corner = IslandBlackImage.image(width: n, height: n, alpha: quad)
        else { return nil }
        self.down = down
        self.along = along
        self.corner = corner
    }
}
