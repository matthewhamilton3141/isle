//
//  ClaudeLimit.swift
//
//  A claude.ai usage limit, said straight (Milestone 19): which window was
//  hit, when it resets, and what Claude Code said it will do then. One place
//  for the words, so the face, the island, the home tile and the session
//  list can't say it four ways.
//
//  Every part comes from the hooks (see "Usage limits" in isle-cli): the
//  window and the reset from the transcript or Claude Code's own words, what
//  comes next from its "continuing automatically" record and the
//  `quota_auto_resume_*` notifications. A part that's missing is left out,
//  never guessed — no window reads "Usage limit", no reset leaves the time
//  off, and nothing said about continuing says nothing about it.
//

import Foundation

/// What Claude Code said comes after a usage limit, as `isle-cli` writes it
/// to `limit_next`.
enum ClaudeLimitNext: String, Equatable {
    /// It waits in the open session and continues on its own at the reset.
    case auto
    /// The reset passed while the Mac slept, and it waits for Enter.
    case enter
    /// It has stopped waiting and won't continue on its own.
    case stopped
    /// It has continued the task (the turn after the limit).
    case resumed
}

enum ClaudeLimit {
    /// The window, as Claude Code names it ("You've hit your 5-hour limit").
    static func windowName(_ kind: String?) -> String {
        switch kind {
        case "five_hour": return "5-hour limit"
        case "seven_day": return "Weekly limit"
        case "seven_day_opus": return "Opus limit"
        case "seven_day_sonnet": return "Sonnet limit"
        default: return "Usage limit"
        }
    }

    /// The face's headline for a limit.
    static func headline(kind: String?, next: ClaudeLimitNext?) -> String {
        next == .enter ? "Limit reset" : windowName(kind)
    }

    /// The face's line under it. `terminal` is the session's app by name
    /// ("Terminal", "iTerm"), when Isle knows it.
    static func detail(resetAt: Date?, next: ClaudeLimitNext?, terminal: String?, now: Date = Date()) -> String {
        if next == .enter {
            return "Press Enter in \(terminal ?? "its terminal") to continue"
        }
        let resets = resetAt.flatMap { $0 > now ? "resets " + clock($0, now: now) : nil }
        switch next {
        case .stopped:
            return resets.map { "Won't continue on its own · \($0)" } ?? "Won't continue on its own"
        case .auto:
            return resets.map { "\(capitalized($0)) · continues automatically" } ?? "Continues automatically"
        default:
            return resets.map(capitalized) ?? "Limit reached"
        }
    }

    /// The collapsed island's word: the reset as a clock, which needs no
    /// ticking and keeps the island one width for hours. The live countdown
    /// is the face's.
    static func islandWord(resetAt: Date?, next: ClaudeLimitNext?, now: Date = Date()) -> String {
        if next == .enter { return "Press Enter" }
        guard let resetAt, resetAt > now else { return "Limit" }
        return "Limit · " + clock(resetAt, now: now)
    }

    /// A short line for the home tile and a session row.
    static func shortDetail(resetAt: Date?, next: ClaudeLimitNext?, now: Date = Date()) -> String? {
        if next == .enter { return "Press Enter to continue" }
        if next == .stopped { return "Won't continue on its own" }
        guard let resetAt, resetAt > now else { return nil }
        return "Resets " + clock(resetAt, now: now) + (next == .auto ? " · continues" : "")
    }

    /// The working face's line before a resumed turn's first tool.
    static func resumedLine(kind: String?) -> String {
        kind == nil ? "Resumed after the usage limit" : "Resumed after the \(windowName(kind).lowercasedFirst)"
    }

    /// "6:50pm" within a day, "Tue 9:00am" within the week, "Nov 18 9:00am"
    /// past it — Claude Code's own style, in this Mac's clock (12- or
    /// 24-hour, as it's set).
    static func clock(_ date: Date, now: Date = Date()) -> String {
        let time = timeFormatter.string(from: date)
            .replacingOccurrences(of: "\u{202F}", with: " ")
            .replacingOccurrences(of: " AM", with: "am")
            .replacingOccurrences(of: " PM", with: "pm")
        let ahead = date.timeIntervalSince(now)
        if ahead < 20 * 3600 || Calendar.current.isDate(date, inSameDayAs: now) { return time }
        if ahead < 6 * 86400 { return weekdayFormatter.string(from: date) + " " + time }
        return dayFormatter.string(from: date) + " " + time
    }

    /// "in 2h 14m", "in 14m", "in 3d 2h", "in under a minute" — to the
    /// minute, rounded up, so it never reads zero before it's time.
    static func countdown(to date: Date, now: Date = Date()) -> String? {
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else { return nil }
        if seconds < 60 { return "in under a minute" }
        let minutes = Int((seconds / 60).rounded(.up))
        let days = minutes / 1440, hours = (minutes % 1440) / 60, mins = minutes % 60
        if days > 0 { return hours > 0 ? "in \(days)d \(hours)h" : "in \(days)d" }
        if hours > 0 { return mins > 0 ? "in \(hours)h \(mins)m" : "in \(hours)h" }
        return "in \(mins)m"
    }

    private static func capitalized(_ s: String) -> String {
        s.prefix(1).uppercased() + s.dropFirst()
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("jmm")
        return f
    }()
    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE")
        return f
    }()
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f
    }()
}

private extension String {
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}
