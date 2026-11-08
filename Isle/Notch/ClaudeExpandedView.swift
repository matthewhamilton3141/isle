//
//  ClaudeExpandedView.swift
//
//  The Claude face of the expanded panel. Mirrors the music tab's weight — a
//  large marker on the left where the album art sits, and a text column
//  beside it — so the tab fills the panel instead of floating a small glyph
//  in dead space. Shown as the whole panel in `.claude` mode, or under the
//  Claude tab in `.both`.
//
//  Every face is one layout (see `ClaudePanelLayout`): an eyebrow naming the
//  session and what else is going on, a title, a body, and an action row
//  one gap below the body. A status fills it with the state, what Claude is
//  doing, and an empty action row; an approval (Milestone 7) puts the exact
//  command in the body and Approve / Deny / Terminal in the row; a question
//  puts the question in the title and its options in the body, in a panel
//  grown to seat them — the one face without the glyph, so the question and
//  its options have the full width. Every control here is a real `Button`,
//  so its tap is consumed and never falls through to the card's dismiss
//  gesture.
//
//  With more than one live session, the face also flips to a list of them
//  all (Milestone 16): the other-sessions marks are the way in, a row's
//  click puts that session on the face, and the eyebrow's chevron is the way
//  back up.
//

import SwiftUI

private typealias L = ClaudePanelLayout

struct ClaudeExpandedView: View {
    @ObservedObject var viewModel: NotchViewModel
    var island: IslandPresentation
    var palette: ArtworkPalette

    /// The height the session list's rows have, as last laid out — so the
    /// eyebrow can say when they scroll.
    @State private var sessionRowsRoom: CGFloat = 0

    private var state: ClaudeCodeState { viewModel.claudeState }

    /// The approval the notch can decide right now, if any.
    private var approval: ClaudeRequest? {
        guard let request = viewModel.pendingRequest, request.kind == .approval else { return nil }
        return request
    }

    /// The question on screen, if the face is a question's.
    private var asking: (request: ClaudeRequest, question: ClaudeQuestion)? {
        guard let request = viewModel.pendingRequest, request.kind == .question,
              let question = viewModel.currentQuestion else { return nil }
        return (request, question)
    }

    var body: some View {
        let listing = viewModel.sessionListShown
        let isQuestion = asking != nil && !listing
        return ZStack(alignment: .topLeading) {
            // The question face has no glyph: its eyebrow already says it's a
            // question, and the options want the face's whole width. Nor
            // does the list, whose rows each carry their own.
            if !isQuestion, !listing {
                glyph
                    .transition(.opacity.combined(with: .scale(scale: 0.6, anchor: .topLeading)))
            }

            Group {
                if listing {
                    sessionListFace
                        .transition(.opacity)
                } else if let asking {
                    questionFace(asking.request, question: asking.question)
                        .transition(.opacity)
                } else {
                    statusFace
                        .padding(.leading, L.glyphSize + L.glyphGap)
                        .transition(.opacity)
                }
            }
            .frame(width: L.faceWidth, alignment: .topLeading)
            .frame(maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.easeInOut(duration: 0.22), value: listing)
        .foregroundStyle(.white)
        // Click the alert panel to retract it (no-op unless an alert is live and
        // dismissing is enabled). contentShape so taps land on the whole card,
        // not just the glyph and text.
        .contentShape(Rectangle())
        // Not while a field is taking keys: a click meant for the field must
        // never retract the panel it's typing in. Esc is the way out.
        .onTapGesture {
            guard viewModel.composing == nil else { return }
            island.dismissAlert()
        }
    }

    /// Occupies the album cover's exact footprint (size + raise), so the
    /// glyph reads as the same block on both tabs and the dots scale up to
    /// fill it — the frame is the only cap on dot size. Safe to raise into
    /// the housing band: the glyph sits left of the camera cutout, on
    /// ordinary screen, just like the album.
    ///
    /// Absent on the question face: it goes with the same spring the panel
    /// grows on, and comes back when the question leaves.
    private var glyph: some View {
        ClaudeStatusGlyphView(state: state, kind: viewModel.claudeMarkerKind, palette: palette)
            .frame(width: L.glyphSize, height: L.glyphSize)
            .offset(y: -L.glyphRaise)
    }

    // MARK: - Status face

    /// A status, or an approval: the same rows, with the command and the
    /// decision taking the body and the action row.
    private var statusFace: some View {
        VStack(alignment: .leading, spacing: 0) {
            eyebrow(hint: viewModel.composing == .reply ? "esc to cancel" : nil) {
                projectLabel
                if viewModel.composing == .reply {
                    if viewModel.claudeProject?.isEmpty == false { separator }
                    Text("Replying").foregroundStyle(.white.opacity(0.8))
                }
            } extra: {
                if viewModel.claudeUpdatedAt != nil, state != .disconnected, viewModel.composing != .reply {
                    if viewModel.claudeProject?.isEmpty == false { separator }
                    elapsed
                }
            }

            Spacer().frame(height: L.eyebrowGap)

            HStack(spacing: 8) {
                Text(headline)
                    .font(L.headlineFont)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .contentTransition(.opacity)
                    .layoutPriority(1)
                if let pattern = approval?.guardedBy {
                    guardChip(pattern)
                }
            }
            .frame(height: L.headlineLine, alignment: .leading)
            // Level with the waveform pinned at the panel's top-right by
            // ExpandedNotchView; stop short of it.
            .padding(.trailing, L.waveformClearance)

            Spacer().frame(height: L.headlineGap)

            if let approval {
                approvalCommand(approval)
            } else if case .failed(_, let reason) = viewModel.replyDelivery {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .labelStyle(EyebrowLabelStyle())
                    .font(L.detailFont)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .truncationMode(.tail)
                    .frame(height: L.detailLine, alignment: .leading)
            } else if let said = claudeSaid {
                // Claude's own words: up to two lines, cut at the end of a
                // sentence where one falls (see `ClaudeDoneLine`), else at
                // the tail. Never shrunk — it's prose, not a filename.
                Text(said)
                    .font(L.detailFont)
                    .foregroundStyle(.islandSecondary(0.72))
                    .lineLimit(L.saidLines)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, switcherClearance)
                    .contentTransition(.opacity)
            } else {
                Text(detail)
                    .font(L.detailFont)
                    .foregroundStyle(.islandSecondary(0.72))
                    .lineLimit(1)
                    // Shrink a long filename to fit before resorting to an
                    // ellipsis, so "Editing SomeLongComponentName.swift" stays
                    // whole instead of getting clipped mid-name.
                    .minimumScaleFactor(0.7)
                    .truncationMode(.middle)
                    .frame(height: L.detailLine, alignment: .leading)
                    .padding(.trailing, switcherClearance)
            }

            // The row follows what's above it at one gap, whatever its
            // height, and the panel's spare room goes below it. Squeezed
            // toward 2pt, never past, when a taller camera band leaves less.
            Spacer(minLength: 2)
                .frame(maxHeight: L.bodyGap)
                .layoutPriority(1)

            actionRow {
                if approval != nil {
                    approvalActions
                } else {
                    statusActions
                }
            }

            Spacer(minLength: 0)
        }
    }

