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
                // A touch smaller than the album, and only slightly raised, so
                // the top dots stay on the island instead of running off the
                // top edge into the camera band.
                .frame(width: 100, height: 100)
                .offset(y: -4)

            VStack(alignment: .leading, spacing: 0) {
                Spacer(minLength: 0)

                Text(headline)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .contentTransition(.opacity)

                Spacer().frame(height: 2)

                Text(detail)
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
            .offset(y: -1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(.white)
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
        case .working: return viewModel.workingWord   // rotating gerund
        case .needsApproval: return "Needs your approval"
        case .needsQuestion: return "Has a question"
        case .waitingInput: return "Waiting for you"
        case .done: return "Done"
        case .failed: return viewModel.claudeError.title
        }
    }

    /// The secondary line under the headline — what's actually happening.
    private var detail: String {
        switch state {
        case .working:
            // No tool running → Claude is reasoning, not acting.
            return actionText ?? "Thinking…"
        case .needsApproval:
            return "Waiting for your go-ahead"
        case .needsQuestion:
            return "Answer to keep it moving"
        case .waitingInput:
            return "It's ready for your next prompt"
        case .done:
            return "Finished responding"
        case .idle:
            return "Session ready"
        case .failed:
            return viewModel.claudeError.detail
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
