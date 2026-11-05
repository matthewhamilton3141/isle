//
//  ClaudeSessionList.swift
//
//  Every live session at once (Milestone 16). Selection puts one session on
//  the island; the Claude face can also list them all, and the user can pick
//  one to look at.
//
//  Two pieces, both pure so they can be checked without a running bridge:
//
//    * `ClaudeSelection` — the urgency ranking `NotchViewModel.selectStatus`
//      has always used, now shared with the list so the two can't disagree
//      about order, and the pin: the session the user picked from the list,
//      held on the face over the ranking until something more urgent arrives.
//    * `ClaudeSessionRow` — one row of the list, as the face draws it.
//
//  Nothing here decides liveness. The view model hands in only records the
//  registry vouches for (see `NotchViewModel.updateSessionList`).
//

import Foundation

enum ClaudeSelection {
    /// How much a state deserves the island. Higher wins.
    static func urgency(_ state: ClaudeCodeState) -> Int {
        switch state {
        // Blocked on the user, or ended badly — these are the whole point.
        case .needsApproval, .needsQuestion, .failed: return 3
        // Something is actually happening.
        case .working, .compacting: return 2
        // Alive but not doing anything; must never displace the tier above.
        case .waitingInput, .done, .idle: return 1
        case .disconnected: return 0
        }
    }

    /// Whether `a` ranks above `b`: by urgency, then by recency.
    static func outranks(_ a: ClaudeStatus, _ b: ClaudeStatus) -> Bool {
        (urgency(a.state), a.updatedAt ?? .distantPast) > (urgency(b.state), b.updatedAt ?? .distantPast)
    }

