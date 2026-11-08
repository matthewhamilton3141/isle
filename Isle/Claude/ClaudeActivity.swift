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
            // A command → the program name only, so we never splash a full
            // command line — arguments and all — onto the screen; nil (and
            // "Running a command") when there's no name it can stand behind.
            return Self.program(ofCommand: target)
        case .web:
            // A URL → its host; anything else passes through trimmed.
            return host(of: target) ?? target
        case .search, .delegate, .plan, .other:
            return target
        }
    }

    // MARK: - A command's program

    /// What `isle-cli` cuts a target to. A target this long may have lost
    /// its end, so a word that runs into the cut may be part of a name.
    static let hookTargetCap = 48

    /// Words that only set up the command after them: they change the
    /// directory or the environment, and run nothing worth naming.
    private static let setupCommands: Set<String> = ["cd", "pushd", "popd", "export", "unset", "set"]

    /// Words that run the command after them: the program is further on.
    private static let wrappers: Set<String> = ["env", "sudo", "time", "nohup", "command", "exec"]

    /// Reserved words a shell reads before a command.
    private static let keywords: Set<String> = ["!", "{", "}", "if", "then", "elif", "else", "while", "until", "do"]

    /// The program a command line runs, read roughly the way a shell starts
    /// it: past `NAME=value` assignments, past whole `cd …` / `export …`
    /// segments, and through `env` / `sudo` / `time` / `nohup` / `command`
    /// / `exec`, to the first word of the first segment left — de-pathed,
    /// so `/usr/bin/git` is `git`. Segments end at `;` `&` `|` `(` `)` and
    /// newlines; quotes are taken off.
    ///
    /// Nil unless that word is a plain name — letters, digits and `._+-@`,
    /// not starting with `-` — that ends before the text does (when the
    /// text is at `hookTargetCap`, a word running into the end may be cut
    /// short). Also nil when there is no such segment. "Running a command"
    /// is true; "Running -Users-matthew-Documen" was not.
    ///
    /// Not a shell parser: `isle-cli` reads the command properly for the
    /// guard; this only has to name it, or decline to.
    static func program(ofCommand command: String) -> String? {
        // `cut -c` may count bytes; either way, no shorter text was cut.
        let mayBeCut = command.utf8.count >= hookTargetCap
        for segment in segments(of: command) {
            var words = segment[...]
            while let first = words.first {
                if keywords.contains(first.text) || isAssignment(first.text) {
                    words = words.dropFirst()
                } else if wrappers.contains(first.text), !looksUp(words) {
                    words = words.dropFirst()
                    // The wrapper's own options, and env's assignments.
                    while let next = words.first, next.text.hasPrefix("-") || isAssignment(next.text) {
                        let takesValue = first.text == "sudo" && ["-u", "-g", "-C", "-h", "-p", "-U"].contains(next.text)
                        words = words.dropFirst(takesValue ? 2 : 1)
                    }
                } else {
                    break
                }
            }
            guard let word = words.first else { continue }
            if setupCommands.contains(word.text) { continue }
            guard word.ended || !mayBeCut else { return nil }
            return plainName(word.text)
        }
        return nil
    }

    /// `command -v name` only looks the name up: it runs `command`, not it.
    private static func looksUp(_ words: ArraySlice<Word>) -> Bool {
        words.first?.text == "command" && ["-v", "-V"].contains(words.dropFirst().first?.text ?? "")
    }

    private struct Word {
        var text: String
        /// Something came after it: a space, a separator, a quote closed and
        /// then more. False for a word that runs into the end of the text.
        var ended: Bool
    }

    /// The command's words, segment by segment, with quotes taken off.
    private static func segments(of command: String) -> [[Word]] {
        var segments: [[Word]] = []
        var words: [Word] = []
        var current = ""
        var inWord = false
        var quote: Character?
        var escaped = false
        var comment = false

        func endWord() {
            if inWord { words.append(Word(text: current, ended: true)) }
            current = ""
            inWord = false
        }
        func endSegment() {
            endWord()
            if !words.isEmpty { segments.append(words) }
            words = []
        }

        for ch in command {
            if comment {
                if ch == "\n" { comment = false; endSegment() }
                continue
            }
            if escaped {
                current.append(ch); inWord = true; escaped = false
                continue
            }
            if let open = quote {
                if ch == open { quote = nil } else { current.append(ch) }
                continue
            }
            switch ch {
            case "\\":
                escaped = true
            case "'", "\"":
                quote = ch; inWord = true
            case " ", "\t":
                endWord()
            case ";", "&", "|", "(", ")", "\n", "\r":
                endSegment()
            case "#" where !inWord:
                comment = true
            default:
                current.append(ch); inWord = true
            }
        }
        // The last word ran into the end of the text (or into the end inside
        // an open quote), so nothing vouches that it's whole.
        if inWord { words.append(Word(text: current, ended: false)) }
        if !words.isEmpty { segments.append(words) }
        return segments
    }

    /// `NAME=value`, with a shell variable's name.
    private static func isAssignment(_ word: String) -> Bool {
        guard let eq = word.firstIndex(of: "="), eq != word.startIndex else { return false }
        let name = word[..<eq]
        return name.first.map { $0 == "_" || ($0.isASCII && $0.isLetter) } == true
            && name.allSatisfy { $0 == "_" || ($0.isASCII && ($0.isLetter || $0.isNumber)) }
    }

    /// The word's file name, when the word is a plain path or name: never
    /// an option, an assignment, a variable, a glob or a substitution.
    private static func plainName(_ word: String) -> String? {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._+-@/~"))
        guard !word.isEmpty, word.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        let name = (word as NSString).lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", name != "/", name != "~",
              !name.hasPrefix("-") else { return nil }
        return name
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
