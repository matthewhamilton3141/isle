//
//  ClaudeActivity.swift
//
//  One source of truth for turning a Claude Code tool call — the raw
//  `tool_name` plus the best-effort target the hook captured — into a friendly
//  one-liner for the expanded panel's "what it's doing" line ("Editing
//  App.swift", "Running npm", "Searching \"activeRect\"").
//
//  Target hygiene lives here too. `target` rides in an always-on overlay, so it
//  is reduced to something short and non-leaky — a file's basename, a command's
//  program name, a URL's host — rather than echoed raw. `isle-cli` already caps
//  it at 48 chars and strips backslashes; this narrows it the rest of the way.
//

import Foundation

struct ClaudeActivity: Equatable {
    /// The raw `tool_name` from the hook (Edit / Bash / Read / …).
    let action: String
    /// The best-effort target `isle-cli` pulled from the tool input, if any.
    let target: String?

    init?(action: String?, target: String?) {
        guard let action, !action.isEmpty else { return nil }
        self.action = action
        self.target = target.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Tool family, so the phrasing/glyph tables stay small and every alias of
    /// the same idea (Edit/MultiEdit/Write…) lands in one place.
    private enum Family {
        case edit, read, run, search, web, delegate, plan, other
    }

    private var family: Family {
        switch action {
        case "Edit", "MultiEdit", "Write", "NotebookEdit": return .edit
        case "Read": return .read
        case "Bash", "BashOutput", "KillShell": return .run
        case "Grep", "Glob": return .search
        case "WebFetch", "WebSearch": return .web
        case "Task", "Agent": return .delegate
        case "TodoWrite": return .plan
        default: return .other
        }
    }

    /// Present-tense verb, object-free ("Editing"). Unknown tools fall back to
    /// their raw name so nothing is ever mislabeled.
    var verb: String {
        switch family {
        case .edit: return "Editing"
        case .read: return "Reading"
        case .run: return "Running"
        case .search: return "Searching"
        case .web: return "Browsing"
        case .delegate: return "Delegating"
        case .plan: return "Planning"
        case .other: return action
        }
    }

    /// The full one-liner for the expanded panel, e.g. "Editing App.swift",
    /// "Running npm", "Searching \"activeRect\"". Target is reduced to a safe,
    /// short display form first.
    var phrase: String {
        switch family {
        case .edit: return "Editing \(displayTarget ?? "a file")"
        case .read: return "Reading \(displayTarget ?? "a file")"
        case .run: return displayTarget.map { "Running \($0)" } ?? "Running a command"
        case .search: return displayTarget.map { "Searching \(quoted($0))" } ?? "Searching"
        case .web: return displayTarget.map { "Browsing \($0)" } ?? "Browsing the web"
        case .delegate: return "Delegating a task"
        case .plan: return "Updating the plan"
        case .other: return displayTarget.map { "\(verb) \($0)" } ?? verb
        }
    }

    // MARK: - Target hygiene

    /// The target narrowed to something short and non-leaky, by family.
    private var displayTarget: String? {
        guard let target else { return nil }
        switch family {
        case .edit, .read:
            // A path → just the file name.
            return lastComponent(of: target)
        case .run:
            // A command → the program name only (first token, de-pathed), so we
            // never splash a full command line — arguments and all — onto the
            // screen.
            guard let token = target.split(whereSeparator: { $0 == " " }).first else { return nil }
            return lastComponent(of: String(token))
        case .web:
            // A URL → its host; anything else passes through trimmed.
            return host(of: target) ?? target
        case .search, .delegate, .plan, .other:
            return target
        }
    }

    private func lastComponent(of path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }

    private func host(of string: String) -> String? {
        guard let url = URL(string: string), let host = url.host else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private func quoted(_ s: String) -> String { "\u{201C}\(s)\u{201D}" }
}
