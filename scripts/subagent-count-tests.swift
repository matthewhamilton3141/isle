//
//  subagent-count-tests.swift
//
//  The app's side of subagents, counted (Milestone 22): the record parser on
//  status files isle-cli wrote in scripts/test-subagent-count.sh (passed in
//  as a directory), and the line the face and the home tile show —
//  grouping, order, "+N", plugin names. Compiled with every Isle source.
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

typealias S = ClaudeSubagents

@main
enum Tests {
    @MainActor
    static func main() {
        let records = URL(fileURLWithPath: CommandLine.arguments[1])
        NSApplication.shared.setActivationPolicy(.prohibited)
        parserTests(records)
        groupTests()
        lineTests()
        rowTests()
        livenessTests()
        print("\nswift: \(passes) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - Parsing

    static func record(_ url: URL) -> ClaudeStatus? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return ClaudeStatusWatcher.decode(data, fileStem: url.deletingPathExtension().lastPathComponent)
    }

    static func parserTests(_ records: URL) {
        print("The record")
        let one = record(records.appendingPathComponent("one.json"))
        equal(one?.subagents, ["Explore"], "isle-cli's record with one agent")
        equal(one?.state, .working, "and its state")
        equal(record(records.appendingPathComponent("three.json"))?.subagents,
              ["Explore", "Explore", "Plan"], "three, in the order they started")
        equal(record(records.appendingPathComponent("odd.json"))?.subagents,
              ["feature-dev:code-reviewer", "evil", ""], "odd types still decode")

        let old = #"{"state":"working","project":"isle","session_id":"s1","updated_at":"2026-11-08T00:00:00Z"}"#
        equal(ClaudeStatusWatcher.decode(Data(old.utf8), fileStem: "s1")?.subagents, [],
              "a record from an older helper: none")
        let empty = #"{"state":"done","session_id":"s1","subagents":[]}"#
        equal(ClaudeStatusWatcher.decode(Data(empty.utf8), fileStem: "s1")?.subagents, [], "an empty list")
    }

    // MARK: - Grouping

    static func groupTests() {
        print("Grouping")
        equal(S.groups(["Plan", "Explore", "Explore"]),
              [.init(type: "Explore", count: 2), .init(type: "Plan", count: 1)], "most of a kind first")
        equal(S.groups(["B", "A", "A", "B", "C"]),
              [.init(type: "B", count: 2), .init(type: "A", count: 2), .init(type: "C", count: 1)],
              "between equal counts, the one that started first")
        equal(S.groups(["Explore", "", "Explore"]), [.init(type: "Explore", count: 2)],
              "an agent with no type is in no group")
        equal(S.groups(["pr-review-toolkit:silent-failure-hunter", "silent-failure-hunter"]),
              [.init(type: "silent-failure-hunter", count: 2)], "a plugin's agent by its own name")
        equal(S.displayName("feature-dev:code-reviewer"), "code-reviewer", "plugin prefix dropped")
        equal(S.displayName("Explore"), "Explore", "a built-in as is")
        equal(S.displayName("odd:"), "odd:", "nothing after the colon: kept whole")
    }

    // MARK: - The line

    static func lineTests() {
        print("The line")
        equal(S.line([], naming: 3), nil, "nothing running: no line")
        equal(S.lines([]), [], "nothing running: no forms")
        equal(S.line(["Explore"], naming: 1), "1 agent · Explore", "one")
        equal(S.line(["Explore", "Plan", "Explore"], naming: 2), "3 agents · Explore ×2, Plan", "the roadmap's example")
        equal(S.line(["Explore", "Plan", "Explore"], naming: 1), "3 agents · Explore ×2, +1",
              "+N counts the agents not named")
        equal(S.line(["Explore", "Plan", "Explore"], naming: 0), "3 agents", "naming none: the count")
        equal(S.line(["Explore", "Plan"], naming: 9), "2 agents · Explore, Plan", "naming more kinds than there are")
        equal(S.line(["", ""], naming: 2), "2 agents", "no types at all: the count")
        equal(S.line(["Explore", ""], naming: 1), "2 agents · Explore, +1", "an untyped agent is a +1")
        let many = ["Explore", "Plan", "general-purpose", "Explore", "statusline-setup",
                    "claude-code-guide", "Explore", "code-reviewer"]
        equal(S.lines(many), [
            "8 agents · Explore ×3, Plan, general-purpose, statusline-setup, claude-code-guide, code-reviewer",
            "8 agents · Explore ×3, Plan, general-purpose, statusline-setup, claude-code-guide, +1",
            "8 agents · Explore ×3, Plan, general-purpose, statusline-setup, +2",
            "8 agents · Explore ×3, Plan, general-purpose, +3",
            "8 agents · Explore ×3, Plan, +4",
            "8 agents · Explore ×3, +5",
            "8 agents",
        ], "every form, fullest first, the count last")
        equal(S.lines(["Explore"]), ["1 agent · Explore", "1 agent"], "one: named, then counted")

        print("The activity line's tail")
        equal(S.briefs([]), [], "nothing running: no tail")
        equal(S.briefs(["general-purpose"]), ["1 agent"], "one general-purpose: just the count")
        equal(S.briefs([""]), ["1 agent"], "one untyped: just the count")
        equal(S.briefs(["Explore"]), ["Explore agent", "1 agent"], "one named: its type, then the count")
        equal(S.briefs(["feature-dev:code-reviewer"]), ["code-reviewer agent", "1 agent"],
              "one plugin agent: by its own name")
        equal(S.briefs(["Explore", "Plan", "Explore"]), ["3 agents"], "several: the count, types in the tooltip")
        equal(S.briefs(["general-purpose", "general-purpose"]), ["2 agents"], "several general-purpose: the count")
        equal(S.briefs(manyTypes()), ["8 agents"], "many kinds: still the count")
    }

    static func manyTypes() -> [String] {
        ["Explore", "Plan", "general-purpose", "Explore", "statusline-setup",
         "claude-code-guide", "Explore", "code-reviewer"]
    }

    // MARK: - Liveness (v17)

    /// Agents outlive their turn now, so a session's process is what ends
    /// them when no SessionEnd came: its registry record, read by the
    /// registry's own scan (a scratch directory, a dead pid and this one).
    static func livenessTests() {
        print("Liveness: a session's agents go with its process")
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("isle-subagent-liveness-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dead = Process()
        dead.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try? dead.run()
        dead.waitUntilExit()
        let me = ProcessInfo.processInfo.processIdentifier
        func write(_ pid: Int32, _ session: String) {
            let json = #"{"pid":\#(pid),"sessionId":"\#(session)","cwd":"/tmp/work","kind":"interactive","status":"idle"}"#
            try? Data(json.utf8).write(to: dir.appendingPathComponent("\(pid).json"))
        }
        write(me, "alive")
        write(dead.processIdentifier, "killed")
        let live = Set(ClaudeSessionRegistry.scan(dir).map(\.sessionId))
        equal(live, ["alive"], "the registry's scan: the dead pid's record left behind, not listed")
        let agents = ["Explore", "Plan"]
        equal(S.counted(agents, sessionId: "alive", live: live), agents, "a live session keeps its agents, past its turn")
        equal(S.counted(agents, sessionId: "killed", live: live), [], "its pid gone (no SessionEnd): none")
        equal(S.counted(agents, sessionId: nil, live: live), [], "no session id to check: none")
        equal(S.counted(agents, sessionId: "alive", live: []), [], "a registry listing nobody vouches for nobody")
        equal(S.counted([], sessionId: "alive", live: live), [], "none running: none")

        // The CLI's status words (2.1.317-2.1.319): `shell` is at the prompt
        // with a background command running, so a reply may be typed there.
        for (word, atPrompt) in [("idle", true), ("shell", true), ("busy", false), ("waiting", false), ("dialog", false)] {
            let json = #"{"pid":\#(me),"sessionId":"alive","cwd":"/tmp/work","kind":"interactive","status":"\#(word)"}"#
            try? Data(json.utf8).write(to: dir.appendingPathComponent("\(me).json"))
            let status = ClaudeSessionRegistry.scan(dir).first?.status
            equal(status?.isAtPrompt, atPrompt, "status \(word): at the prompt \(atPrompt)")
        }
    }

    // MARK: - Session rows

    static func rowTests() {
        print("Session rows")
        func status(_ state: ClaudeCodeState, _ agents: [String]) -> ClaudeStatus {
            ClaudeStatus(state: state, project: "isle", sessionId: "s1", action: "Bash", target: "rg",
                         subagents: agents)
        }
        equal(ClaudeSessionRow(status(.working, ["Explore", "Plan", "Explore"]), request: nil).detail,
              "3 agents · Running rg", "a working row counts them ahead of the tool")
        equal(ClaudeSessionRow(status(.working, []), request: nil).detail, "Running rg", "none: as before")
        equal(ClaudeSessionRow(status(.done, ["Explore"]), request: nil).detail, "Finished responding",
              "only a working row says so")
    }
}
