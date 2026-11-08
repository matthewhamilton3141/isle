//
//  HomeGridView.swift
//
//  Home: one tile per face, in grid order, each with a glance of its own —
//  the track, what Claude is doing, the next thing on today, the timer. A
//  click goes into the face. Inside a face, the housing band carries the way
//  back (`NotchCrumb`), and a two-finger swipe moves along to the neighbours
//  (see `FacePager`).
//
//  Every glance is built from state Isle already holds and would show on the
//  face itself. A face with nothing to say — no track, no session, nothing
//  left today, a timer nobody started — gets its name and nothing else,
//  rather than a placeholder that reads like news.
//
//  The shelf's tile is there only while the shelf holds something, like
//  the face itself.
//
//  The tiles fill the content area under the housing band edge to edge, so
//  the grid holds its shape whether there are two faces or five. Five is the
//  most Isle offers, and five fit; if that ever stops being true, this row is
//  where a horizontal scroll goes.
//

import SwiftUI

struct HomeGridView: View {
    @ObservedObject var viewModel: NotchViewModel
    var palette: ArtworkPalette

    static let tileGap: CGFloat = 8

    var body: some View {
        HStack(spacing: Self.tileGap) {
            ForEach(viewModel.availableTabs) { tab in
                Button {
                    // No withAnimation: ExpandedNotchView cross-fades on
                    // `expandedPlace` itself.
                    viewModel.selectTab(tab)
                } label: {
                    tile(for: tab)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
            }
        }
        // The middle tiles run under the camera cutout, whose hardware edge
        // sits a point below the band the safe area reports, so their hard
        // top edges keep 4pt clear of the band — the same room the shelf's
        // top row keeps. The album can sit up in the band; it has no
        // hardware above it.
        .padding(.top, 2)
        .padding(.bottom, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(.white)
    }

    @ViewBuilder
    private func tile(for tab: IsleTab) -> some View {
        switch tab {
        case .music:
            HomeTile(title: tab.title, glance: musicGlance) { musicLead }
        case .claude:
            HomeTile(title: tab.title, glance: claudeGlance, attention: viewModel.claudeNeedsYou) { claudeLead }
        case .pomodoro:
            // Ticks once a second while the clock runs and not at all while
            // it's paused, the same clock the face and the island read.
            TimelineView(.animation(minimumInterval: 1, paused: !viewModel.pomodoro.isRunning)) { context in
                HomeTile(title: tab.title, glance: pomodoroGlance(at: context.date)) {
                    FaceIcon(tab: tab, size: 18)
                }
            }
        case .agenda:
            // On the minute, like the face: enough for "in 12 min" to count
            // down, "Now" to arrive as a meeting starts, and a call's Join to
            // come forward when it should.
            TimelineView(.everyMinute) { context in
                let call = AgendaLayout.joinable(viewModel.agendaItems, at: context.date, lead: viewModel.agendaJoinLead)
                HomeTile(title: tab.title, glance: agendaGlance(at: context.date, call: call?.0)) {
                    FaceIcon(tab: tab, size: 18)
                }
                // A call starting soon or under way: Join from Home, without
                // going into the face. Its own button, inside the tile's.
                .overlay(alignment: .topTrailing) {
                    if let (event, url) = call {
                        JoinPill(tint: event.color, url: url, compact: true)
                            .padding(.top, 7)
                            .padding(.trailing, 7)
                    }
                }
            }
        case .shelf:
            HomeTile(title: tab.title, glance: shelfGlance) { shelfLead }
        }
    }

    // MARK: - Music

    private var musicLead: some View {
        Group {
            if viewModel.media.hasTrack, let image = viewModel.media.artwork {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: homeTileLead, height: homeTileLead)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            } else {
                FaceIcon(tab: .music, size: 18)
            }
        }
    }

    /// The track and who it's by, while there is one.
    private var musicGlance: TileGlance? {
        let media = viewModel.media
        guard media.hasTrack, !media.title.isEmpty else { return nil }
        return .init(media.title, media.artist.isEmpty ? nil : media.artist)
    }

    // MARK: - Claude

    /// The user's marker for the current state, as on the face and the
    /// island. Disconnected has no marker to show, so it's the face's icon.
    @ViewBuilder
    private var claudeLead: some View {
        if viewModel.claudeState == .disconnected {
            FaceIcon(tab: .claude, size: 18)
        } else {
            ClaudeStatusGlyphView(state: viewModel.claudeState, kind: viewModel.claudeMarkerKind, palette: palette)
                .frame(width: homeTileLead, height: homeTileLead)
        }
    }

    /// The state in a word or two, and the one detail that says most about
    /// it: the command waiting on an approval, the tool running, the project.
    private var claudeGlance: TileGlance? {
        let vm = viewModel
        let project = vm.claudeProject.flatMap { $0.isEmpty ? nil : $0 }
        // Another session waiting is worth more than this one's project.
        let others = vm.otherSessions.needYou
        // With more than one live session, how many there are and how many
        // of them need you says more than any one session's detail
        // (Milestone 16) — the face has the list.
        let sessions = vm.sessionList
        let needYou = sessions.filter { $0.state.isAttention }.count
        let othersLine = sessions.count > 1
            ? "\(sessions.count) sessions" + (needYou == 0 ? "" : " · \(needYou) \(needYou == 1 ? "needs" : "need") you")
            : others == 0 ? nil
            : others == 1 ? "Another needs you" : "\(others) others need you"

        switch vm.claudeState {
        case .disconnected:
            // Nothing live on the island, but agent view has background
            // sessions (Milestone 21): what they are, counted the same way.
            if !sessions.isEmpty {
                let working = sessions.filter { $0.state == .working || $0.state == .compacting }.count
                let line = "\(sessions.count) \(sessions.count == 1 ? "session" : "sessions")"
                    + (needYou == 0 ? "" : " · \(needYou) \(needYou == 1 ? "needs" : "need") you")
                if needYou > 0 { return .init("Needs you", line) }
                if working > 0 { return .init("Working", line) }
                return nil
            }
            return others > 0 ? .init("Needs you", othersLine) : nil
        case .needsApproval:
            if let request = vm.pendingRequest, request.kind == .approval {
                return .init("Needs approval", Self.approvalLine(request))
            }
            return .init("Needs approval", vm.claudeActivity?.phrase ?? project)
        case .needsQuestion:
            return .init("Has a question", vm.currentQuestion?.question ?? project)
        case .working:
            let resumed = vm.claudeLimitNext == .resumed ? ClaudeLimit.resumedLine(kind: vm.claudeLimitKind) : nil
            return .init("Working", othersLine ?? vm.claudeActivity?.phrase ?? resumed ?? "Thinking")
        case .compacting:
            return .init("Compacting", othersLine ?? project)
        // After a turn, what Claude said last (Milestone 15) says more than
        // the project's name; another session waiting says more still.
        case .waitingInput:
            return .init("Waiting for you", othersLine ?? vm.claudeFinalLine ?? project)
        case .done:
            return .init("Done", othersLine ?? vm.claudeFinalLine ?? project)
        case .idle:
            return .init("Ready", othersLine ?? vm.claudeFinalLine ?? project)
        case .failed:
            if vm.isUsageLimit {
                let says = ClaudeLimit.shortDetail(resetAt: vm.claudeResetAt, next: vm.claudeLimitNext)
                return .init(ClaudeLimit.headline(kind: vm.claudeLimitKind, next: vm.claudeLimitNext),
                             othersLine ?? says ?? project)
            }
            return .init("Error", othersLine ?? project)
        }
    }

    /// "Bash · npm test": the tool and what it wants, as the face shows it
    /// but on one line. A path is cut to its file name; the face below has
    /// the whole of it.
    private static func approvalLine(_ request: ClaudeRequest) -> String {
        var subject = (request.subject ?? "").replacingOccurrences(of: "\n", with: " ")
        if subject.hasPrefix("/") || subject.hasPrefix("~"), !subject.contains(" ") {
            subject = (subject as NSString).lastPathComponent
        }
        return subject.isEmpty ? request.toolName : "\(request.toolName) · \(subject)"
    }

    // MARK: - Pomodoro

    /// The clock and the interval, once the timer has been started. A fresh
    /// one says nothing, as it does on the island.
    private func pomodoroGlance(at date: Date) -> TileGlance? {
        let timer = viewModel.pomodoro
        guard timer.isActive else { return nil }
        let clock = PomodoroTimer.clock(timer.remaining(at: date))
        // "Focus · 2 of 4" running; paused, "Paused" takes the phase's place,
        // so the line still fits a tile.
        let label = timer.isRunning ? timer.phase.title : "Paused"
        guard timer.phase == .focus else {
            return .init(clock, timer.isRunning ? label : "\(label) · \(timer.phase.title)", monospaced: true)
        }
        let total = max(1, viewModel.pomodoroSessionsPerCycle)
        return .init(clock, "\(label) · \(min(timer.completedInCycle + 1, total)) of \(total)", monospaced: true)
    }

    // MARK: - Shelf

    /// The latest thing kept: its thumbnail, filling the lead as the album
    /// does on Music's tile, or its icon while it has none. The tile is only
    /// on the grid while the shelf holds something, so there's always one.
    @ViewBuilder
    private var shelfLead: some View {
        if let item = viewModel.shelf.items.last {
            ShelfPreviewImage(icon: viewModel.shelf.icon(for: item),
                              thumbnail: viewModel.shelf.thumbnail(for: item),
                              side: homeTileLead, corner: 5, fills: true)
        } else {
            FaceIcon(tab: .shelf, size: 18)
        }
    }

    /// "4 items", and what they are: "1 folder, 3 files".
    private var shelfGlance: TileGlance? {
        let tally = viewModel.shelf.tally
        guard tally.total > 0 else { return nil }
        // Shrinks rather than cut: with five tiles, "1 folder, 3 files" is
        // a few points wider than a tile, and "3 fil…" says less than it.
        return .init(tally.itemsLine, tally.kindsLine, shrinksToFit: true)
    }

    // MARK: - Agenda

    /// The next thing left today and when it is — or the call whose Join the
    /// tile is offering, so the button and the words are about one thing.
    private func agendaGlance(at now: Date, call: AgendaItem?) -> TileGlance? {
        guard let item = call ?? viewModel.agendaItems.first else { return nil }
        return .init(item.title, Self.when(item, at: now))
    }

    static func when(_ item: AgendaItem, at now: Date) -> String {
        let time = item.date.formatted(date: .omitted, time: .shortened)
        switch item.kind {
        case .event:
            if item.isAllDay { return "All day" }
            if item.date <= now { return "Now" }
            let minutes = Int((item.date.timeIntervalSince(now) / 60).rounded(.up))
            return minutes < 60 ? "in \(minutes) min" : "at \(time)"
        case .reminder:
            if item.isAllDay { return "Today" }
            return item.date < now ? "Overdue · \(time)" : "Due \(time)"
        }
    }
}

// MARK: - Tile

/// What a tile says under its face's name: a line, and a quieter one under it.
struct TileGlance {
    var line1: String
    var line2: String?
    /// Digits that change in place (a clock), so they don't jitter.
    var monospaced = false
    /// The second line may shrink a little to fit rather than lose its end
    /// — for a line whose last word is the point ("3 files").
    var shrinksToFit = false