    // MARK: - Eyebrow

    /// The face's top row: what it's about on the left, and on the right the
    /// marks that hold whatever the face shows — the other live sessions and
    /// the keep-awake hold. Same height and place on every face.
    ///
    /// When it's crowded it gives way in order of what matters least:
    /// `extra` first (the elapsed time), then the keep-awake mark's word,
    /// leaving its cup; the project is cut short only after both.
    private func eyebrow<Leading: View, Extra: View>(
        hint: String? = nil,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder extra: () -> Extra = { EmptyView() }
    ) -> some View {
        let leading = leading()
        let extra = extra()
        return ViewThatFits(in: .horizontal) {
            eyebrowRow(compactMarks: false, hint: hint) { leading; extra }
            eyebrowRow(compactMarks: false, hint: hint) { leading }
            eyebrowRow(compactMarks: true, hint: hint) { leading }
        }
        .font(L.eyebrowFont)
        .labelStyle(EyebrowLabelStyle())
        .foregroundStyle(.islandSecondary(0.5))
        .lineLimit(1)
        .frame(height: L.eyebrowHeight)
        // Level with the waveform at the top-right; clear it.
        .padding(.trailing, L.waveformClearance)
    }

    private func eyebrowRow<Leading: View>(compactMarks: Bool, hint: String? = nil,
                                           @ViewBuilder leading: () -> Leading) -> some View {
        HStack(spacing: 5) {
            leading()
            Spacer(minLength: 6)
            if let hint {
                Text(hint).fixedSize()
            }
            marks(compact: compactMarks)
            // On a status face only: a request's own row has Terminal.
            if jumpIsLone, asking == nil, approval == nil {
                jumpChip
            }
        }
    }

