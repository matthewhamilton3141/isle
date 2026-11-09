//
//  ClaudeBlock.swift
//
//  Auto mode's blocks, shown (Milestone 23): "Auto mode blocked rm · Shared
//  Scratch Sweep", from the record's `blocked` — the last call auto mode's
//  classifier refused in this session, as `isle-cli denied` kept it from
//  Claude Code's `PermissionDenied` hook, with how many it has refused since
//  the last prompt.
//
//  An event, not a state. Claude Code tells the model and the turn carries
//  on, so nothing here says Claude is waiting on you, and there's no Approve:
//  the real way to allow a blocked call is Claude Code's own `/permissions ›
//  Recently blocked`, which the line's tooltip names.
//
//  Only what the hook carried is said. The reason is auto mode's own: a
//  category in brackets when the classifier judged the call
//  ("[Irreversible Local Destruction]"), or a sentence when it couldn't
//  ("Classifier unavailable"). The first is named, the second is said as
//  "couldn't check it", and anything else gives no reason at all.
//
//  Pure, so the wording can be checked without a running bridge
//  (scripts/test-auto-mode-blocks.sh).
//

import Foundation

struct ClaudeBlock: Equatable {
    /// The call's `tool_use_id`. Empty when the hook carried none.
    var id: String
    /// The tool auto mode refused (`Bash`, `Write`, `WebFetch`, an MCP tool).
    var tool: String
    /// The helper's target for it: a Bash or Monitor command's program, a
    /// file path's name, a URL, a pattern. Nil when it couldn't name one.
    var target: String?
    /// A Bash or Monitor call's command: its first line, up to the helper's
    /// 48 characters. Nil for any other tool.
    var command: String?
    /// The command went on past `command`: a longer line, or more lines.
    var commandCut: Bool
    /// Auto mode's reason, as Claude Code sent it.
    var reason: String?
    /// How many calls auto mode has refused in the session since the last
    /// prompt, this one included.
    var count: Int
    /// When the helper wrote it.
    var at: Date?

    // MARK: - The reason

    enum Verdict: Equatable {
        /// The classifier judged the call and refused it, naming the rule
        /// when its reason did.
        case blocked(category: String?)
        /// It refused the call because it couldn't judge it: the classifier
        /// was unavailable, the conversation too long for it.
        case unchecked
    }

    var verdict: Verdict { Self.verdict(reason) }

