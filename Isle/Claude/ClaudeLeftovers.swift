//
//  ClaudeLeftovers.swift
//
//  Done, unless it isn't (Milestone 20): "Left running: npm run dev · Explore
//  agent", "Wakes 9:00am", from the record's `left` — what `isle-cli` kept
//  of Claude Code's `Stop` payload: the background work still in flight when
//  the turn ended (`background_tasks`) and the wake-ups scheduled for later
//  (`session_crons`).
//
//  What was so at the turn's end, and worded as that: "Left running", never
//  "Running". A task ending fires no hook of its own. It does wake the
//  session (Claude Code 2.1.319 submits a <task-notification> prompt), and
//  that prompt clears this, so the line goes with the turn it was said for.
//
//  A shell is named by its program and that program's words ("npm run dev"),
//  read by the helper from the whole command, so a `cd …` in front never
//  stands in for it; an agent by its type ("Explore agent"). Several are
//  listed as far as they fit, the rest counted as "+N", the way the
//  subagent line does it (`ClaudeSubagents`).
//
//  Pure, so the wording can be checked without a running bridge
//  (scripts/test-done-leftovers.sh).
//

import Foundation

struct ClaudeLeftovers: Equatable {
    /// One piece of background work in flight at the turn's end.
    struct Task: Equatable {
        /// Claude Code's label for its kind: `shell`, `subagent`, `monitor`,
        /// `workflow`, `MCP task`, `teammate`, `cloud session`, …
        var type: String
        /// A shell's program, an agent's type, a monitor's or an MCP task's
        /// tool, a workflow's name. Nil when the payload didn't say, or the
        /// command's program couldn't be named.
        var name: String?
        /// A shell's program and its words, up to the end of its own command
        /// and 48 characters ("npm run dev"). Nil for anything else.
        var run: String?
        /// `run` stops short of the command's own words.
        var cut = false
    }

    /// One scheduled wake-up: five cron fields in this Mac's time, and
    /// whether it fires on every match or once.
    struct Wake: Equatable {
        var schedule: String
        var recurring: Bool
    }

    var tasks: [Task]
    /// Tasks the helper didn't keep (past its eight).
    var more = 0
    var wakes: [Wake]
    /// Wake-ups past the helper's four.
    var moreWakes = 0
    /// When the turn ended: the helper's Stop write.
    var at: Date?

    var taskCount: Int { tasks.count + more }
    var wakeCount: Int { wakes.count + moreWakes }
    var isEmpty: Bool { taskCount == 0 && wakeCount == 0 }

    // MARK: - Naming the work

    /// What a task is called on the line at its fullest: a shell's words,
    /// an agent's type.
    static func longName(_ task: Task) -> String {
        if task.type == "shell", let run = task.run.flatMap(clean), !run.isEmpty {
            return task.cut ? run + "…" : run
        }
        return shortName(task)
    }

    /// The same at its shortest: a shell's program alone.
    static func shortName(_ task: Task) -> String {
        let name = task.name.flatMap(clean).flatMap { $0.isEmpty ? nil : $0 }
        switch task.type {
        case "shell":
            return name ?? "command"
        case "subagent":
            guard let name else { return "agent" }
            let shown = ClaudeSubagents.displayName(name)
            return shown.lowercased().hasSuffix("agent") ? shown : "\(shown) agent"
        case "monitor":
            return name.map { "\($0) monitor" } ?? "monitor"
        case "workflow":
            return name.map { "\($0) workflow" } ?? "workflow"
        case "MCP task":
            return name ?? "MCP task"
        default:
            return task.type.isEmpty ? "task" : task.type
        }
    }

