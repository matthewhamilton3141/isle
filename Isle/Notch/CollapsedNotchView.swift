//
//  CollapsedNotchView.swift
//
//  Resting state: sits either side of the physical camera housing.
//
//  Nothing may be drawn in the middle — that's where the actual camera is.
//  So this is a left cluster, a spacer the width of the cutout, and a right
//  cluster. The camera itself acts as the divider: music (album + waveform)
//  groups on the left, Claude (dots + a short status word) on the right, so
//  the two sources read as two mini-displays rather than a jumbled row. The
//  per-side widths come from the view model (CollapsedSize) so the shape is
//  sized and centred to match.
//

import SwiftUI

struct CollapsedNotchView: View {
    @ObservedObject var viewModel: NotchViewModel
    var palette: ArtworkPalette

    private var cutoutWidth: CGFloat {
        viewModel.metrics?.notchSize.width ?? 0
    }

    var body: some View {
        let sides = viewModel.collapsedSideWidths
        HStack(spacing: 0) {
            // The cutout gap sits between each cluster and the camera, so the
            // clusters tuck against the housing with a little air and the album
            // pulls back toward the outer edge (rather than sitting flush).
            leading
                .padding(.trailing, CollapsedSize.cutoutGap)
                .frame(width: sides.leading, alignment: .trailing)

            // Dead zone over the camera housing.
            Color.clear
                .frame(width: cutoutWidth)

            trailing
                .padding(.leading, CollapsedSize.cutoutGap)
                .frame(width: sides.trailing, alignment: .leading)
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Left (music)

    @ViewBuilder
    private var leading: some View {
        if viewModel.claudeState.isAttention {
            // Approval takes over the whole notch; the "!" leads.
            claudeDots(size: 18)
        } else if viewModel.shouldSplitCollapsed {
            // Music cluster: album + waveform, waveform tucked toward the camera.
            HStack(spacing: CollapsedSize.gap) {
                artworkThumbnail
                if viewModel.showWaveform {
                    equalizer(width: CollapsedSize.waveSplit)
                }
            }
        } else if viewModel.hasMusicActivity {
            artworkThumbnail
        } else {
            EmptyView()
        }
    }

    // MARK: - Right (Claude / waveform)

    @ViewBuilder
    private var trailing: some View {
        if viewModel.claudeState.isAttention {
            // Music demotes to a thin tinted ring so approval can't be missed.
            if viewModel.hasMusicActivity {
                Circle()
                    .stroke(palette.accent.opacity(0.8), lineWidth: 2)
                    .frame(width: 8, height: 8)
            }
        } else if viewModel.shouldSplitCollapsed
                    || (viewModel.hasClaudeActivity && !viewModel.hasMusicActivity) {
            // Claude cluster: dots next to the camera, status word beside them,
            // text coloured to match the marker.
            HStack(spacing: CollapsedSize.gap) {
                claudeDots(size: CollapsedSize.dots)
                statusText
            }
        } else if viewModel.hasMusicActivity {
            if viewModel.showWaveform {
                equalizer(width: CollapsedSize.waveSolo)
            }
        } else {
            EmptyView()
        }
    }

    // MARK: - Pieces

    private func claudeDots(size: CGFloat) -> some View {
        ClaudeStatusGlyphView(state: viewModel.claudeState, palette: palette)
            .frame(width: size, height: size)
    }

    private var statusText: some View {
        // Matches the width the view model measured for sizing, so the text
        // fits its slot exactly.
        Text(viewModel.collapsedStatusText)
            .font(.system(size: CollapsedSize.statusFontSize, weight: .semibold))
            .foregroundStyle(markerColor)
            .lineLimit(1)
            .fixedSize()
    }

    /// The marker's colour, so the status text matches the dots: its fixed hue,
    /// or the artwork accent for palette-tinted markers.
    private var markerColor: Color {
        let design = MarkerStore.shared.design(for: MarkerKind(state: viewModel.claudeState))
        return design.colorMode == .fixed ? Color(hex: design.fixedColorHex) : palette.accent
    }

    private func equalizer(width: CGFloat) -> some View {
        EqualizerView(
            palette: palette,
            isPlaying: viewModel.media.isPlaying,
            levels: viewModel.audioLevels
        )
        .frame(width: width, height: 14)
    }

    private var artworkThumbnail: some View {
        Group {
            if let artwork = viewModel.media.artwork {
                // High interpolation is load-bearing here: this is a ~640px
                // bitmap being drawn into 22pt, and the default filter aliases
                // badly at that reduction.
                Image(nsImage: artwork)
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
            }
        }
        .frame(width: CollapsedSize.album, height: CollapsedSize.album)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}