    /// The session's project. On a session picked from the list it's the way
    /// back up — a chevron where the folder was — so the face says it's
    /// holding this session by choice, not by urgency.
    ///
    /// A background session goes by its own name (Milestone 21).
    @ViewBuilder
    private var projectLabel: some View {
        if isPinned {
            Button {
                viewModel.showSessionList()
            } label: {
                Label(sessionLabel ?? "Sessions", systemImage: "chevron.left")
                    .foregroundStyle(.white.opacity(0.8))
                    .truncationMode(.tail)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .layoutPriority(-1)
            .help("Back to every session")
            .accessibilityLabel("Back to every session")
        } else if let name = viewModel.claudeBackground?.name {
            Label(name, systemImage: "rectangle.stack.fill")
                .foregroundStyle(.white.opacity(0.8))
                .truncationMode(.tail)
                .layoutPriority(-1)
                .help("A background session")
        } else if let project = viewModel.claudeProject, !project.isEmpty {
            Label(project, systemImage: "folder.fill")
                .foregroundStyle(.white.opacity(0.8))
                .truncationMode(.tail)
                // The first thing to give way when the marks need the room.
                .layoutPriority(-1)
        }
    }

    /// The session's name in the eyebrow: a background session's own, else
    /// its project.
    private var sessionLabel: String? {
        viewModel.claudeBackground?.name ?? viewModel.claudeProject.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The face is holding a session the user picked from the list.
    private var isPinned: Bool {
        viewModel.pinnedSessionId != nil && viewModel.pinnedSessionId == viewModel.claudeSessionId
    }

    private var separator: some View {
        Text("·").foregroundStyle(.white.opacity(0.3))
    }

    /// Other sessions and the keep-awake hold. Each is shown only while the
    /// thing it names is true — the count from the registry's live sessions,
    /// the cup from the assertion itself (`isKeepingAwake`) — and neither has
    /// an "off" form.
    private func marks(compact: Bool) -> some View {
        HStack(spacing: 8) {
            sessionMarks
            if viewModel.isKeepingAwake {
                Label("Mac awake", systemImage: "cup.and.saucer.fill")
                    .labelStyle(EyebrowLabelStyle(iconOnly: compact))
                    .accessibilityLabel("Keeping the Mac awake while Claude works")
            }
        }
        .fixedSize()
        .animation(.easeInOut(duration: 0.2), value: viewModel.otherSessions)
        .animation(.easeInOut(duration: 0.2), value: viewModel.isKeepingAwake)
    }

    /// The other live sessions, and the way to the list of them all
    /// (Milestone 16). The counts are what they always were — busy or
    /// blocked, from the registry's live sessions — and clicking them flips
    /// the face to the list. With nothing busy elsewhere but another session
    /// alive, a quiet count of the rest stands in, so the list is always
    /// reachable when there's more than one session to list.
    ///
    /// "More than one" counts the rows other than the island's own, so the
    /// list is reachable too when the island has nothing live and the only
    /// sessions are background ones agent view lists (Milestone 21).
    @ViewBuilder
    private var sessionMarks: some View {
        let others = viewModel.otherSessions
        let elsewhere = viewModel.sessionList.filter { $0.id != viewModel.claudeSessionId }.count
        let quiet = elsewhere - others.needYou - others.working
        if elsewhere > 0 {
            Button {
                viewModel.showSessionList()
            } label: {
                HStack(spacing: 8) {
                    othersCounts(others)
                    if others.isEmpty, quiet > 0 {
                        Text("+\(quiet) more")
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .padding(.leading, -4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Every session")
            .accessibilityLabel("Every session, \(viewModel.sessionList.count) live")
        } else {
            othersCounts(others)
        }
    }

    @ViewBuilder
    private func othersCounts(_ others: ClaudeOtherSessions) -> some View {
        if others.needYou > 0 {
            Text("+\(others.needYou) \(others.needYou == 1 ? "needs" : "need") you")
                .foregroundStyle(.white.opacity(0.8))
                .accessibilityLabel("\(others.needYou) other \(others.needYou == 1 ? "session needs" : "sessions need") you")
        }
        if others.working > 0 {
            Text("+\(others.working) working")
                .accessibilityLabel("\(others.working) other \(others.working == 1 ? "session" : "sessions") working")
        }
    }

    /// Live "… ago", ticking once a second — or, on a usage limit with a
    /// reset still to come, the live count to it ("in 2h 14m").
    @ViewBuilder
    private var elapsed: some View {
        if viewModel.isUsageLimit, !viewModel.isLimitWaitingForEnter,
           let reset = viewModel.claudeResetAt, reset > Date() {
            TimelineView(.periodic(from: Date(), by: 1)) { context in
                Text(ClaudeLimit.countdown(to: reset, now: context.date) ?? "now")
                    .monospacedDigit()
            }
            .fixedSize()
        } else if let date = viewModel.claudeUpdatedAt {
            TimelineView(.periodic(from: date, by: 1)) { context in
                Text(Self.relative(from: date, to: context.date))
                    .monospacedDigit()
            }
            .fixedSize()
        }
    }

    // MARK: - Session list (Milestone 16)

    /// Every live session, one line each, most pressing first — selection's
    /// own order. A row's click makes that session the face's; its Jump goes
    /// to the session's terminal. The way back is the eyebrow's chevron.
    ///
    /// No glyph: each row has its own marker, and the rows want the face's
    /// whole width. Four rows fit the standard panel; past that they scroll
    /// (vertically — a sideways swipe is the way between faces), with the
    /// count in the eyebrow and the last row fading at the foot to say so.
    private var sessionListFace: some View {
        let rows = viewModel.sessionList
        let scrolls = sessionRowsRoom > 0 && L.sessionRowsHeight(rows.count) > sessionRowsRoom + 0.5
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                Button {
                    viewModel.closeSessionList()
                } label: {
                    Label("Sessions", systemImage: "chevron.left")
                        .foregroundStyle(.white.opacity(0.8))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .fixedSize()
                .accessibilityLabel("Back")
                separator
                // "live" only while it's true of every row: a background
                // session agent view lists may have no process at all.
                Text(rows.allSatisfy { $0.background?.hasHookRecord ?? true }
                     ? "\(rows.count) live" : "\(rows.count) \(rows.count == 1 ? "session" : "sessions")")
                    .monospacedDigit()
                if scrolls {
                    // More than fit: the rest are a scroll away.
                    Image(systemName: "arrow.up.and.down")
                        .imageScale(.small)
                        .accessibilityLabel("Scrolls")
                }
                Spacer(minLength: 6)
                if viewModel.isKeepingAwake {
                    Label("Mac awake", systemImage: "cup.and.saucer.fill")
                        .accessibilityLabel("Keeping the Mac awake while Claude works")
                }
            }
            .font(L.eyebrowFont)
            .labelStyle(EyebrowLabelStyle())
            .foregroundStyle(.islandSecondary(0.5))
            .lineLimit(1)
            .frame(height: L.eyebrowHeight)

            Spacer().frame(height: L.eyebrowGap)

            GeometryReader { proxy in
                let fits = L.sessionRowsHeight(rows.count) <= proxy.size.height + 0.5
                Group {
                    if fits {
                        sessionRows(rows)
                    } else {
                        ScrollView(.vertical) {
                            sessionRows(rows)
                        }
                        .scrollIndicators(.never)
                        // The foot fades, so a row cut off there reads as
                        // more below rather than as the end.
                        .mask(
                            VStack(spacing: 0) {
                                Color.black
                                LinearGradient(colors: [.black, .black.opacity(0)],
                                               startPoint: .top, endPoint: .bottom)
                                    .frame(height: 12)
                            }
                        )
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                .onAppear { sessionRowsRoom = proxy.size.height }
                .onChange(of: proxy.size.height) { _, height in sessionRowsRoom = height }
            }
            .padding(.bottom, L.sessionListBottomInset)
        }
        // Clear of the waveform pinned at the panel's top-right: the eyebrow
        // and the first row are level with it, and the rows keep one edge.
        .padding(.trailing, L.waveformClearance)
        .animation(.easeInOut(duration: 0.2), value: rows)
    }

    private func sessionRows(_ rows: [ClaudeSessionRow]) -> some View {
        // Ticks twice a minute, for the "2m" at each row's end — nothing
        // finer is shown.
        // A row without a Jump holds its room when any row has one, so the
        // times line up.
        let holdsJump = rows.contains { viewModel.jumpTarget(for: $0.id) != nil }
        return TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: L.sessionRowGap) {
                ForEach(rows) { row in
                    sessionRow(row, now: context.date, holdsJump: holdsJump)
                }
            }
        }
    }

    /// One session: marker, project, state in its marker's colour, what it's
    /// doing or what Claude said, how long since it moved, and its Jump. The
    /// session on the island is lit.
    private func sessionRow(_ row: ClaudeSessionRow, now: Date, holdsJump: Bool) -> some View {
        let onIsland = row.id == viewModel.claudeSessionId
        let jump = viewModel.jumpTarget(for: row.id)
        let attaches = viewModel.jumpAttaches(row.id)
        // A background session Claude Code says is finished (Milestone 21)
        // steps back: its words dimmer, its state in grey.
        let quiet = row.isQuiet
        return HStack(spacing: 4) {
            Button {
                viewModel.pinSession(row.id)
            } label: {
                HStack(spacing: 6) {
                    ClaudeStatusGlyphView(state: row.state, kind: row.markerKind, palette: palette)
                        .frame(width: L.sessionGlyphSize, height: L.sessionGlyphSize)
                        .opacity(quiet ? 0.6 : 1)
                    Text(row.label ?? "Session")
                        .font(L.sessionProjectFont)
                        .foregroundStyle(.white.opacity(quiet ? 0.6 : 0.92))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: row.background?.name != nil ? L.sessionNameMaxWidth : 120,
                               alignment: .leading)
                        .fixedSize(horizontal: true, vertical: false)
                    Text(row.stateTitle)
                        .font(L.sessionStateFont)
                        .foregroundStyle(quiet ? Color.white.opacity(0.45) : stateColor(row.markerKind))
                        .lineLimit(1)
                        .fixedSize()
                    Text(row.detail)
                        .font(L.sessionDetailFont)
                        .foregroundStyle(.islandSecondary(0.55))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    if let updated = row.updatedAt {
                        Text(Self.shortAge(from: updated, to: now))
                            .font(L.sessionDetailFont)
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(0.4))
                            .fixedSize()
                    }
                }
                .padding(.leading, L.sessionRowPadding)
                .padding(.trailing, holdsJump ? 0 : L.sessionRowPadding)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel([row.label, row.stateTitle, row.detail].compactMap { $0 }.joined(separator: ", "))
            .accessibilityAddTraits(onIsland ? [.isSelected] : [])

            if let jump {
                Button {
                    viewModel.jumpToSession(row.id)
                } label: {
                    Image(systemName: attaches ? "terminal" : "arrow.up.forward.app")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: L.sessionJumpWidth, height: 16)
                        .background(Capsule().fill(.white.opacity(0.12)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 2)
                .help(attaches ? "Attach in \(jump)" : "Show this session in \(jump)")
                .accessibilityLabel(attaches ? "Attach to \(row.label ?? "this session") in \(jump)"
                                             : "Show \(row.label ?? "this session") in \(jump)")
            } else if holdsJump {
                Color.clear
                    .frame(width: L.sessionJumpWidth)
                    .padding(.trailing, 2)
            }
        }
        .frame(height: L.sessionRowHeight)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.white.opacity(onIsland ? 0.1 : 0))
        )
    }

    /// A state's word in its marker's colour: the marker's own hue where it
    /// has one, the palette the marker draws from where it doesn't.
    private func stateColor(_ kind: MarkerKind) -> Color {
        let design = MarkerStore.shared.design(for: kind)
        return design.colorMode == .fixed ? Color(hex: design.fixedColorHex) : palette.primary
    }

    /// "now", "4m", "2h": how long since the session's hook last wrote.
    private static func shortAge(from date: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        return "\(hours / 24)d"
    }

    // MARK: - Approval

    /// The tool and the exact thing it will act on — the whole command, not
    /// the island's hygienic "Running npm" — because this is what the click
    /// authorises. Monospaced, two lines, cut from the middle so both the
    /// program and the end of the command survive. One line or two, as the
    /// command needs, and the row follows it (see `commandBoxLines`).
    ///
    /// An edit gives its second line to what it changes (`note`), counted from
    /// the input; a plan is read from the top, so it's cut at the end. While
    /// "Always…" is being reviewed the box holds what would be saved instead.
    private func approvalCommand(_ request: ClaudeRequest) -> some View {
        Group {
            if viewModel.isReviewingRemember, let remember = request.remember {
                rememberReview(remember)
            } else if let note = request.note {
                VStack(alignment: .leading, spacing: 0) {
                    commandText(request)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(note)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            } else {
                commandText(request)
                    .lineLimit(L.commandLines)
                    .truncationMode(request.isPlan ? .tail : .middle)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(L.commandFont)
        .foregroundStyle(.islandSecondary(0.72))
        .frame(minHeight: CGFloat(Self.commandBoxLines(request)) * L.commandLine, alignment: .topLeading)
        .padding(.trailing, switcherClearance)
    }

    /// The fewest lines the command's box keeps: two for a request that can
    /// show two — an edit and its note, or one with "Always…", whose review
    /// takes two — so the buttons don't move under the pointer when it opens
    /// or closes. One otherwise, and the box grows to a second line when the
    /// command needs it.
    private static func commandBoxLines(_ request: ClaudeRequest) -> Int {
        request.note != nil || request.remember != nil ? L.commandLines : 1
    }

    /// The tool, in the brighter weight, and its exact subject. A plan is
    /// just its text: "Plan ready" above has already said what it is.
    private func commandText(_ request: ClaudeRequest) -> Text {
        let subject = (request.subject ?? "")
            // A heredoc or a multi-line script would otherwise spend both lines
            // on its first line break.
            .replacingOccurrences(of: "\n", with: " ↵ ")
        if request.isPlan { return Text(subject) }
        return Text(request.displayTool).fontWeight(.semibold).foregroundStyle(.white.opacity(0.9))
            + Text(subject.isEmpty ? "" : "  " + subject)
    }

    /// Beside the headline when Isle's own guard is why Claude is asking
    /// (Milestone 17), from the guard's record of this very call. The pattern
    /// it matched is the tooltip: beside "Needs your approval" a chip with
    /// the pattern never fit the row's width, and the command is right below.
    /// In a tighter row the word goes, leaving the shield; the headline never
    /// gives way to it.
    private func guardChip(_ pattern: String) -> some View {
        let help = "Guarded in Isle: matches “\(pattern)”, so it asks every time, in any permission mode, and never offers Always…. A speed bump for honest mistakes, not a sandbox."
        func chip(_ showWord: Bool) -> some View {
            HStack(spacing: 4) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 9.5, weight: .semibold))
                if showWord { Text("Guarded") }
            }
            .font(L.eyebrowFont)
            .foregroundStyle(Color(red: 1, green: 0.8, blue: 0.55))
            .padding(.horizontal, 7)
            .frame(height: 17)
            .background(Capsule().fill(Color.orange.opacity(0.2)))
            .overlay(Capsule().inset(by: 0.5).stroke(Color.orange.opacity(0.45), lineWidth: 1))
            .fixedSize()
        }
        return ViewThatFits(in: .horizontal) {
            chip(true)
            chip(false)
        }
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(help)
        .transition(.opacity)
    }

    /// What "Always…" would save, in Claude Code's own terms — the rule as it
    /// lands in the allow list, the mode by its name — and where it's kept.
    /// Two changes (a directory and a mode, say) take a line each, so
    /// neither is cut to fit beside the other; the scope rides on the last.
    private func rememberReview(_ remember: ClaudeRequest.Remember) -> some View {
        let changes = remember.changes
        let first = changes.count > 1 ? changes.dropLast().joined(separator: " · ") : changes.first ?? ""
        let last = changes.count > 1 ? changes.last : nil
        return VStack(alignment: .leading, spacing: 0) {
            Text(first)
                .fontWeight(.semibold)
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
                .truncationMode(.middle)
            Group {
                if let last {
                    Text(last).fontWeight(.semibold).foregroundStyle(.white.opacity(0.9))
                        + Text(" · " + remember.scope)
                } else {
                    Text(remember.scope)
                }
            }
            .lineLimit(1)
            .truncationMode(.middle)
        }
    }

    /// Approve / Deny / Terminal, and "Always…" between Approve and Deny when
    /// Claude Code offered a way to stop asking — Terminal then gives up its
    /// word to its icon, and the three decisions their symbols to their
    /// words, so five pills fit the column. Beside Deny, the terminal's "No,
    /// and tell Claude…" as a symbol, which opens a field in the row. On the
    /// review, just the confirm and the way back.
    @ViewBuilder
    private var approvalActions: some View {
        if viewModel.composing == .denial {
            ComposeField(
                text: $viewModel.denialDraft,
                prompt: approval?.isPlan == true
                    ? "No, and tell Claude what to change…"
                    : "No, and tell Claude what to do instead…",
                sendTitle: "Deny",
                sendFill: .red.opacity(0.85),
                sendForeground: .white,
                onSend: { viewModel.sendCompose() },
                onCancel: { viewModel.endCompose() }
            )
            .disabled(viewModel.isAnsweringRequest)
        } else {
            decisionPills
        }
    }

    private var decisionPills: some View {
        let offersRemember = approval?.remember != nil
        return HStack(spacing: 8) {
            if offersRemember, viewModel.isReviewingRemember {
                pill("Confirm", systemImage: "checkmark", fill: .green.opacity(0.85)) {
                    viewModel.allowRemembering()
                }
                pill("Back", systemImage: "chevron.left", fill: .white.opacity(0.14)) {
                    viewModel.cancelRemember()
                }
            } else {
                pill("Approve", systemImage: "checkmark", fill: .green.opacity(0.85), compact: offersRemember) {
                    viewModel.decide(allow: true)
                }
                if offersRemember {
                    pill("Always…", systemImage: "infinity", fill: .green.opacity(0.3), compact: true) {
                        viewModel.reviewRemember()
                    }
                }
                pill("Deny", systemImage: "xmark", fill: .red.opacity(0.85), compact: offersRemember) {
                    viewModel.decide(allow: false)
                }
                // The terminal's "No, and tell Claude what to do differently":
                // a denial with words. Its symbol only — the row is full —
                // with the words as its tooltip.
                pill("No, and tell Claude…", systemImage: "text.bubble", fill: .red.opacity(0.3), iconOnly: true) {
                    viewModel.beginCompose(.denial)
                }
                pill("Terminal", systemImage: "terminal", fill: .white.opacity(0.14), iconOnly: offersRemember) {
                    answerInTerminal()
                }
            }
            Spacer(minLength: 0)
        }
        .disabled(viewModel.isAnsweringRequest)
        .opacity(viewModel.isAnsweringRequest ? 0.5 : 1)
    }

    // MARK: - Jump and reply

    /// The status face's row (Milestone 11): the session's terminal by name,
    /// and a reply field taking the rest of the row. Each is drawn only when
    /// it can reach the session — Jump when the host app is resolved, Reply
    /// when its terminal can be typed into — and the row is otherwise held
    /// empty at its usual height, so nothing above it moves.
    @ViewBuilder
    private var statusActions: some View {
        if viewModel.composing == .reply {
            ComposeField(
                text: $viewModel.replyDraft,
                prompt: "Reply to Claude…",
                sendTitle: "Send",
                sendFill: .white,
                sendForeground: .black,
                onSend: { viewModel.sendCompose() },
                onCancel: { viewModel.endCompose() }
            )
        } else {
            // Beside the reply field on a terminal Isle can type into; on
            // any other, Jump is the eyebrow's chip and this row stays empty.
            // Attaching to a background session (Milestone 21) is a pill of
            // its own here: its eyebrow has the session's name to hold.
            if viewModel.jumpAttaches {
                pill("Attach in \(ClaudeLauncher.attachApp)", systemImage: "terminal", fill: .white.opacity(0.14)) {
                    viewModel.jumpToSession()
                }
                .help("Open this background session in \(ClaudeLauncher.attachApp) (claude attach)")
            } else if let target = viewModel.jumpTarget, !jumpIsLone {
                pill(target, systemImage: "arrow.up.forward.app", fill: .white.opacity(0.14)) {
                    viewModel.jumpToSession()
                }
                .help(viewModel.jumpAttaches ? "Attach in \(target)" : "Show this session in \(target)")
            }
            switch viewModel.replyDelivery {
            case .sending:
                deliveryNote("Sending…", systemImage: "arrow.up.circle", tint: .white.opacity(0.6))
            case .sent(let text):
                deliveryNote("Sent", detail: text, systemImage: "checkmark.circle.fill", tint: .green)
            default:
                if viewModel.canReply {
                    replyPrompt
                } else {
                    Spacer(minLength: 0)
                }
            }
        }
    }

    /// Jump with no reply beside it, ever: the session's terminal can't be
    /// typed into (Ghostty, VS Code, Cursor, kitty, Warp…) or replying from
    /// the notch is off. Decided by the host, not the state, so on a
    /// terminal that does take replies the pill keeps its place in the row
    /// while the reply field comes and goes beside it.
    private var jumpIsLone: Bool {
        viewModel.jumpTarget != nil && !viewModel.repliesFromNotch && !viewModel.jumpAttaches
    }

    /// The lone Jump, as a quiet chip: the session's app by name, at the
    /// eyebrow's trailing end, on the row that already says where the
    /// session is. Alone in the action row it was a big pill in an empty row,
    /// bottom-left; here it takes no row of its own and leaves the room
    /// below to what Claude said. Right of the camera cutout, and inside the
    /// eyebrow's waveform clearance, so it meets neither.
    @ViewBuilder
    private var jumpChip: some View {
        if let target = viewModel.jumpTarget {
            Button {
                viewModel.jumpToSession()
            } label: {
                Label(target, systemImage: "arrow.up.forward.app")
                    .labelStyle(EyebrowLabelStyle())
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 7)
                    .frame(height: 17)
                    .background(Capsule().fill(.white.opacity(0.12)))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .fixedSize()
            .help(viewModel.jumpAttaches ? "Attach in \(target)" : "Show this session in \(target)")
            .accessibilityLabel(viewModel.jumpAttaches ? "Attach to this session in \(target)" : "Show this session in \(target)")
        }
    }

    /// "Reply to Claude…" at rest: a button shaped like the field it opens
    /// into. A draft kept from before shows in place of the prompt.
    private var replyPrompt: some View {
        let draft = viewModel.replyDraft
        return Button {
            viewModel.beginCompose(.reply)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrowshape.turn.up.left.fill")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.islandSecondary(0.55))
                Text(draft.isEmpty ? "Reply to Claude…" : draft)
                    .foregroundStyle(.white.opacity(draft.isEmpty ? 0.55 : 0.9))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .font(L.pillFont)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Capsule().fill(.white.opacity(0.06)))
            .overlay(Capsule().inset(by: 0.5).stroke(.white.opacity(0.22), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(draft.isEmpty ? "Reply to Claude" : "Reply to Claude: \(draft)")
    }

    /// What became of the reply, in the row it was sent from.
    private func deliveryNote(_ title: String, detail: String? = nil, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
            Text(title)
                .foregroundStyle(.white.opacity(0.85))
                .fixedSize()
            if let detail {
                Text(detail)
                    .foregroundStyle(.islandSecondary(0.5))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .font(L.pillFont)
        .padding(.leading, 4)
    }

    // MARK: - Question

    /// One question of an `AskUserQuestion`: its header and step in the
    /// eyebrow, the question as the title, its options as rows, and the way
    /// out to the terminal. The panel has grown to fit — sized from the same
    /// `ClaudePanelLayout.fit` these rows are drawn from.
    ///
    /// No glyph here: the eyebrow, question and options all run the face's
    /// whole width. Every option is always on screen: where the
    /// capped panel can't hold the descriptions as the setting draws them,
    /// they shorten instead (see `fit`), and the action row below is never
    /// pushed off.
    ///
    /// No free text: answering "Type something" would need a text field, and
    /// a text field needs key focus, which the notch must never take from the
    /// terminal. That stays an "Answer in terminal".
    private func questionFace(_ request: ClaudeRequest, question: ClaudeQuestion) -> some View {
        let index = viewModel.questionIndex
        let isLast = index + 1 >= request.questions.count
        let picks = viewModel.questionPicks.indices.contains(index) ? viewModel.questionPicks[index] : []
        let descriptions = viewModel.optionDescriptions

        return GeometryReader { proxy in
            let fit = L.fit(question, descriptions: descriptions,
                            trailingClearance: switcherClearance, room: proxy.size.height)

            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    eyebrow {
                        projectLabel
                        separator
                        Label(question.header ?? "Question", systemImage: "questionmark.bubble.fill")
                            .foregroundStyle(.white.opacity(0.8))
                            .layoutPriority(-0.5)
                        if request.questions.count > 1 {
                            separator
                            step(index: index, count: request.questions.count)
                        }
                    }

                    Spacer().frame(height: L.eyebrowGap)

                    Text(question.question)
                        .font(L.questionFont)
                        .lineLimit(fit.questionLines)
                        .truncationMode(.tail)
                        .frame(height: CGFloat(fit.questionLines) * L.questionLine, alignment: .topLeading)
                        // Level with the waveform at the top-right; clear it.
                        .padding(.trailing, L.waveformClearance)
                }

                Spacer().frame(height: L.questionGap)

                Group {
                    if fit.scrolls {
                        // Past what AskUserQuestion can send today (see
                        // `OptionsFit.scrolls`): a scroll, said out loud by
                        // the count in the action row.
                        ScrollView(.vertical) {
                            optionRows(question, picks: picks, fit: fit)
                        }
                        .frame(height: max(0, proxy.size.height
                                           - L.questionChromeHeight(questionLines: fit.questionLines)))
                    } else {
                        optionRows(question, picks: picks, fit: fit)
                    }
                }
                .padding(.trailing, switcherClearance)

                Spacer(minLength: L.actionGap)

                actionRow {
                    if viewModel.composing == .answer {
                        ComposeField(
                            text: $viewModel.answerDraft,
                            prompt: "Type your answer…",
                            sendTitle: isLast ? "Send" : "Next",
                            sendFill: .white,
                            sendForeground: .black,
                            onSend: { viewModel.sendCompose() },
                            onCancel: { viewModel.endCompose() }
                        )
                    } else {
                        questionActions(question, isLast: isLast, picks: picks, fit: fit)
                    }
                }
            }
        }
        .disabled(viewModel.isAnsweringRequest)
        .opacity(viewModel.isAnsweringRequest ? 0.5 : 1)
        .animation(.easeInOut(duration: 0.2), value: index)
    }

    /// The question's own row: the way to the terminal, the terminal's "Type
    /// something" as a field here, and Next / Done for a multi-select.
    @ViewBuilder
    private func questionActions(_ question: ClaudeQuestion, isLast: Bool, picks: Set<String>,
                                 fit: L.OptionsFit) -> some View {
                    pill("Answer in terminal", systemImage: "terminal", fill: .white.opacity(0.14)) {
                        answerInTerminal()
                    }
                    pill("Type something", systemImage: "character.cursor.ibeam", fill: .white.opacity(0.14)) {
                        viewModel.beginCompose(.answer)
                    }
                    if fit.scrolls {
                        Label("\(question.options.count) options", systemImage: "arrow.up.and.down")
                            .font(L.eyebrowFont)
                            .labelStyle(EyebrowLabelStyle())
                            .foregroundStyle(.islandSecondary(0.5))
                            .fixedSize()
                    }
                    Spacer(minLength: 0)
                    if question.multiSelect {
                        pill(isLast ? "Done" : "Next",
                             systemImage: isLast ? "checkmark" : "arrow.right",
                             fill: .white.opacity(picks.isEmpty ? 0.14 : 0.3)) {
                            viewModel.advanceQuestion()
                        }
                        .disabled(picks.isEmpty)
                    }
    }

    /// "‹ 2 of 3": where in a multi-part ask this is, and the way back.
    private func step(index: Int, count: Int) -> some View {
        HStack(spacing: 2) {
            if index > 0 {
                Button {
                    viewModel.previousQuestion()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 9.5, weight: .bold))
                        .frame(width: 16, height: L.eyebrowHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.8))
                .accessibilityLabel("Previous question")
            }
            Text("\(index + 1) of \(count)")
                .monospacedDigit()
        }
        .fixedSize()
    }

    private func optionRows(_ question: ClaudeQuestion, picks: Set<String>,
                            fit: L.OptionsFit) -> some View {
        VStack(alignment: .leading, spacing: L.optionGap) {
            ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                optionRow(option, multiSelect: question.multiSelect, picked: picks.contains(option.label),
                          style: fit.style,
                          descriptionLines: fit.style == .full ? fit.descriptionLines[index] : 0)
            }
        }
    }

    /// One option, drawn in the form the fit chose: stacked with
    /// `descriptionLines` of description under `.full`, label and
    /// description on one line under `.oneLine`, the label alone under
    /// `.hidden`.
    private func optionRow(_ option: ClaudeQuestion.Option, multiSelect: Bool, picked: Bool,
                           style: OptionDescriptions, descriptionLines lines: Int) -> some View {
        let height = L.optionRowHeight(style: style, descriptionLines: lines)
        return Button {
            viewModel.pickOption(option.label)
        } label: {
            HStack(alignment: lines > 0 ? .top : .center, spacing: 7) {
                if multiSelect {
                    Image(systemName: picked ? "checkmark.square.fill" : "square")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(picked ? 1 : 0.6))
                        .frame(width: L.checkboxWidth - 7, height: L.optionLabelLine)
                }
                if lines > 0 {
                    // Full: the label, then its description wrapped under it.
                    VStack(alignment: .leading, spacing: L.optionStackedGap) {
                        optionLabel(option)
                            .frame(height: L.optionLabelLine)
                        Text(option.description ?? "")
                            .font(L.optionDescriptionFont)
                            .foregroundStyle(.islandSecondary(0.55))
                            .lineLimit(lines)
                            .truncationMode(.tail)
                            .frame(height: CGFloat(lines) * L.optionDescriptionLine, alignment: .topLeading)
                    }
                } else {
                    optionLabel(option)
                        .layoutPriority(1)
                    if style == .oneLine, let description = option.description {
                        Text(description)
                            .font(L.optionDescriptionFont)
                            .foregroundStyle(.islandSecondary(0.55))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, L.optionHorizontalPadding)
            .padding(.vertical, lines > 0 ? L.optionStackedPadding : 0)
            .frame(height: height)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.white.opacity(picked ? 0.24 : 0.08))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Read out in full whatever the setting hides.
        .accessibilityLabel(option.description.map { "\(option.label), \($0)" } ?? option.label)
        .accessibilityAddTraits(picked ? [.isSelected] : [])
    }

    private func optionLabel(_ option: ClaudeQuestion.Option) -> some View {
        Text(option.label)
            .font(L.optionLabelFont)
            .foregroundStyle(.white)
            .lineLimit(1)
    }

    // MARK: - Controls

    /// The row every face shares: one height. A status or approval face
    /// sets it `bodyGap` below its body; the question face's grows to it.
    private func actionRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            content()
        }
        .frame(height: L.actionHeight)
        .padding(.trailing, switcherClearance)
        .padding(.bottom, L.bottomInset)
    }

