//
//  BluetoothRune.swift
//
//  The Bluetooth mark, drawn by hand because SF Symbols doesn't carry it —
//  `bluetooth` and `bluetooth.fill` both resolve to nil on current macOS.
//  Apple omits it because the rune is Bluetooth SIG's registered figure mark
//  rather than a generic glyph, so it can't ship in a system symbol set.
//
//  It is one continuous polyline, not a filled outline: the mark is a bind
//  rune of Hagall (ᚼ) and Bjarkan (ᛒ), which is a stroke construction to begin
//  with. Six points, traced lower-left → upper-right → apex → foot →
//  lower-right → upper-left, so the stem is drawn once on the way through and
//  the two flags fall out of the diagonals rather than being separate pieces.
//
//  Stroked rather than filled so it inherits weight the way the SF Symbols
//  beside it do — a filled path would stay one fixed thickness while the
//  headphones and keyboard glyphs around it changed with the symbol weight.
//

import SwiftUI

struct BluetoothRune: Shape {
    /// Stroke weight as a fraction of the glyph's height. Tuned against
    /// `headphones` and `keyboard` at semibold so the rune doesn't read as
    /// lighter or heavier than the symbols it sits alongside in the toast set.
    static let strokeFraction: CGFloat = 0.115

    /// The mark's own proportions — 2 wide to 3 tall. Exposed so callers can
    /// size a frame that fits it exactly instead of guessing and letting the
    /// path float inside a too-wide box.
    static let aspectRatio: CGFloat = 2.0 / 3.0

    func path(in rect: CGRect) -> Path {
        // Inset by half the stroke: a stroke straddles its path, so the
        // extremes would otherwise be clipped by the frame's edge.
        let weight = rect.height * Self.strokeFraction
        let box = rect.insetBy(dx: weight / 2, dy: weight / 2)

        // Normalised from the mark's canonical 24-unit construction, whose
        // extents are x 6…18 and y 3…21.
        let points: [(CGFloat, CGFloat)] = [
            (0.0, 0.75),   // lower left
            (1.0, 0.25),   // upper right
            (0.5, 0.00),   // apex
            (0.5, 1.00),   // foot — the stem, drawn in passing
            (1.0, 0.75),   // lower right
            (0.0, 0.25),   // upper left
        ]

        var path = Path()
        for (index, point) in points.enumerated() {
            let p = CGPoint(x: box.minX + point.0 * box.width,
                            y: box.minY + point.1 * box.height)
            index == 0 ? path.move(to: p) : path.addLine(to: p)
        }
        return path
    }
}

extension BluetoothRune {
    /// Ready to draw at a given height, at the weight and joins that match the
    /// symbol set. Round joins on purpose: the mark is traditionally drawn with
    /// mitred corners, but every SF Symbol beside it has rounded terminals, and
    /// a mitred rune in that company reads as pasted in from another typeface.
    @ViewBuilder
    static func view(height: CGFloat, tint: Color) -> some View {
        BluetoothRune()
            .stroke(
                tint,
                style: StrokeStyle(
                    lineWidth: height * strokeFraction,
                    lineCap: .round,
                    lineJoin: .round
                )
            )
            .frame(width: height * aspectRatio, height: height)
    }
}

#if DEBUG
#Preview("Bluetooth rune") {
    HStack(spacing: 22) {
        ForEach([16.0, 24.0, 48.0, 96.0], id: \.self) { size in
            BluetoothRune.view(height: size, tint: .white)
        }
        // Beside the symbols it has to live with.
        Image(systemName: "headphones").font(.system(size: 40))
        Image(systemName: "keyboard").font(.system(size: 40))
    }
    .foregroundStyle(.white)
    .padding(30)
    .background(.black)
}
#endif
