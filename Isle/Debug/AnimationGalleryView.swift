//
//  AnimationGalleryView.swift
//
//  A developer preview surface: every animation Isle draws, running live in
//  one scrollable window. Opened from the menu bar ("Animation Gallery…").
//  Not part of the notch UI — it just instantiates the same components the
//  notch uses so they can be eyeballed and tuned without cycling app state.
//

import SwiftUI
import AppKit

struct AnimationGalleryView: View {
    /// Live designs, so edits in the Marker Editor show up here too.
    @ObservedObject private var markers = MarkerStore.shared

    @State private var notchExpanded = false

    /// A vivid palette so `Artwork` colour mode is visible with no music.
    private let demoPalette = ArtworkPalette(primary: .pink, secondary: .blue, accent: .orange)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                header
                markersSection
                equalizerSection
                marqueeSection
                notchSection
                tabCrossfadeSection
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 660, minHeight: 820)
        .background(Color.black)
        .foregroundStyle(.white)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Isle — Animation Gallery")
                .font(.system(size: 20, weight: .bold))
            Text("Every animation in one place, running live.")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.5))
        }
    }

    // MARK: - Markers (dot matrix)

    private var markersSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Markers — dot matrix")
                    .font(.system(size: 14, weight: .semibold))
                Text("The full 5×5 marker set, rendered from the live store. Edit any of these in the Marker Editor and they update here and in the notch.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(MarkerCategory.allCases) { category in
                VStack(alignment: .leading, spacing: 8) {
                    Text(category.title.uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.35))
                    HStack(alignment: .top, spacing: 20) {
                        ForEach(kinds(in: category)) { kind in
                            labeled(kind.title) {
                                DotMatrixView(design: markers.design(for: kind), palette: demoPalette)
                                    .frame(width: 40, height: 40)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func kinds(in category: MarkerCategory) -> [MarkerKind] {
        MarkerKind.allCases.filter { $0.category == category }
    }

    // MARK: - Equalizer

    private var equalizerSection: some View {
        section(
            "Equalizer (procedural fallback)",
            "What the collapsed notch shows without an audio tap; real audio drives it in-app."
        ) {
            HStack(spacing: 30) {
                labeled("playing") {
                    EqualizerView(palette: .fallback, isPlaying: true, levels: [])
                        .frame(width: 44, height: 22)
                }
                labeled("paused") {
                    EqualizerView(palette: .fallback, isPlaying: false, levels: [])
                        .frame(width: 44, height: 22)
                }
                labeled("artwork colours") {
                    EqualizerView(
                        palette: ArtworkPalette(primary: .pink, secondary: .purple, accent: .orange),
                        isPlaying: true,
                        levels: []
                    )
                    .frame(width: 44, height: 22)
                }
            }
        }
    }

    // MARK: - Marquee

    private var marqueeSection: some View {
        section(
            "Marquee (MarqueeText)",
            "Scrolls only when the text overflows its frame — the short one should sit still."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                MarqueeText(
                    text: "A Very Long Song Title That Should Definitely Overflow And Scroll",
                    fontSize: 14,
                    weight: .semibold,
                    lineHeight: 18
                )
                .frame(width: 240)

                MarqueeText(
                    text: "Short title",
                    fontSize: 14,
                    weight: .semibold,
                    lineHeight: 18
                )
                .frame(width: 240)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.06)))
        }
    }

    // MARK: - Notch spring

    private var notchSection: some View {
        section(
            "Notch open / close spring",
            ".notchOpen is underdamped (overshoots larger); .notchClose is critically damped (never undershoots)."
        ) {
            VStack(alignment: .leading, spacing: 14) {
                NotchShape(
                    topCornerRadius: notchExpanded ? 12 : 8,
                    bottomCornerRadius: notchExpanded ? 22 : 12
                )
                .fill(.white.opacity(0.9))
                .frame(width: notchExpanded ? 320 : 150, height: notchExpanded ? 90 : 32)
                .animation(notchExpanded ? .notchOpen : .notchClose, value: notchExpanded)

                Button(notchExpanded ? "Collapse" : "Expand") {
                    notchExpanded.toggle()
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Tab cross-fade

    private var tabCrossfadeSection: some View {
        section(
            "Tab cross-fade (Both mode)",
            "The 0.2s opacity swap between the Music and Claude tabs."
        ) {
            TabCrossfadeDemo()
        }
    }

    // MARK: - Building blocks

    private func section<Content: View>(
        _ title: String,
        _ subtitle: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.45))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func labeled<Content: View>(
        _ label: String,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        VStack(spacing: 8) {
            content()
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.5))
        }
    }
}

/// Self-contained demo of the tab content cross-fade.
private struct TabCrossfadeDemo: View {
    @State private var showClaude = false

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                if showClaude {
                    claudeLabel.transition(.opacity)
                } else {
                    label("Music", WaveformIcon(color: .white).frame(width: 16, height: 16)).transition(.opacity)
                }
            }
            .frame(width: 200, height: 64)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.06)))
            .animation(.easeInOut(duration: 0.2), value: showClaude)

            Button("Switch tab") { showClaude.toggle() }
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var claudeLabel: some View {
        label("Claude", DotGridIcon(color: .white).frame(width: 16, height: 16))
    }

    private func label(_ text: String, _ icon: some View) -> some View {
        HStack(spacing: 8) {
            icon
            Text(text).font(.system(size: 15, weight: .semibold))
        }
        .foregroundStyle(.white)
    }
}
