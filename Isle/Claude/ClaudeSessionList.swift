//
//  ClaudeSessionList.swift
//
//  Every live session at once (Milestone 16). Selection puts one session on
//  the island; the Claude face can also list them all, and the user can pick
//  one to look at.
//
//  Two pieces, both pure so they can be checked without a running bridge:
//
//    * `ClaudeSelection` — the list's order (`ranked`), and the island's
//      choice (`Selector`): a strict order of ranks, the shown session kept
//      through ties, a higher rank taking the island once it has held (an
//      approval or a question at once), and the pin — the session the user
//      picked, held until a higher rank rises elsewhere.
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

    /// A session the user picked from the list, held on the island.
    ///
    /// It yields only to a session that rises above it in `Rank` while it's
    /// pinned. `heldAgainst` is what was already above it when it was
    /// picked (and still is): a session waiting on you when you picked
    /// another doesn't take the island straight back; it has to drop below
    /// and rise again.
    struct Pin: Equatable {
        let sessionId: String
        var heldAgainst: Set<String> = []
    }

    /// Pins `sessionId`, held against whatever in `pool` already ranks
    /// above it. Nil when the session isn't in the pool.
    static func pin(_ sessionId: String, in pool: [ClaudeStatus], seen: (ClaudeStatus) -> Bool) -> Pin? {
        guard let pinned = pool.first(where: { $0.sessionId == sessionId }) else { return nil }
        let rank = rank(pinned, seen: seen(pinned))
        return Pin(sessionId: sessionId, heldAgainst: Set(pool.compactMap { other in
            guard let id = other.sessionId, id != sessionId, Self.rank(other, seen: seen(other)) > rank else { return nil }
            return id
        }))
    }

    // MARK: - Which session the island shows

    /// How much a session's state deserves the island, in a strict order.
    /// Within a rank the island keeps the session it's showing: a tie never
    /// moves it, and recency never re-sorts it.
    enum Rank: Int, Comparable {
        case none = 0
        /// Ready, Waiting for you, a Done already seen.
        case ready
        case working
        /// A usage limit, an error.
        case trouble
        /// Done, and the user hasn't seen it yet.
        case finished
        case question
        case approval

        static func < (a: Rank, b: Rank) -> Bool { a.rawValue < b.rawValue }

        /// Blocks Claude until the user acts: takes the island at once,
        /// with no hold.
        var blocks: Bool { self >= .question }
    }

    /// A status's rank. `seen` says whether a Done has been seen.
    static func rank(_ status: ClaudeStatus, seen: Bool) -> Rank {
        switch status.state {
        case .needsApproval: return .approval
        case .needsQuestion: return .question
        case .done: return seen ? .ready : .finished
        case .failed: return .trouble
        case .working, .compacting: return .working
        case .idle, .waitingInput: return .ready
        case .disconnected: return .none
        }
    }

    /// Chooses the session the island shows — the collapsed pill and the
    /// open face alike — and keeps choosing it steadily as states change
    /// in several sessions at once (Matthew: "different statuses changing
    /// between different sessions often fight for priority").
    ///
    /// - Another session takes the island only for a higher rank, and only
    ///   once it has held that rank for `hold` — a blip can't steal it —
    ///   except an approval or a question, which take it at once.
    /// - When the shown session drops (its approval answered, say), the
    ///   next is the highest rank, then the session the user last saw or
    ///   chose, then the newest record, then the id: the same pick every
    ///   time from the same states.
    /// - A session the user picked (`Pin`) holds the island until a higher
    ///   rank rises somewhere else; a session already above it when it was
    ///   picked has to drop and rise again to count.
    /// - `frozen` (a reply being written): nothing switches.
    ///
    /// Pure and synchronous: it's handed the pool, which Dones are seen,
    /// and the time, and says when it wants asking again (a hold running
    /// out) rather than keeping a timer.
    struct Selector: Equatable {
        /// The session on the island, by id.
        private(set) var shown: String?
        var pin: Pin?
        /// When each session last took the rank it has.
        private(set) var rankSince: [String: RankSince] = [:]
        /// When the user last saw or chose each session.
        var lastSeen: [String: Date] = [:]

        struct RankSince: Equatable {
            var rank: Rank
            var since: Date
        }

        /// How long a higher rank has to hold before it takes the island.
        static let hold: TimeInterval = 1

        init(shown: String? = nil, pin: Pin? = nil) {
            self.shown = shown
            self.pin = pin
        }

        struct Pick {
            let status: ClaudeStatus
            /// Ask again at this moment: a session's hold runs out then.
            let recheckAt: Date?
        }

        mutating func select(from pool: [ClaudeStatus], seen: (ClaudeStatus) -> Bool,
                             now: Date, frozen: Bool = false) -> Pick {
            // Every session's rank, and since when.
            var ranks: [String: Rank] = [:]
            for status in pool {
                guard let id = status.sessionId else { continue }
                let rank = ClaudeSelection.rank(status, seen: seen(status))
                ranks[id] = rank
                if rankSince[id]?.rank != rank { rankSince[id] = RankSince(rank: rank, since: now) }
            }
            for id in rankSince.keys where ranks[id] == nil { rankSince[id] = nil }
            func rankOf(_ status: ClaudeStatus) -> Rank { status.sessionId.flatMap { ranks[$0] } ?? .none }
            func held(_ status: ClaudeStatus) -> Bool {
                let rank = rankOf(status)
                guard !rank.blocks, let id = status.sessionId, let since = rankSince[id]?.since else { return true }
                return now.timeIntervalSince(since) >= Self.hold - 0.001
            }
            func holdEnds(_ statuses: [ClaudeStatus]) -> Date? {
                statuses.compactMap { $0.sessionId.flatMap { rankSince[$0]?.since } }
                    .map { $0.addingTimeInterval(Self.hold) }.min()
            }
            let current = shown.flatMap { id in pool.first { $0.sessionId == id } }

            if frozen, let current { return Pick(status: current, recheckAt: nil) }

            // A pinned session, while nothing newly above it.
            if let holding = pin, let pinned = pool.first(where: { $0.sessionId == holding.sessionId }) {
                let above = Set(pool.compactMap { other -> String? in
                    guard let id = other.sessionId, id != holding.sessionId, rankOf(other) > rankOf(pinned) else { return nil }
                    return id
                })
                let rising = pool.filter { other in
                    guard let id = other.sessionId else { return false }
                    return above.contains(id) && !holding.heldAgainst.contains(id)
                }
                let takes = rising.filter(held)
                if takes.isEmpty {
                    // What has dropped below it since stops counting against
                    // it: rising again would be news.
                    pin = Pin(sessionId: holding.sessionId, heldAgainst: holding.heldAgainst.intersection(above))
                    shown = holding.sessionId
                    return Pick(status: pinned, recheckAt: holdEnds(rising))
                }
                pin = nil
            } else {
                pin = nil
            }

            guard let current else {
                // Nothing shown, or it's gone: the best there is, at once.
                guard let best = best(of: pool, ranks: ranks) else {
                    shown = nil
                    return Pick(status: .disconnected, recheckAt: nil)
                }
                shown = best.sessionId
                return Pick(status: best, recheckAt: nil)
            }
            let above = pool.filter { $0.sessionId != current.sessionId && rankOf($0) > rankOf(current) }
            let ready = above.filter(held)
            if let best = best(of: ready, ranks: ranks) {
                shown = best.sessionId
                return Pick(status: best, recheckAt: nil)
            }
            return Pick(status: current, recheckAt: holdEnds(above))
        }

        /// The highest rank; then the session the user last saw or chose;
        /// then the newest record; then the id.
        private func best(of pool: [ClaudeStatus], ranks: [String: Rank]) -> ClaudeStatus? {
            pool.max { a, b in
                let ra = a.sessionId.flatMap { ranks[$0] } ?? .none, rb = b.sessionId.flatMap { ranks[$0] } ?? .none
                if ra != rb { return ra < rb }
                let sa = a.sessionId.flatMap { lastSeen[$0] } ?? .distantPast
                let sb = b.sessionId.flatMap { lastSeen[$0] } ?? .distantPast
                if sa != sb { return sa < sb }
                let ua = a.updatedAt ?? .distantPast, ub = b.updatedAt ?? .distantPast
                if ua != ub { return ua < ub }
                return (a.sessionId ?? "") > (b.sessionId ?? "")
            }
        }
    }
}