    /// What auto mode's words say, and only that. The phrases are the ones
    /// 2.1.319 uses for a refusal without a judgment.
    static func verdict(_ reason: String?) -> Verdict {
        let text = (reason ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let category = category(text) { return .blocked(category: category) }
        let lower = text.lowercased()
        let unchecked = ["classifier unavailable", "auto mode unavailable", "transcript exceeded",
                         "no verdict", "could not evaluate", "couldn't check", "could not review",
                         "request aborted"]
        if unchecked.contains(where: lower.contains) { return .unchecked }
        return .blocked(category: nil)
    }

    /// "[Shared Scratch Sweep]" → "Shared Scratch Sweep": a category is the
    /// text in a leading pair of brackets, on one line and of a length a
    /// rule's name has.
    private static func category(_ text: String) -> String? {
        guard text.hasPrefix("["), let close = text.firstIndex(of: "]") else { return nil }
        let name = text[text.index(after: text.startIndex)..<close].trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name.count <= 60,
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { return nil }
        return name
    }

    /// The reason's clause on the face: the category, or "couldn't check it".
    var reasonClause: String? {
        switch verdict {
        case .blocked(let category): return category
        case .unchecked: return "couldn't check it"
        }
    }

    // MARK: - What was blocked

    private var runsCommand: Bool { tool == "Bash" || tool == "Monitor" }

    /// The call in a word or two: a command's program ("rm"), or the tool
    /// and what it named ("Write settings.json", "WebFetch example.com"),
    /// reduced the way the face's activity line reduces it. Nil for a
    /// command whose program couldn't be named.
    var object: String? {
        let shown = ClaudeActivity(action: tool, target: target)?.shownTarget
        if runsCommand { return shown }
        let name = Self.toolName(tool)
        guard !name.isEmpty else { return shown }
        return shown.map { "\(name) \($0)" } ?? name
    }

    /// An MCP tool by its server and tool, not its wire name.
    private static func toolName(_ tool: String) -> String {
        guard tool.hasPrefix("mcp__") else { return tool }
        return tool.dropFirst(5).components(separatedBy: "__").filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// The command as the face may show it: only when it starts with the
    /// program it runs, so a long `cd …` in front never stands in for it,
    /// with "…" where the helper cut it.
    var shownCommand: String? {
        guard runsCommand, let command, let program = object else { return nil }
        let line = command.trimmingCharacters(in: .whitespaces)
        guard let first = line.split(separator: " ", maxSplits: 1).first,
              (String(first) as NSString).lastPathComponent == program,
              !line.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { return nil }
        return commandCut ? line + "…" : line
    }

    // MARK: - The face's line

    /// One way of saying it: the lead, what was blocked (in the command's
    /// font when it's the command itself), and the reason.
    struct Line: Hashable {
        var lead: String
        var object: String?
        var isCommand = false
        var reason: String?

        var plain: String {
            [[lead, object].compactMap { $0 }.joined(separator: " "), reason]
                .compactMap { $0 }.joined(separator: " · ")
        }
    }

    /// Every form, fullest first; the face shows the first that fits. The
    /// reason outlasts the command's own words, and the count outlasts both.
    var lines: [Line] {
        let objects: [(String, Bool)] = [shownCommand.map { ($0, true) }, object.map { ($0, false) }]
            .compactMap { $0 }
        let leads = count > 1
            ? ["Auto mode blocked \(count) calls, last", "Blocked \(count), last"]
            : ["Auto mode blocked", "Blocked"]
        let unnamed = count > 1
            ? ["Auto mode blocked \(count) calls", "Blocked \(count) calls"]
            : ["Auto mode blocked a call", "Blocked a call"]
        var forms: [Line] = []
        for reason in reasonClause.map({ [$0, nil] }) ?? [nil] {
            if objects.isEmpty {
                forms += unnamed.map { Line(lead: $0, reason: reason) }
            }
            for (text, isCommand) in objects {
                // The command only beside the whole lead: cut short, it
                // gives way to the program.
                for lead in isCommand ? [leads[0]] : leads {
                    forms.append(Line(lead: lead, object: text, isCommand: isCommand, reason: reason))
                }
            }
        }
        forms.append(Line(lead: count > 1 ? "Blocked \(count)" : "Blocked"))
        var seen = Set<Line>()
        return forms.filter { seen.insert($0).inserted }
    }

    /// The tooltip: the call, what auto mode said, and the way to allow it.
    var help: String {
        let what = shownCommand ?? object ?? "this call"
        let why: String
        switch verdict {
        case .blocked(let category?):
            why = "Auto mode's classifier blocked \(what) (\(category)), so it didn't run."
        case .blocked(nil):
            why = "Auto mode's classifier blocked \(what), so it didn't run."
        case .unchecked:
            let said = reason.map { " (\($0.trimmingCharacters(in: .whitespacesAndNewlines)))" } ?? ""
            why = "Auto mode couldn't check \(what)\(said), so it didn't run."
        }
        let count = count > 1 ? " \(self.count) calls blocked since your last prompt." : ""
        return why + count
            + " Claude carries on without it. To allow it, use /permissions › Recently blocked in Claude Code."
    }

    /// A session row's words for it, ahead of what the session is doing:
    /// "Blocked rm", or "2 blocked".
    var rowPhrase: String {
        count > 1 ? "\(count) blocked" : "Blocked \(object ?? "a call")"
    }

    // MARK: - The toast

    /// What the collapsed island says: "Auto mode blocked rm", or for a
    /// session the island isn't showing, "isle-website · blocked rm".
    func toastText(project: String?) -> String {
        let short = Self.toolName(runsCommand ? (object ?? "a command") : tool)
        if let project, !project.isEmpty {
            return IslandToast.name(project, beside: " · blocked \(short)")
        }
        let middle = IslandToast.fit(short: "Blocked \(short)", long: object.map { "Blocked \($0)" })
        return IslandToast.fit(short: middle, long: object.map { "Auto mode blocked \($0)" })
    }

    /// What tells one block from the next: the call, and the count, so the
    /// same call reported again changes nothing.
    var key: String { "\(id)|\(count)|\(at.map { "\($0.timeIntervalSince1970)" } ?? "")" }
}
