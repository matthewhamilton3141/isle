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
    var reviewingRemember = false
    var picks: [Set<String>] = []
    var descriptions: OptionDescriptions = .default
    var keepAwake = false
    var others = ClaudeOtherSessions()
    /// Where the session is on screen (Milestone 11): the Jump pill, and
    /// whether a reply can be typed.
    var host: ClaudeSessionHost? = nil
    var composing: ComposeKind? = nil
    var replyDraft = ""
    var answerDraft = ""
    var denialDraft = ""
    var delivery: ReplyDelivery = .none

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

    /// An approval decoded by the app's own decoder from a hook's stdin —
    /// the payloads below are ones Claude Code 2.1.318 sent (scratch paths
    /// swapped for plausible ones), so the face is checked against what
    /// actually arrives rather than against a hand-built request.
    static func approval(stdin: String) -> ClaudeRequest {
        ClaudeRequestWatcher.decode(stdin: Data(stdin.utf8), id: "preview-session-1762300000-4242")!
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

    // MARK: Approval payloads

    /// Wraps a tool call in the PermissionRequest envelope.
    private static func permissionRequest(_ tool: String, input: String, suggestions: String = "[]",
                                          extra: String = "") -> String {
        #"{"session_id":"preview-session","cwd":"/Users/matthew/Documents/isle","hook_event_name":"PermissionRequest","permission_mode":"default","tool_name":""#
            + tool + #"","tool_input":"# + input + #","permission_suggestions":"# + suggestions + extra + "}"
    }

    static let bashShortStdin = permissionRequest("Bash",
        input: #"{"command":"python3 -c 'print(42)'","description":"Print 42 using python3"}"#,
        suggestions: #"[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"python3 -c 'print(42)'"}],"behavior":"allow","destination":"localSettings"}]"#)

    static let bashPrefixStdin = permissionRequest("Bash",
        input: #"{"command":"npm run build -- --prod","description":"Run npm build with prod flag"}"#,
        suggestions: #"[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"npm run *"}],"behavior":"allow","destination":"localSettings"}]"#)

    static let bashQuotesStdin = permissionRequest("Bash",
        input: #"{"command":"echo \"it's a \\\"quoted\\\" value\" > made-quotes.txt","description":"Write quoted value"}"#,
        suggestions: #"[{"type":"addDirectories","directories":["/Users/matthew/Documents/isle"],"destination":"session"}]"#)

    static let bashMultilineStdin = permissionRequest("Bash",
        input: #"{"command":"cat > made-multi.txt <<'EOF'\nfirst line\nsecond line with \"quotes\"\nEOF\nwc -l made-multi.txt","description":"Write two-line file and count its lines"}"#,
        suggestions: #"[{"type":"addDirectories","directories":["/Users/matthew/Documents/isle"],"destination":"session"}]"#)

    /// A Bash call whose suggestion is a *Read* rule — the label has to come
    /// from the suggestion, not the tool.
    static let bashReadRuleStdin = permissionRequest("Bash",
        input: #"{"command":"find /etc -maxdepth 1 -name '*.conf' 2>/dev/null | sort","description":"List top-level .conf files in /etc"}"#,
        suggestions: #"[{"type":"addRules","rules":[{"toolName":"Read","ruleContent":"//private/etc/**"}],"behavior":"allow","destination":"session"}]"#)

    /// From inside a subagent: no suggestions at all.
    static let subagentBashStdin = permissionRequest("Bash",
        input: #"{"command":"echo \"TOTAL_FILES: $(find . -type f | wc -l)\" && echo \"TOTAL_DIRS: $(find . -mindepth 1 -type d | wc -l)\"","description":"Count files and directories"}"#,
        extra: #","agent_id":"a81a74a2ca45ef80f","agent_type":"general-purpose""#)

    static let editStdin = permissionRequest("Edit",
        input: #"{"file_path":"/Users/matthew/Documents/isle/Isle/Notch/NotchMetrics.swift","old_string":"    static let expandedSize = CGSize(width: 520, height: 146)","new_string":"    static let expandedSize = CGSize(width: 520, height: 152)","replace_all":false}"#,
        suggestions: #"[{"type":"setMode","mode":"acceptEdits","destination":"session"}]"#)

    static let editMultilineStdin = permissionRequest("Edit",
        input: #"{"file_path":"/Users/matthew/Documents/isle/Isle/Claude/ClaudeRequestWatcher.swift","old_string":"        case .deny:\n            guard request.kind == .approval else { return nil }","new_string":"        case .deny:\n            // Claude hears this as the tool's result.\n            guard request.kind == .approval else { return nil }\n            log(\"deny\")","replace_all":false}"#,
        suggestions: #"[{"type":"setMode","mode":"acceptEdits","destination":"session"}]"#)

    static let writeStdin = permissionRequest("Write",
        input: #"{"file_path":"/Users/matthew/Documents/isle/integration/claude-code-hooks/README.md","content":"alpha\nbeta\ngamma\n"}"#,
        suggestions: #"[{"type":"setMode","mode":"acceptEdits","destination":"session"}]"#)

    static let notebookStdin = permissionRequest("NotebookEdit",
        input: #"{"notebook_path":"/Users/matthew/Documents/analysis/palette-extraction.ipynb","cell_id":"c1","new_source":"print('bye')","edit_mode":"replace"}"#,
        suggestions: #"[{"type":"setMode","mode":"acceptEdits","destination":"session"}]"#)

    static let webFetchStdin = permissionRequest("WebFetch",
        input: #"{"url":"https://developer.apple.com/documentation/swiftui/imagerenderer?language=swift","prompt":"Report the page title, the main topics, and any key facts."}"#,
        suggestions: #"[{"type":"addRules","destination":"localSettings","rules":[{"toolName":"WebFetch","ruleContent":"domain:developer.apple.com"}],"behavior":"allow"}]"#,
        extra: #","agent_id":"a62257eb7251b2000","agent_type":"web-fetch""#)

    static let webSearchStdin = permissionRequest("WebSearch",
        input: #"{"query":"swift ImageRenderer scale","mode":"standard"}"#,
        suggestions: #"[{"type":"addRules","rules":[{"toolName":"WebSearch"}],"behavior":"allow","destination":"localSettings"}]"#)

    static let mcpStdin = permissionRequest("mcp__acme__deploy_service",
        input: #"{"environment":"staging","service":"api-gateway"}"#,
        suggestions: #"[{"type":"addRules","rules":[{"toolName":"mcp__acme__deploy_service"}],"behavior":"allow","destination":"localSettings"}]"#,
        extra: #","mcp_server":{"name":"acme","source":"dynamic"}"#)

    static let mcpIssueStdin = permissionRequest("mcp__acme__create_issue",
        input: #"{"title":"Crash when the notch opens on an external display","body":"Steps:\n1. Plug in a monitor\n2. Hover the notch","labels":["bug","notch"]}"#,
        suggestions: #"[{"type":"addRules","rules":[{"toolName":"mcp__acme__create_issue"}],"behavior":"allow","destination":"localSettings"}]"#,
        extra: #","mcp_server":{"name":"acme","source":"dynamic"}"#)

    static let readOutsideStdin = permissionRequest("Read",
        input: #"{"file_path":"/etc/hosts"}"#,
        suggestions: #"[{"type":"addRules","rules":[{"toolName":"Read","ruleContent":"//etc/**"}],"behavior":"allow","destination":"session"},{"type":"addRules","rules":[{"toolName":"Read","ruleContent":"//private/etc/**"}],"behavior":"allow","destination":"session"}]"#)

    static let planStdin = ##"{"session_id":"preview-session","cwd":"/Users/matthew/Documents/isle","hook_event_name":"PermissionRequest","permission_mode":"plan","tool_name":"ExitPlanMode","tool_input":{"plan":"# Plan: add made-plan.txt\n\n## Context\nAdd a file `made-plan.txt` containing the word \"hi\" to the project root.\n\n## Steps\n1. Create `made-plan.txt` in the working directory with the Write tool.\n2. Set its contents to exactly `hi`.\n3. Verify by reading the file back and confirming it contains `hi`.\n","planFilePath":"/Users/matthew/.claude/plans/plan-how-to-add-serialized-honey.md"}}"##

    /// One approval per tool kind that raised a prompt in 2.1.318.
    static var approvalKinds: [ClaudePanelFixture] {
        [
            .init(name: "approval_bash_short", state: .needsApproval, action: "Bash", target: "python3",
                  request: approval(stdin: bashShortStdin)),
            .init(name: "approval_bash_prefix", state: .needsApproval, action: "Bash", target: "npm",
                  request: approval(stdin: bashPrefixStdin)),
            .init(name: "approval_bash_quotes", state: .needsApproval, action: "Bash", target: "echo",
                  request: approval(stdin: bashQuotesStdin)),
            .init(name: "approval_bash_multiline", state: .needsApproval, action: "Bash", target: "cat",
                  request: approval(stdin: bashMultilineStdin)),
            .init(name: "approval_bash_readrule", state: .needsApproval, action: "Bash", target: "find",
                  request: approval(stdin: bashReadRuleStdin)),
            .init(name: "approval_bash_subagent_nosugg", state: .needsApproval, action: "Bash", target: "echo",
                  request: approval(stdin: subagentBashStdin)),
            .init(name: "approval_edit_real", state: .needsApproval, action: "Edit", target: "NotchMetrics.swift",
                  request: approval(stdin: editStdin)),
            .init(name: "approval_edit_multiline", state: .needsApproval, action: "Edit", target: "ClaudeRequestWatcher.swift",
                  request: approval(stdin: editMultilineStdin)),
            .init(name: "approval_write", state: .needsApproval, action: "Write", target: "README.md",
                  request: approval(stdin: writeStdin)),
            .init(name: "approval_notebook", state: .needsApproval, action: "NotebookEdit", target: "palette-extraction.ipynb",
                  request: approval(stdin: notebookStdin)),
            .init(name: "approval_webfetch", state: .needsApproval, action: "WebFetch", target: "https://developer.apple.com",
                  request: approval(stdin: webFetchStdin)),
            .init(name: "approval_websearch", state: .needsApproval, action: "WebSearch", target: "swift ImageRenderer scale",
                  request: approval(stdin: webSearchStdin)),
            .init(name: "approval_mcp", state: .needsApproval, action: "mcp__acme__deploy_service",
                  request: approval(stdin: mcpStdin)),
            .init(name: "approval_mcp_issue", state: .needsApproval, action: "mcp__acme__create_issue",
                  request: approval(stdin: mcpIssueStdin)),
            .init(name: "approval_read_outside", state: .needsApproval, action: "Read", target: "hosts",
                  request: approval(stdin: readOutsideStdin)),
            .init(name: "approval_plan", state: .needsApproval, action: "ExitPlanMode",
                  request: approval(stdin: planStdin)),
            .init(name: "both_approval_prefix", mode: .both, state: .needsApproval, action: "Bash", target: "npm",
                  request: approval(stdin: bashPrefixStdin)),
            .init(name: "both_approval_mcp", mode: .both, state: .needsApproval, action: "mcp__acme__deploy_service",
                  request: approval(stdin: mcpStdin)),
            .init(name: "both_approval_plan", mode: .both, state: .needsApproval, action: "ExitPlanMode",
                  request: approval(stdin: planStdin)),
            .init(name: "others_approval_edit", state: .needsApproval, action: "Edit", target: "NotchMetrics.swift",
                  request: approval(stdin: editStdin), keepAwake: true, others: .init(working: 1, needYou: 1)),
            .init(name: "approval_bash_touch", state: .needsApproval, action: "Bash", target: "touch",
                  request: approval(stdin: bashTouchStdin)),
        ] + rememberReviews
    }

    /// `touch` in the project: Claude Code offers the directory *and*
    /// acceptEdits together (M7 finding 9), as one terminal option.
    static let bashTouchStdin = permissionRequest("Bash",
        input: #"{"command":"touch made-1.txt","description":"Create made-1.txt"}"#,
        suggestions: #"[{"type":"addDirectories","directories":["/Users/matthew/Documents/isle"],"destination":"session"},{"type":"setMode","mode":"acceptEdits","destination":"session"}]"#)

    /// The second step of "Always…", for each shape of suggestion.
    static var rememberReviews: [ClaudePanelFixture] {
        [
            ("review_bash_short", bashShortStdin), ("review_bash_prefix", bashPrefixStdin),
            ("review_bash_touch", bashTouchStdin), ("review_bash_readrule", bashReadRuleStdin),
            ("review_edit", editStdin), ("review_webfetch", webFetchStdin), ("review_websearch", webSearchStdin),
            ("review_mcp", mcpStdin), ("review_read_outside", readOutsideStdin),
        ].map { name, stdin in
            ClaudePanelFixture(name: name, state: .needsApproval, request: approval(stdin: stdin),
                               reviewingRemember: true)
        } + [
            .init(name: "both_review_bash_prefix", mode: .both, state: .needsApproval,
                  request: approval(stdin: bashPrefixStdin), reviewingRemember: true),
        ]
    }

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
        ] + approvalKinds + descriptionModes + worstCases + liveExtras + jumpAndReply
    }

    // MARK: Jump and reply (Milestone 11)

    static func host(_ name: String, _ bundle: String, tty: String? = "/dev/ttys003",
                     tmux: Bool = false) -> ClaudeSessionHost {
        ClaudeSessionHost(
            app: .init(name: name, bundleIdentifier: bundle, pid: 4242, bundleURL: nil),
            sessionTTY: tmux ? "/dev/ttys009" : tty,
            tabTTY: tty,
            tmux: tmux ? TmuxPane(binary: "/opt/homebrew/bin/tmux", socket: "/private/tmp/tmux-501/default",
                                  pane: "%3", clientTTY: tty) : nil,
            kitty: nil
        )
    }

    static let terminalHost = host("Terminal", "com.apple.Terminal")
    static let iTermHost = host("iTerm", "com.googlecode.iterm2")
    static let reply = "Yes, and bump the version to 0.4.5 first"

    /// Every host the pill can name, the reply field at rest, typing,
    /// sending, sent and failed, and the request faces' own fields.
    static var jumpAndReply: [ClaudePanelFixture] {
        [
            .init(name: "jr_terminal_done", state: .done, host: terminalHost),
            .init(name: "jr_iterm_waiting", state: .waitingInput, host: iTermHost),
            .init(name: "jr_tmux_in_terminal_idle", state: .idle, host: host("Terminal", "com.apple.Terminal", tmux: true)),
            .init(name: "jr_ghostty_done", state: .done, host: host("Ghostty", "com.mitchellh.ghostty")),
            .init(name: "jr_vscode_done", state: .done, host: host("VS Code", "com.microsoft.VSCode")),
            .init(name: "jr_cursor_waiting", state: .waitingInput, host: host("Cursor", "com.todesktop.230313mzl4w4u92")),
            .init(name: "jr_terminal_working", state: .working, action: "Bash", target: "xcodebuild", host: terminalHost),
            .init(name: "jr_unresolved_done", state: .done, host: nil),
            .init(name: "jr_reply_composing_empty", state: .waitingInput, host: terminalHost, composing: .reply),
            .init(name: "jr_reply_composing", state: .waitingInput, host: terminalHost, composing: .reply,
                  replyDraft: reply),
            .init(name: "jr_reply_draft_kept", state: .done, host: terminalHost, replyDraft: reply),
            .init(name: "jr_reply_sending", state: .waitingInput, host: terminalHost, delivery: .sending(reply)),
            .init(name: "jr_reply_sent", state: .working, host: terminalHost, delivery: .sent(reply)),
            .init(name: "jr_reply_failed_permission", state: .done, host: terminalHost, replyDraft: reply,
                  delivery: .failed(text: reply, reason: "Allow Isle to control Terminal in Privacy › Automation")),
            .init(name: "jr_reply_failed_unconfirmed", state: .waitingInput, host: terminalHost, replyDraft: reply,
                  delivery: .failed(text: reply, reason: "Typed into Terminal, but Claude didn't take it — check its prompt")),
            .init(name: "jr_reply_failed_busy", state: .done, host: terminalHost, replyDraft: reply,
                  delivery: .failed(text: reply, reason: "Claude isn't at its prompt right now")),
            .init(name: "jr_both_terminal_done", mode: .both, state: .done, host: terminalHost),
            .init(name: "jr_both_reply_composing", mode: .both, state: .waitingInput, host: terminalHost,
                  composing: .reply, replyDraft: reply),
            .init(name: "jr_others_keepawake_done", state: .done, keepAwake: true,
                  others: .init(working: 1, needYou: 1), host: terminalHost),
            // The request faces: their own fields, on every host.
            .init(name: "jr_question_type_pill", state: .needsQuestion, request: question([fourOptions]),
                  host: terminalHost),
            .init(name: "jr_question_typing", state: .needsQuestion, request: question([fourOptions]),
                  host: terminalHost, composing: .answer, answerDraft: "Mango, and make it a smoothie"),
            .init(name: "jr_question_multi_typing", state: .needsQuestion,
                  request: question([twoOptions, multiSelect, thirdQuestion]), questionIndex: 1,
                  picks: [["Run now"], [], []], host: terminalHost, composing: .answer,
                  answerDraft: "Only the unit tests, skip the rest"),
            .init(name: "jr_both_question_type_pill", mode: .both, state: .needsQuestion,
                  request: question([fourLongMulti]), picks: [["Approvals"]], descriptions: .full),
            .init(name: "jr_approval_tell_pill", state: .needsApproval, action: "Bash", target: "npm",
                  request: approval("Bash", "npm run lint -- --fix"), host: terminalHost),
            .init(name: "jr_approval_tell_pill_always", state: .needsApproval, action: "Bash", target: "npm",
                  request: approval(stdin: bashPrefixStdin), host: terminalHost),
            .init(name: "jr_approval_denying", state: .needsApproval, action: "Bash", target: "npm",
                  request: approval(stdin: bashPrefixStdin), host: terminalHost, composing: .denial,
                  denialDraft: "Run the tests first, then the build"),
            .init(name: "jr_approval_denying_empty", state: .needsApproval, action: "Edit", target: "NotchMetrics.swift",
                  request: approval(stdin: editStdin), composing: .denial),
            .init(name: "jr_plan_denying", state: .needsApproval, action: "ExitPlanMode",
                  request: approval(stdin: planStdin), composing: .denial,
                  denialDraft: "Put the file under Isle/Debug instead"),
            .init(name: "jr_both_approval_tell_pill_always", mode: .both, state: .needsApproval, action: "Bash",
                  target: "npm", request: approval(stdin: bashPrefixStdin)),
        ]
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
            .frame(width: NotchMetrics.expandedSize.width + 40, height: NotchMetrics.panelMaxHeight + 20)
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
