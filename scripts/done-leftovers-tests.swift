//
//  done-leftovers-tests.swift
//
//  The app's side of "Done, unless it isn't" (Milestone 20): the record
//  parser on status files isle-cli wrote in scripts/test-done-leftovers.sh
//  (passed in as a directory), the wake-ups in words, and the lines the face,
//  the home tile and a session row show. Compiled with every Isle source.
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

typealias LO = ClaudeLeftovers

func shell(_ program: String?, _ run: String?, cut: Bool = false) -> LO.Task {
    .init(type: "shell", name: program, run: run, cut: cut)
}
func agent(_ type: String?) -> LO.Task { .init(type: "subagent", name: type) }

/// A fixed moment, Sunday 8 November 2026, 10:00 in this Mac's zone.
let sunday10 = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 8, hour: 10, minute: 0))!

func left(_ tasks: [LO.Task], more: Int = 0, wakes: [LO.Wake] = [], moreWakes: Int = 0) -> LO {
    LO(tasks: tasks, more: more, wakes: wakes, moreWakes: moreWakes, at: sunday10)
}

/// "9:00am" in this Mac's clock, as the line says it.
func clock(_ hour: Int, _ minute: Int) -> String {
    let d = Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: sunday10)!
    return ClaudeLimit.clock(d, now: d)
}

