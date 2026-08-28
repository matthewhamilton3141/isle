//
//  WaveformIcon.swift
//
//  A tiny static 4-bar waveform, the Music-side counterpart to `DotGridIcon`
//  (the Claude 3x3 mark). Bars are centered vertically with rounded caps and a
//  deliberately thick stroke, drawn to fill the frame it's given so it never
//  reads bigger than the dot-grid icon it sits beside in the tab switcher.
//

import SwiftUI

struct WaveformIcon: View {
    var color: Color
    /// Bar heights as a fraction of the icon height, left to right. Four bars.
    var heights: [CGFloat] = [0.3, 0.7, 0.5, 0.62]
    /// Bar thickness as a fraction of each bar's column width — high, so the
    /// lines read thick at 16pt.
    var thickness: CGFloat = 0.62

    var body: some View {
        Canvas { context, size in
            let n = heights.count
            let cell = size.width / CGFloat(n)
            let barWidth = cell * thickness
            let midY = size.height / 2
            for (i, h) in heights.enumerated() {
                let cx = (CGFloat(i) + 0.5) * cell
                let barHeight = max(barWidth, h * size.height)
                let rect = CGRect(
                    x: cx - barWidth / 2,
                    y: midY - barHeight / 2,
                    width: barWidth,
                    height: barHeight
                )
                context.fill(
                    Path(roundedRect: rect, cornerRadius: barWidth / 2),
                    with: .color(color)
                )
            }
        }
        .accessibilityHidden(true)
    }
}

#if DEBUG
#Preview("Waveform icon") {
    WaveformIcon(color: .white)
        .frame(width: 16, height: 16)
        .padding(40)
        .background(.black)
}
#endif
