//
//  session-priority-tests.swift
//
//  Which session the island shows, with several sessions changing at once
//  (`ClaudeSelection.Selector`): a strict order of ranks, a session kept
//  through ties, a higher rank taking the island only once it has held
//  (approvals and questions at once), the next pick when the shown session
//  drops, a picked session pinned, nothing switching while a reply is
//  written — and no flip-flop through interleaved streams from two and
//  three sessions. Pure: no bridge, no clock but the one passed in.
//
//  Run with scripts/test-session-priority.sh.
//

import Foundation

var failures = 0
var passes = 0
func check(_ ok: Bool, _ name: String, _ detail: String = "") {
    if ok { passes += 1 } else { failures += 1 }
    print("  \(ok ? "ok  " : "FAIL")  \(name)\(detail.isEmpty ? "" : "  [\(detail)]")")
}

let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

func status(_ id: String, _ state: ClaudeCodeState, updated: Double = 0) -> ClaudeStatus {
    var s = ClaudeStatus(state: state, project: id, sessionId: id)
    s.updatedAt = at(updated)
    return s
}

/// A run of the selector over a timeline: the pool as it stands at each
/// moment (each session's latest state), the pick after each, and how many
/// times the island changed hands.
struct Run {
    var selector = ClaudeSelection.Selector()
    var pool: [String: ClaudeStatus] = [:]
    var seen: Set<String> = []
    var shown: [String] = []
    var times: [Double] = []
    var frozen = false

    mutating func at(_ time: Double, _ id: String, _ state: ClaudeCodeState) -> String {
        pool[id] = status(id, state, updated: time)
        return pick(time)
    }

    mutating func pick(_ time: Double) -> String {
        let ordered = pool.keys.sorted().map { pool[$0]! }
        let seen = self.seen
        let picked = selector.select(from: ordered, seen: { seen.contains($0.sessionId ?? "") },
                                     now: t0.addingTimeInterval(time), frozen: frozen)
        let id = picked.status.sessionId ?? "-"
        shown.append(id)
        times.append(time)
        return id
    }

    var switches: Int { zip(shown, shown.dropFirst()).filter { $0 != $1 }.count }
}

print("The order")
check(ClaudeSelection.rank(status("a", .needsApproval), seen: false) > ClaudeSelection.rank(status("a", .needsQuestion), seen: false)
      && ClaudeSelection.rank(status("a", .needsQuestion), seen: false) > ClaudeSelection.rank(status("a", .done), seen: false)
      && ClaudeSelection.rank(status("a", .done), seen: false) > ClaudeSelection.rank(status("a", .failed), seen: false)
      && ClaudeSelection.rank(status("a", .failed), seen: false) > ClaudeSelection.rank(status("a", .working), seen: false)
      && ClaudeSelection.rank(status("a", .working), seen: false) > ClaudeSelection.rank(status("a", .idle), seen: false),
      "approval > question > finished-unseen > error > working > ready")
check(ClaudeSelection.rank(status("a", .done), seen: true) == ClaudeSelection.rank(status("a", .idle), seen: false),
      "a Done already seen is just ready")

print("Ties keep the session on the island")
do {
    var run = Run()
    _ = run.at(0, "a", .working)
    _ = run.at(0.1, "b", .working)
    // B keeps writing newer records; A is shown; nothing re-sorts.
    for i in 1...30 { _ = run.at(0.1 + Double(i) * 0.3, i % 2 == 0 ? "b" : "a", .working) }
    check(Set(run.shown) == ["a"], "A working stays through 30 newer records from B", run.shown.suffix(3).joined())
}

print("A blip can't steal the island")
do {
    var run = Run()
    _ = run.at(0, "a", .working)
    _ = run.at(0.2, "b", .working)
    _ = run.at(1.0, "b", .failed)       // a failure for 0.5s, then back to work
    _ = run.pick(1.3)
    _ = run.at(1.5, "b", .working)
    _ = run.pick(2.5)
    check(Set(run.shown) == ["a"], "B's half-second error never takes it", run.shown.joined())
    _ = run.at(3.0, "b", .failed)       // an error that holds
    let early = run.pick(3.6)
    let held = run.pick(4.05)
    check(early == "a" && held == "b", "an error that holds a second does", "\(early) then \(held)")
}

print("Approvals and questions take it at once")
do {
    var run = Run()
    _ = run.at(0, "a", .working)
    _ = run.at(0.5, "b", .working)
    check(run.at(1.0, "b", .needsApproval) == "b", "B's approval, the moment it arrives")
    check(run.at(1.2, "a", .needsQuestion) == "b", "A's question doesn't take it from B's approval (lower)")
    // B's approval answered: B is working, A's question is the highest.
    check(run.at(2.0, "b", .working) == "a", "approval answered: the question next, at once")
}

