//
//  ExpandedNotchView.swift
//
//  The open panel: artwork, ticker text, seekable scrubber, transport row,
//  and the output switcher at the head of that row, whose device list
//  stands in for the text column while it's open, the output's volume
//  across its header.
//  When Claude Code opened the notch rather than the pointer, its status
//  card takes the leading position and music shares the row (spec 3.1).
//

import SwiftUI

struct ExpandedNotchView: View {
    @ObservedObject var viewModel: NotchViewModel
    /// Observed for the drop face, which is this island's alone.
    @ObservedObject var island: IslandPresentation
    var palette: ArtworkPalette
    /// The waveform's colours: the cover's as the pill on the notch draws
    /// them, wherever the bars are. `palette` is lifted for glass
    /// (`flooredForGlass`), which made the open panel's bars and a
    /// detached island's a paler thing than the notch's (Matthew: "i want
    /// compacted notch colours"). The bars have a dark edge on glass
    /// instead (`EqualizerStyle.onGlass`). Nil: `palette`.
    var waveformPalette: ArtworkPalette? = nil

    private var media: MediaPlaybackModel { viewModel.media }

    /// A file drag is over this island and it may be dropped: the drop face
    /// stands in for wherever the panel was, and goes again with the drag.
    private var dropPayload: DropPayload? {
        guard island.isDropTarget, viewModel.acceptsDrops else { return nil }
        return viewModel.dropPayload
    }

    /// The output list is showing in place of the text column. Per island
    /// rather than on the view model: it's this panel's state, and it goes
    /// when the panel collapses (this view is torn down) or the face changes
    /// (see `musicBody`'s `onDisappear`).
    @State private var showsOutputs = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// With Prism's ribbon along the lip (`IslandPrism.showsRibbon`), it is
    /// the waveform, and the bars in the corner would be the same thing
    /// said twice.
    @Environment(\.islandHasRibbon) private var hasRibbon

    private static let crossDissolve = Animation.easeInOut(duration: 0.28)

    var body: some View {
        // The way home lives in NotchRootView, in the housing band to the
        // right of the physical cutout — see the crumb in NotchRootView.notch.
        content
            // Home to a face and back: the tile grows into its face and the
            // face draws back into it (see `TileMorph`), on its own spring —
            // the inner of the two, so it wins when both change. Between
            // faces (the interrupt-driven switch to Claude) and everywhere
            // under Reduce Motion, a clean cross-dissolve: nothing moves, the
            // old place fades out as the new one fades in. A swipe lands
            // without either: its faces are already where they belong (see
            // `FacePager.settle`).
            .animation(reduceMotion ? Self.crossDissolve : .tileMorph, value: viewModel.expandedPlace == .home)
            .animation(Self.crossDissolve, value: viewModel.expandedPlace)
            .animation(.easeInOut(duration: 0.2), value: dropPayload != nil)
            // The waveform, on the Music face only: the other faces are about
            // something else, and a row of paused dots in their corner was
            // one more thing to read. Pinned to the panel's top-right outside
            // the face switch, so it fades out as a swipe carries the Music
            // face away and in once it lands back. Gated on a live track;
            // non-interactive so it never swallows a seek or dismiss tap.
            .overlay(alignment: .topTrailing) {
                ZStack {
                    if showsCornerWaveform {
                        LiveEqualizer(
                            source: viewModel.audioLevelSource,
                            palette: waveformPalette ?? palette,
                            isPlaying: media.isPlaying,
                            listens: viewModel.waveformSource.capturesAudio
                        )
                        .frame(width: 30, height: 24)
                        .padding(.top, 10)
                        .padding(.trailing, 4)
                        .allowsHitTesting(false)
                        .modifier(SwipeFade(pager: island.pager))
                        .transition(.opacity)
                    }
                }
                // Scoped to the waveform, so it fades in and out without
                // re-timing anything on the faces under it.
                .animation(Self.crossDissolve, value: showsCornerWaveform)
            }
    }

