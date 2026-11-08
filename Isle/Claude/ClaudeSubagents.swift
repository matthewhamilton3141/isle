//
//  ClaudeSubagents.swift
//
//  Subagents, counted (Milestone 22): "3 agents · Explore ×2, Plan", from
//  the record's `subagents` — the types of the agents the session has
//  running, oldest first, as `isle-cli` kept them from Claude Code's
//  `SubagentStart` and `SubagentStop`. Only agents a start was seen for are
//  in it, and each stays until its own stop — a background agent outlives
//  its turn — or its session's end. A session whose process is gone has no
//  agents, whatever its record says (`counted`), so the line says what the
//  hooks reported and nothing it would have to guess.
//
//  Pure, so the wording can be checked without a running bridge
//  (scripts/test-subagent-count.sh).
//

import Foundation

enum ClaudeSubagents {
    /// A record's agents, while its session's process is alive: the
    /// registry's pids are the one word on that, since a session killed
    /// outright fires no SessionEnd to clear them. None for a record with no
    /// session id to check, or one the registry doesn't list.
    static func counted(_ running: [String], sessionId: String?, live: Set<String>) -> [String] {
        guard !running.isEmpty, let id = sessionId, live.contains(id) else { return [] }
        return running
    }

    /// One type and how many of it are running.
    struct Group: Equatable {
        let type: String
        let count: Int
    }

    /// The running agents by type: the most of a kind first, and between
    /// kinds with as many, the one that started first. An agent whose type
    /// the hook didn't carry is counted but in no group.
    static func groups(_ running: [String]) -> [Group] {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for raw in running {
            let type = displayName(raw)
            guard !type.isEmpty else { continue }
            if counts[type] == nil { order.append(type) }
            counts[type, default: 0] += 1
        }
        return order.enumerated()
            .sorted { lhs, rhs in
                let l = counts[lhs.element]!, r = counts[rhs.element]!
                return l != r ? l > r : lhs.offset < rhs.offset
            }
            .map { Group(type: $0.element, count: counts[$0.element]!) }
    }

    /// A type as the line names it: a plugin's agent (`plugin:agent`) by
    /// its own name, since the plugin's adds length and nothing the reader
    /// needs to tell agents apart.
    static func displayName(_ type: String) -> String {
        let trimmed = type.trimmingCharacters(in: .whitespaces)
        guard let colon = trimmed.lastIndex(of: ":") else { return trimmed }
        let name = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? trimmed : name
    }

    /// "3 agents", "1 agent".
    static func count(_ running: [String]) -> String {
        "\(running.count) \(running.count == 1 ? "agent" : "agents")"
    }

    /// The line naming the first `naming` groups, the rest as "+N" — N the
    /// agents not named, so the numbers add up to the count in front.
    /// "3 agents · Explore ×2, Plan"; "6 agents · Explore ×3, +3". Nil with
    /// nothing running.
    static func line(_ running: [String], naming: Int) -> String? {
        guard !running.isEmpty else { return nil }
        let groups = groups(running)
        let named = Array(groups.prefix(max(0, naming)))
        var parts = named.map { $0.count > 1 ? "\($0.type) ×\($0.count)" : $0.type }
        let rest = running.count - named.reduce(0) { $0 + $1.count }
        if rest > 0, !parts.isEmpty { parts.append("+\(rest)") }
        guard !parts.isEmpty else { return count(running) }
        return "\(count(running)) · " + parts.joined(separator: ", ")
    }

    /// Every form of the line, the fullest first and the bare count last,
    /// for a view to take the first that fits its width. Empty with nothing
    /// running.
    static func lines(_ running: [String]) -> [String] {
        guard !running.isEmpty else { return [] }
        let kinds = groups(running).count
        var lines: [String] = []
        for naming in stride(from: kinds, through: 0, by: -1) {
            if let line = line(running, naming: naming), !lines.contains(line) {
                lines.append(line)
            }
        }
        return lines
    }
}