print("When the shown session drops, the next is chosen the same way every time")
do {
    var run = Run()
    _ = run.at(0, "a", .needsApproval)
    _ = run.at(0.1, "b", .failed)
    _ = run.at(0.2, "c", .failed)
    run.selector.lastSeen = ["c": at(-60), "b": at(-120)]
    _ = run.pick(2)
    check(run.at(3, "a", .working) == "c", "two errors: the one seen last (C)")
    var again = Run()
    _ = again.at(0, "a", .needsApproval)
    _ = again.at(0.1, "b", .failed)
    _ = again.at(0.2, "c", .failed)
    _ = again.pick(2)
    check(again.at(3, "a", .working) == "c", "none seen: the newest record (C)")
}

print("Finished and unseen outranks working, until it's seen")
do {
    var run = Run()
    _ = run.at(0, "a", .working)
    _ = run.at(0.5, "b", .working)
    _ = run.at(1, "b", .done)
    check(run.pick(1.5) == "a", "B's Done waits out its second")
    check(run.pick(2.1) == "b", "then takes the island")
    run.seen = ["b"]
    check(run.pick(2.2) == "a", "once seen, B is just ready: the working session comes back")
}

print("A picked session is pinned until a higher rank rises elsewhere")
do {
    var run = Run()
    _ = run.at(0, "a", .working)
    _ = run.at(0.1, "b", .idle)
    _ = run.at(0.2, "c", .idle)
    _ = run.pick(1)
    run.selector.pin = ClaudeSelection.pin("c", in: Array(run.pool.values), seen: { _ in false })
    check(run.pick(1.1) == "c", "C pinned over A working (already above it when picked)")
    for i in 0..<10 { _ = run.at(1.2 + Double(i) * 0.2, "a", .working) }
    check(run.shown.last == "c", "A's records keep coming: C stays")
    _ = run.at(4, "b", .failed)
    check(run.pick(4.5) == "c" && run.pick(5.1) == "b", "B's error rises and holds: the pin gives way",
          run.shown.suffix(2).joined())
    check(run.selector.pin == nil, "and the pin is gone")
}

print("Nothing switches while a reply is written")
do {
    var run = Run()
    _ = run.at(0, "a", .working)
    run.frozen = true
    _ = run.at(1, "b", .needsApproval)
    _ = run.at(3, "a", .done)
    check(Set(run.shown) == ["a"], "not even for an approval")
    run.frozen = false
    check(run.pick(4) == "b", "the approval, once the reply is sent or put away")
}

print("No flip-flop: three sessions interleaved")
do {
    var run = Run()
    // A tool loop in A and B, C idle, with A and B blipping through short
    // states as hooks race; then B finishes, then C asks a question.
    var time = 0.0
    var flips = 0
    for step in 0..<120 {
        time += 0.15
        let a: ClaudeCodeState = step % 7 == 3 ? .compacting : .working
        let b: ClaudeCodeState = step < 80 ? (step % 9 == 4 ? .failed : .working) : .done
        _ = run.at(time, "a", a)
        _ = run.at(time + 0.01, "b", b)
        if step == 100 { _ = run.at(time + 0.02, "c", .needsQuestion) } else if step < 100 { _ = run.at(time + 0.02, "c", .idle) }
    }
    // An A→B→A inside two seconds is a flip-flop.
    var last: [(String, Double)] = []
    for (id, time) in zip(run.shown, run.times) where last.last?.0 != id { last.append((id, time)) }
    for w in last.indices.dropFirst(2) where last[w].0 == last[w - 2].0 && last[w].1 - last[w - 2].1 < 2 { flips += 1 }
    check(flips == 0, "no session leaves and comes back within two seconds", "\(last.map(\.0).joined(separator: "→"))")
    check(run.switches <= 3, "the island changes hands only for real news", "\(run.switches) switches: \(last.map(\.0).joined(separator: "→"))")
    check(run.shown.last == "c", "and ends on C's question")

    // For comparison, the rule before this one — urgency, then the newest
    // record — over the same stream.
    var pool: [String: ClaudeStatus] = [:]
    var oldShown: [String] = []
    var t = 0.0
    for step in 0..<120 {
        t += 0.15
        let a: ClaudeCodeState = step % 7 == 3 ? .compacting : .working
        let b: ClaudeCodeState = step < 80 ? (step % 9 == 4 ? .failed : .working) : .done
        for (id, state, dt) in [("a", a, 0.0), ("b", b, 0.01)] {
            pool[id] = status(id, state, updated: t + dt)
            oldShown.append(ClaudeSelection.ranked(pool.keys.sorted().map { pool[$0]! }).first?.sessionId ?? "-")
        }
        if step <= 100 {
            pool["c"] = status("c", step == 100 ? .needsQuestion : .idle, updated: t + 0.02)
            oldShown.append(ClaudeSelection.ranked(pool.keys.sorted().map { pool[$0]! }).first?.sessionId ?? "-")
        }
    }
    let oldSwitches = zip(oldShown, oldShown.dropFirst()).filter { $0 != $1 }.count
    print("        (the old rule changed hands \(oldSwitches) times on this stream; this one \(run.switches))")
}

print("\n\(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