    /// The Music face's waveform: on that face alone, with a track to draw
    /// and the setting on.
    private var showsCornerWaveform: Bool {
        !hasRibbon && media.hasTrack && viewModel.showsWaveform && viewModel.expandedPlace == .face(.music) && dropPayload == nil
    }

    /// What the title and the outputs header keep clear on their right for
    /// the corner waveform; nothing where the ribbon stands in for it.
    private var waveformInset: CGFloat { hasRibbon ? 0 : 36 }

    @ViewBuilder
    private var content: some View {
        if let dropPayload {
            DropFaceView(viewModel: viewModel, island: island, payload: dropPayload)
                .transition(.opacity)
        } else {
            // A container of its own, so the drop face coming and going
            // fades the place as one rather than running the tile moves
            // inside it, which belong to Home and its faces alone.
            ZStack { place }
                .transition(.opacity)
        }
    }

    @ViewBuilder
    private var place: some View {
        switch viewModel.expandedPlace {
        case .home:
            HomeGridView(viewModel: viewModel, palette: palette)
                .transition(reduceMotion ? .opacity : .homeGridAway)
        case .face(let tab):
            FaceCarousel(pager: island.pager, face: tab, height: neighborHeight) { face in
                self.face(face)
            }
            .transition(faceTransition(tab))
        }
    }

    /// The content area `tab` has when it's the face on screen, for the
    /// pager to lay it out at while it's the neighbour coming in.
    private func neighborHeight(_ tab: IsleTab) -> CGFloat {
        let band = island.metrics?.notchSize.height ?? NotchMetrics.fallbackNotchSize.height
        let room = NotchMetrics.contentRoom(bandHeight: band)
        return NotchMetrics.contentAreaHeight(
            contentHeight: viewModel.faceContentHeight(of: tab, room: room), bandHeight: band)
    }

    /// How a face comes in from Home and goes back: out of its tile and into
    /// it again. A face with no tile (the only face, so no grid) and Reduce
    /// Motion just cross-fade.
    private func faceTransition(_ tab: IsleTab) -> AnyTransition {
        let tabs = viewModel.availableTabs
        guard !reduceMotion, tabs.count > 1, let index = tabs.firstIndex(of: tab) else { return .opacity }
        let band = island.metrics?.notchSize.height ?? NotchMetrics.fallbackNotchSize.height
        return .faceFromTile(HomeTileSlot(
            index: index,
            count: tabs.count,
            height: NotchMetrics.standardContentHeight(bandHeight: band)
        ))
    }

