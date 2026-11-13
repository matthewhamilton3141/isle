//
//  CollapsedNotchView+Floating.swift
//
//  The closed island off its notch (`IslandPlacement.floating`): one
//  capsule, as wide as what it holds, instead of a sliver either side of a
//  camera. The numbers are in IslandFloat.swift.
//
//  The pieces are the docked pill's own — the cover, the waveform, the
//  status marker, the timer's ring and clock, a toast's glyph — with the
//  room the notch never gave them: the track's title and artist beside the
//  cover, the project under Claude's status. Music leads, Claude follows,
//  then the timer, a hairline between each; a toast borrows the whole
//  capsule, as it does the whole pill. With nothing live it is a bead with
//  a grabber on it.
//
//  Everything it shows is something Isle was told: the title, the artist,
//  the state and the project are the ones the open panel shows.
//

import SwiftUI
import AppKit

// MARK: - What the capsule holds

/// Measures what the closed capsule holds and describes it as an
/// `IslandFloat.Pill`, which sizes it. Read by `NotchRootView` for the
/// outline — in the panel's tree and the glass window's alike, so the two
/// can't disagree — and by the capsule's layout below.
@MainActor
enum FloatingPillLayout {
    static func pill(for viewModel: NotchViewModel) -> IslandFloat.Pill {
        if let toast = viewModel.collapsedToast {
            return IslandFloat.Pill(toast: width(toast.text, titleFont))
        }
        let music = viewModel.hasMusicActivity
        let claude = viewModel.hasClaudeActivity
        let timer = viewModel.hasPomodoroActivity
        let alone = [music, claude, timer].filter { $0 }.count == 1
        var pill = IslandFloat.Pill()
        if music {
            let media = viewModel.media
            // Alone, the artist has a line of its own under the title.
            let natural = max(width(title(media), titleFont), alone ? width(media.artist, detailFont) : 0)
            pill.music = .init(label: IslandFloat.labelWidth(natural: natural, alone: alone), wave: viewModel.showsWaveform)
        }
        if claude {
            let natural = max(width(viewModel.collapsedStatusText, titleFont),
                              alone ? width(project(viewModel) ?? "", detailFont) : 0)
            // No floor: a status is a word, and the capsule is as wide as it.
            pill.claude = min(natural.rounded(.up), alone ? IslandFloat.labelMaxAlone : IslandFloat.labelMaxShared)
        }
        if timer {
            pill.timer = clockWidth(for: viewModel.pomodoro.phaseDuration)
        }
        return pill
    }

    /// The track's title as the capsule shows it.
    static func title(_ media: MediaPlaybackModel) -> String {
        media.title.isEmpty ? "Not playing" : media.title
    }

    /// The project under Claude's status, when Claude has the capsule to
    /// itself and the session has said where it is.
    static func project(_ viewModel: NotchViewModel) -> String? {
        guard let project = viewModel.claudeProject, !project.isEmpty else { return nil }
        return project
    }

    /// The clock's slot: measured from a template the shape of the
    /// interval's full length, in the monospaced-digit font it's drawn in,
    /// so the capsule keeps one width while the digits count down (as on
    /// the notch: `NotchViewModel.pomodoroClockWidth`).
    static func clockWidth(for phaseDuration: TimeInterval) -> CGFloat {
        let template: String
        switch phaseDuration {
        case 3600...: template = "0:00:00"
        case 600...: template = "00:00"
        default: template = "0:00"
        }
        return width(template, clockFont) + 2
    }

    static let titleFont = NSFont.systemFont(ofSize: IslandFloat.titleSize, weight: .semibold)
    static let detailFont = NSFont.systemFont(ofSize: IslandFloat.detailSize, weight: .medium)
    static let clockFont = NSFont.monospacedDigitSystemFont(ofSize: IslandFloat.titleSize, weight: .semibold)

    /// Measured widths, kept: the outline's size is read several times per
    /// body evaluation, and laying a string out to measure it isn't cheap
    /// (see `NotchViewModel.textWidth`). Titles come and go with the
    /// tracks, so it's emptied past a modest size.
    private static var widthCache: [String: CGFloat] = [:]

    private static func width(_ string: String, _ font: NSFont) -> CGFloat {
        guard !string.isEmpty else { return 0 }
        let key = "\(font.pointSize)|\(font.fontName)|\(string)"
        if let cached = widthCache[key] { return cached }
        if widthCache.count >= 256 { widthCache.removeAll(keepingCapacity: true) }
        let width = ceil((string as NSString).size(withAttributes: [.font: font]).width)
        widthCache[key] = width
        return width
    }
}

// MARK: - The capsule

extension CollapsedNotchView {
    /// The capsule's content, laid out to exactly `IslandFloat.Pill.size`.
    @ViewBuilder
    var floatingPill: some View {
        let pill = FloatingPillLayout.pill(for: viewModel)
        if pill.isBead {
            IslandGrabber(size: IslandFloat.beadGrabber)
        } else {
            HStack(spacing: 0) {
                if let toast = viewModel.collapsedToast {
                    toastCluster(toast)
                } else {
                    clusters(pill)
                }
            }
            .padding(.leading, IslandFloat.leadingInset(mark: pill.leadingMark))
            .padding(.trailing, IslandFloat.trailingInset)
            .frame(height: IslandFloat.pillHeight)
        }
    }