    /// A capsule button with an icon, for the decisions. Real `Button`s, so
    /// the tap is consumed and doesn't retract the card.
    private func pill(
        _ title: String,
        systemImage: String,
        fill: Color,
        iconOnly: Bool = false,
        compact: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(PillLabelStyle(iconOnly: iconOnly, titleOnly: compact))
                .font(L.pillFont)
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, compact ? 10 : 12)
                .frame(maxHeight: .infinity)
                .background(Capsule().fill(fill))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(iconOnly ? title : "")
        .accessibilityLabel(title)
    }

    /// Hands the prompt back to the terminal now, and — since that is where
    /// the user has said they'll answer — retracts the panel if they allow it
    /// and, when the session's tab is resolved, takes them to it.
    private func answerInTerminal() {
        viewModel.deferToTerminal()
        viewModel.jumpToSession()
        island.dismissAlert()
    }

    /// How far the lower rows stop short of the column's right edge. Nothing:
    /// the way between faces is the crumb up in the housing band now, and
    /// the panel's bottom-right corner is the face's own.
    private var switcherClearance: CGFloat { 0 }

    // MARK: - Text

    /// Claude Code's own state for the island's session, when that's where
    /// the state came from (Milestone 21).
    private var agentState: ClaudeAgent.State? {
        viewModel.claudeStateFromAgent ? viewModel.claudeBackground?.state : nil
    }

    private var headline: String {
        if let agentState, agentState != .working {
            switch agentState {
            case .blocked:
                return viewModel.claudeBackground?.waitingFor == "permission prompt"
                    ? "Needs your approval" : "Needs you"
            default:
                return ClaudeBackground.title(for: agentState, waitingFor: nil)
            }
        }
        switch state {
        case .disconnected: return "No active session"
        case .idle: return "Ready"
        case .working: return viewModel.workingWord + "…"   // rotating gerund
        case .needsApproval:
            if viewModel.isReviewingRemember, approval?.remember != nil { return "Don't ask again?" }
            // ExitPlanMode's prompt is the plan itself, not a tool call.
            return approval?.isPlan == true ? "Plan ready" : "Needs your approval"
        case .needsQuestion: return "Has a question"
        case .waitingInput: return "Waiting for you"
        case .done: return "Done"
        case .failed:
            return viewModel.isUsageLimit
                ? ClaudeLimit.headline(kind: viewModel.claudeLimitKind, next: viewModel.claudeLimitNext)
                : "Error"
        case .compacting: return "Compacting"
        }
    }

    /// What Claude said last, for the states that follow a finished turn:
    /// Done, the "Ready" it eases back to, and "Waiting for you". In place of
    /// the stock line, and only when there are words to quote.
    ///
    /// Also on a background session Claude Code says is blocked after the
    /// hooks saw its turn end: what Claude said is usually what it's asking.
    private var claudeSaid: String? {
        if agentState != nil { return viewModel.claudeFinalLine }
        switch state {
        case .done, .idle, .waitingInput: return viewModel.claudeFinalLine
        default: return nil
        }
    }

    /// The secondary line under the headline — what's actually happening.
    private var detail: String {
        if let agentState {
            // Only what `claude agents` says: where, and what it's waiting
            // for when it names it.
            let project = viewModel.claudeBackground?.project ?? viewModel.claudeProject
            let waiting = ClaudeBackground.waitingPhrase(viewModel.claudeBackground?.waitingFor)
            switch agentState {
            case .blocked:
                let line = [waiting, project].compactMap { $0 }.joined(separator: " · ")
                return line.isEmpty ? "Waiting on you" : line
            case .working: return ["In the background", project].compactMap { $0 }.joined(separator: " · ")
            case .done: return ["Finished", project].compactMap { $0 }.joined(separator: " · ")
            case .failed: return ["Ended with an error", project].compactMap { $0 }.joined(separator: " · ")
            case .stopped: return ["Stopped", project].compactMap { $0 }.joined(separator: " · ")
            case .other: return project ?? "In the background"
            }
        }
        switch state {
        case .working:
            // No tool running → Claude is reasoning, not acting.
            // A turn Claude Code continued after a usage limit says so until
            // its first tool runs.
            if actionText == nil, viewModel.claudeLimitNext == .resumed {
                return ClaudeLimit.resumedLine(kind: viewModel.claudeLimitKind)
            }
            return actionText ?? "Thinking…"
        case .needsApproval, .needsQuestion:
            // Name the tool + target when known ("Running npm", "Editing
            // App.swift"); fall back to the generic prompt for a plain
            // question. A live request draws its own detail instead.
            return actionText ?? "Answer to keep it moving"
        case .waitingInput:
            return "It's ready for your next prompt"
        case .done:
            return "Finished responding"
        case .idle:
            return "Session ready"
        case .failed:
            if viewModel.isUsageLimit {
                return ClaudeLimit.detail(resetAt: viewModel.claudeResetAt, next: viewModel.claudeLimitNext,
                                          terminal: viewModel.jumpTarget)
            }
            return "The turn stopped on an error — resend to retry."
        case .compacting:
            return "Compacting the conversation to free up context"
        case .disconnected:
            // Nothing live, but agent view has sessions (Milestone 21): the
            // marks above are the way to them.
            let background = viewModel.sessionList.count
            if background > 0 {
                return background == 1 ? "One session in the background" : "\(background) sessions in the background"
            }
            return "Install the Claude Code hook to connect a session"
        }
    }

    /// A friendly phrase for the current tool, e.g. "Editing App.swift" or
    /// "Running npm". Nil when there's no tool info. Shares its phrasing and
    /// target hygiene with the collapsed glyph via `ClaudeActivity`.
    private var actionText: String? {
        viewModel.claudeActivity?.phrase
    }

    private static func relative(from date: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds)s ago" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        return "\(minutes / 60)h ago"
    }
}

