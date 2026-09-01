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
    @ObservedObject var island: IslandPresentation
    var palette: ArtworkPalette

    private var cutoutWidth: CGFloat {
        island.metrics?.notchSize.width ?? 0
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
        if let toast = viewModel.powerToast, viewModel.showsPowerToast {
            // A power toast borrows the whole island rather than taking a
            // third seat: its symbol sits in the album cover's footprint, so
            // whatever was there slides back into exactly the same spot when
            // the toast ends.
            toastSymbol(toast)
        } else if viewModel.shouldSplitCollapsed {
            // Music cluster: album + waveform, waveform tucked toward the camera.
            // Kept in place even during a Claude alert — the alert sits on the
            // right rather than displacing the music.
            HStack(spacing: CollapsedSize.gap) {
                artworkThumbnail
                equalizer(width: CollapsedSize.wave)
            }
        } else if viewModel.isClaudeSolo {
            // Claude solo: the dot glyph sits to the left of the camera, in the
            // album cover's footprint so switching music↔Claude keeps it put.
            claudeDots(size: CollapsedSize.album)
        } else if viewModel.hasMusicActivity {
            artworkThumbnail
        } else {
            EmptyView()
        }
    }

    // MARK: - Right (Claude / waveform)

    @ViewBuilder
    private var trailing: some View {
        if let toast = viewModel.powerToast, viewModel.showsPowerToast {
            toastText(toast)
        } else if viewModel.shouldSplitCollapsed {
            // Split: the Claude cluster rides on the right beside the music —
            // dots next to the camera, status word beside them.
            HStack(spacing: CollapsedSize.gap) {
                claudeDots(size: CollapsedSize.dots)
                statusText
            }
        } else if viewModel.isClaudeSolo {
            // Claude solo: only the status word here; the dots are on the left.
            statusText
        } else if viewModel.hasMusicActivity {
            equalizer(width: CollapsedSize.wave)
        } else {
            EmptyView()
        }
    }

    // MARK: - Power toast

    /// Toast glyphs are sized by *point size*, not fitted to a box.
    ///
    /// Fitting each symbol into a fixed rect overrode the proportions SF
    /// Symbols is drawn at: `battery.100percent` is twice as wide as it is
    /// tall, so it hit the width limit and came out 11pt high, while
    /// `bolt.fill` hit the height limit and came out 15.8 — the bolt rendered
    /// 44% taller than the battery beside it. A point size is the size every
    /// symbol in the set is designed to agree at.
    ///
    /// 12 is the ceiling for a 22pt slot: at 13 the widest glyph
    /// (`battery.100percent.bolt`) measures 23pt and overhangs.
    private static let toastGlyphPointSize: CGFloat = 12

    /// The slot every glyph is centred in, so the wide ones and the narrow
    /// ones share one optical centre — which lands where the album artwork's
    /// centre is, so nothing shifts when a toast takes the island and gives it
    /// back. Tall enough for the tallest glyph at this point size (`bolt.fill`,
    /// 17pt) without clipping.
    private static let toastGlyphSlot = CGSize(width: CollapsedSize.album, height: 18)

    /// The rune is hand-drawn, so it has no point size to inherit — 16 puts it
    /// between `headphones` (15) and `computermouse.fill` (16) at the same
    /// setting, which are the glyphs it appears alongside.
    private static let toastRuneHeight: CGFloat = 16

    private func toastSymbol(_ toast: PowerToast) -> some View {
        Group {
            switch toast.glyph {
            case .symbol(let name):
                // Nudged onto its own ink rather than its layout box — see
                // GlyphInk for why the two aren't the same place.
                let ink = GlyphInk.centeringOffset(
                    for: name, pointSize: Self.toastGlyphPointSize
                )
                Image(systemName: name)
                    .font(.system(size: Self.toastGlyphPointSize, weight: .semibold))
                    .foregroundStyle(toast.tint)
                    .offset(x: -ink.width, y: -ink.height)
            case .bluetoothRune:
                BluetoothRune.view(height: Self.toastRuneHeight, tint: toast.tint)
            }
        }
        // Centres both axes for every glyph, whatever its own proportions.
        .frame(width: Self.toastGlyphSlot.width, height: Self.toastGlyphSlot.height)
    }

    private func toastText(_ toast: PowerToast) -> some View {
        Text(toast.text)
            .font(.system(size: CollapsedSize.statusFontSize, weight: .semibold))
            .foregroundStyle(toast.tint)
            .lineLimit(1)
            .fixedSize()
            // Crossfade between consecutive toasts (charging → device level)
            // so the island resizes around a soft swap rather than a hard cut,
            // matching how the Claude status word rotates.
            .contentTransition(.opacity)
    }

    // MARK: - Pieces

    private func claudeDots(size: CGFloat) -> some View {
        ClaudeStatusGlyphView(
            state: viewModel.claudeState,
            kind: viewModel.claudeMarkerKind,
            palette: palette,
            tint: viewModel.workingTint
        )
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
            // Crossfade the word as it rotates ("Coalescing" → "Percolating"),
            // matching the expanded headline, so the swap reads as a soft change
            // rather than a hard cut while the island resizes around it.
            .contentTransition(.opacity)
    }

    /// The status text colour, matched to the dots: the warm thinking/working
    /// tint when it applies, else the marker's fixed hue or the artwork accent.
    private var markerColor: Color {
        if let tint = viewModel.workingTint { return tint }
        let design = MarkerStore.shared.design(for: viewModel.claudeMarkerKind)
        return design.colorMode == .fixed ? Color(hex: design.fixedColorHex) : palette.accent
    }

    private func equalizer(width: CGFloat) -> some View {
        LiveEqualizer(
            source: viewModel.audioLevelSource,
            palette: palette,
            isPlaying: viewModel.media.isPlaying
        )
        .frame(width: width, height: 20)
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