    init(_ line1: String, _ line2: String?, monospaced: Bool = false, shrinksToFit: Bool = false) {
        self.line1 = line1
        self.line2 = line2
        self.monospaced = monospaced
        self.shrinksToFit = shrinksToFit
    }
}

/// The side of a tile's mark: the album thumbnail, the marker, an icon.
private let homeTileLead: CGFloat = 22

/// One face on the home grid: its mark at the top, its name and glance at the
/// bottom, an amber dot when it needs you.
struct HomeTile<Lead: View>: View {
    var title: String
    var glance: TileGlance?
    var attention = false
    @ViewBuilder var lead: () -> Lead

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                lead()
                    .frame(width: homeTileLead, height: homeTileLead)
                Spacer(minLength: 0)
                if attention {
                    AttentionDot(size: 7)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.islandSecondary(0.5))
                .lineLimit(1)
            if let glance {
                Text(glance.line1)
                    .font(glance.monospaced
                          ? .system(size: 12, weight: .semibold).monospacedDigit()
                          : .system(size: 12, weight: .semibold))
                    .lineLimit(1)
                if let line2 = glance.line2 {
                    Text(line2)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.islandSecondary(0.65))
                        .lineLimit(1)
                        .minimumScaleFactor(glance.shrinksToFit ? 0.8 : 1)
                        .truncationMode(.tail)
                }
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.white.opacity(attention ? 0.12 : 0.07))
        )
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .animation(.easeInOut(duration: 0.2), value: attention)
    }
}

