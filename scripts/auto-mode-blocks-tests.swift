//
//  auto-mode-blocks-tests.swift
//
//  The app's side of auto mode's blocks, shown (Milestone 23): the record
//  parser on status files isle-cli wrote in scripts/test-auto-mode-blocks.sh
//  (passed in as a directory), the reason read as a category or a refusal
//  without a judgment, the face's line, the toast, the session row, and when
//  a block is announced. Compiled with every Isle source.
//

import AppKit
import Foundation

var failures = 0
var passes = 0

func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    if ok {
        passes += 1
        print("  ok    \(name)")
    } else {
        failures += 1
        let more = detail()
        print("  FAIL  \(name)" + (more.isEmpty ? "" : "\n        \(more)"))
    }
}

func equal<T: Equatable>(_ got: T, _ want: T, _ name: String) {
    check(got == want, name, "want \(want)\n        got  \(got)")
}

func block(_ tool: String = "Bash", target: String? = "rm", command: String? = "rm -rf /tmp/build",
           cut: Bool = false, reason: String? = "[Irreversible Local Destruction]", count: Int = 1,
           id: String = "toolu_1") -> ClaudeBlock {
    ClaudeBlock(id: id, tool: tool, target: target, command: command, commandCut: cut, reason: reason,
                count: count, at: Date(timeIntervalSince1970: 1_794_124_000))
}

