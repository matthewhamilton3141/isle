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

    /// Takes in one record of the session.
    mutating func observe(phase: Phase, action: String?, target: String?, toolActive: Bool) {
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
}
