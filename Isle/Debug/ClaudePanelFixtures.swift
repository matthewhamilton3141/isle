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
    var descriptions: OptionDescriptions = .default
    var keepAwake = false
    var others = ClaudeOtherSessions()

    var id: String { name }

    /// The settings the fixture is drawn under, on an isolated store.
    @MainActor
    func configure(_ settings: AppSettings) {
        settings.mode = mode
        settings.optionDescriptions = descriptions
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

    static let threeOptions = ClaudeQuestion(
        question: "Where should the lyric cache live?",
        header: "Cache",
        options: [
            .init(label: "Application Support", description: "Survives restarts; cleared only when Isle is removed."),
            .init(label: "Caches", description: "The system may purge it when space runs low."),
            .init(label: "Memory only", description: "Gone on quit; nothing written to disk."),
        ],
        multiSelect: false
    )

    /// The schema's worst case for one question: four options (the most
    /// `AskUserQuestion` accepts), every one with a description that wraps
    /// past two lines in the column, under a question that takes two.
    static let fourLong = ClaudeQuestion(
        question: "The request watcher can miss a rename that lands during a re-read. How should I close the gap before the release?",
        header: "Race fix",
        options: [
            .init(label: "Re-read on every event", description: "Rescan the whole requests directory whenever the watch fires, and diff against what's on screen; costs a directory listing per event but can't miss a file."),
            .init(label: "Sequence numbers", description: "Have isle-cli stamp each request with a counter and have Isle notice a gap; precise, but it changes the hook script and needs a HookInstaller bump."),
            .init(label: "Poll as a backstop", description: "Keep the watch and add a slow two-second poll while any request is live, so a missed event costs at most two seconds of a stale panel."),
            .init(label: "Leave it", description: "It needs a rename inside a few milliseconds of a re-read; not seen in testing, so note it in the roadmap and move on to the release."),
        ],
        multiSelect: false
    )

    static let fourLongMulti = ClaudeQuestion(
        question: "Which of these should go into the release notes for 0.4.5?",
        header: "Notes",
        options: [
            .init(label: "Question face", description: "Every option stays in view, descriptions shorten to fit, and the glyph moves to the corner while a question is up."),
            .init(label: "Approvals", description: "Approve and Deny from the notch now show the exact command across two lines, cut from the middle so both ends survive."),
            .init(label: "Keep-awake", description: "The Mac stays awake while Claude works, shown as a cup in the panel's top row only while the hold is actually taken."),
            .init(label: "Output switching", description: "Pick the output device and set its volume from the music face, with a note when the switch is something Isle can't do."),
        ],
        multiSelect: true
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
        ] + descriptionModes + worstCases + liveExtras
    }

    /// The most `AskUserQuestion` sends at once (four options a question,
    /// four questions an ask): four long descriptions under Full, alone and
    /// as the multi-select step of a four-question ask in Both mode, where
    /// the corner toggle narrows the rows.
    static var worstCases: [ClaudePanelFixture] {
        [
            .init(name: "question_4long_full", state: .needsQuestion,
                  request: question([fourLong]), descriptions: .full),
            .init(name: "both_question_4long_full", mode: .both, state: .needsQuestion,
                  request: question([fourLong]), descriptions: .full),
            .init(name: "both_question_worst_full", mode: .both, state: .needsQuestion,
                  request: question([fourLong, fourLongMulti, threeOptions, thirdQuestion]),
                  questionIndex: 1, picks: [["Leave it"], ["Approvals", "Keep-awake"], [], []],
                  descriptions: .full),
            .init(name: "question_4long_multi_oneLine", state: .needsQuestion,
                  request: question([fourLongMulti]), picks: [["Question face"]], descriptions: .oneLine),
        ]
    }

    /// Two, three and four options under each description setting, and the
    /// same in Both mode where the corner toggle narrows the rows.
    static var descriptionModes: [ClaudePanelFixture] {
        OptionDescriptions.allCases.flatMap { mode in
            [
                ClaudePanelFixture(name: "question_2_\(mode.rawValue)", state: .needsQuestion,
                                   request: question([twoOptions]), descriptions: mode),
                ClaudePanelFixture(name: "question_3_\(mode.rawValue)", state: .needsQuestion,
                                   request: question([threeOptions]), descriptions: mode),
                ClaudePanelFixture(name: "question_4_\(mode.rawValue)", state: .needsQuestion,
                                   request: question([fourOptions]), descriptions: mode),
                ClaudePanelFixture(name: "both_question_4_\(mode.rawValue)", mode: .both, state: .needsQuestion,
                                   request: question([fourOptions]), descriptions: mode),
                ClaudePanelFixture(name: "question_multi_\(mode.rawValue)", state: .needsQuestion,
                                   request: question([twoOptions, multiSelect, thirdQuestion]),
                                   questionIndex: 1, picks: [["Run now"], ["Unit tests"], []],
                                   descriptions: mode),
            ]
        }
    }

    /// The marks that ride along with any state: the keep-awake hold and
    /// other live sessions.
    static var liveExtras: [ClaudePanelFixture] {
        [
            .init(name: "keepawake_working", state: .working, action: "Bash", target: "swift",
                  keepAwake: true),
            .init(name: "keepawake_others_working", state: .working, action: "Read", target: "ROADMAP.md",
                  keepAwake: true, others: .init(working: 2)),
            .init(name: "others_approval", state: .needsApproval, action: "Bash", target: "git",
                  request: approval("Bash", "git push --force-with-lease origin feature/claude-panel-rework"),
                  keepAwake: true, others: .init(working: 1, needYou: 1)),
            .init(name: "others_question", state: .needsQuestion, request: question([fourOptions]),
                  keepAwake: true, others: .init(working: 1)),
            .init(name: "both_keepawake_failed", mode: .both, state: .failed, errorType: "overloaded",
                  keepAwake: true, others: .init(working: 1)),
            .init(name: "long_project", state: .done, project: "an-extremely-long-project-directory-name",
                  keepAwake: true, others: .init(working: 3)),
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
