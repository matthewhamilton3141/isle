//
//  ClaudeExpandedView.swift
//
//  The Claude face of the expanded panel. Mirrors the music tab's weight — a
//  large marker on the left where the album art sits, and a text column with
//  the status, what Claude is doing, and the project + elapsed — so the tab
//  fills the panel instead of floating a small glyph in dead space. Shown as
//  the whole panel in `.claude` mode, or under the Claude tab in `.both`.
//

import SwiftUI

struct ClaudeExpandedView: View {
    @ObservedObject var viewModel: NotchViewModel
    var palette: ArtworkPalette

    private var state: ClaudeCodeState { viewModel.claudeState }

    var body: some View {
        // Same skeleton as the music tab: a 114pt block on the left where the
        // album art sits, then a text column — but with a bold headline and a
        // width-spanning info row so the panel doesn't read as empty.
        HStack(spacing: 14) {
            ClaudeStatusGlyphView(state: state, kind: viewModel.claudeMarkerKind, palette: palette)
                // Occupies the album cover's exact footprint (size + raise), so
                // the glyph reads as the same block on both tabs and the dots
                // scale up to fill it — the frame is the only cap on dot size.
                // Safe to raise into the housing band: the glyph sits left of
                // the camera cutout, on ordinary screen, just like the album.
                .frame(width: 114, height: 114)
                .offset(y: -10)

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

                Spacer(minLength: 0)
            }
            .frame(minWidth: 340, maxWidth: 340, maxHeight: .infinity, alignment: .leading)
            // Nudged up so the headline/detail/info block sits higher in the
            // panel.
            .offset(y: -21)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(.white)
        // Click the alert panel to retract it (no-op unless an alert is live and
        // dismissing is enabled). contentShape so taps land on the whole card,
        // not just the glyph and text.
        .contentShape(Rectangle())
        .onTapGesture { viewModel.dismissAlert() }
    }

    /// The project chip and the elapsed time, grouped together on the left so
    /// the time isn't stranded at the far right of the panel.
    private var infoRow: some View {
        HStack(spacing: 10) {
            if let project = viewModel.claudeProject, !project.isEmpty {
                Label(project, systemImage: "folder.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(.white.opacity(0.12)))
            }

            if viewModel.claudeUpdatedAt != nil, state != .disconnected {
                metaLine
            }

            Spacer(minLength: 0)
        }
    }

    // MARK: - Text

    private var headline: String {
        switch state {
        case .disconnected: return "No active session"
        case .idle: return "Ready"
        case .working: return viewModel.workingWord + "…"   // rotating gerund
        case .needsApproval, .needsQuestion: return "Has a question"
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
            // For a live permission `ask`, name the exact tool + target so the
            // decision is informed ("Running npm", "Editing App.swift"); fall
            // back to the generic prompt for a plain question.
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
