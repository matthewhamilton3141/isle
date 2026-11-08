//
//  GuardedCommands.swift
//
//  Guarded commands (Milestone 17): a short list, the user's own, of commands
//  that always ask — even in auto mode, under acceptEdits, past an allow rule,
//  or with permissions bypassed. `isle-cli guard` (PreToolUse on Bash and
//  Monitor) reads the list and answers `permissionDecision: "ask"` when a
//  command matches; Claude Code then shows its own prompt, which the notch
//  answers like any other approval.
//
//  A speed bump for honest mistakes, not a sandbox: the hook reads the command
//  the way a shell splits it (see `isle-cli`), and an alias, a variable or a
//  script file in front of the real thing is beyond what it can see.
//
//  Two files under ~/.isle, neither watched:
//
//    guarded-commands       Isle → hook   One pattern a line. Present only
//                                         while the feature is on and the list
//                                         isn't empty, so with nothing to
//                                         guard the hook is one `test`.
//    guarded/<session>.json hook → Isle   The last call the guard asked about
//                                         in that session: the pattern and the
//                                         command. The PermissionRequest that
//                                         follows carries no reason, so this
//                                         is how the approval face knows why.
//

import Foundation

enum GuardedCommands {
    /// One-click suggestions in Settings — the commands the field scan's
    /// competitor guards, and the usual ways to publish or destroy something
    /// that can't be taken back.
    static let suggestions = ["git push", "rm -rf", "npm publish", "gh pr merge", "terraform apply"]

    private static var isleDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".isle", isDirectory: true)
    }

    static var listURL: URL { isleDirectory.appendingPathComponent("guarded-commands") }
    static var recordsDirectory: URL { isleDirectory.appendingPathComponent("guarded", isDirectory: true) }

    /// A pattern as the hook will read it: words, single-spaced. Nil for one
    /// with nothing in it. Control characters can't be typed into a field,
    /// but a pasted newline would split a line of the list, so every one of
    /// them is a space, like a tab.
    static func normalized(_ pattern: String) -> String? {
        let words = String(String.UnicodeScalarView(pattern.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) ? " " : $0
        }))
        .split(separator: " ")
        guard !words.isEmpty else { return nil }
        return words.joined(separator: " ")
    }

    /// Puts the list where the hook reads it, by rename — or takes it away
    /// when the feature is off or the list is empty, which is what turns the
    /// hook back into an immediate, silent exit.
    /// `url` is for tests; the app only ever writes `listURL`.
    static func sync(enabled: Bool, patterns: [String], at url: URL = listURL) {
        let fm = FileManager.default
        let lines = patterns.compactMap(normalized)
        guard enabled, !lines.isEmpty else {
            try? fm.removeItem(at: url)
            return
        }
        let body = lines.joined(separator: "\n") + "\n"
        if (try? String(contentsOf: url, encoding: .utf8)) == body { return }
        let directory = url.deletingLastPathComponent()
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        // Not ending in the list's own name, so a half-written file is never read.
        let temp = directory.appendingPathComponent(".guarded-commands.tmp")
        guard (try? Data(body.utf8).write(to: temp)) != nil else { return }
        if rename(temp.path, url.path) != 0 {
            try? fm.removeItem(at: temp)
        }
    }

    // MARK: - Why an approval is asking

    /// How long before its PermissionRequest a guard record still counts. The
    /// two come within milliseconds (PreToolUse hooks finish, then Claude Code
    /// asks); the slack is for someone else's slow PreToolUse hook running
    /// beside Isle's. A record older than that is about some earlier call.
    private static let recordWindow: TimeInterval = 60

    /// The pattern a Bash (or Monitor) approval was guarded by, read from the
    /// session's record — only when the record names this very command and
    /// was written just before the request. Anything else is an ordinary
    /// approval: the notch never claims a guard it can't point to.
    /// `directory` is the records' folder: `guarded` beside the requests
    /// folder the watcher reads, so a watcher pointed at a scratch folder
    /// never reads the real records.
    static func pattern(forCommand command: String, sessionId: String?, requestDate: Date?,
                        in directory: URL = recordsDirectory) -> String? {
        let safe = String((sessionId ?? "").unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" || $0 == "_"
        }.map(Character.init))
        let url = directory.appendingPathComponent("\(safe.isEmpty ? "unknown" : safe).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let requestDate,
           let written = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date {
            let lead = requestDate.timeIntervalSince(written)
            guard lead > -2, lead < recordWindow else { return nil }
        }
        return pattern(inRecord: data, command: command)
    }

    /// The record's pattern when its command is `command`. Pure, for tests.
    static func pattern(inRecord data: Data, command: String) -> String? {
        guard let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pattern = record["pattern"] as? String, !pattern.isEmpty,
              let recorded = record["command"] as? String, recorded == command
        else { return nil }
        return pattern
    }

    /// Tools whose `command` the hook guards. Monitor runs a shell command
    /// too, and never asks on its own.
    static func guards(tool: String) -> Bool {
        tool == "Bash" || tool == "Monitor"
    }
}
