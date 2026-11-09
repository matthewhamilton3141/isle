//
//  ClaudeTrail.swift
//
//  The steps a turn has taken so far, for the working face's trail under
//  what Claude is doing now: "Read NotchMetrics.swift", "Ran xcodebuild".
//
//  Built from the session's records as they arrive — no new hook, nothing
//  new in the record. A record with a tool named and `tool_active` false is
//  that tool's PostToolUse (or PostToolUseFailure): the call ran. A
//  PreToolUse has `tool_active` true and isn't a step yet, so a call that
//  was denied, or is still waiting on an approval, never shows as done.
//
//  What it can't promise is every step. The watcher coalesces a burst of
//  writes into one read, so a quick call that started and finished between
//  two reads is never seen, and parallel calls share the one record. Every
//  step the trail shows ran, in the order shown; it just isn't a count, so
//  nothing reads one off it.
//
//  Kept per session in memory, and cleared when a turn starts: a working
//  record after one that ended the turn (Done, Ready, Waiting, an error).
//  Pure, so it's tested without a bridge (scripts/test-claude-activity.sh).
//

import Foundation

struct ClaudeTrail: Equatable {
    /// One finished call. `id` is unique within the trail, for the rows'
    /// identity as they slide in.
    struct Step: Equatable, Identifiable {
        let id: Int
        let activity: ClaudeActivity
    }

    /// What a record says about the turn, as far as the trail cares.
    enum Phase {
        /// Working or compacting: a step may have finished.
        case working
        /// Done, Ready, Waiting for you, an error, no session: the turn is
        /// over, and the next working record starts a new one.
        case ended
        /// A request waiting on the user: neither.
        case waiting
    }

    /// The most kept: the face shows three, and one more stands behind the
    /// newest when it's the call the face's headline already names.
    static let capacity = 4

    /// Oldest first.
    private(set) var steps: [Step] = []
    private var nextId = 0
    private var ended = false

    /// The first line of the prompt that started this turn, once read from
    /// the session's transcript (`turnPrompt`). Nil until it has been, and
    /// cleared with the trail when a new turn starts.
    private(set) var prompt: String?
    /// When this turn started, as the first working record after the last
    /// turn's end was written: what a prompt read from the transcript must
    /// be at least as new as. Nil for a turn already running when the trail
    /// was made (Isle launched mid-turn), when the newest prompt is the one.
    private(set) var turnStartedAt: Date?

    /// The turn is running and its prompt hasn't been read yet.
    var wantsPrompt: Bool { !ended && prompt == nil }

    mutating func setPrompt(_ prompt: String?) {
        guard !ended else { return }
        self.prompt = prompt
    }

    /// Takes in one record of the session, written at `at`.
    mutating func observe(phase: Phase, action: String?, target: String?, toolActive: Bool, at: Date? = nil) {
        switch phase {
        case .ended:
            ended = true
            return
        case .waiting:
            return
        case .working:
            if ended {
                ended = false
                steps.removeAll()
                prompt = nil
                turnStartedAt = at
            }
        }
        guard !toolActive, let activity = ClaudeActivity(action: action, target: target) else { return }
        // The same record read again — a rewrite for a subagent's start or
        // stop carries the last call as it was — isn't a second step.
        guard steps.last?.activity != activity else { return }
        steps.append(Step(id: nextId, activity: activity))
        nextId += 1
        if steps.count > Self.capacity { steps.removeFirst(steps.count - Self.capacity) }
    }

    /// The steps before the one the face's headline names, newest first, at
    /// most `limit`. `current` is the call in the headline: the newest step
    /// is dropped when it's that call, since the headline already says it.
    func shown(current: ClaudeActivity?, limit: Int) -> [Step] {
        var recent = Array(steps.reversed())
        if let first = recent.first, first.activity == current { recent.removeFirst() }
        return Array(recent.prefix(max(0, limit)))
    }

    // MARK: - The turn's prompt

    /// The first line of the prompt that started the turn, from a session's
    /// transcript lines, newest first: the newest user entry a person typed
    /// (`origin.kind == "human"`), at least as new as `since` (less a few
    /// seconds: the transcript and the hook stamp the same moment from
    /// different clocks). A prompt typed while Claude was working isn't one:
    /// Claude Code files it as a `queue-operation` and hands it over as an
    /// attachment, never as a user entry (measured, 2.1.321), so the newest
    /// such entry is the turn's own. Slash commands and Claude Code's own
    /// wrappers (text starting with "<") aren't a prompt to show. Nil when
    /// there's none in reach — the trail then shows no prompt rather than a
    /// guess.
    static func turnPrompt(in lines: [Data], since: Date?) -> String? {
        for line in lines {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  object["type"] as? String == "user"
            else { continue }
            if let since, let stamp = object["timestamp"] as? String, let at = date(stamp),
               at < since.addingTimeInterval(-3) {
                return nil
            }
            guard let origin = object["origin"] as? [String: Any], origin["kind"] as? String == "human",
                  let message = object["message"] as? [String: Any]
            else { continue }
            let content: String
            if let string = message["content"] as? String {
                content = string
            } else if let blocks = message["content"] as? [[String: Any]] {
                content = blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
            } else {
                continue
            }
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("<") else { return nil }
            let first = trimmed.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? trimmed
            return first.trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private static func date(_ string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}
