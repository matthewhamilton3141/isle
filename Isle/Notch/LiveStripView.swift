//
//  LiveStripView.swift
//
//  The live strip at the primary face's foot (see `LiveStrip` for what goes
//  in it and when): one row of small cards, centred under the face, each a
//  click into its own face.
//
//    Music    the cover, title and artist, the waveform beside the artist
//             where it fits, and play/pause and next. The cover and the
//             words open the Music face; the keys are keys.
//    Timer    the ring and the clock, and the phase.
//    Agenda   the event's colour, its title and when, and Join while its
//             call can be joined. Join is a key; the rest opens the agenda.
//    Shelf    how many things it holds.
//
//  Every card is the home tiles' plate at a strip's height. Nothing here
//  keeps a clock of its own but the timer's (once a second, while it runs,
//  as on the home tile and the island); the agenda's "in 12 min" moves on
//  the view model's minute (`stripMinute`). The waveform is the island's
//  own Core Animation layer: while the panel is open the collapsed
//  island's is gone, so there's still the one on screen.
//

import SwiftUI

struct LiveStripView: View {
    @ObservedObject var viewModel: NotchViewModel
    var palette: ArtworkPalette
    var content: LiveStrip.Content

    var body: some View {
        // All four up don't fit the face's width at their ease: the music
        // card gives up its next key, the event's title some width, the
        // shelf its words.
        let compact = content.count >= 4
        HStack(spacing: LiveStrip.chipGap) {
            if content.music {
                LiveStripMusicCard(viewModel: viewModel, palette: palette, compact: compact)
                    .transition(.opacity)
            }
            if content.timer {
                LiveStripTimerCard(viewModel: viewModel, timer: viewModel.pomodoro, palette: palette)
                    .transition(.opacity)
            }
            if let id = content.event, let event = viewModel.agendaItems.first(where: { $0.id == id }) {
                LiveStripEventCard(viewModel: viewModel, event: event, joinable: content.joinable,
                                   now: viewModel.stripNow, compact: compact)
                    .transition(.opacity)
            }
            if content.shelf > 0 {
                LiveStripShelfCard(viewModel: viewModel, compact: compact)
                    .transition(.opacity)
            }
        }
        // Centred under the face, so one card isn't left hanging at one end.
        .frame(maxWidth: .infinity, alignment: .center)
        .frame(height: LiveStrip.chipHeight)
        .padding(.top, LiveStrip.topGap)
        .foregroundStyle(.white)
        .lineLimit(1)
        .animation(.easeInOut(duration: 0.2), value: content)
    }
}

// MARK: - Plate

/// A card's plate: the home tile's fill and corners at the strip's height.
private struct StripPlate: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(height: LiveStrip.chipHeight)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.white.opacity(HomeTileStyle.restingFill)))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// The part of a card that opens its face: a plain button over its content.
private struct OpenFace<Label: View>: View {
    var face: IsleTab
    var viewModel: NotchViewModel
    @ViewBuilder var label: () -> Label

    var body: some View {
        Button {
            // No withAnimation: ExpandedNotchView animates on the place.
            viewModel.selectTab(face)
        } label: {
            label().contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open \(face.title)")
    }
}

/// The face's two-line text: a label over a quieter line.
private struct CardLines<Second: View>: View {
    var first: String
    var monospaced = false
    @ViewBuilder var second: () -> Second

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(first)
                .font(monospaced ? IsleType.label.monospacedDigit() : IsleType.label)
                .truncationMode(.tail)
            second()
                .font(IsleType.meta)
                .foregroundStyle(.islandSecondary(IsleType.Tone.secondary))
        }
    }
}

// MARK: - Music

struct LiveStripMusicCard: View {
    @ObservedObject var viewModel: NotchViewModel
    var palette: ArtworkPalette
    /// Play/pause alone, for a strip with every card up.
    var compact = false

    static let cover: CGFloat = 26

