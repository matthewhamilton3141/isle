//
//  ExpandedNotchView.swift
//
//  The open panel: artwork, ticker text, seekable scrubber, transport row.
//  When Claude Code opened the notch rather than the pointer, its status
//  card takes the leading position and music shares the row (spec 3.1).
//

import SwiftUI

struct ExpandedNotchView: View {
    @ObservedObject var viewModel: NotchViewModel
    var palette: ArtworkPalette

    private var media: MediaPlaybackModel { viewModel.media }

    var body: some View {
        // Wide gap after the artwork: it pushes the whole text/scrubber/
        // controls column to the right, which is what shortens the playbar.
        HStack(spacing: 32) {
            artwork
                // Extra leading inset on the artwork alone, so the album sits
                // further in from the edge than the trailing margin. Done here
                // rather than widening the root padding, which would pull the
                // right edge in by the same amount and undo the shift.
                .padding(.leading, 10)

            // Spacers rather than fixed gaps: the row's height is driven by
            // the artwork, and letting the text/scrubber/controls distribute
            // into whatever is left keeps the panel from looking top-heavy
            // with a band of dead space under the buttons.
            VStack(alignment: .leading, spacing: 0) {
                if viewModel.hasLiveActivity {
                    claudeCard
                    Spacer(minLength: 6)
                }

                if media.hasTrack {
                    // Fixed gaps between the three rows, flexible space only
                    // at the ends. Previously the inner gaps were flexible
                    // too, so any spare height was spent pushing the labels up
                    // and the controls down — the group drifted apart instead
                    // of staying together and centring.
                    Spacer(minLength: 0)
                    trackLabels
                    Spacer().frame(height: 6)
                    scrubber
                    Spacer().frame(height: 8)
                    controls
                    Spacer(minLength: 0)
                } else if !viewModel.hasLiveActivity {
                    idlePlaceholder
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .frame(maxHeight: .infinity)
        .foregroundStyle(.white)
    }

    // MARK: - Artwork

    private var artwork: some View {
        Group {
            if let image = media.artwork {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(
                    colors: [palette.primary, palette.secondary],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .overlay {
                    Image(systemName: "music.note")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
        }
        // Sized to fill the usable content height (panel 170 minus the
        // reserved housing band and vertical padding). Raising this without
        // also raising NotchMetrics.expandedSize will clip it.
        .frame(width: 114, height: 114)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - Text

    private var trackLabels: some View {
        VStack(alignment: .leading, spacing: 1) {
            MarqueeText(
                text: media.title.isEmpty ? "Not playing" : media.title,
                font: .system(size: 13, weight: .semibold)
            )

            // No HStack wrapper: it gave the marquee an ambiguous width to
            // measure against, which is the other half of why long artist
            // strings failed to scroll. lineHeight is trimmed to suit 11pt
            // rather than inheriting the 18pt title default.
            MarqueeText(
                text: media.artist,
                font: .system(size: 11, weight: .regular),
                lineHeight: 15
            )
            .foregroundStyle(.white.opacity(0.7))
        }
    }

    private var idlePlaceholder: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Nothing playing")
                .font(.system(size: 13, weight: .semibold))
            Text("Start something in Spotify or Music")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    // MARK: - Claude

    private var claudeCard: some View {
        HStack(spacing: 8) {
            ClaudeStatusGlyphView(state: viewModel.claudeState)
                .frame(width: 16, height: 16)

            Text("Claude Code needs your approval")
                .font(.system(size: 12, weight: .medium))

            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 9)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.white.opacity(0.12))
        )
    }

    // MARK: - Scrubber

    private var scrubber: some View {
        // Ticks at display rate so the elapsed label and thumb advance
        // smoothly between the adapter's ~1s updates.
        TimelineView(.animation(paused: !media.isPlaying)) { context in
            let progress = viewModel.displayProgress(at: context.date)
            let elapsed = progress * media.duration

            VStack(spacing: 2) {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(.white.opacity(0.22))

                        // Fixed white rather than palette.accent: the accent is
                        // derived from artwork and on a dark or low-contrast
                        // cover the filled portion became hard to read against
                        // the track behind it.
                        Capsule()
                            .fill(.white)
                            .frame(width: max(0, proxy.size.width * progress))
                    }
                    // Visible track is 6pt; the hit area is the full
                    // GeometryReader height so the grab target stays generous.
                    .frame(height: 6)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(dragGesture(width: proxy.size.width))
                }
                .frame(height: 10)

                HStack {
                    Text(TimeFormatter.string(from: elapsed))
                    Spacer()
                    Text("-" + TimeFormatter.string(from: max(0, media.duration - elapsed)))
                }
                .font(.system(size: 9, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.55))
            }
        }
        .opacity(viewModel.canSeek && media.duration > 0 ? 1 : 0.4)
        .disabled(!viewModel.canSeek || media.duration <= 0)
    }

    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard width > 0 else { return }
                viewModel.scrubTarget = min(max(0, value.location.x / width), 1)
            }
            .onEnded { _ in
                // Seek once on release rather than on every sample — issuing
                // a seek per drag event makes the source app stutter badly.
                viewModel.commitScrub()
            }
    }

    // MARK: - Controls

    private var controls: some View {
        // One tight cluster rather than shuffle and repeat pinned to the far
        // edges. The transport keys are the primary targets so they're sized
        // up, and the two mode toggles sit right alongside them, smaller and
        // dimmer, reading as secondary without being flung to the corners.
        HStack(spacing: 11) {
            Spacer(minLength: 0)

            controlButton("shuffle", size: 13, isActive: media.isShuffled) {
                viewModel.toggleShuffle()
            }

            controlButton("backward.fill", size: 21) { viewModel.previousTrack() }

            controlButton(
                media.isPlaying ? "pause.fill" : "play.fill",
                size: 28
            ) {
                viewModel.togglePlayPause()
            }

            controlButton("forward.fill", size: 21) { viewModel.nextTrack() }

            controlButton(
                media.repeatMode.symbolName,
                size: 13,
                isActive: media.repeatMode.isActive
            ) {
                viewModel.cycleRepeat()
            }

            Spacer(minLength: 0)
        }
        .disabled(!viewModel.canControlPlayback)
        .opacity(viewModel.canControlPlayback ? 1 : 0.4)
    }

    private func controlButton(
        _ symbol: String,
        size: CGFloat = 13,
        isActive: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(isActive ? .white : .white.opacity(0.4))
                .frame(width: size + 7, height: size + 7)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