    /// A name with nothing a single line can't hold.
    private static func clean(_ s: String) -> String {
        s.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }
            .joined()
            .trimmingCharacters(in: .whitespaces)
    }

    /// The tasks by name, in the order Claude Code listed them, the same
    /// name counted once with "×N".
    static func grouped(_ names: [String]) -> [(name: String, count: Int)] {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for name in names {
            if counts[name] == nil { order.append(name) }
            counts[name, default: 0] += 1
        }
        return order.map { ($0, counts[$0]!) }
    }

    /// "Left running: npm run dev · Explore agent", naming the first
    /// `naming` names, the rest as "+N" (N the tasks not named).
    private func taskLine(long: Bool, naming: Int) -> String {
        let groups = Self.grouped(tasks.map(long ? Self.longName : Self.shortName))
        let named = groups.prefix(max(0, naming))
        var parts = named.map { $0.count > 1 ? "\($0.name) ×\($0.count)" : $0.name }
        let rest = taskCount - named.reduce(0) { $0 + $1.count }
        if rest > 0, !parts.isEmpty { parts.append("+\(rest)") }
        guard !parts.isEmpty else { return countLine }
        return "Left running: " + parts.joined(separator: " · ")
    }

    /// "Left 3 tasks running", "Left a task running".
    private var countLine: String {
        taskCount == 1 ? "Left a task running" : "Left \(taskCount) tasks running"
    }

    /// Every form of the task part, fullest first, the bare count last.
    var taskLines: [String] {
        guard taskCount > 0 else { return [] }
        let kinds = Self.grouped(tasks.map(Self.longName)).count
        var lines: [String] = []
        for naming in stride(from: kinds, through: 1, by: -1) {
            for long in [true, false] {
                let line = taskLine(long: long, naming: naming)
                if !lines.contains(line) { lines.append(line) }
            }
        }
        if !lines.contains(countLine) { lines.append(countLine) }
        return lines
    }

    // MARK: - Wake-ups

    /// When a wake-up comes, in a few words: "9:00am", "Mon 9:00am",
    /// "every hour", "weekdays 9:00am". Nil for a one-shot whose time has
    /// passed: it has fired, or won't, and either way it's not still to come.
    func wakePhrase(_ wake: Wake, now: Date = Date()) -> String? {
        Self.wakePhrase(wake, from: at ?? now, now: now)
    }

    static func wakePhrase(_ wake: Wake, from: Date, now: Date) -> String? {
        let fields = wake.schedule.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard fields.count == 5 else { return wake.recurring ? "on a schedule" : "later" }
        let (minute, hour, day, month, weekday) = (fields[0], fields[1], fields[2], fields[3], fields[4])
        if !wake.recurring, let m = Int(minute), let h = Int(hour), let d = Int(day), let mo = Int(month),
           weekday == "*" {
            guard let date = nextDate(month: mo, day: d, hour: h, minute: m, after: from) else { return "later" }
            guard date > now else { return nil }
            return ClaudeLimit.clock(date, now: now)
        }
        if let phrase = repeating(minute: minute, hour: hour, day: day, month: month, weekday: weekday) {
            return phrase
        }
        return wake.recurring ? "on a schedule" : "later"
    }

    /// The first time at or after `after` (less a minute's grace) that the
    /// calendar reads month/day hour:minute, this year or the next.
    private static func nextDate(month: Int, day: Int, hour: Int, minute: Int, after: Date) -> Date? {
        let calendar = Calendar.current
        let year = calendar.component(.year, from: after)
        for y in [year, year + 1] {
            let parts = DateComponents(year: y, month: month, day: day, hour: hour, minute: minute)
            guard let date = calendar.date(from: parts),
                  calendar.component(.day, from: date) == day
            else { continue }
            if date >= after.addingTimeInterval(-60) { return date }
        }
        return nil
    }

    /// A recurring schedule in words, for the shapes CronCreate is asked for
    /// most; nil for anything else, which reads "on a schedule".
    private static func repeating(minute: String, hour: String, day: String, month: String,
                                  weekday: String) -> String? {
        guard day == "*", month == "*" else { return nil }
        func every(_ field: String) -> Int? {
            guard field.hasPrefix("*/"), let n = Int(field.dropFirst(2)), n > 0 else { return nil }
            return n
        }
        if hour == "*", weekday == "*" {
            if minute == "*" { return "every minute" }
            if let n = every(minute) { return n == 1 ? "every minute" : "every \(n) min" }
            if Int(minute) != nil { return "every hour" }
            return nil
        }
        guard let m = Int(minute), (0...59).contains(m) else { return nil }
        if let n = every(hour), weekday == "*" { return n == 1 ? "every hour" : "every \(n) hours" }
        guard let h = Int(hour), (0...23).contains(h) else { return nil }
        let time = timeOfDay(hour: h, minute: m)
        switch weekday {
        case "*": return "daily \(time)"
        case "1-5", "MON-FRI", "mon-fri": return "weekdays \(time)"
        case "0,6", "6,0", "SAT,SUN", "sat,sun": return "weekends \(time)"
        default:
            guard let d = Int(weekday), (0...7).contains(d) else { return nil }
            let names = ["Sundays", "Mondays", "Tuesdays", "Wednesdays", "Thursdays", "Fridays", "Saturdays"]
            return "\(names[d % 7]) \(time)"
        }
    }

    /// "9:00am", in this Mac's clock, as `ClaudeLimit` says a reset's time.
    private static func timeOfDay(hour: Int, minute: Int) -> String {
        let calendar = Calendar.current
        let date = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
        return ClaudeLimit.clock(date, now: date)
    }

    /// The wake-ups still to come, in words, in the order Claude Code listed
    /// them.
    func wakePhrases(now: Date = Date()) -> [String] {
        wakes.compactMap { wakePhrase($0, now: now) }
    }

    /// Every form of the wake-up part, fullest first: "Wakes 9:00am, every
    /// hour", "Wakes 9:00am, +1", "2 wake-ups".
    func wakeLines(now: Date = Date()) -> [String] {
        let phrases = wakePhrases(now: now)
        let count = phrases.count + moreWakes
        guard count > 0 else { return [] }
        var lines: [String] = []
        // On the hour, the time can lose its ":00" before a wake-up loses
        // its name: "Wakes Mon 9am" fits a tile "Wakes Mon 9:00am" doesn't.
        let onTheHour = phrases.map {
            $0.replacingOccurrences(of: ":00am", with: "am").replacingOccurrences(of: ":00pm", with: "pm")
        }
        for set in onTheHour == phrases ? [phrases] : [phrases, onTheHour] where !set.isEmpty {
            for naming in stride(from: set.count, through: 1, by: -1) {
                var parts = Array(set.prefix(naming))
                let rest = count - naming
                if rest > 0 { parts.append("+\(rest)") }
                let line = "Wakes " + parts.joined(separator: ", ")
                if !lines.contains(line) { lines.append(line) }
            }
        }
        let bare = count == 1 ? "1 wake-up" : "\(count) wake-ups"
        if !lines.contains(bare) { lines.append(bare) }
        return lines
    }

    // MARK: - The face's line

    /// Every form of the Done face's line, fullest first; the face shows the
    /// first that fits. The tasks give way first, then the wake-ups, and
    /// both stay said, however short.
    func lines(now: Date = Date()) -> [String] {
        let tasks = taskLines
        let wakes = wakeLines(now: now)
        guard let lastTask = tasks.last else { return wakes }
        guard let firstWake = wakes.first else { return tasks }
        var lines = tasks.map { "\($0) · \(firstWake)" }
        lines += wakes.dropFirst().map { "\(lastTask) · \($0)" }
        return lines
    }

    /// A session row's words for it, ahead of what Claude said: "Left npm
    /// running", "Left 3 running", or the first wake-up.
    func rowPhrase(now: Date = Date()) -> String? {
        if taskCount == 1, let task = tasks.first { return "Left \(Self.shortName(task)) running" }
        if taskCount > 1 { return "Left \(taskCount) running" }
        let phrases = wakePhrases(now: now)
        if let first = phrases.first {
            return phrases.count + moreWakes > 1 ? "Wakes \(first), +\(phrases.count + moreWakes - 1)" : "Wakes \(first)"
        }
        return moreWakes > 0 ? "\(moreWakes) wake-ups" : nil
    }

    /// The tooltip: the whole of it, and what it can't know.
    func help(now: Date = Date()) -> String {
        var said: [String] = []
        if taskCount > 0 {
            var names = tasks.map(Self.longName)
            if more > 0 { names.append("\(more) more") }
            said.append("When this turn ended, Claude had left running: " + names.joined(separator: ", ") + ".")
        }
        let phrases = wakePhrases(now: now)
        if !phrases.isEmpty || moreWakes > 0 {
            var names = phrases
            if moreWakes > 0 { names.append("\(moreWakes) more") }
            said.append("It has scheduled a wake-up: " + names.joined(separator: ", ") + ".")
        }
        return (said + ["That's as of the turn's end; when a task finishes, Claude Code wakes the session."])
            .joined(separator: " ")
    }

    /// Nil when nothing in it is still to be said: no task, and no wake-up
    /// still to come.
    func shown(now: Date = Date()) -> ClaudeLeftovers? {
        taskCount == 0 && wakePhrases(now: now).isEmpty && moreWakes == 0 ? nil : self
    }
}