    /// Music, Claude, the timer — whichever are live, in that order, with
    /// a hairline between.
    @ViewBuilder
    private func clusters(_ pill: IslandFloat.Pill) -> some View {
        let alone = pill.clusters == 1
        if let music = pill.music {
            musicCluster(music, alone: alone)
        }
        if let claude = pill.claude {
            if pill.music != nil { clusterDivider }
            claudeCluster(width: claude, alone: alone)
        }
        if let timer = pill.timer {
            if pill.music != nil || pill.claude != nil { clusterDivider }
            timerCluster(width: timer)
        }
    }

    private var clusterDivider: some View {
        Capsule()
            .fill(.islandSecondary(IslandFloat.dividerOpacity))
            .frame(width: IslandFloat.divider.width, height: IslandFloat.divider.height)
            .padding(.horizontal, IslandFloat.clusterGap)
    }

    /// The cover, the title — over the artist, with the capsule to itself —
    /// and the waveform. Both lines are the open panel's marquee: text that
    /// fits is still, text that doesn't travels.
    private func musicCluster(_ music: IslandFloat.Pill.Music, alone: Bool) -> some View {
        let media = viewModel.media
        return HStack(spacing: 0) {
            artworkThumbnail(size: IslandFloat.cover, radius: IslandFloat.coverRadius)
            VStack(alignment: .leading, spacing: 0) {
                MarqueeText(
                    text: FloatingPillLayout.title(media),
                    fontSize: IslandFloat.titleSize,
                    weight: .semibold,
                    lineHeight: IslandFloat.titleLine
                )
                if alone, !media.artist.isEmpty {
                    MarqueeText(
                        text: media.artist,
                        fontSize: IslandFloat.detailSize,
                        weight: .medium,
                        color: .white.opacity(detailOpacity),
                        lineHeight: IslandFloat.detailLine
                    )
                }
            }
            .frame(width: music.label, alignment: .leading)
            .padding(.leading, IslandFloat.markGap)
            if music.wave {
                equalizer(width: IslandFloat.wave.width)
                    .padding(.leading, IslandFloat.waveGap)
            }
        }
    }

    /// The status marker and the state in its colour — over the project,
    /// with the capsule to itself.
    private func claudeCluster(width: CGFloat, alone: Bool) -> some View {
        HStack(spacing: IslandFloat.markGap) {
            claudeDots(size: IslandFloat.marker)
            VStack(alignment: .leading, spacing: 0) {
                statusText(fontSize: IslandFloat.titleSize)
                    .frame(height: IslandFloat.titleLine)
                if alone, let project = FloatingPillLayout.project(viewModel) {
                    Text(project)
                        .font(.system(size: IslandFloat.detailSize, weight: .medium))
                        .foregroundStyle(.white.opacity(detailOpacity))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(height: IslandFloat.detailLine)
                }
            }
            .frame(width: width, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    /// The timer's ring and its clock.
    private func timerCluster(width: CGFloat) -> some View {
        HStack(spacing: IslandFloat.markGap) {
            pomodoroRing(size: IslandFloat.ring)
            pomodoroClock(fontSize: IslandFloat.titleSize, width: width)
        }
    }

    /// A toast: its glyph where the cover sits, its message beside it.
    private func toastCluster(_ toast: IslandToast) -> some View {
        HStack(spacing: IslandFloat.markGap) {
            toastSymbol(toast, slot: CGSize(width: IslandFloat.toastGlyph, height: 18))
            toastText(toast, fontSize: IslandFloat.titleSize)
        }
    }

    /// The second line's white: secondary, lifted on glass like every
    /// other secondary text (the marquee draws into a layer, so it's
    /// handed the resolved colour rather than a style).
    private var detailOpacity: Double {
        onGlass ? IslandGlass.liftedOpacity(IsleType.Tone.secondary) : IsleType.Tone.secondary
    }
}

// MARK: - For the faces

private struct IslandFloatingKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Whether the island is off its notch (`IslandPlacement.floating`).
    /// Set by NotchRootView on the open panel's content, for the one face
    /// that lays its header out round the camera.
    var islandFloating: Bool {
        get { self[IslandFloatingKey.self] }
        set { self[IslandFloatingKey.self] = newValue }
    }
}

// MARK: - The grabber

/// The mark for "this can be moved": a short rounded bar, in the middle of
/// the open panel's header where the camera was, and on the bead a closed
/// island with nothing to show comes down to.
struct IslandGrabber: View {
    var size: CGSize

    var body: some View {
        Capsule()
            .fill(.islandSecondary(IslandFloat.grabberOpacity))
            .frame(width: size.width, height: size.height)
            .accessibilityHidden(true)
    }
}