/// A pill's label: the symbol and the word, or, when the row is short of
/// room, the symbol alone (the word stays its tooltip and accessibility
/// label) or the word alone — the pill's colour already says which it is.
private struct PillLabelStyle: LabelStyle {
    var iconOnly = false
    var titleOnly = false

    func makeBody(configuration: Configuration) -> some View {
        if iconOnly {
            configuration.icon
        } else if titleOnly {
            configuration.title
        } else {
            Label(configuration)
                .labelStyle(.titleAndIcon)
        }
    }
}

/// An eyebrow label: the symbol a touch smaller than the text and tucked in
/// closer than `Label`'s default, so a mark reads as one word.
private struct EyebrowLabelStyle: LabelStyle {
    /// Drops the word, for a crowded eyebrow.
    var iconOnly = false

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon
                .imageScale(.small)
            if !iconOnly {
                configuration.title
            }
        }
    }
}

/// The face's text field, in the action row it replaces: the text, and the
/// button that sends it. Return sends and Esc cancels, both handled here so
/// every field behaves the same. Takes focus as it appears — the panel has
/// just become key for it (see `NotchViewModel.composing`).
///
/// One line: Claude Code submits a prompt on Return, so a reply can't carry
/// one, and a question's answer or a denial's reason reads as one anyway.
private struct ComposeField: View {
    @Binding var text: String
    let prompt: String
    let sendTitle: String
    let sendFill: Color
    let sendForeground: Color
    let onSend: () -> Void
    let onCancel: () -> Void