/// One live session, as a row of the list — or a background session agent
/// view lists that has no live process to be live in (Milestone 21).
struct ClaudeSessionRow: Identifiable, Equatable {
    let id: String
    let project: String?
    /// The state the row reports — the record's, after the same corrections
    /// the island makes (see `NotchViewModel.updateSessionList`).
    let state: ClaudeCodeState
    let errorType: String?
    /// For a usage limit, what Claude Code said comes next (Milestone 19).
    let limitNext: ClaudeLimitNext?
    let limitKind: String?
    /// What it's doing, what it's asking, or what Claude said last.
    let detail: String
    /// When the session's hook last wrote. Nil for a background session no
    /// hook has written for — the row then shows no age.
    let updatedAt: Date?
    /// For a session agent view hosts (Milestone 21): its name, how to
    /// attach to it, and Claude Code's state for it.
    let background: ClaudeBackgroundInfo?
    /// The state is Claude Code's (`claude agents`), not a hook's.
    let stateFromAgent: Bool

    /// What the row is called: a background session by its own name, any
    /// other by its project.
    var label: String? {
        background?.name ?? project
    }

    /// A background session Claude Code reports finished — done, failed or
    /// stopped — is drawn quieter than the ones still going.
    var isQuiet: Bool {
        background?.isFinished ?? false
    }