    @ViewBuilder
    private func face(_ tab: IsleTab) -> some View {
        switch tab {
        case .music:
            musicBody
        case .claude:
            ClaudeExpandedView(viewModel: viewModel, island: island, palette: palette)
        case .pomodoro:
            PomodoroExpandedView(viewModel: viewModel, palette: palette)
        case .agenda:
            AgendaExpandedView(viewModel: viewModel, agenda: viewModel.agendaModel, palette: palette)
        case .shelf:
            ShelfExpandedView(viewModel: viewModel, shelf: viewModel.shelf)
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
                        .padding(.trailing, waveformInset)
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
                        // The output switcher, in the slack left of the
                        // centred keys and flush with the title's leading
                        // edge. An overlay so the keys stay centred, and
                        // outside `controls` so a player that can't take
                        // commands doesn't grey out the Mac's own output.
                        .overlay(alignment: .leading) {
                            OutputButton(devices: viewModel.outputDevices) {
                                withAnimation(.easeInOut(duration: 0.2)) { showsOutputs = true }
                            }
                        }
                    Spacer(minLength: 0)
                } else {
                    idlePlaceholder
                }
            }
            // While the output list is up the column keeps its layout and
            // just steps aside, so closing the list puts everything back
            // exactly where it was.
            .opacity(showingOutputs ? 0 : 1)
            .allowsHitTesting(!showingOutputs)
            // Fixed width rather than filling: a filling column would stretch
            // to the right edge and the "pair" could never be centred. 340 is
            // the width it occupied before, so the playbar length is unchanged.
            .frame(minWidth: 340, maxWidth: 340, maxHeight: .infinity, alignment: .leading)
            // The list takes the column's own box: the album stays, nothing
            // moves, and it never reaches past the panel the pointer is in.
            .overlay {
                if showingOutputs {
                    OutputList(devices: viewModel.outputDevices) {
                        withAnimation(.easeInOut(duration: 0.2)) { showsOutputs = false }
                    }
                    .transition(.opacity)
                }
            }
            // Vertical position of the whole text column (title, artist,
            // playbar, transport). The column is ~107 tall against 114 of
            // usable space, so there is only a few points of slack top and
            // bottom to play with here.
            .offset(y: -1)
        }
        // Centres the album+text pair between the panel edges.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(.white)
        // The outputs' HAL listeners only run while this face is on screen,
        // not behind a collapsed island or another face. Leaving the face
        // closes the list, so coming back finds the player.
        .onAppear { viewModel.outputDevices.attach() }
        .onDisappear {
            viewModel.outputDevices.detach()
            showsOutputs = false
        }
    }

    /// Only with a track: without one the column shows the idle text, and
    /// the switcher that opened the list isn't on screen.
    private var showingOutputs: Bool {
        showsOutputs && media.hasTrack
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
                        .foregroundStyle(.islandSecondary(0.75))
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
                fontSize: IsleType.Size.headline,
                weight: .semibold,
                lineHeight: 17
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
                fontSize: IsleType.Size.meta,
                weight: .medium,
                color: .white.opacity(IsleType.Tone.secondary),
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
                .font(IsleType.title)
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Spacer().frame(height: 2)

            Text("Start something in Spotify or Music")
                .font(IsleType.body)
                .foregroundStyle(.islandSecondary(IsleType.Tone.secondary))
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
                .font(IsleType.micro.monospacedDigit())
                .foregroundStyle(.islandSecondary(IsleType.Tone.meta))
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
        // repeat toggle over the routed player's AppleScript. Repeat is a
        // toggle in both players — off ↔ all — so the key lights for .all and
        // clears for .off; Music's repeat-one (set in Music itself) reads back
        // as the lit repeat-1 glyph and clears to off when pressed. The two
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

// MARK: - Swipe between faces

/// The face on screen, and while a swipe is moving it, the neighbour coming
/// in beside it — both following the fingers by an offset (see `FacePager`).
/// At rest it's the one face, at its home.
///
/// Each face is keyed by which face it is, not by its slot. When a swipe
/// lands, the face that slid in becomes the face and the one it pushed out
/// becomes the neighbour; keyed by slot, both would be torn down and rebuilt
/// at that instant — the marker's loop, the marquee and the output listeners
/// all restarting under a face that never visibly moved. A tile click, which
/// does change the face, still gets its insert and remove, and so the
/// cross-fade.
/// How much of a swipe's travel a face actually moves (see `FaceCarousel`).
private let faceSwipeDrift: CGFloat = 0.1

private struct FaceCarousel<Face: View>: View {
    @ObservedObject var pager: FacePager
    var face: IsleTab
    /// The content area a face has when it's the one on screen. The face on
    /// screen has the panel's; the neighbour coming in is laid out at its
    /// own, top-pinned, so it's drawn where it will land — not centred in a
    /// box of the current face's height (a 104pt face beside the 144pt
    /// agenda sat 20pt low, and jumped up the frame the swipe landed).
    var height: (IsleTab) -> CGFloat
    @ViewBuilder var content: (IsleTab) -> Face

    private struct Slot: Identifiable {
        var tab: IsleTab
        var x: CGFloat
        var id: IsleTab { tab }
    }

    private var slots: [Slot] {
        // A pager left on another face (an interrupt took the panel
        // mid-swipe) doesn't move this one.
        guard pager.current == face else { return [Slot(tab: face, x: 0)] }
        var slots = [Slot(tab: face, x: pager.offset)]
        if let neighbor = pager.neighbor, neighbor.tab != face {
            slots.append(Slot(tab: neighbor.tab, x: pager.offset + CGFloat(neighbor.side) * pager.page))
        }
        return slots
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                ForEach(slots) { slot in
                    let progress = min(1, abs(slot.x) / pager.page)
                    content(slot.tab)
                        .frame(width: proxy.size.width,
                               height: slot.tab == face ? proxy.size.height : height(slot.tab))
                        .frame(height: proxy.size.height, alignment: .top)
                        // A short drift and a cross-fade, not a full page of
                        // travel: a face sliding the panel's width would run
                        // its raised artwork under the camera housing and its
                        // text under the waveform. Drifting a tenth of the
                        // distance keeps everything clear of both while the
                        // fingers still visibly carry it.
                        .offset(x: slot.x * faceSwipeDrift)
                        // Sequential, not overlapping: the leaving face is
                        // gone by half-way and the arriving one builds from
                        // there, so the two never show through each other.
                        .opacity(max(0, 1 - 2 * progress))
                        .transition(.opacity)
                }
            }
        }
        // Closing the panel ends any swipe with it. A gesture's end phase
        // can't arrive for a panel that isn't there, and the next open
        // mustn't find a face parked half-way.
        .onDisappear { pager.reset() }
    }
}

