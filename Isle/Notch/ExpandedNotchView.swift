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
    var island: IslandPresentation
    var palette: ArtworkPalette

    private var media: MediaPlaybackModel { viewModel.media }

    /// The output list is showing in place of the text column. Per island
    /// rather than on the view model: it's this panel's state, and it goes
    /// when the panel collapses (this view is torn down) or the face changes
    /// (see `musicBody`'s `onDisappear`).
    @State private var showsOutputs = false

    var body: some View {
        // The way home lives in NotchRootView, in the housing band to the
        // right of the physical cutout — see the crumb in NotchRootView.notch.
        content
            // A clean cross-dissolve: nothing moves, the old place just fades
            // out as the new one fades in, in place — Home to a face, a face
            // to Home, and the interrupt-driven switch to Claude, which
            // doesn't go through a tile. A swipe lands without it: its faces
            // are already where they belong (see `FacePager.settle`).
            .animation(.easeInOut(duration: 0.28), value: viewModel.expandedPlace)
            // The waveform is pinned to ONE fixed spot in the panel and drawn
            // outside the face switch, so it holds the exact same real position
            // on every face instead of re-aligning to each face's text — it
            // stays put through a swipe, too. Not on Home, where it would sit
            // on a tile and the Music tile already says what's playing. Gated
            // on a live track; non-interactive so it never swallows a seek or
            // dismiss tap.
            .overlay(alignment: .topTrailing) {
                if media.hasTrack, viewModel.showsWaveform, viewModel.expandedPlace != .home {
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
        switch viewModel.expandedPlace {
        case .home:
            HomeGridView(viewModel: viewModel, palette: palette)
                .transition(.opacity)
        case .face(let tab):
            FaceCarousel(pager: island.pager, face: tab) { face in
                self.face(face)
            }
            .transition(.opacity)
        }
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
            AgendaExpandedView(viewModel: viewModel, palette: palette)
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
private struct FaceCarousel<Face: View>: View {
    @ObservedObject var pager: FacePager
    var face: IsleTab
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
                    content(slot.tab)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .offset(x: slot.x)
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
                        .foregroundStyle(.white.opacity(0.5))
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
/// The current output's volume shares the header line, across from the back
/// control and ending on the ticks' edge, so the rows keep all the height
/// they had.
private struct OutputList: View {
    @ObservedObject var devices: OutputDevices
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 0) {
                Button(action: close) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 9, weight: .semibold))
                        Text("Output")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(height: 16)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer(minLength: 20)

                OutputVolumeSlider(volume: devices.volume)
            }

            // Four rows fit; a fifth scrolls rather than growing the panel.
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(devices.devices) { device in
                        row(device)
                    }
                }
            }
            .scrollIndicators(.never)
        }
        // Clear of the waveform pinned at the panel's top-right, the same
        // inset the title keeps.
        .padding(.trailing, 36)
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
                    .font(.system(size: 12, weight: isCurrent ? .semibold : .regular))
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
/// empty, at the same size, so nothing in the header moves.
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
        .frame(width: 150, height: 16)
        .animation(.easeInOut(duration: 0.15), value: volume.state == nil)
    }

    @ViewBuilder
    private func muteKey(_ state: OutputVolume.State) -> some View {
        let glyph = Image(systemName: symbol(state))
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(0.55))
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

