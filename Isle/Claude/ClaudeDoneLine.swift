//
//  ClaudeDoneLine.swift
//
//  "Done says what happened" (Milestone 15). The `Stop` hook carries the
//  text of Claude's final message, and the helper keeps its first 300
//  characters (`ClaudeStatus.lastMessage`). This turns that into the line the
//  Done face shows under its headline: the start of what Claude actually said,
//  with the Markdown taken off — never a summary Isle makes up.
//
//  What it keeps is Claude's own words, in Claude's own order:
//
//    * the first line of prose — a heading only when there's nothing else,
//      and a line that ends in a colon carries on into the line it introduces;
//    * cut at the end of a sentence when one ends early enough, so the line
//      stops on Claude's full stop rather than on an ellipsis;
//    * emphasis, links, list markers, quote marks and backticks removed, the
//      text inside them kept.
//
//  What it leaves out: code blocks (fenced, or cut off by the 300-character
//  excerpt before their closing fence), tables' rules, horizontal rules, and
//  control characters. A message that is only code, or empty, has no line —
//  the face says "Finished responding", as it always did.
//

import Foundation

enum ClaudeDoneLine {
    /// Roughly two lines of the face's detail type. A first sentence that
    /// ends within this is shown whole and alone; past it, the view truncates
    /// the line at its tail.
    static let budget = 120

    /// Below this, a first sentence ("Done.", "All set!") says too little on
    /// its own, and the next one rides along with it.
    static let shortSentence = 24

    /// How much of the message the helper keeps, in characters (an escape
    /// counts as one) — `isle-cli`'s two runs of 150. An excerpt this long
    /// was most likely cut there.
    static let excerptLength = 300

    /// The line for `message`, or nil when there is nothing to quote.
    static func line(from message: String?) -> String? {
        guard let message else { return nil }
        let lines = proseLines(message)
        guard let first = lines.first(where: { !$0.isHeading }) ?? lines.first,
              var index = lines.firstIndex(of: first)
        else { return nil }

        var text = first.text
        // "Here's what changed:" introduces what follows; on its own it says
        // nothing, so the line it introduces comes with it.
        if text.hasSuffix(":"), index + 1 < lines.count {
            index += 1
            text += " " + lines[index].text
        }
        let line = sentences(text)
        // The helper's cut landed in this line, and no sentence ended before
        // it: say it goes on, rather than stop mid-word as if that were all
        // Claude said.
        if line == text, index == lines.count - 1, message.unicodeScalars.count >= excerptLength {
            return line + "…"
        }
        return line
    }

    // MARK: - Lines

    private struct ProseLine: Equatable {
        let text: String
        let isHeading: Bool
    }

    /// The message's lines with code and rules dropped and the Markdown taken
    /// off, blank ones gone.
    private static func proseLines(_ message: String) -> [ProseLine] {
        let normalized = message
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var result: [ProseLine] = []
        var fence: String?   // the opening fence's marker while inside one
        for raw in normalized.components(separatedBy: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if let open = fence {
                // Only the same marker, at least as long, closes it.
                if trimmed.hasPrefix(open), trimmed.allSatisfy({ $0 == open.first }) { fence = nil }
                continue
            }
            if let marker = fenceMarker(trimmed) {
                fence = marker
                continue
            }
            // Indented code: four spaces or a tab, outside a list.
            if raw.hasPrefix("    ") || raw.hasPrefix("\t") { continue }
            if trimmed.isEmpty || isRule(trimmed) || isTableRule(trimmed) { continue }

            let isHeading = trimmed.hasPrefix("#")
            let text = clean(stripBlockMarkers(trimmed))
            guard !text.isEmpty else { continue }
            result.append(ProseLine(text: text, isHeading: isHeading))
        }
        return result
    }

    /// "```" or "~~~" (or longer), with or without an info string.
    private static func fenceMarker(_ line: String) -> String? {
        for mark in ["`", "~"] {
            let run = line.prefix(while: { String($0) == mark })
            if run.count >= 3 { return String(run) }
        }
        return nil
    }

    /// `---`, `***`, `___` and spaced forms.
    private static func isRule(_ line: String) -> Bool {
        let chars = line.filter { $0 != " " }
        guard chars.count >= 3, let first = chars.first, "-*_".contains(first) else { return false }
        return chars.allSatisfy { $0 == first }
    }

    /// A table's `|---|:--:|` row.
    private static func isTableRule(_ line: String) -> Bool {
        line.contains("-") && line.allSatisfy { "|-: ".contains($0) }
    }

