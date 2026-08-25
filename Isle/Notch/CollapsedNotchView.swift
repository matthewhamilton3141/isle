//
//  CollapsedNotchView.swift
//
//  Resting state: sits either side of the physical camera housing.
//
//  Nothing may be drawn in the middle — that's where the actual camera is.
//  So this is a left cluster, a spacer the width of the cutout, and a right
//  cluster. The split rule from spec 3.1 decides what goes in each.
//

import SwiftUI

struct CollapsedNotchView: View {
    @ObservedObject var viewModel: NotchViewModel
    var palette: ArtworkPalette

    private var cutoutWidth: CGFloat {
        viewModel.metrics?.notchSize.width ?? 0
    }

    var body: some View {
        HStack(spacing: 0) {
            leading
                .frame(maxWidth: .infinity, alignment: .leading)

            // Dead zone over the camera housing.
            Color.clear
                .frame(width: cutoutWidth)

            trailing
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Sides

    /// Left side: album art thumbnail. Suppressed entirely when Claude needs
    /// approval, which per spec takes over the whole collapsed notch.
    @ViewBuilder
    private var leading: some View {
        if viewModel.claudeState == .needsApproval {
            ClaudeStatusGlyphView(state: viewModel.claudeState)
                .frame(width: 18, height: 18)
        } else if viewModel.hasMusicActivity {
            artworkThumbnail
        } else {
            EmptyView()
        }
    }

    /// Right side: equalizer, the Claude glyph, or both split.
    @ViewBuilder
    private var trailing: some View {
        if viewModel.claudeState == .needsApproval {
            // Music demotes to a thin tinted ring so the approval state can't
            // be missed (spec 3.1).
            if viewModel.hasMusicActivity {
                Circle()
                    .stroke(palette.accent.opacity(0.8), lineWidth: 2)
                    .frame(width: 8, height: 8)
            }
        } else if viewModel.shouldSplitCollapsed {
            HStack(spacing: 6) {
                EqualizerView(
                    palette: palette,
                    isPlaying: viewModel.media.isPlaying,
                    levels: viewModel.audioLevels
                )
                    .frame(width: 22, height: 13)
                ClaudeStatusGlyphView(state: viewModel.claudeState)
                    .frame(width: 14, height: 14)
            }
        } else if viewModel.hasClaudeActivity {
            ClaudeStatusGlyphView(state: viewModel.claudeState)
                .frame(width: 16, height: 16)
        } else if viewModel.hasMusicActivity {
            EqualizerView(
                palette: palette,
                isPlaying: viewModel.media.isPlaying,
                levels: viewModel.audioLevels
            )
                .frame(width: 26, height: 14)
        } else {
            EmptyView()
        }
    }

    private var artworkThumbnail: some View {
        Group {
            if let artwork = viewModel.media.artwork {
                Image(nsImage: artwork)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                // Keep the layout stable while artwork loads rather than
                // letting the row jump when it arrives.
                LinearGradient(
                    colors: [palette.primary, palette.secondary],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
        .frame(width: 18, height: 18)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}