@main
enum Tests {
    @MainActor
    static func main() {
        let records = URL(fileURLWithPath: CommandLine.arguments[1])
        NSApplication.shared.setActivationPolicy(.prohibited)
        parserTests(records)
        reasonTests()
        objectTests()
        lineTests()
        toastTests()
        rowTests()
        announceTests()
        print("\nswift: \(passes) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - Parsing

    static func record(_ records: URL, _ name: String) -> ClaudeStatus? {
        let url = records.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return ClaudeStatusWatcher.decode(data, fileStem: "s1")
    }

    static func parserTests(_ records: URL) {
        print("The record")
        let real = record(records, "real.json")
        equal(real?.state, .working, "isle-cli's record after the real block: still working")
        equal(real?.toolActive, false, "and nothing running")
        equal(real?.action, nil, "the blocked call isn't the activity")
        let b = real?.blocked
        equal(b?.id, "toolu_012JgyzrLEk1tuqf9XYrQG4J", "the call's id")
        equal(b?.tool, "Bash", "its tool")
        equal(b?.target, "rm", "its program")
        equal(b?.command, #"rm -rf ../victim && echo "victim removed: $(test"#, "its command, unescaped, cut")
        equal(b?.commandCut, true, "said to be cut")
        equal(b?.reason, "[Shared Scratch Sweep]", "auto mode's reason")
        equal(b?.count, 1, "one so far")
        check(b?.at.map { abs($0.timeIntervalSinceNow) < 600 } == true, "a time it was written")
        let two = record(records, "two.json")?.blocked
        equal(two?.count, 2, "the second: counted")
        equal(two?.command, "git push --force origin main", "and the latest's command")
        equal(two?.commandCut, false, "whole")
        equal(record(records, "done.json")?.state, .done, "Done keeps it")
        check(record(records, "done.json")?.blocked != nil, "with its block")
        equal(record(records, "unchecked.json")?.blocked?.verdict, .unchecked, "a refusal without a judgment")
        let hostile = record(records, "hostile.json")?.blocked
        equal(hostile?.reason, "[A \"quoted\" \\ rule]\nsecond line", "a hostile reason reads back as sent")
        equal(hostile?.verdict, .blocked(category: "A \"quoted\" \\ rule"), "and its category")
        let write = record(records, "write.json")?.blocked
        equal(write?.tool, "Write", "another tool")
        equal(write?.command, nil, "no command")
        equal(write?.object, "Write settings.json", "the tool and the file")
        let bad = record(records, "bad-block.json")
        check(bad != nil, "a block that doesn't read leaves the record readable")
        equal(bad?.blocked, nil, "and is no block")
        let old = ClaudeStatusWatcher.decode(Data(#"{"state":"working","session_id":"s9"}"#.utf8), fileStem: "s9")
        equal(old?.blocked, nil, "an older helper's record: none")
        let null = ClaudeStatusWatcher.decode(Data(#"{"state":"done","blocked":null}"#.utf8), fileStem: "s9")
        equal(null?.blocked, nil, "null: none")
        let noTool = ClaudeStatusWatcher.decode(
            Data(#"{"state":"done","blocked":{"id":"t","tool":"","reason":"[X]","count":1}}"#.utf8), fileStem: "s9")
        equal(noTool?.blocked, nil, "a block without a tool says nothing")
    }

    // MARK: - The reason

    static func reasonTests() {
        print("The reason")
        equal(ClaudeBlock.verdict("[Shared Scratch Sweep]"), .blocked(category: "Shared Scratch Sweep"), "a category")
        equal(ClaudeBlock.verdict("[Git Destructive] force-pushes main"), .blocked(category: "Git Destructive"),
              "a category with words after it")
        equal(ClaudeBlock.verdict("Classifier unavailable"), .unchecked, "the classifier unavailable")
        equal(ClaudeBlock.verdict("Auto mode classifier transcript exceeded context window \u{2014} falling back to manual approval (try /compact to reduce conversation size)"),
              .unchecked, "the conversation too long for it")
        equal(ClaudeBlock.verdict("Auto mode unavailable \u{2014} stopped after repeated responses with no safety verdict"),
              .unchecked, "no verdict")
        equal(ClaudeBlock.verdict("Auto mode could not evaluate this action and is blocking it for safety"),
              .unchecked, "could not evaluate")
        equal(ClaudeBlock.verdict("Blocked by fast classifier"), .blocked(category: nil), "a judgment with no category")
        equal(ClaudeBlock.verdict("The server-side auto mode classifier judged this action dangerous (it gave no explanation)"),
              .blocked(category: nil), "the server's, unexplained")
        equal(ClaudeBlock.verdict(nil), .blocked(category: nil), "none at all")
        equal(ClaudeBlock.verdict("[ ]"), .blocked(category: nil), "empty brackets: no category")
        equal(ClaudeBlock.verdict("[" + String(repeating: "x", count: 80) + "]"), .blocked(category: nil),
              "too long for a rule's name")
        equal(block(reason: "Classifier unavailable").reasonClause, "couldn't check it", "said as couldn't check it")
        equal(block(reason: "Permission denied").reasonClause, nil, "Claude Code's default: no reason given")
    }

    // MARK: - What was blocked

    static func objectTests() {
        print("What was blocked")
        equal(block().object, "rm", "a command: its program")
        equal(block(target: nil, command: "$CMD --now").object, nil, "a program it couldn't name: none")
        equal(block("Monitor", target: "tail", command: "tail -f log").object, "tail", "Monitor too")
        equal(block("WebFetch", target: "https://www.example.dev/install.sh", command: nil).object,
              "WebFetch example.dev", "a URL: its host")
        equal(block("Edit", target: "/Users/matthew/.zshrc", command: nil).object, "Edit .zshrc", "a path: its name")
        equal(block("mcp__github__create_issue", target: nil, command: nil).object, "github create_issue",
              "an MCP tool by server and tool")
        equal(block().shownCommand, "rm -rf /tmp/build", "the command, when it starts with its program")
        equal(block(cut: true).shownCommand, "rm -rf /tmp/build…", "cut: an ellipsis")
        equal(block(target: "git", command: "cd /Users/matthew/Documents/isle && git pu", cut: true).shownCommand, nil,
              "a cd in front: not the command")
        equal(block(target: "git", command: "/usr/bin/git push").shownCommand, "/usr/bin/git push", "a path to it is fine")
    }

    // MARK: - The face's line

    static func lineTests() {
        print("The face's line")
        let one = block().lines.map(\.plain)
        equal(one.first, "Auto mode blocked rm -rf /tmp/build · Irreversible Local Destruction", "fullest first")
        equal(Array(one.dropFirst().prefix(2)),
              ["Auto mode blocked rm · Irreversible Local Destruction", "Blocked rm · Irreversible Local Destruction"],
              "then the program, keeping the reason")
        equal(one.last, "Blocked", "the shortest last")
        check(one.firstIndex(of: "Blocked rm · Irreversible Local Destruction")! < one.firstIndex(of: "Auto mode blocked rm -rf /tmp/build")!,
              "the reason outlasts the command's own words")
        equal(Set(one).count, one.count, "no form twice")
        let two = block(target: "git", command: "git push --force", reason: "[Git Destructive]", count: 2).lines.map(\.plain)
        equal(two.first, "Auto mode blocked 2 calls, last git push --force · Git Destructive", "two: counted")
        check(two.contains("Blocked 2, last git · Git Destructive"), "and its short form", "\(two)")
        equal(two.last, "Blocked 2", "the shortest keeps the count")
        let unchecked = block(reason: "Classifier unavailable").lines.map(\.plain)
        check(unchecked.contains("Auto mode blocked rm · couldn't check it"), "couldn't check it", "\(unchecked)")
        let none = block(reason: nil).lines.map(\.plain)
        check(!none.contains { $0.contains(" · ") }, "no reason: none invented", "\(none)")
        let unnamed = block(target: nil, command: nil, reason: "[X Y]").lines.map(\.plain)
        equal(unnamed.first, "Auto mode blocked a call · X Y", "nothing to name: a call")
        check(block().lines.first?.isCommand == true, "the command in the command's font")
        let help = block(target: "git", command: "git push --force", reason: "[Git Destructive]", count: 2).help
        check(help.contains("/permissions › Recently blocked"), "the tooltip says where to allow it", help)
        check(help.contains("Git Destructive") && help.contains("git push --force") && help.contains("2 calls"),
              "with the call, the rule and the count", help)
        check(block(reason: "Classifier unavailable").help.contains("couldn't check rm -rf /tmp/build (Classifier unavailable)"),
              "a refusal without a judgment, in auto mode's words", block(reason: "Classifier unavailable").help)
        check(!block().help.lowercased().contains("approve"), "and never says Approve")
    }

    // MARK: - The toast

    @MainActor
    static func toastTests() {
        print("The toast")
        equal(block().toastText(project: nil), "Auto mode blocked rm", "the island's own session")
        equal(block(target: "git").toastText(project: "isle-website"), "isle-website · blocked git", "another session")
        let long = block(target: "git").toastText(project: "an-extremely-long-project-directory-name")
        check(long.hasSuffix(" · blocked git") && long.contains("…"), "a long project gives way", long)
        check(IslandToast.width(of: long) <= IslandToast.maxTextWidth, "and fits", "\(IslandToast.width(of: long))")
        let write = block("Write", target: "settings.json", command: nil).toastText(project: nil)
        check(IslandToast.width(of: write) <= IslandToast.maxTextWidth && write.hasPrefix("Blocked Write"),
              "another tool fits", write)
        equal(block(target: nil, command: "$X").toastText(project: nil), "Blocked a command", "a command it can't name")
        let toast = IslandToast.autoModeBlocked(block(), sessionId: "s1", project: nil)
        check(toast.coalesces(with: .autoModeBlocked(block(id: "t2"), sessionId: "s1", project: nil)),
              "a second in the same session replaces it")
        check(!toast.coalesces(with: .autoModeBlocked(block(), sessionId: "s2", project: "x")),
              "another session's waits its turn")
        equal(toast.gate, .claudeSessions, "on whenever the bridge is")
    }

    // MARK: - Session rows

    static func rowTests() {
        print("Session rows")
        func status(_ state: ClaudeCodeState, _ blocked: ClaudeBlock?, agents: [String] = []) -> ClaudeStatus {
            var s = ClaudeStatus(state: state, project: "isle", sessionId: "s1", action: nil, target: nil,
                                 subagents: agents)
            s.blocked = blocked
            return s
        }
        equal(ClaudeSessionRow(status(.working, block()), request: nil).detail, "Blocked rm · Thinking…",
              "a working row says it first")
        equal(ClaudeSessionRow(status(.working, block(count: 3), agents: ["Explore"]), request: nil).detail,
              "3 blocked · 1 agent · Thinking…", "counted, ahead of the agents")
        equal(ClaudeSessionRow(status(.working, nil), request: nil).detail, "Thinking…", "none: as before")
        equal(ClaudeSessionRow(status(.done, block()), request: nil).detail, "Finished responding",
              "only a working row says so")
    }

    // MARK: - When it's announced

    @MainActor
    static func announceTests() {
        print("When it's announced")
        let suite = "isle.tests.\(UUID().uuidString)"
        let settings = AppSettings(defaults: UserDefaults(suiteName: suite)!)
        settings.mode = .claude
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        func status(_ id: String, _ project: String, _ blocked: ClaudeBlock?,
                    _ state: ClaudeCodeState = .working, ago: TimeInterval = 5,
                    requestId: String? = nil) -> ClaudeStatus {
            var s = ClaudeStatus(state: state, project: project, sessionId: id,
                                 updatedAt: Date().addingTimeInterval(-ago), requestId: requestId)
            s.blocked = blocked
            return s
        }
        let vm = NotchViewModel(settings: settings)
        let quiet = status("s2", "isle-website", nil, .idle, ago: 60)
        vm.applyTestReading(statuses: [status("s1", "isle", nil), quiet], sessions: [])
        equal(vm.claudeSessionId, "s1", "(the island shows s1)")
        let first = block(id: "toolu_a")
        vm.announceBlocks(in: [status("s1", "isle", first), quiet])
        equal(vm.activeToast?.text, nil, "a block already there at the first reading: not news")
        vm.announceBlocks(in: [status("s1", "isle", first), quiet])
        equal(vm.activeToast?.text, nil, "read again: still not")
        vm.announceBlocks(in: [status("s1", "isle", block(count: 2, id: "toolu_b")), quiet])
        equal(vm.activeToast?.text, "Auto mode blocked rm", "a new one in the island's session")
        let shown = vm.activeToast?.id
        vm.announceBlocks(in: [status("s1", "isle", block(count: 2, id: "toolu_b")), quiet])
        equal(vm.activeToast?.id, shown, "the same one again: no second toast")
        var other = quiet
        other.blocked = block(target: "npm", id: "toolu_c")
        vm.announceBlocks(in: [status("s1", "isle", block(count: 2, id: "toolu_b")), other])
        equal(vm.activeToast?.id, shown, "another session's waits its turn")
        vm.announceBlocks(in: [status("s1", "isle", block(count: 3, id: "toolu_d")), other])
        check(vm.activeToast?.id != shown && vm.activeToast?.text == "Auto mode blocked rm",
              "a third in the same session replaces the one up", "\(String(describing: vm.activeToast?.text))")

        // An approval live on the island: the toast is dropped, as every
        // toast is; the face's line and the session row still say it.
        let alert = NotchViewModel(settings: settings)
        let website = status("website", "isle-website", nil, .needsApproval, ago: 1,
                             requestId: ClaudePanelFixture.websiteApproval.id)
        alert.applyTestReading(statuses: [status("s1", "isle", nil, ago: 30), website], sessions: [],
                               requests: [ClaudePanelFixture.websiteApproval])
        equal(alert.claudeState, .needsApproval, "(the island holds website's approval)")
        alert.announceBlocks(in: [status("s1", "isle", nil, ago: 30), website])
        alert.announceBlocks(in: [status("s1", "isle", block(id: "toolu_e"), ago: 30), website])
        equal(alert.activeToast?.text, nil, "an approval pending elsewhere holds the island: no toast")
        alert.announceBlocks(in: [status("s1", "isle", block(id: "toolu_e"), ago: 30), website])
        equal(alert.activeToast?.text, nil, "nor later, for the same block")

        // The island's own session's block reaches the face, state untouched.
        let face = NotchViewModel(settings: settings)
        face.applyTestReading(statuses: [status("s1", "isle", block(id: "toolu_f"))], sessions: [])
        equal(face.claudeBlock?.id, "toolu_f", "the face's block is the record's")
        equal(face.claudeState, .working, "and the state is untouched")
        face.applyTestReading(statuses: [status("s1", "isle", nil)], sessions: [])
        equal(face.claudeBlock, nil, "gone when the record's is")
    }
}
