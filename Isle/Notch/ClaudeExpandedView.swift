//
//  ClaudeExpandedView.swift
//
//  The Claude face of the expanded panel. Shown as the whole panel in
//  `.claude` mode, or under the Claude tab in `.both`.
//
//  The face starts in the housing band, in the wings either side of the
//  camera: the left wing has the marker and the state in its colour —
//  the collapsed pill's own mark and word, grown — and the right the other
//  live sessions, ahead of the crumb. The body starts right under the
//  housing and leads with what the state is about: the exact command on an
//  approval, Claude's own words when a turn ends, what it's doing while it
//  works. Under that, one quiet meta line (project · time · agents), and at
//  the foot of the face the action row — Approve / Deny / Terminal, or the
//  terminal and the reply field. A question puts its header in the wing,
//  the question and its options in the body, in a panel grown to seat
//  them. Every control here is a real `Button`, so its tap is consumed and
//  never falls through to the card's dismiss gesture.
//
//  With more than one live session, the face also flips to a list of them
//  all (Milestone 16): the sessions chip in the right wing is the way in, a
//  row's click puts that session on the face, and the chevron in the left
//  wing is the way back up.
//

import SwiftUI

private typealias L = ClaudePanelLayout

struct ClaudeExpandedView: View {
    @ObservedObject var viewModel: NotchViewModel
    var island: IslandPresentation
    var palette: ArtworkPalette

