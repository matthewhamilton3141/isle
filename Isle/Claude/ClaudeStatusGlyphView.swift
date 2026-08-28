//
//  ClaudeStatusGlyphView.swift
//
//  The glyph you actually drop into the notch. Swaps between the
//  continuous breathing loop (BreathingShapeView, from
//  BreathingShapeView.swift) and a one-shot checkmark reveal for
//  `.done`, driven by ClaudeCodeState.
//
//  Built on the Canvas implementation rather than BreathingShapeLayer
//  because it picks up a changed period/scale/opacity/color on the very
//  next frame with no restart bookkeeping — see the `configure(...)`
//  method added to BreathingShapeLayer.swift for the AppKit equivalent,
//  which you'd use instead if you move this into a persistently-hosted
//  NSView elsewhere in the app for CPU-cost reasons.
//

import SwiftUI

struct ClaudeStatusGlyphView: View {
    var state: ClaudeCodeState

    /// An explicit marker to draw, overriding the lifecycle mapping — used to
    /// pick a specific failure marker (rate-limit / server / generic) from the
    /// error type. Nil falls back to the plain state marker.
    var kind: MarkerKind? = nil

    /// Artwork colours to tint the dots with, so the indicator matches the
    /// waveform. Falls back to a neutral palette when none is available.
    var palette: ArtworkPalette = .fallback

    /// Overrides the marker's colour with a single hue (shape/animation kept).
    /// Used for the warm thinking/working colouring in the Claude-solo island.
    var tint: Color? = nil

    /// The designs are read from the shared store, so editing a marker in the
    /// editor updates the live notch immediately.
    @ObservedObject private var markers = MarkerStore.shared

    var body: some View {
        DotMatrixView(
            design: markers.design(for: kind ?? MarkerKind(state: state)),
            palette: palette,
            tint: tint
        )
    }
}

/// Type-erased Shape wrapper so call sites can hold "some shape" without
/// the generic `Shape` constraint leaking outward. Swap `SparkShape()` for
/// your own tuned geometry — see the note in BreathingShapeView.swift about
/// keeping this an original design rather than a reproduction of Anthropic's
/// actual mark.
struct AnyShape: Shape {
    private let pathBuilder: (CGRect) -> Path
    init<S: Shape>(_ shape: S) { self.pathBuilder = { rect in shape.path(in: rect) } }
    func path(in rect: CGRect) -> Path { pathBuilder(rect) }
}

/// One-shot spark -> checkmark morph. Kept separate from the looping
/// breathe animation on purpose: a loop (`repeatCount = .infinity`) has no
/// natural "finished" moment, and `.done` needs one to hand control back.
struct CheckmarkBurstView: View {
    var color: Color
    var onFinished: () -> Void

    @State private var progress: CGFloat = 0

    /// How long the checkmark takes to draw in, before the hold.
    private let drawInDuration: Double = 0.35
    /// Matches the spec's "~4s toast, then auto-collapse" for `done`.
    private let holdDuration: Double = 4.0

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 4, dy: 4)
            var path = Path()
            path.move(to: CGPoint(x: rect.minX + rect.width * 0.15, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.42, y: rect.maxY - rect.height * 0.18))
            path.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.12, y: rect.minY + rect.height * 0.15))

            let trimmed = path.trimmedPath(from: 0, to: progress)
            context.stroke(trimmed, with: .color(color), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
        .onAppear {
            withAnimation(.easeOut(duration: drawInDuration)) { progress = 1 }
            DispatchQueue.main.asyncAfter(deadline: .now() + drawInDuration + holdDuration) {
                onFinished()
            }
        }
    }
}

// MARK: - Example usage

struct ClaudeStatusGlyphExample: View {
    @State private var state: ClaudeCodeState = .working

    var body: some View {
        VStack(spacing: 24) {
            ClaudeStatusGlyphView(
                state: state,
                palette: ArtworkPalette(primary: .pink, secondary: .blue, accent: .orange)
            )
            .frame(width: 40, height: 40)

            Picker("State", selection: $state) {
                Text("Disconnected").tag(ClaudeCodeState.disconnected)
                Text("Idle").tag(ClaudeCodeState.idle)
                Text("Working").tag(ClaudeCodeState.working)
                Text("Needs Approval").tag(ClaudeCodeState.needsApproval)
                Text("Done").tag(ClaudeCodeState.done)
            }
            .pickerStyle(.segmented)
        }
        .padding(40)
    }
}

#Preview {
    ClaudeStatusGlyphExample()
}