/// The mark for "this needs you": the warm amber Isle uses for an interrupt
/// you haven't looked at.
struct AttentionDot: View {
    var size: CGFloat = 6

    static let color = Color(hex: "#FF9F0A")

    var body: some View {
        Circle()
            .fill(Self.color)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

// MARK: - Crumb

/// The housing band's chrome inside a face: the way home, and where you are.
/// `⊞ › Music`. The home mark is the button; it carries the amber dot when
/// another face needs you, which is the only place that shows while you're
/// in a different face.
struct NotchCrumb: View {
    var face: IsleTab
    var attention: Bool
    var goHome: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: goHome) {
                HStack(spacing: 6) {
                    Image(systemName: "square.grid.2x2.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .opacity(0.55)
                        .overlay(alignment: .topTrailing) {
                            if attention {
                                AttentionDot(size: 6)
                                    .offset(x: 3, y: -2)
                                    .transition(.opacity)
                            }
                        }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .opacity(0.35)
                }
                // A target bigger than the glyphs, so the way home isn't a
                // precision click.
                .frame(height: 22)
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(attention ? "Home, something needs you" : "Home")
            .padding(.trailing, -6)

            Text(face.title)
                .font(.system(size: 11, weight: .semibold))
                .opacity(0.85)
                .lineLimit(1)
                .contentTransition(.opacity)
        }
        .foregroundStyle(.white)
        .animation(.easeInOut(duration: 0.15), value: attention)
        .animation(.easeInOut(duration: 0.15), value: face)
    }
}

// MARK: - Face icon

/// One face's mark, as the old switcher drew it: Music the four-bar
/// waveform, Claude the 3x3 dot grid, Pomodoro and Agenda their SF Symbols,
/// all drawn into the same square so none outweighs the others.
struct FaceIcon: View {
    var tab: IsleTab
    var size: CGFloat
    var color: Color = .white

    var body: some View {
        switch tab {
        case .music:
            WaveformIcon(color: color)
                .frame(width: size, height: size)
        case .claude:
            // A simpler 3x3 grid reads better than 5x5 at icon size.
            DotGridIcon(color: color, dimension: 3)
                .frame(width: size, height: size)
        case .pomodoro, .agenda, .shelf:
            Image(systemName: tab.symbolName)
                .font(.system(size: size * 0.85, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: size, height: size)
        }
    }
}