    @FocusState private var focused: Bool

    private var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(spacing: 6) {
            TextField(text: $text, prompt: Text(prompt).foregroundStyle(.white.opacity(0.4))) {
                Text(prompt)
            }
            .textFieldStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white)
            .focused($focused)
            .onSubmit { if !isEmpty { onSend() } }
            .onExitCommand(perform: onCancel)

            Button(action: onSend) {
                HStack(spacing: 4) {
                    Text(sendTitle)
                    Image(systemName: "return")
                        .font(.system(size: 9.5, weight: .bold))
                }
                .font(ClaudePanelLayout.pillFont)
                .foregroundStyle(sendForeground)
                .padding(.horizontal, 9)
                .frame(maxHeight: .infinity)
                .background(Capsule().fill(sendFill))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(isEmpty)
            .opacity(isEmpty ? 0.5 : 1)
            .padding(.vertical, 2)
        }
        .padding(.leading, 10)
        .padding(.trailing, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Capsule().fill(.white.opacity(0.08)))
        .overlay(Capsule().inset(by: 0.5).stroke(.white.opacity(0.4), lineWidth: 1))
        .onAppear {
            // After the panel has been made key, which the window controller
            // does on the same turn of the run loop that put this on screen.
            DispatchQueue.main.async { focused = true }
        }
        // Gone from the face for any reason — a swipe to another face, an
        // approval taking this one — and the keys go back with it, rather
        // than the panel holding focus for a field nobody can see.
        .onDisappear(perform: onCancel)
    }
}