@main
enum Tests {
    @MainActor
    static func main() {
        let records = URL(fileURLWithPath: CommandLine.arguments[1])
        NSApplication.shared.setActivationPolicy(.prohibited)
        parserTests(records)
        nameTests()
        wakeTests()
        lineTests()
        rowTests()
        print("\nswift: \(passes) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - Parsing

    static func record(_ name: String, _ records: URL) -> ClaudeStatus? {
        let url = records.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return ClaudeStatusWatcher.decode(data, fileStem: "s1")
    }

    static func parserTests(_ records: URL) {
        print("The record")
        let one = record("real1.json", records)
        equal(one?.left?.tasks, [shell("sleep", "sleep 300"), agent("Explore")],
              "the real Stop: a shell and an agent")
        equal(one?.subagents, ["Explore"], "and the agent still counted until its own stop (v17)")
        check(one?.left?.at != nil, "with when the turn ended")
        let two = record("real2.json", records)
        equal(two?.left?.wakes, [.init(schedule: "0 9 9 11 *", recurring: false),
                                 .init(schedule: "0 * * * *", recurring: true)], "the real wake-ups")
        let kinds = record("kinds.json", records)?.left
        equal(kinds?.tasks.map(LO.shortName),
              ["watch_issues monitor", "release workflow", "run_suite", "cloud session", "code-reviewer agent"],
              "other kinds, named")
        let many = record("many.json", records)?.left
        equal(many.map { [$0.tasks.count, $0.more, $0.wakes.count, $0.moreWakes] }, [8, 2, 4, 1], "the counts")

        func decode(_ json: String) -> ClaudeStatus? {
            ClaudeStatusWatcher.decode(Data(json.utf8), fileStem: "s1")
        }
        equal(decode(#"{"state":"done","session_id":"s1"}"#)?.left, nil, "an older helper: nothing")
        equal(decode(#"{"state":"done","session_id":"s1","left":null}"#)?.left, nil, "null: nothing")
        equal(decode(#"{"state":"done","session_id":"s1","left":{"tasks":[],"crons":[]}}"#)?.left, nil,
              "empty: nothing")
        let odd = decode(#"{"state":"done","session_id":"s1","left":{"tasks":[{"type":"shell","name":"npm","run":"npm run dev","cut":false},{"name":"no type"},7],"crons":"x"}}"#)
        equal(odd?.left?.tasks, [shell("npm", "npm run dev")], "what doesn't read is dropped, not the record")
        equal(decode(#"{"state":"done","session_id":"s1","left":"x"}"#)?.state, .done, "a bad `left` keeps the record")
    }

    // MARK: - Names

    static func nameTests() {
        print("Names")
        equal(LO.longName(shell("npm", "npm run dev")), "npm run dev", "a shell by its words")
        equal(LO.shortName(shell("npm", "npm run dev")), "npm", "or its program")
        equal(LO.longName(shell("xcodebuild", "xcodebuild -project Isle.xcodeproj", cut: true)),
              "xcodebuild -project Isle.xcodeproj…", "cut words end in …")
        equal(LO.longName(shell(nil, nil)), "command", "a program it couldn't name")
        equal(LO.longName(agent("Explore")), "Explore agent", "an agent by its type")
        equal(LO.longName(agent("feature-dev:code-reviewer")), "code-reviewer agent", "a plugin's by its own name")
        equal(LO.longName(agent("my-agent")), "my-agent", "never \"agent agent\"")
        equal(LO.longName(agent(nil)), "agent", "an untyped one")
        equal(LO.longName(shell("echo", "echo a\nb")), "echo a b", "one line, whatever it holds")
    }

    // MARK: - Wake-ups

    static func wakeTests() {
        print("Wake-ups")
        func phrase(_ schedule: String, _ recurring: Bool, now: Date = sunday10) -> String? {
            LO.wakePhrase(.init(schedule: schedule, recurring: recurring), from: sunday10, now: now)
        }
        equal(phrase("30 14 8 11 *", false), clock(14, 30), "later today: the time")
        equal(phrase("0 9 9 11 *", false), ClaudeLimit.clock(
            Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 9))!, now: sunday10),
              "tomorrow morning: as a reset is said")
        equal(phrase("0 9 8 11 *", false), ClaudeLimit.clock(
            Calendar.current.date(from: DateComponents(year: 2027, month: 11, day: 8, hour: 9))!, now: sunday10),
              "a time already past this year is next year's")
        equal(phrase("30 14 8 11 *", false, now: sunday10.addingTimeInterval(5 * 3600)), nil,
              "a one-shot whose time has passed isn't said")
        equal(phrase("0 * * * *", true), "every hour", "hourly")
        equal(phrase("*/5 * * * *", true), "every 5 min", "every few minutes")
        equal(phrase("* * * * *", true), "every minute", "every minute")
        equal(phrase("15 */2 * * *", true), "every 2 hours", "every few hours")
        equal(phrase("0 9 * * *", true), "daily \(clock(9, 0))", "daily")
        equal(phrase("30 8 * * 1-5", true), "weekdays \(clock(8, 30))", "weekdays")
        equal(phrase("0 18 * * 5", true), "Fridays \(clock(18, 0))", "one weekday")
        equal(phrase("0 9 1 * *", true), "on a schedule", "anything else, recurring")
        equal(phrase("0 9 * * 1,3", false), "later", "an odd one-shot")
        equal(phrase("nonsense", true), "on a schedule", "not five fields")
    }

    // MARK: - The face's line

    static func lineTests() {
        print("The face's line")
        let real1 = left([shell("sleep", "sleep 300"), agent("Explore")])
        equal(real1.lines(now: sunday10), [
            "Left running: sleep 300 · Explore agent",
            "Left running: sleep · Explore agent",
            "Left running: sleep 300 · +1",
            "Left running: sleep · +1",
            "Left 2 tasks running",
        ], "every form, fullest first, the count last")
        equal(left([shell("npm", "npm run dev")]).lines(now: sunday10),
              ["Left running: npm run dev", "Left running: npm", "Left a task running"], "one task")
        let twice = left([agent("Explore"), shell("npm", "npm run dev"), agent("Explore")], more: 1)
        equal(twice.lines(now: sunday10).first, "Left running: Explore agent ×2 · npm run dev · +1",
              "the same name counted, the helper's rest as +N")
        equal(twice.lines(now: sunday10).last, "Left 4 tasks running", "and in the count")
        let wakes = left([], wakes: [.init(schedule: "30 14 8 11 *", recurring: false),
                                     .init(schedule: "0 * * * *", recurring: true)])
        equal(wakes.lines(now: sunday10), [
            "Wakes \(clock(14, 30)), every hour",
            "Wakes \(clock(14, 30)), +1",
            "2 wake-ups",
        ], "wake-ups only")
        let onTheHour = left([], wakes: [.init(schedule: "0 15 8 11 *", recurring: false)])
        if clock(15, 0).hasSuffix(":00pm") {
            equal(onTheHour.lines(now: sunday10), ["Wakes 3:00pm", "Wakes 3pm", "1 wake-up"],
                  "on the hour, the time gives way before the name")
        }
        let both = left([shell("sleep", "sleep 120")], wakes: wakes.wakes)
        equal(both.lines(now: sunday10).first, "Left running: sleep 120 · Wakes \(clock(14, 30)), every hour",
              "both: the tasks, then the wake-ups")
        equal(both.lines(now: sunday10).last, "Left a task running · 2 wake-ups", "both outlast everything")
        let past = left([], wakes: [.init(schedule: "30 14 8 11 *", recurring: false)])
        equal(past.shown(now: sunday10.addingTimeInterval(6 * 3600)), nil, "a wake-up that has passed: nothing to show")
        check(past.shown(now: sunday10) != nil, "before it: shown")
        check(real1.help(now: sunday10).contains("sleep 300, Explore agent"), "the tooltip names them all")
        check(real1.help(now: sunday10).contains("as of the turn's end"), "and says when it was so")
    }

    // MARK: - Session rows and the tile's last resort

    static func rowTests() {
        print("Session rows")
        func status(_ state: ClaudeCodeState, _ left: LO?) -> ClaudeStatus {
            ClaudeStatus(state: state, project: "isle", sessionId: "s1",
                         lastMessage: "The dev server is up.", left: left)
        }
        let one = left([shell("npm", "npm run dev")])
        equal(ClaudeSessionRow(status(.done, one), request: nil).detail, "Left npm running · The dev server is up.",
              "a done row says it first")
        equal(ClaudeSessionRow(status(.waitingInput, left([shell("a", "a"), agent("Plan")])), request: nil).detail,
              "Left 2 running · The dev server is up.", "several: counted")
        equal(ClaudeSessionRow(status(.idle, left([], wakes: [.init(schedule: "0 * * * *", recurring: true)])),
                               request: nil).detail,
              "Wakes every hour · The dev server is up.", "a wake-up alone")
        equal(ClaudeSessionRow(status(.done, nil), request: nil).detail, "The dev server is up.", "nothing: as before")
        equal(ClaudeSessionRow(status(.working, one), request: nil).detail, "Thinking…",
              "a working row never says it: that turn is over")
    }
}
