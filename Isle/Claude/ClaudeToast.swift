//
//  ClaudeToast.swift
//
//  A session that finished out of sight (Milestone 15).
//
//  The island already says "Done" for the session it shows — the checkmark
//  and the word, for `doneToastSeconds` — so that one gets no toast. But
//  selection ranks by urgency: while another session is working, or a newer
//  one holds the island, a background session's `Stop` changes nothing on
//  screen except "+1 working" quietly going away. This is the one moment
//  that turn's end would otherwise go unseen, so it borrows the island for
//  one toast, naming the session by its project. The words Claude said are
//  on that session's face; a collapsed pill has no room for them.
//

import SwiftUI

extension IslandToast {
    /// "isle-website · done", in the done marker's green.
    static func sessionDone(sessionId: String, project: String?) -> IslandToast {
        IslandToast(
            kind: .sessionDone(session: sessionId),
            glyph: .symbol("checkmark.circle.fill"),
            text: name(project ?? "Claude", beside: " · done"),
            tint: Color(hex: "#34C759"),
            gate: .claudeSessions
        )
    }
}

// MARK: - Keyboard shortcuts

extension IslandToast {
    /// What a shortcut did to the request, for the collapsed island: the
    /// island's answer to a press made without looking at it. The same
    /// words and colours as the face's own buttons.
    enum ShortcutOutcome {
        case approved
        case alwaysAllowed
        case denied
        case answered
        /// The hook let go before the answer reached it (its deadline, or
        /// the terminal answered first): nothing was sent.
        case notSent
    }

    static func shortcut(_ outcome: ShortcutOutcome, project: String?) -> IslandToast {
        let (symbol, word, tint): (String, String, Color) = {
            switch outcome {
            case .approved: return ("checkmark.circle.fill", "Approved", Color(hex: "#34C759"))
            case .alwaysAllowed: return ("checkmark.circle.fill", "Always allowed", Color(hex: "#34C759"))
            case .denied: return ("xmark.circle.fill", "Denied", Color(hex: "#FF453A"))
            case .answered: return ("checkmark.circle.fill", "Answered", neutral)
            case .notSent: return ("exclamationmark.circle.fill", "Not sent", Color.orange)
            }
        }()
        let text = project.map { name($0, beside: " · " + word.lowercased()) } ?? word
        return IslandToast(kind: .shortcut, glyph: .symbol(symbol), text: text, tint: tint, gate: .claudeSessions)
    }
}
