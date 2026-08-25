//
//  EqualizerView.swift
//
//  The waveform in the collapsed notch.
//
//  Bars grow symmetrically out of a centre line rather than up from a
//  baseline, so silence resolves to a neat row of dots and sound pushes
//  them open from the middle. The gradient runs vertically across the whole
//  strip, which means a tall bar picks up the full colour ramp while a short
//  one stays near the middle tone — the colour itself ends up encoding
//  amplitude.
//
//  Levels come from SystemAudioLevels when audio capture is available. If it
//  isn't — permission denied, or nothing is playing through the tapped
//  device — this falls back to the procedural sine pattern so the notch
//  still looks alive rather than dead.
//

import SwiftUI

struct EqualizerView: View {
    var palette: ArtworkPalette = .fallback
    var isPlaying: Bool = true

    /// Real per-band magnitudes, 0...1, one per bar. Empty means fall back to
    /// the procedural pattern.
    var levels: [Double] = []

    var barCount: Int = 6
    var spacing: CGFloat = 2.5

    /// Height of a bar at complete silence — the "dot" resting state.
    var dotHeight: CGFloat = 2.5

    /// Per-bar frequency multipliers for the fallback pattern. Deliberately
    /// not evenly spaced, or the bars visibly march in a wave.
    private static let frequencies: [Double] = [1.00, 1.37, 0.83, 1.61, 1.13, 0.71]
    private static let phases: [Double] = [0.0, 0.9, 1.8, 0.45, 2.3, 1.35]

    private var usesRealLevels: Bool { levels.count >= barCount }

    var body: some View {
        TimelineView(.animation(paused: !isPlaying && !usesRealLevels)) { context in
            Canvas { canvasContext, size in
                draw(
                    in: canvasContext,
                    size: size,
                    time: context.date.timeIntervalSinceReferenceDate
                )
            }
        }
        .accessibilityHidden(true)
    }

    private func draw(in context: GraphicsContext, size: CGSize, time: TimeInterval) {
        let totalSpacing = spacing * CGFloat(barCount - 1)
        let barWidth = max(1, (size.width - totalSpacing) / CGFloat(barCount))
        let midY = size.height / 2

        // One gradient shading for the whole strip, sampled per bar, so the
        // ramp is continuous across the waveform instead of restarting in
        // each bar.
        //
        // Runs bottom-to-top. Because the bars are symmetric about the centre
        // line, a top-to-bottom ramp made each bar read as mirrored — bright
        // at the top, bright again at the bottom, darkest in the middle. This
        // way the colour travels in a single direction across the strip.
        let shading = GraphicsContext.Shading.linearGradient(
            Gradient(colors: [palette.primary, palette.accent]),
            startPoint: CGPoint(x: 0, y: size.height),
            endPoint: CGPoint(x: 0, y: 0)
        )

        for index in 0..<barCount {
            let level = level(for: index, at: time)

            // Grow from the dot outward. Half above centre, half below.
            let full = max(dotHeight, size.height * CGFloat(level))
            let half = full / 2

            let x = CGFloat(index) * (barWidth + spacing)
            let rect = CGRect(
                x: x,
                y: midY - half,
                width: barWidth,
                height: full
            )

            context.fill(
                Path(roundedRect: rect, cornerRadius: barWidth / 2),
                with: shading
            )
        }
    }

    /// Normalised 0...1 height for a bar.
    private func level(for index: Int, at time: TimeInterval) -> Double {
        if usesRealLevels {
            return min(max(levels[index], 0), 1)
        }

        guard isPlaying else { return 0 }

        let frequency = Self.frequencies[index % Self.frequencies.count]
        let phase = Self.phases[index % Self.phases.count]
        let wave = sin(time * frequency * 3.1 + phase)
        return 0.18 + (wave + 1) / 2 * 0.72
    }
}

#Preview("Waveform") {
    VStack(spacing: 24) {
        // Silence — should read as a row of dots.
        EqualizerView(isPlaying: false, levels: [0, 0, 0, 0, 0, 0])
            .frame(width: 30, height: 18)

        // Mid and loud.
        EqualizerView(
            palette: ArtworkPalette(primary: .pink, secondary: .purple, accent: .orange),
            levels: [0.3, 0.65, 0.45, 0.9, 0.5, 0.25]
        )
        .frame(width: 30, height: 18)

        // Procedural fallback.
        EqualizerView(isPlaying: true)
            .frame(width: 30, height: 18)
    }
    .padding(40)
    .background(.black)
}
