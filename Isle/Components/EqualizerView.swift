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
//  Both are drawn by Core Animation; see EqualizerLayer.swift. These are the
//  SwiftUI faces of it: `LiveEqualizer` for the notch, which hands the layer
//  view the levels source and then stays out of the way, and `EqualizerView`
//  for the previews and the gallery, which pushes a fixed array.
//

import SwiftUI

/// The waveform wired to the live capture, and the only view in the app that
/// observes it.
///
/// Note what this deliberately does *not* do: observe the levels itself. Levels
/// change 30 times a second, and an `@ObservedObject` here would put every one
/// of those through the view graph — which is what the Canvas version cost, just
/// scoped smaller. The layer view subscribes directly instead, so a level change
/// moves six layers and never reaches SwiftUI at all.
struct LiveEqualizer: View {
    var source: SystemAudioLevels
    var palette: ArtworkPalette = .fallback
    var isPlaying: Bool = true

    var body: some View {
        LiveEqualizerRepresentable(source: source, palette: palette, isPlaying: isPlaying)
            .accessibilityHidden(true)
    }
}

private struct LiveEqualizerRepresentable: NSViewRepresentable {
    var source: SystemAudioLevels
    var palette: ArtworkPalette
    var isPlaying: Bool

    func makeNSView(context: Context) -> EqualizerLayerView {
        let view = EqualizerLayerView()
        view.attach(to: source)
        view.configure(palette: palette, isPlaying: isPlaying)
        return view
    }

    func updateNSView(_ view: EqualizerLayerView, context: Context) {
        view.attach(to: source)
        view.configure(palette: palette, isPlaying: isPlaying)
    }
}

/// A waveform driven by a fixed set of levels, for the previews and the
/// animation gallery. Empty levels mean the procedural pattern.
struct EqualizerView: View {
    var palette: ArtworkPalette = .fallback
    var isPlaying: Bool = true

    /// Real per-band magnitudes, 0...1, one per bar. Empty means fall back to
    /// the procedural pattern.
    var levels: [Double] = []

    var body: some View {
        StaticEqualizerRepresentable(palette: palette, isPlaying: isPlaying, levels: levels)
            .accessibilityHidden(true)
    }
}

private struct StaticEqualizerRepresentable: NSViewRepresentable {
    var palette: ArtworkPalette
    var isPlaying: Bool
    var levels: [Double]

    func makeNSView(context: Context) -> EqualizerLayerView {
        let view = EqualizerLayerView()
        view.configure(palette: palette, isPlaying: isPlaying)
        view.setStaticLevels(levels)
        return view
    }

    func updateNSView(_ view: EqualizerLayerView, context: Context) {
        view.configure(palette: palette, isPlaying: isPlaying)
        view.setStaticLevels(levels)
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