// MARK: - Output switcher

/// The system output, as a glyph at the head of the transport row. Quiet —
/// the grey of an unlit toggle and a size under the shuffle key — because
/// it's read far more often than it's pressed. Observes the device list
/// alone, so an output coming or going redraws this and nothing else.
///
/// Absent until the HAL has answered, so a closed list never shows a guess.
private struct OutputButton: View {
    @ObservedObject var devices: OutputDevices
    var open: () -> Void

    var body: some View {
        ZStack {
            if !devices.devices.isEmpty {
                Button(action: open) {
                    // The default can be a device the list leaves out (a
                    // driver that says it can't be default, but is); then the
                    // plain speaker stands in rather than a guessed kind.
                    Image(systemName: devices.current?.symbolName ?? "speaker.wave.2")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.islandSecondary(0.5))
                        // Leading-aligned so the glyph lines up with the
                        // title and the elapsed time above it.
                        .frame(width: 22, height: 22, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(devices.current.map { "Output: \($0.name)" } ?? "Output")
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: devices.current?.symbolName)
    }
}

/// Every output a user could pick, in the text column's place. The current
/// one is lit and ticked; tapping another asks for it and closes the list.
/// The tick moves when the HAL reports the new default, not on the tap — a
/// switch that doesn't take leaves the tick on the device still playing.
///
/// The current output's volume sits at the foot of the list, under the rows
/// and ending on the ticks' edge, clear of the camera housing above.
private struct OutputList: View {
    @ObservedObject var devices: OutputDevices
    var close: () -> Void

    /// As on the Music face under it: no corner waveform to keep clear of
    /// where Prism's ribbon stands in for it.
    @Environment(\.islandHasRibbon) private var hasRibbon
    private var waveformInset: CGFloat { hasRibbon ? 0 : 36 }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 0) {
                Button(action: close) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 9, weight: .semibold))
                        Text("Output")
                            .font(IsleType.metaStrong)
                    }
                    .foregroundStyle(.islandSecondary(0.55))
                    .frame(height: 16)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)
            }

            // Three rows fit above the volume; more scroll rather than
            // growing the panel.
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(devices.devices) { device in
                        row(device)
                    }
                }
            }
            .scrollIndicators(.never)

            // At the foot, not on the header line: the header sits just under
            // the housing band, and a slider there runs beneath the camera
            // cutout, where the hardware hides it.
            OutputVolumeSlider(volume: devices.volume)
        }
        // The header runs under the camera cutout: down far enough that its
        // chevron and caps clear the hardware edge, level with the Claude
        // face's eyebrow. The column box rides 5pt up with the album it's
        // centred against, so this is measured, not the band's 2. The gaps
        // above give the three rows back the room.
        .padding(.top, 5)
        // Clear of the waveform pinned at the panel's top-right, the same
        // inset the title keeps.
        .padding(.trailing, waveformInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(.white)
        // The volume listens to the HAL only while the list is up.
        .onAppear { devices.volume.attach() }
        .onDisappear { devices.volume.detach() }
    }

    private func row(_ device: OutputDevice) -> some View {
        let isCurrent = device.id == devices.currentID
        return Button {
            devices.select(device)
            close()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: device.symbolName)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 18, alignment: .leading)
                Text(device.name)
                    .font(isCurrent ? IsleType.label : IsleType.body)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                if isCurrent {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                }
            }
            .foregroundStyle(isCurrent ? .white : .white.opacity(0.7))
            .frame(height: 21)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
    }
}