    var body: some View {
        let media = viewModel.media
        HStack(spacing: 2) {
            OpenFace(face: .music, viewModel: viewModel) {
                HStack(spacing: 8) {
                    cover(media)
                    CardLines(first: media.title.isEmpty ? "Not playing" : media.title) {
                        // The waveform beside the artist where both fit;
                        // otherwise the artist alone.
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 6) {
                                Text(media.artist).fixedSize()
                                waveform(media)
                            }
                            Text(media.artist).truncationMode(.tail)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            HStack(spacing: 0) {
                key(media.isPlaying ? "pause.fill" : "play.fill", size: 14,
                    label: media.isPlaying ? "Pause" : "Play") { viewModel.togglePlayPause() }
                if !compact {
                    key("forward.fill", size: 11, label: "Next track") { viewModel.nextTrack() }
                }
            }
            .disabled(!viewModel.canControlPlayback)
            .opacity(viewModel.canControlPlayback ? 1 : 0.4)
        }
        .padding(.leading, 6)
        .padding(.trailing, 3)
        .frame(minWidth: 150, idealWidth: 214, maxWidth: 214)
        .modifier(StripPlate())
    }

    @ViewBuilder
    private func cover(_ media: MediaPlaybackModel) -> some View {
        Group {
            if let image = media.artwork {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(colors: [palette.primary, palette.secondary],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
        .frame(width: Self.cover, height: Self.cover)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    @ViewBuilder
    private func waveform(_ media: MediaPlaybackModel) -> some View {
        if viewModel.showsWaveform {
            LiveEqualizer(source: viewModel.audioLevelSource, palette: palette,
                          isPlaying: media.isPlaying, listens: viewModel.waveformSource.capturesAudio)
                .frame(width: 16, height: 10)
                .allowsHitTesting(false)
        }
    }

    private func key(_ symbol: String, size: CGFloat, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .frame(width: 24, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

// MARK: - Timer

struct LiveStripTimerCard: View {
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject var timer: PomodoroTimer
    var palette: ArtworkPalette

    var body: some View {
        OpenFace(face: .pomodoro, viewModel: viewModel) {
            // Once a second while it runs and not at all while paused, the
            // same clock the home tile and the island read.
            TimelineView(.animation(minimumInterval: 1, paused: !timer.isRunning)) { context in
                HStack(spacing: 8) {
                    PomodoroRing(progress: timer.progress(at: context.date), tint: tint, lineWidth: 2.5)
                        .frame(width: 20, height: 20)
                        .opacity(timer.isRunning ? 1 : 0.55)
                    CardLines(first: PomodoroTimer.clock(timer.remaining(at: context.date)), monospaced: true) {
                        Text(timer.isRunning ? timer.phase.title : "Paused")
                    }
                }
            }
            .padding(.horizontal, 9)
        }
        .fixedSize()
        .modifier(StripPlate())
    }

    /// With a cover up, the cover's colours, as on the island. Without one
    /// the palette is the Claude accent's, whose light stop washes out at a
    /// ring's width, so focus takes its full colour and a break its light.
    private var tint: Color {
        let cover = viewModel.artworkPalette != nil && viewModel.hasMusicActivity
        if timer.phase.isBreak { return cover ? palette.secondary : palette.accent }
        return cover ? palette.accent : palette.primary
    }
}

// MARK: - Agenda

struct LiveStripEventCard: View {
    var viewModel: NotchViewModel
    var event: AgendaItem
    var joinable: Bool
    var now: Date
    var compact = false

    var body: some View {
        HStack(spacing: 8) {
            OpenFace(face: .agenda, viewModel: viewModel) {
                HStack(spacing: 8) {
                    Capsule().fill(event.color).frame(width: 3, height: 24)
                    CardLines(first: event.title) {
                        Text(HomeGridView.when(event, at: now))
                    }
                    .frame(maxWidth: compact ? 84 : 130, alignment: .leading)
                }
            }
            if joinable, let url = event.joinURL {
                JoinPill(tint: event.color, url: url, compact: true)
                    .transition(.opacity)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, joinable ? 8 : 10)
        .fixedSize()
        .modifier(StripPlate())
    }
}

// MARK: - Shelf

struct LiveStripShelfCard: View {
    var viewModel: NotchViewModel
    /// The count alone beside the tray.
    var compact = false

    var body: some View {
        let tally = viewModel.shelf.tally
        OpenFace(face: .shelf, viewModel: viewModel) {
            HStack(spacing: compact ? 6 : 8) {
                Image(systemName: IsleTab.shelf.symbolName)
                    .font(.system(size: 13, weight: .semibold))
                    .opacity(0.8)
                if compact {
                    Text("\(tally.total)").font(IsleType.label.monospacedDigit())
                } else {
                    CardLines(first: tally.itemsLine) { Text("Shelf") }
                }
            }
            .padding(.horizontal, 9)
        }
        .fixedSize()
        .modifier(StripPlate())
    }
}
