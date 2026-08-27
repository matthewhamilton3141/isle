//
//  DotGridIcon.swift
//
//  A tiny static 5x5 dot grid, used where the Claude side needs a plain icon
//  (the tab switcher) rather than the full animated marker. Same visual
//  language as DotMatrixView, so the tab reads as "the dot thing".
//

import SwiftUI

struct DotGridIcon: View {
    var color: Color
    var dimension: Int = MarkerDesign.dimension
    /// Dot radius as a fraction of the cell.
    var fill: CGFloat = 0.30

    var body: some View {
        Canvas { context, size in
            let n = dimension
            let cell = min(size.width, size.height) / CGFloat(n)
            let radius = cell * fill
            for row in 0..<n {
                for col in 0..<n {
                    let cx = (CGFloat(col) + 0.5) * cell
                    let cy = (CGFloat(row) + 0.5) * cell
                    let rect = CGRect(x: cx - radius, y: cy - radius, width: radius * 2, height: radius * 2)
                    context.fill(Path(ellipseIn: rect), with: .color(color))
                }
            }
        }
        .accessibilityHidden(true)
    }
}