/// The current output's volume: a mute key and a track, styled after the
/// playbar's — a 6pt capsule, white fill on a faint track, grabbed anywhere
/// across its height. A drag sets the level as it goes, as the system's own
/// sliders do (the playbar seeks only on release, but a seek is costly to
/// the player and a volume change isn't); `OutputVolume` spaces the writes.
/// Like the playbar it's a plain drag gesture, so the non-activating panel
/// never has to take focus for it.
///
/// Drawn only when the device has a volume Isle can read. One it can read
/// but not set is shown greyed and inert; one it can't read leaves the space
/// empty, at the same size, so nothing in the list moves.
private struct OutputVolumeSlider: View {
    @ObservedObject var volume: OutputVolume

    var body: some View {
        ZStack {
            if let state = volume.state {
                HStack(spacing: 6) {
                    muteKey(state)
                    track(state)
                }
                .transition(.opacity)
            }
        }
        // The list's width, ending on the ticks' edge like the rows.
        .frame(maxWidth: .infinity, minHeight: 16, maxHeight: 16)
        .animation(.easeInOut(duration: 0.15), value: volume.state == nil)
    }

    @ViewBuilder
    private func muteKey(_ state: OutputVolume.State) -> some View {
        let glyph = Image(systemName: symbol(state))
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.islandSecondary(0.55))
            // Leading-aligned in a fixed slot: the wave glyphs differ in
            // width, and the track mustn't shift as the level crosses them.
            .frame(width: 18, height: 16, alignment: .leading)
            .contentShape(Rectangle())
        if state.canMute {
            Button(action: volume.toggleMute) { glyph }
                .buttonStyle(.plain)
                .accessibilityLabel(state.isMuted == true ? "Unmute" : "Mute")
        } else {
            glyph
        }
    }

    private func track(_ state: OutputVolume.State) -> some View {
        let muted = state.isMuted == true
        return GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.22))
                // Muted, the level stays where it is — that's what unmuting
                // returns to — but dims, as the device is silent.
                Capsule()
                    .fill(.white.opacity(muted ? 0.35 : 1))
                    .frame(width: max(0, proxy.size.width * CGFloat(state.level)))
            }
            .frame(height: 6)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard proxy.size.width > 0 else { return }
                        volume.setLevel(Float(value.location.x / proxy.size.width))
                    }
            )
        }
        .opacity(state.canSetLevel ? 1 : 0.4)
        .allowsHitTesting(state.canSetLevel)
        .accessibilityElement()
        .accessibilityLabel("Output volume")
        .accessibilityValue("\(Int((state.level * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: volume.setLevel(state.level + 1.0 / 16.0)
            case .decrement: volume.setLevel(state.level - 1.0 / 16.0)
            @unknown default: break
            }
        }
    }

    private func symbol(_ state: OutputVolume.State) -> String {
        if state.isMuted == true { return "speaker.slash.fill" }
        switch state.level {
        case ..<0.001: return "speaker.fill"
        case ..<0.34: return "speaker.wave.1.fill"
        case ..<0.67: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }
}


/// Fades a fixed element out while faces cross under it during a swipe, and
/// back in as they land. Observes the pager alone, so a gesture redraws the
/// element and nothing around it.
private struct SwipeFade: ViewModifier {
    @ObservedObject var pager: FacePager

    func body(content: Content) -> some View {
        let progress = pager.current == nil ? 0 : min(1, abs(pager.offset) / pager.page)
        content.opacity(1 - min(1, progress * 3))
    }
}
