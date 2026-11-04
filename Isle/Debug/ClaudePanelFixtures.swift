//
//  ClaudePanelFixtures.swift
//
//  Every state the Claude face can be in, as data, for the previews below and
//  for rendering the panel offscreen to check a layout change without a live
//  session (see `NotchViewModel.applyPreviewFixture`). A face that has to hold
//  approvals, questions, other sessions and the keep-awake mark at once is
//  only checked properly by looking at all of them side by side.
//
//  Debug only; nothing here ships.
//

#if DEBUG
import SwiftUI
import AppKit

struct ClaudePanelFixture: Identifiable {
    /// File-name safe; the render harness writes `<prefix>_<name>.png`.
    let name: String
    var mode: IsleMode = .claude
    var state: ClaudeCodeState
    var project: String? = "isle"
    var action: String? = nil
    var target: String? = nil
    var errorType: String? = nil
    var resetAt: Date? = nil
    var updatedAt: Date = Date().addingTimeInterval(-42)
    var workingWord: String? = "Percolating"
    var request: ClaudeRequest? = nil
    var questionIndex = 0
    var picks: [Set<String>] = []

    var id: String { name }

    /// The settings the fixture is drawn under, on an isolated store.
    @MainActor
    func configure(_ settings: AppSettings) {
        settings.mode = mode
    }
}

extension ClaudePanelFixture {
    // MARK: Requests

    static func approval(_ tool: String, _ subject: String) -> ClaudeRequest {
        ClaudeRequest(
            id: "preview-session-1762300000-4242",
            kind: .approval,
            sessionId: "preview-session",
            toolName: tool,
            subject: subject,
            questions: []
        )
    }

    static func question(_ questions: [ClaudeQuestion]) -> ClaudeRequest {
        ClaudeRequest(
            id: "preview-session-1762300000-4343",
            kind: .question,
            sessionId: "preview-session",
            toolName: "AskUserQuestion",
            subject: nil,
            questions: questions
        )
    }

    static let twoOptions = ClaudeQuestion(
        question: "Should the migration run now or wait for the next deploy?",
        header: "Migration",
        options: [
            .init(label: "Run now", description: "Applies the schema change to the dev database immediately."),
            .init(label: "Wait", description: "Leaves it queued; it runs with the next deploy."),
        ],
        multiSelect: false
    )

    static let fourOptions = ClaudeQuestion(
        question: "Which approach should I take for caching the artwork palette across track changes?",
        header: "Approach",
        options: [
            .init(label: "LRU cache", description: "Keep the last 32 palettes keyed by artwork hash; evict the least recently used one first when the cache is full."),
            .init(label: "Per-album", description: "One palette per album identifier, so every track on an album shares it."),
            .init(label: "No cache", description: "Recompute on every change; simplest, costs a few ms per track."),
            .init(label: "Disk cache", description: nil),
        ],
        multiSelect: false
    )

    static let multiSelect = ClaudeQuestion(
        question: "Which checks should run before the release build?",
        header: "Checks",
        options: [
            .init(label: "Unit tests", description: "The fast suite, about 40 seconds."),
            .init(label: "UI snapshots", description: "Renders every face and diffs against the baseline."),
            .init(label: "Notarisation dry run", description: "Signs and submits without stapling."),
        ],
        multiSelect: true
    )

    static let thirdQuestion = ClaudeQuestion(
        question: "Bump the version?",
        header: "Version",
        options: [
            .init(label: "Patch", description: "0.4.4 → 0.4.5"),
            .init(label: "Minor", description: "0.4.4 → 0.5.0"),
        ],
        multiSelect: false
    )

    // MARK: The set

    static var all: [ClaudePanelFixture] {
        [
            .init(name: "disconnected", state: .disconnected, project: nil),
            .init(name: "idle", state: .idle),
            .init(name: "working_thinking", state: .working),
            .init(name: "working_tool", state: .working, action: "Edit",
                  target: "/Users/matthew/Documents/isle/Isle/Notch/ClaudeExpandedView.swift"),
            .init(name: "compacting", state: .compacting),
            .init(name: "waiting", state: .waitingInput),
            .init(name: "done", state: .done),
            .init(name: "failed", state: .failed, errorType: "overloaded"),
            .init(name: "usage_limit", state: .failed, errorType: "usage_limit",
                  resetAt: Date().addingTimeInterval(2 * 3600 + 14 * 60)),
            .init(name: "approval_short", state: .needsApproval, action: "Bash", target: "npm test",
                  request: approval("Bash", "npm test")),
            .init(name: "approval_long", state: .needsApproval, action: "Bash", target: "python3",
                  request: approval("Bash", "python3 -c \"import json,sys; d=json.load(open('/Users/matthew/.isle/sessions/abc.json')); print(d['state'], d.get('request_id'))\" && rm -rf /private/tmp/claude-501/scratch/build-cache")),
            .init(name: "approval_edit", state: .needsApproval, action: "Edit", target: "NotchMetrics.swift",
                  request: approval("Edit", "/Users/matthew/Documents/isle/Isle/Notch/NotchMetrics.swift")),
            .init(name: "question_2", state: .needsQuestion, request: question([twoOptions])),
            .init(name: "question_4", state: .needsQuestion, request: question([fourOptions])),
            .init(name: "question_multi_step2", state: .needsQuestion,
                  request: question([twoOptions, multiSelect, thirdQuestion]),
                  questionIndex: 1, picks: [["Run now"], ["Unit tests"], []]),
            .init(name: "both_working", mode: .both, state: .working, action: "Bash", target: "xcodebuild"),
            .init(name: "both_approval", mode: .both, state: .needsApproval, action: "Bash", target: "npm",
                  request: approval("Bash", "npm run lint -- --fix")),
            .init(name: "both_question_4", mode: .both, state: .needsQuestion, request: question([fourOptions])),
        ]
    }
}

/// The face in its panel, at the panel's real size, for the canvas.
private struct ClaudePanelPreview: View {
    let fixture: ClaudePanelFixture

    var body: some View {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "isle.preview.claude")!)
        fixture.configure(settings)
        let vm = NotchViewModel(settings: settings)
        vm.applyPreviewFixture(fixture)
        let island = IslandPresentation(content: vm)
        island.metrics = NotchMetrics.preferredScreen().map(NotchMetrics.init(screen:))
        island.setHovering(true)
        return NotchRootView(viewModel: vm, island: island)
            .frame(width: NotchMetrics.expandedSize.width + 40, height: NotchMetrics.questionPanelMaxHeight + 20)
            .background(Color(white: 0.25))
    }
}

#Preview("Claude panel — every state") {
    ScrollView {
        VStack(spacing: 8) {
            ForEach(ClaudePanelFixture.all) { fixture in
                ClaudePanelPreview(fixture: fixture)
            }
        }
    }
}
#endif