    /// Heading marks, quote marks, list bullets and numbers, task boxes.
    private static func stripBlockMarkers(_ line: String) -> String {
        var text = Substring(line)
        // Headings: "## Title" (and a closing run of #s).
        if text.hasPrefix("#") {
            text = text.drop(while: { $0 == "#" })
            text = Substring(text.trimmingCharacters(in: .whitespaces))
            while text.hasSuffix("#") { text = text.dropLast() }
        }
        // Block quotes, possibly nested.
        while text.hasPrefix(">") {
            text = Substring(text.dropFirst().trimmingCharacters(in: .whitespaces))
        }
        // Bullets.
        for bullet in ["- ", "* ", "+ ", "• "] where text.hasPrefix(bullet) {
            text = text.dropFirst(bullet.count)
            break
        }
        // "1. " / "1) ".
        let digits = text.prefix(while: { $0.isASCII && $0.isNumber })
        if !digits.isEmpty, digits.count <= 3 {
            let rest = text.dropFirst(digits.count)
            if rest.hasPrefix(". ") || rest.hasPrefix(") ") { text = rest.dropFirst(2) }
        }
        // Task boxes.
        for box in ["[ ] ", "[x] ", "[X] "] where text.hasPrefix(box) {
            text = text.dropFirst(box.count)
            break
        }
        // A table row: its cells, side by side.
        if text.hasPrefix("|") {
            let cells = text.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            return cells.filter { !$0.isEmpty }.joined(separator: " · ")
        }
        return String(text)
    }

    // MARK: - Inline

    /// The inline Markdown taken off, the words inside kept. Code spans keep
    /// their text verbatim — `snake_case` and `**kwargs` aren't emphasis.
    private static func clean(_ line: String) -> String {
        let parts = line.components(separatedBy: "`")
        var out = ""
        for (index, part) in parts.enumerated() {
            out += index % 2 == 1 ? part : stripInline(part)
        }
        // Terminal colour codes, then control characters, out — but not
        // format characters: the joiner inside 👩‍👩‍👧 is one. Runs of
        // whitespace to one space.
        out = ansi.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "")
        let visible = out.unicodeScalars.filter { $0.properties.generalCategory != .control }
        return String(String.UnicodeScalarView(visible))
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    /// Where an underscore emphasis may end: before a space, closing
    /// punctuation, or a full stop that ends the sentence — so `__init__.py`
    /// and `file_name.txt` aren't read as emphasis.
    private static let closes = #"(?=[\s,;:!?)\]]|$|\.(?:\s|$))"#

    private static let inlineRules: [(NSRegularExpression, String)] = [
        // Images, then links: the text in the brackets.
        (#"!\[([^\]]*)\]\([^)]*\)"#, "$1"),
        (#"\[([^\]]+)\]\([^)]*\)"#, "$1"),
        // Autolinks: the address.
        (#"<((?:https?|mailto):[^>]+)>"#, "$1"),
        // Inline HTML tags (<br>, <kbd>…</kbd>).
        (#"</?[A-Za-z][A-Za-z0-9]*(?:\s[^>]*)?/?>"#, ""),
        // Bold and strikethrough, by their doubled markers.
        (#"\*\*(.+?)\*\*"#, "$1"),
        (#"(?<![\w])__(.+?)__"# + closes, "$1"),
        (#"~~(.+?)~~"#, "$1"),
        // Italics: single markers that hug a word. Underscores only at a word
        // boundary, so file_names_like_this survive.
        (#"(?<![\w*])\*(?=\S)(.+?)(?<=\S)\*(?![\w*])"#, "$1"),
        (#"(?<![\w])_(?=\S)(.+?)(?<=\S)_"# + closes, "$1"),
        // Anything left unpaired — the excerpt can stop mid-emphasis.
        (#"\*\*|~~"#, ""),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    private static let ansi = try! NSRegularExpression(pattern: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]")

    private static func stripInline(_ text: String) -> String {
        var result = text
        for (rule, template) in inlineRules {
            let range = NSRange(result.startIndex..., in: result)
            result = rule.stringByReplacingMatches(in: result, range: range, withTemplate: template)
        }
        return result
    }

    // MARK: - Sentences

    /// The line cut at the end of a sentence, when one ends within the
    /// budget; whole otherwise, for the view to truncate.
    private static func sentences(_ line: String) -> String {
        guard line.count > shortSentence else { return line }
        var cut: String.Index?
        var index = line.startIndex
        while index < line.endIndex {
            let char = line[index]
            let next = line.index(after: index)
            if ".!?".contains(char),
               next == line.endIndex || line[next] == " " {
                // Not "e.g." / "i.e." / a lone initial — but "0.4.5." and
                // "notes.txt." do end sentences.
                let word = line[..<index].split(separator: " ").last ?? ""
                let isAbbreviation = char == "." && (word.count <= 1 || (word.contains(".")
                    && word.split(separator: ".").allSatisfy { $0.count <= 2 && $0.allSatisfy(\.isLetter) }))
                if !isAbbreviation {
                    let length = line.distance(from: line.startIndex, to: next)
                    if length > budget { break }
                    cut = next
                    if length >= shortSentence { break }
                }
            }
            index = next
        }
        guard let cut else { return line }
        return String(line[..<cut])
    }
}