    /// The height the session list's rows have, as last laid out — so the
    /// wing can say when they scroll.
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
        return ZStack(alignment: .topLeading) {
            Group {
                if listing {
                    sessionListFace
                        .transition(.opacity)
                } else if let asking {
                    questionFace(asking.request, question: asking.question)
                        .transition(.opacity)
                } else {
                    statusFace
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
        // The wings: raised out of the face's box into the housing band,
        // either side of the camera, the way the album rises beside it on
        // the Music face. An overlay, so they never move the body.
        //
        // Outside the content shape above, on purpose: a content shape
        // bounds hit-testing for everything inside it, and the wings are
        // drawn above the face's box, so inside it they drew but took no
        // clicks — the sessions chip and the list's way back were dead.
        .overlay(alignment: .top) {
            wings
                .offset(y: -(wingLayout.band + NotchMetrics.contentTopGap))
                .foregroundStyle(.white)
                .animation(.easeInOut(duration: 0.22), value: listing)
        }
    }

    // MARK: - Wings

    /// The housing band beside the camera, laid out for this screen.
    private var wingLayout: L.Wings {
        let metrics = island.metrics
        return L.wings(
            notch: metrics?.notchSize.width ?? NotchMetrics.fallbackNotchSize.width,
            band: metrics?.notchSize.height ?? NotchMetrics.fallbackNotchSize.height,
            physical: metrics?.hasPhysicalNotch ?? true,
            crumb: L.crumbWidth(showsHome: viewModel.showsHome)
        )
    }

    /// Either side of the camera, in the band as tall as the housing: what
    /// the face is about on the left, the other sessions on the right ahead
    /// of the crumb. Each wing ends `wingClearance` short of the cutout, and
    /// what it holds gives way to its own width rather than reach past it.
    private var wings: some View {
        let layout = wingLayout
        return HStack(spacing: 0) {
            leftWing
                .frame(width: layout.left, alignment: .leading)
            Spacer(minLength: 0)
            rightWing
                .frame(width: layout.right, alignment: .trailing)
                .padding(.trailing, layout.trailing)
        }
        .lineLimit(1)
        .frame(width: L.faceWidth, height: layout.band)
    }

    /// The status: the marker and the state in its colour — "Percolating…",
    /// "Done", "Needs approval" — the pill's own mark and word, grown. On a
    /// question its header; on the list the way back.
    @ViewBuilder
    private var leftWing: some View {
        if viewModel.sessionListShown {
            listBack
        } else if let asking {
            questionWing(asking.request, question: asking.question)
        } else {
            HStack(spacing: L.glyphGap) {
                glyph
                Text(wingWord)
                    .font(L.statusFont)
                    .foregroundStyle(statusTint)
                    .minimumScaleFactor(0.85)
                    .truncationMode(.tail)
                    .contentTransition(.opacity)
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// The other sessions and the way to them, ahead of the crumb; the
    /// list's count on the list.
    @ViewBuilder
    private var rightWing: some View {
        if viewModel.sessionListShown {
            listCount
        } else {
            sessionMarks
                .animation(.easeInOut(duration: 0.2), value: viewModel.otherSessions)
        }
    }

    /// The marker: the collapsed island's mark at the collapsed island's
    /// size, so opening the island grows its pill rather than replacing it.
    private var glyph: some View {
        ClaudeStatusGlyphView(state: state, kind: viewModel.claudeMarkerKind, palette: palette)
            .frame(width: L.glyphSize, height: L.glyphSize)
    }

    /// The status word in the wing: the headline, in its short form where
    /// the long one is a sentence. The wing holds about fourteen letters.
    private var wingWord: String {
        switch state {
        case .needsApproval where agentState == nil:
            if viewModel.isReviewingRemember, approval?.remember != nil { return "Always allow?" }
            return approval?.isPlan == true ? "Plan ready" : "Needs approval"
        case .failed where viewModel.isUsageLimit:
            return ClaudeLimit.headline(kind: viewModel.claudeLimitKind, next: viewModel.claudeLimitNext)
        default:
            return headline
        }
    }

    /// The state's colour, for its words: the marker's own hue — working in
    /// the palette's, done green, an approval amber, an error red — lifted a
    /// little so it reads as text on black. Ready and No session are plain:
    /// they're not news.
    private var statusTint: Color {
        if agentState == nil, state == .idle || state == .disconnected { return .white.opacity(0.85) }
        return Self.lifted(stateColor(viewModel.claudeMarkerKind))
    }

    private static func lifted(_ color: Color) -> Color {
        guard let ns = NSColor(color).usingColorSpace(.sRGB),
              let mixed = ns.blended(withFraction: 0.18, of: .white) else { return color }
        return Color(nsColor: mixed)
    }

    // MARK: - Status face

    /// A status, or an approval. The state is the wing's, so the body leads
    /// with what it's about — the command to approve, what Claude said, what
    /// it's doing — then where and when, then the action row, which sits at
    /// the foot of the face on every status and approval so it's always
    /// where the pointer left it.
    private var statusFace: some View {
        VStack(alignment: .leading, spacing: 0) {
            hero
            Spacer().frame(height: L.heroGap)
            metaLine
            if approval == nil {
                extraLine
            }
            if approval != nil || viewModel.claudeHasActions {
                Spacer(minLength: L.bodyGap)
                actionRow {
                    if approval != nil {
                        approvalActions
                    } else {
                        statusActions
                    }
                }
            } else {
                // Nothing to press: the panel is the hero and the meta's
                // height (`bareStatusHeight`), with no row held empty.
                Spacer(minLength: 0)
            }
        }
    }

    /// The face's lead: the exact command on an approval; Claude's own words
    /// after a turn (two lines at most, cut at a sentence's end where one
    /// falls — see `ClaudeDoneLine` — never shrunk, one line when a line
    /// below needs the room); otherwise what it's doing or what the state
    /// means, as a title.
    @ViewBuilder
    private var hero: some View {
        if let approval {
            approvalCard(approval)
        } else if let said = claudeSaid {
            Text(said)
                .font(L.saidFont)
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(hasExtraLine ? 1 : L.saidLines)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentTransition(.opacity)
        } else {
            // A long filename shrinks to fit before it's cut, and then from
            // the middle, so "Editing SomeLongComponentName.swift" keeps
            // its name and its extension.
            Text(detail)
                .font(L.headlineFont)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .truncationMode(.middle)
                .frame(height: L.headlineLine, alignment: .leading)
                .contentTransition(.opacity)
        }
    }

    /// Where, when, and what else: "isle · 2m ago", "isle · 3 agents ☕",
    /// "isle · 4m ago  [Guarded]", "isle · Replying · esc to cancel". Gives
    /// way from the end, down to the project alone. A reply that didn't
    /// land takes the whole line.
    @ViewBuilder
    private var metaLine: some View {
        Group {
            if case .failed(_, let reason) = viewModel.replyDelivery {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .minimumScaleFactor(0.8)
                    .truncationMode(.tail)
            } else {
                ViewThatFits(in: .horizontal) {
                    metaItems(full: true)
                    metaItems(full: false)
                }
            }
        }
        .font(L.metaFont)
        .labelStyle(MetaLabelStyle())
        .foregroundStyle(.islandSecondary(IsleType.Tone.meta))
        .lineLimit(1)
        .frame(height: L.metaHeight, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The meta line in full, or (`full` false) the project alone, cut
    /// short if it must be.
    @ViewBuilder
    private func metaItems(full: Bool) -> some View {
        if full {
            let agents = foldsAgents ? ClaudeSubagents.briefs(viewModel.claudeSubagents).last : nil
            HStack(spacing: 5) {
                projectLabel
                // A dot between items, never ahead of the first.
                if viewModel.composing == .reply {
                    if showsProject { separator }
                    Text("Replying").foregroundStyle(.white.opacity(0.8))
                    separator
                    Text("esc to cancel")
                } else if viewModel.claudeUpdatedAt != nil, showsAge {
                    if showsProject { separator }
                    elapsed
                }
                if let agents {
                    if showsProject || viewModel.composing == .reply
                        || (viewModel.claudeUpdatedAt != nil && showsAge) { separator }
                    Text(agents)
                        .help(ClaudeSubagents.lines(viewModel.claudeSubagents).first ?? "")
                }
                if viewModel.isKeepingAwake {
                    keepAwakeCup
                        .padding(.leading, 3)
                }
                if let pattern = approval?.guardedBy {
                    guardChip(pattern)
                        .padding(.leading, 4)
                }
            }
            .fixedSize()
        } else {
            HStack(spacing: 5) { projectLabel }
        }
    }

    /// The meta line has a project (or a session's name, or the way back
    /// to the list) to lead with.
    private var showsProject: Bool {
        isPinned || viewModel.claudeBackground?.name != nil || viewModel.claudeProject?.isEmpty == false
    }

    /// One more line, under the meta, for what didn't happen or is still
    /// going on its own: a block (Milestone 23), what the turn left running
    /// (Milestone 20), or the agents of a face with no activity for them to
    /// join (Milestone 22) — in that order, one at most.
    @ViewBuilder
    private var extraLine: some View {
        if viewModel.claudeBlock != nil {
            blockLine
        } else if leftovers != nil {
            leftLine
        } else if claudeSaid == nil, !foldsAgents {
            subagentLine
        }
    }

    private var hasExtraLine: Bool {
        viewModel.claudeBlock != nil || leftovers != nil
            || (claudeSaid == nil && !foldsAgents && !viewModel.claudeSubagents.isEmpty)
    }

    /// The command to approve, on a card of its own edged in the request's
    /// colour: the thing the click authorises, set apart from everything
    /// around it.
    private func approvalCard(_ request: ClaudeRequest) -> some View {
        approvalCommand(request)
            .padding(.horizontal, L.cardPadding.width)
            .padding(.vertical, L.cardPadding.height)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: L.cardRadius, style: .continuous)
                .fill(.white.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: L.cardRadius, style: .continuous)
                .inset(by: 0.5)
                .stroke(statusTint.opacity(0.35), lineWidth: 1))
    }

    /// The agents are counted on the meta line while Claude is doing
    /// something (working, thinking, compacting), the tooltip naming every
    /// kind. The faces after a turn have no activity to count them beside,
    /// and keep their own line (Milestones 20 and 22).
    private var foldsAgents: Bool {
        agentState == nil && (state == .working || state == .compacting)
    }

    /// The subagents running for this session (Milestone 22), under what
    /// it's doing: "3 agents · Explore ×2, Plan". Only while the hooks say
    /// one is; one line, quieter than the detail above it, naming as many
    /// kinds as fit and counting the rest as "+N". On the faces with no
    /// activity line for them to join (see `foldsAgents`).
    @ViewBuilder
    private var subagentLine: some View {
        let lines = ClaudeSubagents.lines(viewModel.claudeSubagents)
        if !lines.isEmpty {
            ViewThatFits(in: .horizontal) {
                ForEach(lines, id: \.self) { line in
                    Text(line).lineLimit(1)
                }
            }
            .font(IsleType.meta)
            .foregroundStyle(.islandSecondary(IsleType.Tone.meta))
            .frame(height: L.detailLine, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, switcherClearance)
            .contentTransition(.opacity)
            .transition(.opacity)
            .accessibilityLabel(lines[0])
        }
    }

    /// What the turn left behind (Milestone 20), on the faces that follow a
    /// finished turn: "Left running: npm run dev · Explore agent", "Wakes
    /// 9:00am". One quiet line, as of the turn's end, in the fullest form
    /// that fits; the tooltip has the whole of it.
    @ViewBuilder
    private var leftLine: some View {
        if let left = leftovers {
            let lines = left.lines()
            ViewThatFits(in: .horizontal) {
                ForEach(lines, id: \.self) { line in
                    Text(line).lineLimit(1)
                }
            }
            .font(IsleType.meta)
            .foregroundStyle(.islandSecondary(IsleType.Tone.meta))
            .frame(height: L.detailLine, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, switcherClearance)
            .contentTransition(.opacity)
            .transition(.opacity)
            .help(left.help())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(left.help())
        }
    }

    /// The last call auto mode blocked (Milestone 23), under what Claude is
    /// doing: "Auto mode blocked rm · Shared Scratch Sweep". One line, in the
    /// guard chip's pale orange, in the fullest form that fits; the tooltip says
    /// how to allow it in Claude Code. No button: the face's Jump is the way
    /// to the session.
    @ViewBuilder
    private var blockLine: some View {
        if let block = viewModel.claudeBlock {
            ViewThatFits(in: .horizontal) {
                ForEach(block.lines, id: \.self) { line in
                    blockText(line).lineLimit(1)
                }
            }
            .font(L.detailFont)
            .foregroundStyle(IslandToast.blockTint)
            .frame(height: L.detailLine, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, switcherClearance)
            .contentTransition(.opacity)
            .transition(.opacity)
            .help(block.help)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(block.help)
        }
    }

    private func blockText(_ line: ClaudeBlock.Line) -> Text {
        var text = Text(Image(systemName: "hand.raised.fill")).font(.system(size: 10, weight: .semibold))
            + Text(" " + line.lead)
        if let object = line.object {
            text = text + Text(" ") + (line.isCommand ? Text(object).font(L.commandFont) : Text(object))
        }
        if let reason = line.reason {
            text = text + Text(" · ").foregroundColor(.white.opacity(0.3)) + Text(reason)
        }
        return text
    }

    // MARK: - Where

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

    /// The session's name on the meta line: a background session's own, else
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

    /// The keep-awake hold, as its cup alone: the words are its tooltip.
    private var keepAwakeCup: some View {
        Image(systemName: "cup.and.saucer.fill")
            .imageScale(.small)
            .help("Mac kept awake while Claude works")
            .accessibilityLabel("Keeping the Mac awake while Claude works")
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
                // In words where the wing has the room; else as the counts
                // in their states' colours — amber needs you, the working
                // colour busy — which the tooltip says in words.
                ViewThatFits(in: .horizontal) {
                    sessionChip(others, quiet: quiet, form: .words)
                    sessionChip(others, quiet: quiet, form: .counts)
                    sessionChip(others, quiet: quiet, form: .total)
                    sessionChip(others, quiet: quiet, form: .tight)
                }
            }
            .buttonStyle(.plain)
            .help(sessionsHelp(others, quiet: quiet))
            .accessibilityLabel(others.isEmpty && quiet > 0
                                ? "\(quiet) more \(quiet == 1 ? "session" : "sessions"), show every session"
                                : "Every session, \(viewModel.sessionList.count) live")
        } else if !others.isEmpty {
            ViewThatFits(in: .horizontal) {
                sessionChip(others, quiet: 0, form: .words, chevron: false)
                sessionChip(others, quiet: 0, form: .counts, chevron: false)
                sessionChip(others, quiet: 0, form: .total, chevron: false)
                sessionChip(others, quiet: 0, form: .tight, chevron: false)
            }
            .help(sessionsHelp(others, quiet: 0))
        }
    }

    private func sessionsHelp(_ others: ClaudeOtherSessions, quiet: Int) -> String {
        var parts: [String] = []
        if others.needYou > 0 { parts.append("\(others.needYou) \(others.needYou == 1 ? "needs" : "need") you") }
        if others.working > 0 { parts.append("\(others.working) working") }
        if others.isEmpty, quiet > 0 { parts.append("\(quiet) more \(quiet == 1 ? "session" : "sessions")") }
        return (parts.isEmpty ? "Every session" : parts.joined(separator: ", ")) + " — show every session"
    }

    /// `tight` is `total` drawn closer, for the widest housings.
    private enum ChipForm { case words, counts, total, tight }

    /// The other sessions as a chip, in the fullest form the wing holds:
    /// "● 1 needs you  ● 1 working ›", then "● 1  ● 1 ›", then the total
    /// behind the most pressing state's dot, "● 2 ›". Amber is needs you,
    /// the working colour busy; the tooltip says it in words.
    private func sessionChip(_ others: ClaudeOtherSessions, quiet: Int, form: ChipForm,
                             chevron: Bool = true) -> some View {
        let amber = Self.lifted(stateColor(.warning))
        let busy = Self.lifted(stateColor(.working))
        let tight = form == .tight
        return HStack(spacing: tight ? 4 : 6) {
            if form == .total || tight, !others.isEmpty {
                sessionCount(others.needYou + others.working, words: nil,
                             color: others.needYou > 0 ? amber : busy)
            } else {
                if others.needYou > 0 {
                    sessionCount(others.needYou,
                                 words: form == .words ? (others.needYou == 1 ? "needs you" : "need you") : nil,
                                 color: amber)
                        .accessibilityLabel("\(others.needYou) other \(others.needYou == 1 ? "session needs" : "sessions need") you")
                }
                if others.working > 0 {
                    sessionCount(others.working, words: form == .words ? "working" : nil, color: busy)
                        .accessibilityLabel("\(others.working) other \(others.working == 1 ? "session" : "sessions") working")
                }
            }
            if others.isEmpty, quiet > 0 {
                Text("+\(quiet)")
                    .foregroundStyle(.white.opacity(0.85))
            }
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.leading, -2)
            }
        }
        .font(IsleType.metaStrong)
        .monospacedDigit()
        .padding(.horizontal, tight ? 5 : 7)
        .frame(height: L.chipHeight)
        .background(Capsule().fill(.white.opacity(chevron ? 0.1 : 0.05)))
        .contentShape(Capsule())
        .fixedSize()
    }

    private func sessionCount(_ count: Int, words: String?, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(words.map { "\(count) \($0)" } ?? "\(count)")
                .foregroundStyle(.white.opacity(0.85))
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
    /// to the session's terminal. The way back is the left wing's chevron.
    ///
    /// No glyph: each row has its own marker, and the rows want the face's
    /// whole width. Four rows fit the standard panel; past that they scroll
    /// (vertically — a sideways swipe is the way between faces), with the
    /// count in the right wing and the last row fading at the foot to say so.
    private var sessionListFace: some View {
        let rows = viewModel.sessionList
        return VStack(alignment: .leading, spacing: 0) {
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
        .animation(.easeInOut(duration: 0.2), value: rows)
    }

    /// The list's left wing: the way back to the face.
    private var listBack: some View {
        Button {
            viewModel.closeSessionList()
        } label: {
            Label("Sessions", systemImage: "chevron.left")
                .font(IsleType.headline)
                .labelStyle(MetaLabelStyle())
                .foregroundStyle(.white.opacity(0.9))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel("Back")
    }

    /// The list's right wing: how many, whether the rest are a scroll
    /// away, and the keep-awake cup — the cup first to go when the wing is
    /// short, then the scroll mark.
    private var listCount: some View {
        let rows = viewModel.sessionList
        let scrolls = sessionRowsRoom > 0 && L.sessionRowsHeight(rows.count) > sessionRowsRoom + 0.5
        return ViewThatFits(in: .horizontal) {
            listCountRow(rows, scrolls: scrolls, cup: viewModel.isKeepingAwake)
            listCountRow(rows, scrolls: scrolls, cup: false)
            listCountRow(rows, scrolls: false, cup: false)
        }
        .font(L.metaFont)
        .foregroundStyle(.islandSecondary(IsleType.Tone.meta))
    }

    private func listCountRow(_ rows: [ClaudeSessionRow], scrolls: Bool, cup: Bool) -> some View {
        HStack(spacing: 5) {
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
            if cup {
                keepAwakeCup
                    .padding(.leading, 3)
            }
        }
        .fixedSize()
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
                        .foregroundStyle(.islandSecondary(IsleType.Tone.meta))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    if let updated = row.updatedAt {
                        Text(Self.shortAge(from: updated, to: now))
                            .font(L.sessionDetailFont)
                            .monospacedDigit()
                            .foregroundStyle(.islandSecondary(IsleType.Tone.meta))
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
        .foregroundStyle(.islandSecondary(IsleType.Tone.secondary))
        // Centred in the lines it holds, so a one-line command in a box
        // kept at two (for the review) sits in the card's middle.
        .frame(minHeight: CGFloat(Self.commandBoxLines(request)) * L.commandLine, alignment: .leading)
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
            .font(L.metaFont)
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

    /// The decisions, with their keys (`ShortcutHints`) where the row has
    /// the room: at the usual spacing, else a little closer (Always…'s five
    /// pills), else without them (keys rebound to long chords) — never a
    /// row any wider than before. A row that fits is drawn at its own width:
    /// laid out squeezed instead, an HStack shortens Approve to "Appr…" with
    /// room to spare.
    private var decisionPills: some View {
        ViewThatFits(in: .horizontal) {
            decisionPillRow(hints: true, spacing: 8).fixedSize(horizontal: true, vertical: false)
            decisionPillRow(hints: true, spacing: 6).fixedSize(horizontal: true, vertical: false)
            decisionPillRow(hints: false, spacing: 8).fixedSize(horizontal: true, vertical: false)
            // The last resort, taken even when it doesn't fit: squeezed to
            // the row, so a pill shortens rather than the row spilling out
            // of the panel.
            decisionPillRow(hints: false, spacing: 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .disabled(viewModel.isAnsweringRequest)
        .opacity(viewModel.isAnsweringRequest ? 0.5 : 1)
    }

    private func decisionPillRow(hints: Bool, spacing: CGFloat) -> some View {
        let offersRemember = approval?.remember != nil
        return HStack(spacing: spacing) {
            if offersRemember, viewModel.isReviewingRemember {
                // The review's Confirm and Back are what Approve's and
                // Deny's keys press there.
                pill("Confirm", systemImage: "checkmark", fill: .green.opacity(0.85),
                     hint: hints ? .approve : nil) {
                    viewModel.allowRemembering()
                }
                pill("Back", systemImage: "chevron.left", fill: .white.opacity(0.14),
                     hint: hints ? .deny : nil) {
                    viewModel.cancelRemember()
                }
            } else {
                pill("Approve", systemImage: "checkmark", fill: .green.opacity(0.85), compact: offersRemember,
                     hint: hints ? .approve : nil) {
                    viewModel.decide(allow: true)
                }
                if offersRemember {
                    pill("Always…", systemImage: "infinity", fill: .green.opacity(0.3), compact: true) {
                        viewModel.reviewRemember()
                    }
                }
                pill("Deny", systemImage: "xmark", fill: .red.opacity(0.85), compact: offersRemember,
                     hint: hints ? .deny : nil) {
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
        }
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
            // The session's app by name, beside the reply field on a
            // terminal Isle can type into and alone on any other. Attaching
            // to a background session (Milestone 21) is a pill of its own.
            if viewModel.jumpAttaches {
                pill("Attach in \(ClaudeLauncher.attachApp)", systemImage: "terminal", fill: .white.opacity(0.14)) {
                    viewModel.jumpToSession()
                }
                .help("Open this background session in \(ClaudeLauncher.attachApp) (claude attach)")
            } else if let target = viewModel.jumpTarget {
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
                    .foregroundStyle(.islandSecondary(IsleType.Tone.meta))
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
                    .foregroundStyle(.islandSecondary(IsleType.Tone.meta))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .font(L.pillFont)
        .padding(.leading, 4)
    }

    // MARK: - Question

    /// One question of an `AskUserQuestion`: its header and step in the left
    /// wing, the question as the title, its options as rows, and the way
    /// out to the terminal. The panel has grown to fit — sized from the same
    /// `ClaudePanelLayout.fit` these rows are drawn from.
    ///
    /// The header is the left wing's; the question and options run the
    /// face's whole width. Every option is always on screen: where the
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
                    Text(question.question)
                        .font(L.questionFont)
                        .lineLimit(fit.questionLines)
                        .truncationMode(.tail)
                        .frame(height: CGFloat(fit.questionLines) * L.questionLine, alignment: .topLeading)
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
                        // Done's key where the row has the room for it; else
                        // Done as it was, so a long chord never squeezes
                        // "Answer in terminal" and "Type something".
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 8) {
                                questionActions(question, isLast: isLast, picks: picks, fit: fit, hints: true)
                            }
                            HStack(spacing: 8) {
                                questionActions(question, isLast: isLast, picks: picks, fit: fit, hints: false)
                            }
                        }
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
                                 fit: L.OptionsFit, hints: Bool) -> some View {
                    pill("Answer in terminal", systemImage: "terminal", fill: .white.opacity(0.14)) {
                        answerInTerminal()
                    }
                    pill("Type something", systemImage: "character.cursor.ibeam", fill: .white.opacity(0.14)) {
                        viewModel.beginCompose(.answer)
                    }
                    if fit.scrolls {
                        Label("\(question.options.count) options", systemImage: "arrow.up.and.down")
                            .font(L.metaFont)
                            .labelStyle(MetaLabelStyle())
                            .foregroundStyle(.islandSecondary(IsleType.Tone.meta))
                            .fixedSize()
                    }
                    Spacer(minLength: 0)
                    // Which session is asking, in the row's slack: the
                    // header has the wing.
                    HStack(spacing: 5) { projectLabel }
                        .font(L.metaFont)
                        .labelStyle(MetaLabelStyle())
                        .foregroundStyle(.islandSecondary(IsleType.Tone.meta))
                        .lineLimit(1)
                        .layoutPriority(-1)
                    if question.multiSelect {
                        // Approve's key presses it, once there's a pick to send.
                        pill(isLast ? "Done" : "Next",
                             systemImage: isLast ? "checkmark" : "arrow.right",
                             fill: .white.opacity(picks.isEmpty ? 0.14 : 0.3),
                             hint: hints ? .approve : nil, hintLive: !picks.isEmpty) {
                            viewModel.advanceQuestion()
                        }
                        .disabled(picks.isEmpty)
                    }
    }

    /// The question's left wing: its marker and header, and where in a
    /// multi-part ask this is. The project is the right wing's to give up
    /// first.
    private func questionWing(_ request: ClaudeRequest, question: ClaudeQuestion) -> some View {
        let index = viewModel.questionIndex
        return HStack(spacing: L.glyphGap) {
            glyph
            Text(question.header ?? "Question")
                .font(L.statusFont)
                .foregroundStyle(statusTint)
                .truncationMode(.tail)
                .layoutPriority(-1)
            if request.questions.count > 1 {
                step(index: index, count: request.questions.count)
                    .font(L.metaFont)
                    .foregroundStyle(.islandSecondary(IsleType.Tone.meta))
            }
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
                        .frame(width: 16, height: L.metaHeight)
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
                          descriptionLines: fit.style == .full ? fit.descriptionLines[index] : 0,
                          hint: ShortcutAction.options.indices.contains(index) ? ShortcutAction.options[index] : nil)
            }
        }
    }

    /// One option, drawn in the form the fit chose: stacked with
    /// `descriptionLines` of description under `.full`, label and
    /// description on one line under `.oneLine`, the label alone under
    /// `.hidden`.
    private func optionRow(_ option: ClaudeQuestion.Option, multiSelect: Bool, picked: Bool,
                           style: OptionDescriptions, descriptionLines lines: Int,
                           hint: ShortcutAction?) -> some View {
        let height = L.optionRowHeight(style: style, descriptionLines: lines)
        // A stacked row's label keeps the key's own width clear; a key too
        // long for that (a rebound chord) is left off the row. A one-line
        // row has the room: its description gives way instead.
        let bound = hint.flatMap { viewModel.shortcutHints.key($0) }
        let clearance = lines > 0 ? bound.flatMap { L.keyHintClearance(for: $0) } : nil
        let key = lines > 0 && clearance == nil ? nil : bound
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
                            // Clear of the key over the corner.
                            .padding(.trailing, clearance ?? 0)
                        Text(option.description ?? "")
                            .font(L.optionDescriptionFont)
                            .foregroundStyle(.islandSecondary(IsleType.Tone.meta))
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
                            .foregroundStyle(.islandSecondary(IsleType.Tone.meta))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Spacer(minLength: 0)
                // Its key at the row's end. Beside a one-line row's text,
                // which is cut to fit anyway; over a stacked row's top
                // corner, level with the label, so a description wraps to
                // exactly the lines the fit measured.
                if lines == 0, let key, let hint {
                    keyHint(key, live: viewModel.shortcutHints.isLive(hint), opacity: 0.45)
                }
            }
            .overlay(alignment: .topTrailing) {
                if lines > 0, let key, let hint {
                    keyHint(key, live: viewModel.shortcutHints.isLive(hint), opacity: 0.45)
                        .frame(height: L.optionLabelLine)
                }
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
    ///
    /// With `hint`, the shortcut's keys follow the word in place of the
    /// symbol, when it has keys (`ShortcutHints`): the pill's colour already
    /// says which decision it is, and the swap keeps the pill about as wide.
    private func pill(
        _ title: String,
        systemImage: String,
        fill: Color,
        iconOnly: Bool = false,
        compact: Bool = false,
        hint: ShortcutAction? = nil,
        hintLive: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        let key = iconOnly ? nil : hint.flatMap { viewModel.shortcutHints.key($0) }
        return Button(action: action) {
            Group {
                if let key, let hint {
                    HStack(spacing: 4) {
                        Text(title)
                        keyHint(key, live: hintLive && viewModel.shortcutHints.isLive(hint), opacity: 0.6)
                    }
                } else {
                    Label(title, systemImage: systemImage)
                        .labelStyle(PillLabelStyle(iconOnly: iconOnly, titleOnly: compact))
                }
            }
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

    /// A shortcut's keys on its button: faint, and there only while a press
    /// would do what the button does. Its room is kept when it isn't, so it
    /// coming or going never moves a thing.
    private func keyHint(_ key: String, live: Bool, opacity: Double) -> some View {
        Text(key)
            .font(L.keyHintFont)
            .foregroundStyle(.islandSecondary(opacity))
            .lineLimit(1)
            .fixedSize()
            .opacity(live ? 1 : 0)
            .animation(.easeInOut(duration: 0.2), value: live)
            .accessibilityHidden(true)
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

    /// The meta line says how long ago the session last moved only where the
    /// age means something: after a turn (Done, Waiting, Ready), on a
    /// request, a failure. Not while Claude is at work — working, thinking,
    /// compacting — when it's always a few seconds and only ticks.
    private var showsAge: Bool {
        guard state != .disconnected else { return false }
        if let agentState { return agentState != .working }
        return state != .working && state != .compacting
    }

    /// What Claude said last, for the states that follow a finished turn:
    /// Done, the "Ready" it eases back to, and "Waiting for you". In place of
    /// the stock line, and only when there are words to quote.
    ///
    /// Also on a background session Claude Code says is blocked after the
    /// hooks saw its turn end: what Claude said is usually what it's asking.
    /// What the last turn left running or scheduled (Milestone 20), on the
    /// same faces as Claude's last words, from a hook's record only, and
    /// only while some of it is still to say.
    private var leftovers: ClaudeLeftovers? {
        guard agentState == nil else { return nil }
        switch state {
        case .done, .idle, .waitingInput: return viewModel.claudeLeftovers?.shown()
        default: return nil
        }
    }

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

/// A meta label: the symbol a touch smaller than the text and tucked in
/// closer than `Label`'s default, so a mark reads as one word.
private struct MetaLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon
                .imageScale(.small)
            configuration.title
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
            .font(IsleType.body)
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