    /// The pool in island order, most deserving first. Stable, so equal
    /// records keep the order they came in — and the first is exactly the
    /// record selection has always picked.
    static func ranked(_ pool: [ClaudeStatus]) -> [ClaudeStatus] {
        pool.enumerated()
            .sorted { lhs, rhs in
                if outranks(lhs.element, rhs.element) { return true }
                if outranks(rhs.element, lhs.element) { return false }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    /// A session the user picked from the list, held on the face.
    ///
    /// It yields to one thing only: another session that *newly* needs the
    /// user — an approval, a question or a failure — while the pinned one
    /// doesn't. `heldAgainst` is what already outranked the pinned session
    /// that way when it was last resolved, so a session that was waiting on
    /// you when you picked another doesn't take the face straight back; it
    /// has to stop needing you and start again, or the pinned session has to
    /// stop needing you while it still does. A session that only starts
    /// working never takes the face from the one you're looking at.
    struct Pin: Equatable {
        let sessionId: String
        var heldAgainst: Set<String> = []
    }

    /// Whether `other` would take the face from a pinned `pinned`: it needs
    /// the user, and the pinned session doesn't.
    static func overrides(_ other: ClaudeStatus, pinned: ClaudeStatus) -> Bool {
        urgency(other.state) == 3 && urgency(pinned.state) < 3
    }

    /// Pins `sessionId`, held against whatever in `pool` already overrides
    /// it. Nil when the session isn't in the pool.
    static func pin(_ sessionId: String, in pool: [ClaudeStatus]) -> Pin? {
        guard let pinned = pool.first(where: { $0.sessionId == sessionId }) else { return nil }
        return Pin(sessionId: sessionId, heldAgainst: overriding(pinned, in: pool))
    }

    /// The record that owns the island, and the pin as it stands after this
    /// pass: nil once the pinned session has gone from the pool or something
    /// newly overrides it.
    static func select(from pool: [ClaudeStatus], pin: Pin?) -> (status: ClaudeStatus, pin: Pin?) {
        if let pin, let pinned = pool.first(where: { $0.sessionId == pin.sessionId }) {
            let against = overriding(pinned, in: pool)
            if against.isSubset(of: pin.heldAgainst) {
                return (pinned, Pin(sessionId: pin.sessionId, heldAgainst: against))
            }
        }
        return (ranked(pool).first ?? .disconnected, nil)
    }

    private static func overriding(_ pinned: ClaudeStatus, in pool: [ClaudeStatus]) -> Set<String> {
        Set(pool.compactMap { other in
            guard let id = other.sessionId, id != pinned.sessionId,
                  overrides(other, pinned: pinned) else { return nil }
            return id
        })
    }
}

/// One live session, as a row of the list.
struct ClaudeSessionRow: Identifiable, Equatable {
    let id: String
    let project: String?
    /// The state the row reports — the record's, after the same corrections
    /// the island makes (see `NotchViewModel.updateSessionList`).
    let state: ClaudeCodeState
    let errorType: String?
    /// What it's doing, what it's asking, or what Claude said last.
    let detail: String
    /// When the session's hook last wrote.
    let updatedAt: Date?

    /// The marker the row draws: the island's own mapping, failure kinds and
    /// all.
    var markerKind: MarkerKind {
        ClaudeSessionRow.markerKind(state: state, errorType: errorType)
    }

    /// The state in a word or two, as the face's headline and the home tile
    /// say it.
    var stateTitle: String {
        switch state {
        case .needsApproval: return "Needs approval"
        case .needsQuestion: return "Question"
        case .working: return "Working"
        case .compacting: return "Compacting"
        case .waitingInput: return "Waiting"
        case .done: return "Done"
        case .idle: return "Ready"
        case .failed: return errorType == "usage_limit" ? "Usage limit" : "Error"
        case .disconnected: return ""
        }
    }

    static func markerKind(state: ClaudeCodeState, errorType: String?) -> MarkerKind {
        guard state == .failed else { return MarkerKind(state: state) }
        switch errorType {
        case "usage_limit", "rate_limit", "rate_limit_error", "rate_limited": return .rateLimited
        case "server_error", "api_error", "overloaded", "overloaded_error": return .serverError
        default: return .apiError
        }
    }

    /// The row for `status`, whose request (if a hook is blocked on one) is
    /// `request`. Words only from what the record carries: the tool and its
    /// target, the request's own text, or Claude's final message.
    init(_ status: ClaudeStatus, request: ClaudeRequest?) {
        id = status.sessionId ?? ""
        project = status.project.flatMap { $0.isEmpty ? nil : $0 }
        state = status.state
        errorType = status.errorType
        updatedAt = status.updatedAt
        let activity = ClaudeActivity(action: status.action, target: status.target)?.phrase
        let said = ClaudeDoneLine.line(from: status.lastMessage)
        switch status.state {
        case .working:
            detail = activity ?? "Thinking…"
        case .compacting:
            detail = "Compacting the conversation"
        case .needsApproval:
            detail = request.map(Self.approvalLine) ?? activity ?? "Answer in its terminal"
        case .needsQuestion:
            detail = request?.questions.first?.question ?? "Answer in its terminal"
        case .waitingInput:
            detail = said ?? "Ready for your next prompt"
        case .done:
            detail = said ?? "Finished responding"
        case .idle:
            detail = said ?? "Session ready"
        case .failed:
            if status.errorType == "usage_limit", let reset = status.resetAt {
                detail = "Resets " + reset.formatted(date: .omitted, time: .shortened)
            } else {
                detail = "The turn stopped on an error"
            }
        case .disconnected:
            detail = ""
        }
    }

    /// "Bash · npm test": the tool and what it wants, on one line. A path is
    /// cut to its file name.
    static func approvalLine(_ request: ClaudeRequest) -> String {
        var subject = (request.subject ?? "").replacingOccurrences(of: "\n", with: " ")
        if subject.hasPrefix("/") || subject.hasPrefix("~"), !subject.contains(" ") {
            subject = (subject as NSString).lastPathComponent
        }
        return subject.isEmpty ? request.displayTool : "\(request.displayTool) · \(subject)"
    }
}
