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
        HStack(spacing: 14) {
            artwork

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
                    trackLabels
                    Spacer(minLength: 4)
                    scrubber
                    Spacer(minLength: 4)
                    controls
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
        .frame(width: 108, height: 108)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Text

    private var trackLabels: some View {
        VStack(alignment: .leading, spacing: 1) {
            MarqueeText(
                text: media.title.isEmpty ? "Not playing" : media.title,
                font: .system(size: 13, weight: .semibold)
            )

            HStack(spacing: 4) {
                MarqueeText(
                    text: media.artist,
                    font: .system(size: 11, weight: .regular)
                )
                .foregroundStyle(.white.opacity(0.7))
            }
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

            VStack(spacing: 3) {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(.white.opacity(0.22))

                        Capsule()
                            .fill(palette.accent)
                            .frame(width: max(0, proxy.size.width * progress))
                    }
                    .contentShape(Rectangle())
                    .gesture(dragGesture(width: proxy.size.width))
                }
                .frame(height: 4)

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
        HStack(spacing: 16) {
            controlButton("shuffle", isActive: media.isShuffled) {
                viewModel.toggleShuffle()
            }

            Spacer(minLength: 0)

            controlButton("backward.fill") { viewModel.previousTrack() }

            controlButton(
                media.isPlaying ? "pause.fill" : "play.fill",
                size: 17
            ) {
                viewModel.togglePlayPause()
            }

            controlButton("forward.fill") { viewModel.nextTrack() }

            Spacer(minLength: 0)

            controlButton(media.repeatMode.symbolName, isActive: media.repeatMode.isActive) {
                viewModel.cycleRepeat()
            }
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
                .frame(width: size + 10, height: size + 10)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
