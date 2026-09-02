//
//  PomodoroRing.swift
//
//  A circular progress track for the Pomodoro clock, drawn at two sizes: 16pt
//  beside the collapsed clock, and 114pt as the expanded tab's hero where the
//  album art sits. Pure geometry so it can be recoloured from the palette and
//  driven off a TimelineView.
//

import SwiftUI

struct PomodoroRing: View {
    /// 0 empty, 1 full.
    var progress: Double
    var tint: Color
    var lineWidth: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .stroke(tint.opacity(0.22), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(1, max(0, progress)))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                // Start at twelve o'clock and run clockwise.
                .rotationEffect(.degrees(-90))
        }
        .padding(lineWidth / 2)
    }
}
