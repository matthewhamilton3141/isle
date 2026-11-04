//
//  ClaudeExpandedView.swift
//
//  The Claude face of the expanded panel. Mirrors the music tab's weight — a
//  large marker on the left where the album art sits, and a text column with
//  the status, what Claude is doing, and the project + elapsed — so the tab
//  fills the panel instead of floating a small glyph in dead space. Shown as
//  the whole panel in `.claude` mode, or under the Claude tab in `.both`.
//
//  While a hook is blocked on the notch (Milestone 7) the face becomes the
//  place to answer it: an approval swaps the info row for Approve / Deny /
//  Terminal under the exact command, and a question becomes its own face —
//  the options as rows, in a panel grown to seat them. Every control here is
//  a real `Button`, so its tap is consumed and never falls through to the
//  card's dismiss gesture.
//

import SwiftUI

struct ClaudeExpandedView: View {
    @ObservedObject var viewModel: NotchViewModel
    var island: IslandPresentation
    var palette: ArtworkPalette

    private var state: ClaudeCodeState { viewModel.claudeState }

    /// The approval the notch can decide right now, if any.
    private var approval: ClaudeRequest? {
        guard let request = viewModel.pendingRequest, request.kind == .approval else { return nil }
        return request
    }

    var body: some View {
        Group {
            if let request = viewModel.pendingRequest, request.kind == .question,
               let question = viewModel.currentQuestion {
                questionFace(request, question: question)
                    .transition(.opacity)
            } else {
                statusFace
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(.white)
        // Click the alert panel to retract it (no-op unless an alert is live and
        // dismissing is enabled). contentShape so taps land on the whole card,
        // not just the glyph and text.
        .contentShape(Rectangle())
        .onTapGesture { island.dismissAlert() }
    }

    // MARK: - Status face

    private var statusFace: some View {
        // Same skeleton as the music tab: a 114pt block on the left where the
        // album art sits, then a text column — but with a bold headline and a
        // width-spanning info row so the panel doesn't read as empty.
        HStack(spacing: 14) {
            glyph(raise: 10)

            VStack(alignment: .leading, spacing: 0) {
                Spacer(minLength: 0)

                Text(headline)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .contentTransition(.opacity)
                    // Clear the waveform pinned at the panel's top-right by
                    // ExpandedNotchView, so the headline stops short of it.
                    .padding(.trailing, 36)

                Spacer().frame(height: 2)

                if let approval {
                    approvalDetail(approval)
                    Spacer().frame(height: 8)
                    approvalActions
                } else {
                    detailLine
                        .font(.system(size: 12.5, weight: .regular))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                        // Shrink a long filename to fit before resorting to an
                        // ellipsis, so "Editing SomeLongComponentName.swift" stays
                        // whole instead of getting clipped mid-name.
                        .minimumScaleFactor(0.7)
                        .truncationMode(.middle)

                    Spacer().frame(height: 11)

                    infoRow
                }

                Spacer(minLength: 0)
            }
            .frame(minWidth: 340, maxWidth: 340, maxHeight: .infinity, alignment: .leading)
            // Nudged up so the headline/detail/info block sits higher in the
            // panel. The approval block is 18pt taller (a two-line detail and
            // the buttons) and centres, so it is nudged half that less — which
            // keeps the headline exactly where it sits on every other state,
            // clear of the camera housing above it.
            .offset(y: approval == nil ? -21 : -12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// `raise` lifts it out of its slot; the two faces lay the glyph out
    /// differently (centred / top-aligned) and pass whatever lands it on the
    /// same spot.
    private func glyph(raise: CGFloat) -> some View {
        ClaudeStatusGlyphView(state: state, kind: viewModel.claudeMarkerKind, palette: palette)
            // Occupies the album cover's exact footprint (size + raise), so
            // the glyph reads as the same block on both tabs and the dots
            // scale up to fill it — the frame is the only cap on dot size.
            // Safe to raise into the housing band: the glyph sits left of
            // the camera cutout, on ordinary screen, just like the album.
            .frame(width: 114, height: 114)
            .offset(y: -raise)
    }

    /// The project chip and the elapsed time, grouped together on the left so
    /// the time isn't stranded at the far right of the panel.
    private var infoRow: some View {
        HStack(spacing: 10) {
            if let project = viewModel.claudeProject, !project.isEmpty {
                chip(project, systemImage: "folder.fill")
            }

            if viewModel.claudeUpdatedAt != nil, state != .disconnected {
                metaLine
            }

            Spacer(minLength: 0)
        }
    }

    private func chip(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.white.opacity(0.85))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(.white.opacity(0.12)))
    }

    // MARK: - Approval

    /// The tool and the exact thing it will act on — the whole command, not
    /// the island's hygienic "Running npm" — because this is what the click
    /// authorises. Monospaced, two lines, cut from the middle so both the
    /// program and the end of the command survive. A fixed two-line box, so
    /// the buttons below never move with the command's length.
    private func approvalDetail(_ request: ClaudeRequest) -> some View {
        let subject = (request.subject ?? "")
            // A heredoc or a multi-line script would otherwise spend both lines
            // on its first line break.
            .replacingOccurrences(of: "\n", with: " ↵ ")
        return (Text(request.toolName).fontWeight(.semibold).foregroundStyle(.white.opacity(0.9))
                + Text(subject.isEmpty ? "" : "  " + subject))
            .font(.system(size: 11.5, design: .monospaced))
            .foregroundStyle(.white.opacity(0.72))
            .lineLimit(2)
            .truncationMode(.middle)
            .frame(height: 30, alignment: .topLeading)
            // A long command fills the width, and its first line runs level
            // with the waveform pinned at the top-right; stop short of it, as
            // the headline does.
            .padding(.trailing, 36)
    }

    private var approvalActions: some View {
        HStack(spacing: 8) {
            pill("Approve", systemImage: "checkmark", fill: .green.opacity(0.85)) {
                viewModel.decide(allow: true)
            }
            pill("Deny", systemImage: "xmark", fill: .red.opacity(0.85)) {
                viewModel.decide(allow: false)
            }
            pill("Terminal", systemImage: "terminal", fill: .white.opacity(0.14)) {
                answerInTerminal()
            }
            Spacer(minLength: 0)
        }
        .frame(height: 24)
        .disabled(viewModel.isAnsweringRequest)
        .opacity(viewModel.isAnsweringRequest ? 0.5 : 1)
    }

    // MARK: - Question

    /// One question of an `AskUserQuestion`: its header as a chip, the
    /// question, its options as rows (label, then the description in the
    /// secondary weight), and the way out to the terminal. The panel has grown
    /// to fit — see `NotchMetrics.questionPanelHeight`, whose arithmetic
    /// follows these rows; change one, change the other.
    ///
    /// No free text: answering "Type something" would need a text field, and
    /// a text field needs key focus, which the notch must never take from the
    /// terminal. That stays an "Answer in terminal".
    private func questionFace(_ request: ClaudeRequest, question: ClaudeQuestion) -> some View {
        let index = viewModel.questionIndex
        let isLast = index + 1 >= request.questions.count
        let picks = viewModel.questionPicks.indices.contains(index) ? viewModel.questionPicks[index] : []

        return HStack(alignment: .top, spacing: 14) {
            // Top-aligned here rather than centred in a 104pt band, so it takes
            // a further 5pt to sit exactly where the status face draws it.
            glyph(raise: 15)

            VStack(alignment: .leading, spacing: 0) {
                // Header row: the question's chip, and where in a multi-part
                // ask this is. Clear of the waveform at the top-right.
                HStack(spacing: 8) {
                    chip(question.header ?? "Question", systemImage: "questionmark.bubble.fill")
                    if request.questions.count > 1 {
                        if index > 0 {
                            Button {
                                viewModel.previousQuestion()
                            } label: {
                                Image(systemName: "chevron.left")
                                    .font(.system(size: 10, weight: .semibold))
                                    .frame(width: 18, height: 18)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Previous question")
                        }
                        Text("\(index + 1) of \(request.questions.count)")
                            .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    Spacer(minLength: 0)
                }
                .frame(height: 18)
                .padding(.trailing, 36)

                Spacer().frame(height: 5)

                // Up to two lines, and the only row that can give way: if the
                // panel is at its cap, the question loses its second line
                // before anything else moves.
                Text(question.question)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1...2)
                    .truncationMode(.tail)
                    // Level with the waveform at the top-right; clear it.
                    .padding(.trailing, 36)

                Spacer().frame(height: 6)

                optionRows(question, picks: picks)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer().frame(height: 6)

                HStack(spacing: 8) {
                    pill("Answer in terminal", systemImage: "terminal", fill: .white.opacity(0.14)) {
                        answerInTerminal()
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
                .frame(height: 22)
                .padding(.trailing, switcherClearance)
            }
            .frame(minWidth: 340, maxWidth: 340, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .disabled(viewModel.isAnsweringRequest)
        .opacity(viewModel.isAnsweringRequest ? 0.5 : 1)
        .animation(.easeInOut(duration: 0.2), value: index)
    }

    private func optionRows(_ question: ClaudeQuestion, picks: Set<String>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            // AskUserQuestion offers two to four; anything past four still
            // fits by scrolling rather than by pushing the actions off the
            // panel.
            if question.options.count > 4 {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(question.options.enumerated()), id: \.offset) { _, option in
                            optionRow(option, multiSelect: question.multiSelect, picked: picks.contains(option.label))
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .frame(height: 4 * NotchMetrics.questionOptionPitch - 3)
            } else {
                ForEach(Array(question.options.enumerated()), id: \.offset) { _, option in
                    optionRow(option, multiSelect: question.multiSelect, picked: picks.contains(option.label))
                }
            }
        }
        .padding(.trailing, switcherClearance)
    }

    private func optionRow(_ option: ClaudeQuestion.Option, multiSelect: Bool, picked: Bool) -> some View {
        Button {
            viewModel.pickOption(option.label)
        } label: {
            HStack(spacing: 7) {
                if multiSelect {
                    Image(systemName: picked ? "checkmark.square.fill" : "square")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(picked ? 1 : 0.6))
                }
                Text(option.label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .layoutPriority(1)
                if let description = option.description {
                    Text(description)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: NotchMetrics.questionOptionPitch - 3)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.white.opacity(picked ? 0.24 : 0.08))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.description.map { "\(option.label), \($0)" } ?? option.label)
        .accessibilityAddTraits(picked ? [.isSelected] : [])
    }

    // MARK: - Controls

    /// A capsule button with an icon, for the decisions. Real `Button`s, so
    /// the tap is consumed and doesn't retract the card.
    private func pill(
        _ title: String,
        systemImage: String,
        fill: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(maxHeight: .infinity)
                .background(Capsule().fill(fill))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// Hands the prompt back to the terminal now, and — since that is where
    /// the user has said they'll answer — retracts the panel if they allow it.
    private func answerInTerminal() {
        viewModel.deferToTerminal()
        island.dismissAlert()
    }

    /// How far rows stop short of the column's right edge. With the face
    /// toggle parked in the panel's bottom-right corner, enough that the lower
    /// rows don't run under it; with the strip up in the housing band, nothing.
    private var switcherClearance: CGFloat {
        viewModel.showsTabToggle ? 44 : 0
    }

    // MARK: - Text

    private var headline: String {
        switch state {
        case .disconnected: return "No active session"
        case .idle: return "Ready"
        case .working: return viewModel.workingWord + "…"   // rotating gerund
        case .needsApproval: return "Needs your approval"
        case .needsQuestion: return "Has a question"
        case .waitingInput: return "Waiting for you"
        case .done: return "Done"
        case .failed: return "Error"
        case .compacting: return "Compacting"
        }
    }

    /// The detail line under the headline. The shared text modifiers are
    /// applied by the caller.
    private var detailLine: some View {
        Text(detail)
    }

    /// The secondary line under the headline — what's actually happening.
    private var detail: String {
        switch state {
        case .working:
            // No tool running → Claude is reasoning, not acting.
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
            return "The turn stopped on an error — resend to retry."
        case .compacting:
            return "Compacting the conversation to free up context"
        case .disconnected:
            return "Install the Claude Code hook to connect a session"
        }
    }

    /// A friendly phrase for the current tool, e.g. "Editing App.swift" or
    /// "Running npm". Nil when there's no tool info. Shares its phrasing and
    /// target hygiene with the collapsed glyph via `ClaudeActivity`.
    private var actionText: String? {
        viewModel.claudeActivity?.phrase
    }

    /// Live "… ago", ticking once a second. Project lives in its own chip.
    @ViewBuilder
    private var metaLine: some View {
        if let date = viewModel.claudeUpdatedAt {
            TimelineView(.periodic(from: date, by: 1)) { context in
                Text(Self.relative(from: date, to: context.date))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    private static func relative(from date: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds)s ago" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        return "\(minutes / 60)h ago"
    }
}