    /// The marker the row draws: the island's own mapping, failure kinds and
    /// all.
    var markerKind: MarkerKind {
        ClaudeSessionRow.markerKind(state: state, errorType: errorType)
    }

    /// The state in a word or two, as the face's headline and the home tile
    /// say it. Claude Code's own word when the state came from it.
    var stateTitle: String {
        if stateFromAgent, let agentState = background?.state {
            return ClaudeBackground.title(for: agentState, waitingFor: background?.waitingFor)
        }
        switch state {
        case .needsApproval: return "Needs approval"
        case .needsQuestion: return "Question"
        case .working: return "Working"
        case .compacting: return "Compacting"
        case .waitingInput: return "Waiting"
        case .done: return "Done"
        case .idle: return "Ready"
        case .failed:
            return errorType == "usage_limit" ? ClaudeLimit.headline(kind: limitKind, next: limitNext) : "Error"
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
    ///
    /// A background session's row (Milestone 21) carries `background`. When
    /// its state is Claude Code's rather than a hook's (`status.fromAgent`),
    /// the detail is what `claude agents` gives — the project, and what it's
    /// waiting for when it names it — or, for a turn the hooks saw end,
    /// Claude's own last words.
    init(_ status: ClaudeStatus, request: ClaudeRequest?, background: ClaudeBackgroundInfo? = nil) {
        id = status.sessionId ?? ""
        project = status.project.flatMap { $0.isEmpty ? nil : $0 }
        state = status.state
        errorType = status.errorType
        limitNext = status.limitNext
        limitKind = status.limitKind
        updatedAt = status.updatedAt
        self.background = background
        stateFromAgent = status.fromAgent && background?.state != nil
        let activity = ClaudeActivity(action: status.action, target: status.target)?.phrase
        let said = ClaudeDoneLine.line(from: status.lastMessage)
        if self.stateFromAgent, let background {
            // What it's waiting for first, so a narrow row cuts the project
            // rather than it — except a permission prompt, which the state
            // ("Needs approval") already says.
            let waiting = background.waitingFor == "permission prompt"
                ? nil : ClaudeBackground.waitingPhrase(background.waitingFor)
            let whereAndWhat = [waiting, project ?? background.project]
                .compactMap { $0 }
                .joined(separator: " · ")
            let fallback = whereAndWhat.isEmpty ? "In the background" : whereAndWhat
            switch background.state {
            case .working?: detail = fallback
            default: detail = said ?? fallback
            }
            return
        }
        // No terminal to answer in: a background session is answered by
        // attaching to it.
        let answerIn = background?.attachId != nil ? "Attach to answer" : "Answer in its terminal"
        switch status.state {
        case .working:
            let doing = activity ?? (status.limitNext == .resumed ? ClaudeLimit.resumedLine(kind: status.limitKind) : "Thinking…")
            // Its subagents (Milestone 22), counted ahead of the tool so a
            // narrow row cuts the tool rather than the count.
            let working = status.subagents.isEmpty ? doing : "\(ClaudeSubagents.count(status.subagents)) · \(doing)"
            // A block auto mode made this turn (Milestone 23) ahead of both:
            // the row is where it's seen when an alert elsewhere held the
            // island and its toast was dropped.
            detail = status.blocked.map { "\($0.rowPhrase) · \(working)" } ?? working
        case .compacting:
            detail = "Compacting the conversation"
        case .needsApproval:
            detail = request.map(Self.approvalLine) ?? activity ?? answerIn
        case .needsQuestion:
            detail = request?.questions.first?.question ?? answerIn
        case .waitingInput:
            detail = Self.leftFirst(status, said ?? "Ready for your next prompt")
        case .done:
            detail = Self.leftFirst(status, said ?? "Finished responding")
        case .idle:
            detail = Self.leftFirst(status, said ?? "Session ready")
        case .failed:
            if status.errorType == "usage_limit" {
                detail = ClaudeLimit.shortDetail(resetAt: status.resetAt, next: status.limitNext) ?? "Limit reached"
            } else {
                detail = "The turn stopped on an error"
            }
        case .disconnected:
            detail = ""
        }
    }

    /// What the turn left running or scheduled (Milestone 20) ahead of what
    /// Claude said, so a narrow row cuts the words rather than it: "Left npm
    /// running · I've started the dev server…".
    private static func leftFirst(_ status: ClaudeStatus, _ rest: String) -> String {
        guard let phrase = status.left?.shown()?.rowPhrase() else { return rest }
        return "\(phrase) · \(rest)"
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
