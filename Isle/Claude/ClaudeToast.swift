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
