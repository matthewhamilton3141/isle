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
    var island: IslandPresentation
    var palette: ArtworkPalette

    private var media: MediaPlaybackModel { viewModel.media }

    var body: some View {
        // The Music/Claude switcher itself lives in NotchRootView, positioned
        // to the right of the physical cutout — see NotchRootView.tabBar.
        content
            // A clean cross-dissolve: nothing moves, the old tab just fades out
            // as the new one fades in, in place. Covers the interrupt-driven
            // switch to Claude too, which doesn't go through the tab button's
            // own animation.
            .animation(.easeInOut(duration: 0.28), value: viewModel.expandedTab)
            // The waveform is pinned to ONE fixed spot in the panel and drawn
            // outside the tab switch, so it holds the exact same real position
            // on Music and Claude instead of re-aligning to each tab's text —
            // switching tabs no longer makes it hop. Gated on a live track;
            // non-interactive so it never swallows a seek or dismiss tap.
            .overlay(alignment: .topTrailing) {
                if media.hasTrack, viewModel.showsWaveform {
                    LiveEqualizer(
                        source: viewModel.audioLevelSource,
                        palette: palette,
                        isPlaying: media.isPlaying,
                        listens: viewModel.waveformSource.capturesAudio
                    )
                    .frame(width: 30, height: 24)
                    .padding(.top, 10)
                    .padding(.trailing, 4)
                    .allowsHitTesting(false)
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.expandedTab {
        case .music:
            musicBody
                .transition(.opacity)
        case .claude:
            ClaudeExpandedView(viewModel: viewModel, island: island, palette: palette)
                .transition(.opacity)
        }
    }

    // MARK: - Music

    private var musicBody: some View {
        // The album and the text column are one tight pair — a small fixed gap
        // between them, a fixed-width text block — and that pair is centred in
        // the panel by the outer `.frame(maxWidth: .infinity)`, so the leftover
        // space splits evenly into equal left and right margins.
        HStack(spacing: 14) {
            artwork
                // Raised out of its layout slot into the housing band. That's
                // safe only because the artwork spans x 32-146 while the
                // camera cutout starts at x 167 — there is no hardware above
                // the album. `offset` rather than negative padding so the
                // text column's own position is left undisturbed.
                .offset(y: -11)

            // Spacers rather than fixed gaps: the row's height is driven by
            // the artwork, and letting the text/scrubber/controls distribute
            // into whatever is left keeps the panel from looking top-heavy
            // with a band of dead space under the buttons.
            VStack(alignment: .leading, spacing: 0) {
                if media.hasTrack {
                    // Fixed gaps between the three rows, flexible space only
                    // at the ends. Previously the inner gaps were flexible
                    // too, so any spare height was spent pushing the labels up
                    // and the controls down — the group drifted apart instead
                    // of staying together and centring.
                    Spacer(minLength: 0)
                    // Trailing inset keeps the title/artist clear of the fixed
                    // waveform pinned at the panel's top-right (see body).
                    trackLabels
                        .padding(.trailing, 36)
                    if viewModel.showScrubber {
                        Spacer().frame(height: 6)
                        scrubber
                            // Nudged down without changing the layout gaps, so
                            // the group stays centred. Safe against the transport
                            // row because the time labels sit at the far edges
                            // while the keys are centred — they don't collide.
                            .offset(y: 3)
                    }
                    // Tight gap so the transport keys sit up close under the
                    // playbar rather than floating below it.
                    Spacer().frame(height: viewModel.showScrubber ? 2 : 8)
                    controls
                    Spacer(minLength: 0)
                } else {
                    idlePlaceholder
                }
            }
            // Fixed width rather than filling: a filling column would stretch
            // to the right edge and the "pair" could never be centred. 340 is
            // the width it occupied before, so the playbar length is unchanged.
            .frame(minWidth: 340, maxWidth: 340, maxHeight: .infinity, alignment: .leading)
            // Vertical position of the whole text column (title, artist,
            // playbar, transport). The column is ~107 tall against 114 of
            // usable space, so there is only a few points of slack top and
            // bottom to play with here.
            .offset(y: -1)
        }
        // Centres the album+text pair between the panel edges.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        // Sized to fill the usable content height (panel 146 minus the
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
                fontSize: 14,
                weight: .semibold,
                lineHeight: 18
            )

            // No HStack wrapper: it gave the marquee an ambiguous width to
            // measure against, which is the other half of why long artist
            // strings failed to scroll. lineHeight is trimmed to suit 11pt
            // rather than inheriting the 18pt title default.
            // The dimming is passed in rather than applied with
            // `foregroundStyle`: the text is drawn into a layer now, and a
            // SwiftUI style modifier can't reach inside it.
            MarqueeText(
                text: media.artist,
                fontSize: 11,
                weight: .regular,
                color: .white.opacity(0.7),
                lineHeight: 15
            )
        }
    }

    private var idlePlaceholder: some View {
        // Mirror the Claude tab's headline/detail block exactly — same font
        // sizes, weights, colours, and vertical placement (leading + trailing
        // spacers centre it, with a filler standing in for Claude's info row) —
        // so switching between the two tabs doesn't jump the text around.
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0)

            Text("Nothing playing")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Spacer().frame(height: 2)

            Text("Start something in Spotify or Music")
                .font(.system(size: 12.5, weight: .regular))
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .truncationMode(.middle)

            Spacer().frame(height: 11)
            // Stands in for the height of Claude's project/elapsed info row so
            // the two text lines sit at the same vertical position on both tabs.
            Color.clear.frame(height: 22)

            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - Scrubber

    private var scrubber: some View {
        // Ticks between the adapter's ~1s updates so the elapsed label and thumb
        // advance smoothly rather than stepping once a second. Capped at 30fps
        // like the rest of the app's timelines: the fill creeps across at a
        // pixel or two a second, so redrawing it 120 times a second on a
        // ProMotion panel buys nothing that can be seen.
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !media.isPlaying)) { context in
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
        // Shuffle · prev · play/pause · next · repeat, centred. Shuffle and
        // repeat toggle over Spotify's AppleScript; repeat is boolean there
        // (no repeat-one), so it lights for .all and clears for .off. The two
        // toggles show white when on and grey when off; the transport keys
        // stay white throughout (they aren't stateful).
        HStack(spacing: 16) {
            Spacer(minLength: 0)

            if viewModel.showShuffleRepeat {
                controlButton("shuffle", size: 15, active: viewModel.isShuffled) {
                    viewModel.toggleShuffle()
                }
            }

            controlButton("backward.fill", size: 21) { viewModel.previousTrack() }

            controlButton(
                media.isPlaying ? "pause.fill" : "play.fill",
                size: 28
            ) {
                viewModel.togglePlayPause()
            }

            controlButton("forward.fill", size: 21) { viewModel.nextTrack() }

            if viewModel.showShuffleRepeat {
                controlButton(
                    viewModel.repeatMode == .one ? "repeat.1" : "repeat",
                    size: 15,
                    active: viewModel.repeatMode != .off
                ) {
                    viewModel.toggleRepeat()
                }
            }

            Spacer(minLength: 0)
        }
        .disabled(!viewModel.canControlPlayback)
        .opacity(viewModel.canControlPlayback ? 1 : 0.4)
    }

    private func controlButton(
        _ symbol: String,
        size: CGFloat = 13,
        active: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                // White when on, grey when off — so the shuffle/repeat toggles
                // read their state at a glance. Transport keys default `active`
                // to true, so they stay white.
                .foregroundStyle(active ? .white : .white.opacity(0.35))
                .frame(width: size + 7, height: size + 7)
                .contentShape(Rectangle())
                .animation(.easeInOut(duration: 0.15), value: active)
        }
        .buttonStyle(.plain)
    }
}
