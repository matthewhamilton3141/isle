//
//  background-sessions-tests.swift
//
//  Tests for background sessions in the list (Milestone 21): the
//  `claude agents --json` parser against real output from 2.1.319, the merge
//  with the bridge's own sessions, and the view model's list, counts and pin
//  through `applyTestReading` / `applyTestAgents`. Compiled with every Isle
//  source by scripts/test-background-sessions.sh; nothing here runs `claude`
//  or touches ~/.claude.
//

import AppKit
import Foundation

var failures = 0
var passes = 0

func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    if ok {
        passes += 1
        print("  ok    \(name)")
    } else {
        failures += 1
        let more = detail()
        print("  FAIL  \(name)" + (more.isEmpty ? "" : "\n        \(more)"))
    }
}

func equal<T: Equatable>(_ got: T, _ want: T, _ name: String) {
    check(got == want, name, "want \(want)\n        got  \(got)")
}

func parse(_ json: String) -> [ClaudeAgent]? {
    ClaudeAgentsParser.parse(Data(json.utf8))
}

func agent(_ id: String, _ state: ClaudeAgent.State?, name: String? = nil, cwd: String = "/Users/me/proj",
           pid: pid_t? = nil, waitingFor: String? = nil, sessionId: String? = nil,
           kind: String = "background", lastChange: Date? = nil) -> ClaudeAgent {
    ClaudeAgent(id: id, sessionId: sessionId ?? "\(id)-0000-0000-0000-000000000000", name: name, cwd: cwd,
                kind: kind, state: state, pid: pid, status: pid == nil ? nil : "idle",
                waitingFor: waitingFor, startedAt: nil, lastChange: lastChange)
}

func hook(_ id: String, _ project: String, _ state: ClaudeCodeState, ago: TimeInterval = 30,
          said: String? = nil, action: String? = nil, target: String? = nil) -> ClaudeStatus {
    ClaudeStatus(state: state, project: project, sessionId: id, action: action, target: target,
                 updatedAt: Date().addingTimeInterval(-ago), lastMessage: said)
}

func registry(_ id: String, pid: pid_t, cwd: String = "/Users/me/proj", kind: String = "interactive",
              jobId: String? = nil, name: String? = nil) -> ClaudeSession {
    ClaudeSession(pid: pid, sessionId: id, cwd: cwd, name: name, kind: kind, status: .idle,
                  waitingFor: nil, statusUpdatedAt: nil, startedAt: nil, cliVersion: "2.1.319", jobId: jobId)
}

@main
enum Tests {
    @MainActor
    static func main() {
        let fixtures = URL(fileURLWithPath: CommandLine.arguments[1])
        NSApplication.shared.setActivationPolicy(.prohibited)
        parserTests(fixtures)
        mergeTests()
        staleTests(fixtures)
        rowTests()
        attachTests()
        viewModelTests()
        runnerTests()
        print("\n\(passes) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - Running the CLI

    /// `ClaudeCLI.run`, on fake commands: never wedged by a child that
    /// leaves something holding its stdout, never past its timeout.
    static func runnerTests() {
        print("Running the CLI, bounded")
        let sh = URL(fileURLWithPath: "/bin/sh")
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("isle-runner-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        func timed(_ body: () -> Data?) -> (Data?, TimeInterval) {
            let start = Date()
            let out = body()
            return (out, Date().timeIntervalSince(start))
        }
        func text(_ data: Data?) -> String? { data.map { String(decoding: $0, as: UTF8.self) } }
        func alive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 || errno == EPERM }
        func pid(in file: URL) -> pid_t? {
            (try? String(contentsOf: file, encoding: .utf8))
                .flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        func gone(_ pid: pid_t, within seconds: TimeInterval) -> Bool {
            let until = Date().addingTimeInterval(seconds)
            while Date() < until {
                if !alive(pid) { return true }
                usleep(20_000)
            }
            return !alive(pid)
        }

        var (out, took) = timed { ClaudeCLI.run(sh, ["-c", "echo '[]'"], timeout: 5) }
        equal(text(out), "[]\n", "a plain run: its stdout")
        check(took < 1, "promptly", "\(took)s")
        (out, _) = timed { ClaudeCLI.run(sh, ["-c", "echo nope; exit 3"], timeout: 5) }
        check(out == nil, "a non-zero exit: nil")
        (out, _) = timed { ClaudeCLI.run(sh, ["-c", "head -c 300000 /dev/zero"], timeout: 5) }
        equal(out?.count, 300000, "more than a pipe's buffer, all of it")

        // The wedge: the child exits 0, but a grandchild it left behind
        // still has its stdout. Reading to EOF waited the grandchild out.
        let lingering = scratch.appendingPathComponent("lingering.pid")
        (out, took) = timed {
            ClaudeCLI.run(sh, ["-c", "echo '[]'; sleep 30 & echo $! > '\(lingering.path)'; exit 0"], timeout: 8)
        }
        equal(text(out), "[]\n", "a grandchild holding stdout after the child exits: the child's output")
        check(took < 1.5, "without waiting the grandchild out", "\(took)s")
        if let grandchild = pid(in: lingering) { kill(grandchild, SIGKILL) }

        // A child that never finishes, with a grandchild on the pipe too:
        // the timeout ends the lot.
        let hung = scratch.appendingPathComponent("hung.pid")
        (out, took) = timed {
            ClaudeCLI.run(sh, ["-c", "sleep 30 & echo $! > '\(hung.path)'; echo partial; sleep 30"], timeout: 1)
        }
        check(out == nil, "a run that outlives its timeout: nil")
        check(took < 2, "returns at the timeout, not when the children finish", "\(took)s")
        if let grandchild = pid(in: hung) {
            check(gone(grandchild, within: 1), "and the grandchild is killed with it (its process group)")
        } else {
            check(false, "the grandchild wrote its pid")
        }

        // Ignores SIGTERM: SIGKILL follows.
        (out, took) = timed { ClaudeCLI.run(sh, ["-c", "trap '' TERM; sleep 30"], timeout: 0.5) }
        check(out == nil && took < 2, "a child that ignores SIGTERM is killed all the same", "\(took)s")

        // The serial queue the monitor reads on keeps moving.
        let queue = DispatchQueue(label: "isle.runner-test")
        let done = DispatchSemaphore(value: 0)
        let stray = scratch.appendingPathComponent("stray.pid")
        queue.async { _ = ClaudeCLI.run(sh, ["-c", "sleep 30 & echo $! > '\(stray.path)'; exit 0"], timeout: 8) }
        queue.async { done.signal() }
        check(done.wait(timeout: .now() + 2) == .success, "the next read on the same serial queue isn't stuck behind it")
        if let grandchild = pid(in: stray) { kill(grandchild, SIGKILL) }

        setenv("CLAUDECODE", "1", 1)
        (out, _) = timed { ClaudeCLI.run(sh, ["-c", "echo ${CLAUDECODE-unset}"], timeout: 5) }
        unsetenv("CLAUDECODE")
        equal(text(out), "unset\n", "CLAUDECODE isn't passed on")
        (out, _) = timed { ClaudeCLI.run(URL(fileURLWithPath: "/nonexistent/claude"), [], timeout: 5) }
        check(out == nil, "no such binary: nil")
    }

    // MARK: - Parsing

    static func parserTests(_ fixtures: URL) {
        print("The real output (claude agents --json --all, 2.1.319, this Mac)")
        let real = try! Data(contentsOf: fixtures.appendingPathComponent("claude-agents-2.1.319.json"))
        let agents = ClaudeAgentsParser.parse(real)
        equal(agents?.count, 4, "four entries")
        if let agents, agents.count == 4 {
            let bg = agents[0]
            equal(bg.kind, "background", "the first is background")
            check(bg.isBackground, "isBackground")
            equal(bg.id, "30d0d02c", "its short id")
            equal(bg.attachId, "30d0d02c", "which is safe to attach with")
            equal(bg.sessionId, "30d0d02c-03cd-4849-bcfd-5c8c43c49dc9", "its session id")
            equal(bg.name, "Redesign grid system and modernize app chrome", "its name")
            equal(bg.state, .blocked, "blocked")
            equal(bg.pid, nil, "no pid: its process has exited")
            equal(bg.status, nil, "and so no status")
            equal(bg.waitingFor, nil, "and no waitingFor")
            equal(bg.project, "retermina", "project from cwd")
            equal(bg.startedAt.map { Int($0.timeIntervalSince1970) }, 1781978364, "startedAt from millis")
            let waiting = agents[1]
            equal(waiting.kind, "interactive", "the second is interactive")
            check(!waiting.isBackground, "not background")
            equal(waiting.pid, 38412, "with its pid")
            equal(waiting.status, "waiting", "status waiting")
            equal(waiting.waitingFor, "dialog open", "waiting for a dialog")
            equal(waiting.state, nil, "and no state: that's background only")
            equal(waiting.id, nil, "nor a short id")
            equal(agents[3].status, "busy", "the last is busy")
        }

        print("Shapes seen during the probe runs")
        let probe = try! Data(contentsOf: fixtures.appendingPathComponent("claude-agents-2.1.319-probe.json"))
        if let p = ClaudeAgentsParser.parse(probe), p.count == 3 {
            equal(p[0].state, .blocked, "blocked on a permission prompt")
            equal(p[0].waitingFor, "permission prompt", "names it")
            equal(p[0].pid, 94941, "while its process is alive")
            equal(p[1].state, .done, "done with its process still up")
            equal(p[1].pid, 94930, "pid present")
            equal(p[2].state, .done, "done after `claude stop`: the state stays done")
            equal(p[2].pid, nil, "and the pid goes")
        } else {
            check(false, "probe fixture parses to three")
        }

        print("Edge cases")
        equal(parse("not json"), nil, "malformed JSON is nil, not empty")
        equal(parse("{\"cwd\":\"/x\",\"kind\":\"background\"}"), nil, "an object, not an array, is nil")
        equal(parse("Error: unknown option '--json'"), nil, "an older CLI's error text is nil")
        equal(parse("")?.count, nil, "no output is nil")
        equal(parse("[]")?.count, 0, "an empty list is empty")
        equal(parse("[1, \"x\", null, []]")?.count, 0, "elements that aren't objects are skipped")
        equal(parse("[{\"kind\":\"background\",\"id\":\"a\"}]")?.count, 0, "no cwd: skipped")
        equal(parse("[{\"cwd\":\"/x\",\"id\":\"a\"}]")?.count, 0, "no kind: skipped")
        equal(parse("[{\"cwd\":\"\",\"kind\":\"background\"}]")?.count, 0, "an empty cwd: skipped")
        let minimal = parse("[{\"cwd\":\"/x/y\",\"kind\":\"background\"}]")?.first
        check(minimal != nil, "cwd and kind alone parse")
        equal(minimal?.state, nil, "with no state")
        equal(minimal?.attachId, nil, "and no id to attach with")
        equal(parse("[{\"cwd\":\"/x\",\"kind\":\"background\",\"state\":\"paused\"}]")?.first?.state,
              .other("paused"), "an unknown state is kept, verbatim")
        equal(parse("[{\"cwd\":\"/x\",\"kind\":\"background\",\"state\":\"  \"}]")?.first?.state, nil,
              "a blank state is none")
        equal(parse("[{\"cwd\":\"/x\",\"kind\":\"interactive\",\"pid\":\"38412\"}]")?.first?.pid, nil,
              "a pid of the wrong type reads as absent")
        equal(parse("[{\"cwd\":\"/x\",\"kind\":\"interactive\",\"pid\":-4}]")?.first?.pid, nil, "a negative pid is none")
        equal(parse("[{\"cwd\":\"/x\",\"kind\":\"interactive\",\"pid\":99999999999}]")?.first?.pid, nil,
              "a pid past pid_t is none")
        equal(parse("[{\"cwd\":\"/x\",\"kind\":\"background\",\"name\":\"\"}]")?.first?.name, nil, "an empty name is none")
        equal(parse("[{\"cwd\":\"/x\",\"kind\":\"background\",\"name\":42}]")?.first?.name, nil,
              "a name of the wrong type is none")
        equal(parse("[{\"cwd\":\"/x\",\"kind\":\"background\",\"future\":{\"a\":1},\"state\":\"working\"}]")?.first?.state,
              .working, "unknown fields are ignored")
        equal(parse("[{\"cwd\":\"/\",\"kind\":\"background\"}]")?.first?.project, nil, "cwd / has no project")

        print("Attach ids")
        func attach(_ id: String) -> String? { ClaudeAgent(id: id, cwd: "/", kind: "background").attachId }
        equal(attach("7c5dcf5d"), "7c5dcf5d", "eight hex digits")
        equal(attach("job_1-a"), "job_1-a", "letters, digits, - and _")
        equal(attach("; rm -rf ~"), nil, "shell syntax is refused")
        equal(attach("$(id)"), nil, "a substitution is refused")
        equal(attach("-rf"), nil, "a leading - (an option) is refused")
        equal(attach("abc def"), nil, "a space is refused")
        equal(attach("café"), nil, "non-ASCII is refused")
        equal(attach(String(repeating: "a", count: 65)), nil, "past 64 characters is refused")
    }

    // MARK: - Merging

    static func mergeTests() {
        let now = Date()
        print("Merging with the bridge")

        // A live background session the hooks see: one row, enriched.
        let live = agent("9feb2230", .done, name: "m21-probe-a", pid: 94930)
        var m = ClaudeBackground.merge(hookSessionIds: [live.sessionId!], registry: [], agents: [live],
                                       finishedAt: [:], now: now)
        equal(m.agentOnly.count, 0, "a hook-backed background session isn't listed twice")
        equal(m.info[live.sessionId!]?.name, "m21-probe-a", "it carries its name")
        equal(m.info[live.sessionId!]?.attachId, "9feb2230", "and its attach id")
        equal(m.info[live.sessionId!]?.hasHookRecord, true, "and knows the hooks cover it")

        // A resumed copy: the hook's session id differs from the job's, but
        // the registry names the job.
        let resumed = agent("30d0d02c", .working, name: "Redesign", pid: 501,
                            sessionId: "30d0d02c-03cd-4849-bcfd-5c8c43c49dc9")
        m = ClaudeBackground.merge(hookSessionIds: ["84fa003a-hook"],
                                   registry: [registry("84fa003a-hook", pid: 501, kind: "bg", jobId: "30d0d02c")],
                                   agents: [resumed], finishedAt: [:], now: now)
        equal(m.agentOnly.count, 0, "matched by the registry's jobId: still one row")
        equal(m.info["84fa003a-hook"]?.name, "Redesign", "under the hook's id")
        m = ClaudeBackground.merge(hookSessionIds: ["other-id"],
                                   registry: [registry("other-id", pid: 501, kind: "bg")],
                                   agents: [resumed], finishedAt: [:], now: now)
        equal(m.agentOnly.count, 0, "matched by pid when nothing else matches")

        // The registry alone, before `claude agents` has been read.
        m = ClaudeBackground.merge(hookSessionIds: ["s1"],
                                   registry: [registry("s1", pid: 700, cwd: "/Users/me/site", kind: "bg",
                                                       jobId: "abcd1234", name: "site-fix")],
                                   agents: [], finishedAt: [:], now: now)
        equal(m.info["s1"]?.attachId, "abcd1234", "a bg registry record gives the attach id")
        equal(m.info["s1"]?.name, "site-fix", "and the name")
        equal(m.info["s1"]?.state, nil, "but no state of Claude Code's")
        m = ClaudeBackground.merge(hookSessionIds: ["s2"], registry: [registry("s2", pid: 701)],
                                   agents: [], finishedAt: [:], now: now)
        equal(m.info["s2"], nil, "an interactive session gets nothing")

        // Only agent view knows of these.
        let blocked = agent("30d0d02c", .blocked, name: "Redesign grid system and modernize app chrome",
                            cwd: "/Users/me/retermina")
        let approval = agent("4a2d55f1", .blocked, name: "probe-b", pid: 94941, waitingFor: "permission prompt")
        let working = agent("11111111", .working, name: "Fix flaky test")
        let doneLive = agent("22222222", .done, name: "done-live", pid: 900)
        let doneGone = agent("33333333", .done, name: "done-gone")
        let failedGone = agent("44444444", .failed, name: "failed-gone")
        let stoppedGone = agent("55555555", .stopped, name: "stopped-gone")
        let paused = agent("66666666", .other("paused"), name: "paused", pid: 901)
        let pausedGone = agent("77777777", .other("paused"), name: "paused-gone")
        let interactive = agent("x", nil, pid: 38412, kind: "interactive")
        let noState = agent("88888888", nil, name: "no-state")
        m = ClaudeBackground.merge(
            hookSessionIds: [], registry: [],
            agents: [blocked, approval, working, doneLive, doneGone, failedGone, stoppedGone, paused, pausedGone,
                     interactive, noState],
            finishedAt: [failedGone.sessionId!: now.addingTimeInterval(-600),
                         stoppedGone.sessionId!: now.addingTimeInterval(-7200)],
            now: now)
        let listed = Set(m.agentOnly.compactMap(\.sessionId))
        check(listed.contains(blocked.sessionId!), "blocked with no process is listed")
        check(listed.contains(approval.sessionId!), "blocked on a permission prompt is listed")
        check(listed.contains(working.sessionId!), "working is listed")
        check(listed.contains(doneLive.sessionId!), "done with its process alive is listed")
        check(!listed.contains(doneGone.sessionId!), "done, process gone, never seen finishing: not listed")
        check(listed.contains(failedGone.sessionId!), "failed ten minutes ago, seen by Isle: listed")
        check(!listed.contains(stoppedGone.sessionId!), "stopped two hours ago: not listed")
        check(listed.contains(paused.sessionId!), "an unknown state with a live process is listed")
        check(!listed.contains(pausedGone.sessionId!), "an unknown state with none isn't")
        check(!listed.contains(interactive.sessionId!), "interactive entries are never added")
        check(!listed.contains(noState.sessionId!), "a background entry with no state isn't")
        let state = Dictionary(uniqueKeysWithValues: m.agentOnly.map { ($0.sessionId!, $0) })
        equal(state[blocked.sessionId!]?.state, .needsQuestion, "blocked reads as needing you")
        equal(state[approval.sessionId!]?.state, .needsApproval, "blocked on a permission prompt as an approval")
        equal(state[working.sessionId!]?.state, .working, "working as working")
        equal(state[failedGone.sessionId!]?.state, .failed, "failed as failed")
        equal(state[paused.sessionId!]?.state, .idle, "an unknown state at rest")
        check(m.agentOnly.allSatisfy { $0.fromAgent && $0.updatedAt == nil },
              "agent-only records are marked fromAgent, with no hook time")
        equal(state[blocked.sessionId!]?.project, "retermina", "with the project from cwd")

        print("Resolving a hook record against Claude Code's state")
        let bgId = "bg-1"
        let bgAgent = agent("bbbbbbbb", .blocked, name: "asks", pid: 950, sessionId: bgId)
        m = ClaudeBackground.merge(hookSessionIds: [bgId], registry: [], agents: [bgAgent], finishedAt: [:], now: now)
        let said = "Should I rename it to index.html and commit it?"
        let done = m.resolve(hook(bgId, "retermina", .done, said: said))
        equal(done.state, .needsQuestion, "a turn the hooks saw end reads as blocked")
        check(done.fromAgent, "marked as Claude Code's")
        equal(done.lastMessage, said, "keeping Claude's last words, which are the question")
        equal(m.resolve(hook(bgId, "retermina", .idle)).state, .needsQuestion, "Ready, likewise")
        equal(m.resolve(hook(bgId, "retermina", .waitingInput)).state, .needsQuestion, "Waiting, likewise")
        let workingHook = m.resolve(hook(bgId, "retermina", .working, action: "Bash", target: "npm test"))
        equal(workingHook.state, .working, "a hook saying working wins over a read that may be stale")
        check(!workingHook.fromAgent, "and stays the hook's")
        equal(m.resolve(hook(bgId, "retermina", .needsApproval)).state, .needsApproval,
              "a hook's approval (with buttons) stays an approval")
        equal(m.resolve(hook(bgId, "retermina", .failed)).state, .failed, "a hook's failure stays")
        let doneAgent = agent("bbbbbbbb", .done, name: "asks", pid: 950, sessionId: bgId)
        m = ClaudeBackground.merge(hookSessionIds: [bgId], registry: [], agents: [doneAgent], finishedAt: [:], now: now)
        equal(m.resolve(hook(bgId, "x", .working)).state, .working, "Claude Code's done never overrides a hook")
        equal(m.resolve(hook("someone-else", "x", .done)).state, .done, "a session agent view doesn't host is untouched")

        print("Seeing a session finish")
        let w = agent("cccccccc", .working)
        let d = agent("cccccccc", .done)
        var at = ClaudeBackground.noteFinishes(previous: [w], current: [d], finishedAt: [:], now: now)
        equal(at[d.sessionId!], now, "working then done is a finish, now")
        at = ClaudeBackground.noteFinishes(previous: [d], current: [d], finishedAt: at,
                                           now: now.addingTimeInterval(60))
        equal(at[d.sessionId!], now, "and keeps its time")
        at = ClaudeBackground.noteFinishes(previous: [d], current: [d], finishedAt: at,
                                           now: now.addingTimeInterval(3601))
        equal(at[d.sessionId!], nil, "an hour on, it's forgotten")
        at = ClaudeBackground.noteFinishes(previous: [], current: [d], finishedAt: [:], now: now)
        equal(at[d.sessionId!], nil, "first seen already done (at launch): no finish Isle saw")
        at = ClaudeBackground.noteFinishes(previous: [w], current: [d], finishedAt: [:], now: now)
        at = ClaudeBackground.noteFinishes(previous: [d], current: [w], finishedAt: at, now: now)
        equal(at[d.sessionId!], nil, "working again drops it")
    }

    // MARK: - Stale sessions

    static func staleTests(_ fixtures: URL) {
        let now = Date()
        let day: TimeInterval = 24 * 60 * 60
        print("No process and unchanged for over a day: hidden")
        func listed(_ agents: [ClaudeAgent], finishedAt: [String: Date] = [:], at: Date = now) -> Set<String> {
            Set(ClaudeBackground.merge(hookSessionIds: [], registry: [], agents: agents,
                                       finishedAt: finishedAt, now: at).agentOnly.compactMap(\.sessionId))
        }
        let staleBlocked = agent("a1a1a1a1", .blocked, lastChange: now.addingTimeInterval(-2 * day))
        let staleBlockedLive = agent("a2a2a2a2", .blocked, pid: 4242, lastChange: now.addingTimeInterval(-2 * day))
        let freshBlocked = agent("a3a3a3a3", .blocked, lastChange: now.addingTimeInterval(-23 * 60 * 60))
        let staleWorking = agent("a4a4a4a4", .working, lastChange: now.addingTimeInterval(-3 * day))
        let freshWorking = agent("a5a5a5a5", .working, lastChange: now.addingTimeInterval(-60))
        let undated = agent("a6a6a6a6", .blocked)
        let future = agent("a7a7a7a7", .blocked, lastChange: now.addingTimeInterval(day))
        let staleDoneSeen = agent("a8a8a8a8", .done, lastChange: now.addingTimeInterval(-2 * day))
        let l = listed([staleBlocked, staleBlockedLive, freshBlocked, staleWorking, freshWorking, undated, future,
                        staleDoneSeen],
                       finishedAt: [staleDoneSeen.sessionId!: now.addingTimeInterval(-600)])
        check(!l.contains(staleBlocked.sessionId!), "stale blocked, no process: hidden")
        check(l.contains(staleBlockedLive.sessionId!), "stale blocked with a live process: listed")
        check(l.contains(freshBlocked.sessionId!), "blocked 23 hours ago, no process: listed")
        check(!l.contains(staleWorking.sessionId!), "stale working, no process: hidden")
        check(l.contains(freshWorking.sessionId!), "fresh working, no process: listed")
        check(l.contains(undated.sessionId!), "blocked with no age to go on: listed, as before")
        check(l.contains(future.sessionId!), "a change dated in the future: listed")
        check(l.contains(staleDoneSeen.sessionId!), "the finished rule is unchanged: seen finishing, listed")

        print("The job's age, from its state file")
        let jobs = FileManager.default.temporaryDirectory
            .appendingPathComponent("isle-jobs-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: jobs) }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func write(_ id: String, _ data: Data, modified: Date) {
            let dir = jobs.appendingPathComponent(id, isDirectory: true)
            try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("state.json")
            try! data.write(to: file)
            try! FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
        }

        // The real one: a 2.1.183 job from June, blocked with no process.
        let fixture = try! Data(contentsOf: fixtures.appendingPathComponent("claude-job-2.1.183-stale-blocked-state.json"))
        let updatedAt = iso.date(from: "2026-06-27T06:23:33.300Z")!
        write("30d0d02c", fixture, modified: updatedAt)
        let real = ClaudeAgentsParser.parse(try! Data(contentsOf: fixtures.appendingPathComponent("claude-agents-2.1.319.json")))!
        let dated = ClaudeJobs.dated(real, jobsURL: jobs)
        equal(dated[0].lastChange.map { $0.timeIntervalSince1970.rounded() }, updatedAt.timeIntervalSince1970.rounded(),
              "the retermina job's lastChange is its updatedAt")
        check(dated[1...].allSatisfy { $0.lastChange == nil }, "interactive entries aren't dated")
        check(!listed(dated).contains(dated[0].sessionId!), "the retermina job is hidden")
        check(listed(dated, at: iso.date(from: "2026-06-27T12:00:00.000Z")!).contains(dated[0].sessionId!),
              "but was listed the day it changed")

        // The later of updatedAt and the file's date.
        write("b1b1b1b1", Data("{\"sessionId\":\"b1b1b1b1-0000-0000-0000-000000000000\",\"updatedAt\":\"\(iso.string(from: now.addingTimeInterval(-5 * day)))\"}".utf8),
              modified: now.addingTimeInterval(-60))
        let touched = agent("b1b1b1b1", .blocked)
        equal(ClaudeJobs.lastChange(of: touched, jobsURL: jobs).map { Int($0.timeIntervalSince1970) },
              Int(now.addingTimeInterval(-60).timeIntervalSince1970), "a file written since its updatedAt: the later")
        check(listed(ClaudeJobs.dated([touched], jobsURL: jobs)).contains(touched.sessionId!), "and so listed")
        write("b2b2b2b2", Data("{\"updatedAt\":\"\(iso.string(from: now.addingTimeInterval(-60)))\"}".utf8),
              modified: now.addingTimeInterval(-5 * day))
        check(listed(ClaudeJobs.dated([agent("b2b2b2b2", .blocked)], jobsURL: jobs)).count == 1,
              "an old file whose updatedAt is recent: listed")
        write("b3b3b3b3", Data("not json".utf8), modified: now.addingTimeInterval(-5 * day))
        let garbled = ClaudeJobs.dated([agent("b3b3b3b3", .working)], jobsURL: jobs)
        equal(garbled[0].lastChange.map { Int($0.timeIntervalSince1970) },
              Int(now.addingTimeInterval(-5 * day).timeIntervalSince1970), "unreadable JSON: the file's date alone")
        write("b4b4b4b4", Data("{\"sessionId\":\"someone-else\",\"updatedAt\":\"2026-01-01T00:00:00Z\"}".utf8),
              modified: now.addingTimeInterval(-5 * day))
        equal(ClaudeJobs.lastChange(of: agent("b4b4b4b4", .blocked), jobsURL: jobs), nil,
              "a file naming another session: no date")
        equal(ClaudeJobs.lastChange(of: agent("b5b5b5b5", .blocked), jobsURL: jobs), nil, "no file: no date")
        let noId = ClaudeAgent(id: nil, sessionId: "x", cwd: "/x", kind: "background", state: .blocked)
        equal(ClaudeJobs.lastChange(of: noId, jobsURL: jobs), nil, "no short id: no date")
        let unsafe = ClaudeAgent(id: "../b1b1b1b1", sessionId: "x", cwd: "/x", kind: "background", state: .blocked)
        equal(ClaudeJobs.lastChange(of: unsafe, jobsURL: jobs), nil, "an id that isn't a plain name: no date")
        let live = ClaudeJobs.dated([agent("b3b3b3b3", .working, pid: 4243)], jobsURL: jobs)
        equal(live[0].lastChange, nil, "a live process isn't dated: it's listed regardless")
        equal(ClaudeJobs.date("2026-06-27T06:23:33Z").map { Int($0.timeIntervalSince1970) },
              Int(updatedAt.timeIntervalSince1970), "updatedAt without fractional seconds")
        equal(ClaudeJobs.date(NSNumber(value: 1781978364057)).map { Int($0.timeIntervalSince1970) }, 1781978364,
              "or as epoch millis")
        equal(ClaudeJobs.date("yesterday"), nil, "anything else: none")
    }

    // MARK: - Rows

    static func rowTests() {
        let now = Date()
        print("The list's rows")
        let own = hook("own", "isle", .working, ago: 5, action: "Edit", target: "/x/NotchViewModel.swift")
        let other = hook("other", "website", .done, ago: 300, said: "Shipped it.")
        let blocked = agent("30d0d02c", .blocked, name: "Redesign grid system and modernize app chrome",
                            cwd: "/Users/me/retermina")
        let approval = agent("4a2d55f1", .blocked, name: "probe-b", cwd: "/Users/me/probe", pid: 94941,
                             waitingFor: "permission prompt")
        let doneLive = agent("22222222", .done, name: "Tidy the changelog", cwd: "/Users/me/site", pid: 900)
        let merge = ClaudeBackground.merge(hookSessionIds: ["own", "other"], registry: [],
                                           agents: [blocked, approval, doneLive], finishedAt: [:], now: now)
        let rows = ClaudeBackground.rows(live: [own, other], merge: merge) { _ in nil }
        equal(rows.count, 5, "two hook rows and three background ones")
        equal(Set(rows.map(\.id)).count, rows.count, "no session twice")
        equal(rows.map(\.id).prefix(2).contains(blocked.sessionId!), true, "a blocked one ranks with what needs you")
        equal(rows.last?.id, doneLive.sessionId!, "a finished one ranks with the quiet ones, after hook rows")
        let byId = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        let b = byId[blocked.sessionId!]
        equal(b?.label, "Redesign grid system and modernize app chrome", "labelled by its own name")
        equal(b?.stateTitle, "Needs you", "Claude Code's word: needs you")
        equal(b?.detail, "retermina", "the detail is where it is — nothing more is known")
        equal(b?.updatedAt, nil, "no age: no hook wrote it")
        equal(b?.isQuiet, false, "not quiet")
        equal(b?.markerKind, .needsQuestion, "an attention marker")
        let a = byId[approval.sessionId!]
        equal(a?.stateTitle, "Needs approval", "blocked on a permission prompt says so")
        equal(a?.detail, "probe", "the prompt is in the state word, so the detail is where")
        let input = ClaudeBackground.merge(
            hookSessionIds: [], registry: [],
            agents: [agent("5e6f7a8b", .blocked, name: "notes", cwd: "/Users/me/isle", pid: 4104,
                           waitingFor: "input needed")],
            finishedAt: [:], now: now)
        let inputRow = ClaudeBackground.rows(live: [], merge: input) { _ in nil }.first
        equal(inputRow?.detail, "Input needed · isle", "what it's waiting for first, in Claude Code's words")
        equal(inputRow?.stateTitle, "Needs you", "titled needs you")
        let dl = byId[doneLive.sessionId!]
        equal(dl?.stateTitle, "Done", "done")
        equal(dl?.isQuiet, true, "and quieter")
        let o = byId["own"]
        equal(o?.label, "isle", "a terminal session keeps its project")
        equal(o?.background, nil, "and no background info")
        equal(o?.stateTitle, "Working", "and the hook's word")

        print("Without any background sessions, the list is what it was")
        let before = ClaudeSelection.ranked([own, other]).map { ClaudeSessionRow($0, request: nil) }
        let after = ClaudeBackground.rows(live: [own, other], merge: .empty) { _ in nil }
        equal(after, before, "identical rows")

        print("A live background session the hooks cover")
        let liveAgent = agent("9feb2230", .working, name: "m21-probe-a", cwd: "/Users/me/proj-a", pid: 94930,
                              sessionId: "live-bg")
        let liveHook = hook("live-bg", "proj-a", .working, ago: 2, action: "Bash", target: "npm test")
        let m2 = ClaudeBackground.merge(hookSessionIds: ["live-bg"], registry: [], agents: [liveAgent],
                                        finishedAt: [:], now: now)
        let r = ClaudeBackground.rows(live: [liveHook], merge: m2) { _ in nil }
        equal(r.count, 1, "one row")
        equal(r.first?.label, "m21-probe-a", "by its name")
        equal(r.first?.detail, "Running npm", "with the hook's detail")
        equal(r.first?.stateTitle, "Working", "and the hook's state")
        check(r.first?.stateFromAgent == false, "which is the hook's, not Claude Code's")
        let askAgent = agent("9feb2230", .blocked, name: "m21-probe-a", cwd: "/Users/me/proj-a", pid: 94930,
                             sessionId: "live-bg")
        let m3 = ClaudeBackground.merge(hookSessionIds: ["live-bg"], registry: [], agents: [askAgent],
                                        finishedAt: [:], now: now)
        let asked = ClaudeBackground.rows(live: [hook("live-bg", "proj-a", .done, said: "Rename it to index.html?")],
                                          merge: m3) { _ in nil }
        equal(asked.first?.stateTitle, "Needs you", "a finished turn Claude Code calls blocked")
        equal(asked.first?.detail, "Rename it to index.html?", "with what Claude asked")
        let attachAsk = ClaudeSessionRow(hook("live-bg", "proj-a", .needsQuestion), request: nil,
                                         background: m3.info["live-bg"])
        equal(attachAsk.detail, "Attach to answer", "a hook's question with no request: attach to answer")
    }

    // MARK: - Attach

    static func attachTests() {
        print("Jump's command line")
        equal(ClaudeLauncher.attachCommand("30d0d02c", in: "/Users/me/retermina"),
              "cd -- '/Users/me/retermina' 2>/dev/null; claude attach 30d0d02c", "cd, then attach")
        equal(ClaudeLauncher.attachCommand("30d0d02c", in: nil), "claude attach 30d0d02c", "no cwd: just attach")
        equal(ClaudeLauncher.attachCommand("30d0d02c", in: "/Users/me/it's here"),
              "cd -- '/Users/me/it'\\''s here' 2>/dev/null; claude attach 30d0d02c", "a quote in the path is quoted")
        equal(ClaudeLauncher.attachCommand("30d0d02c", in: "/Users/me/a\nb"), "claude attach 30d0d02c",
              "a newline in the path: no cd")
        equal(ClaudeLauncher.attachCommand("x; rm -rf ~", in: "/tmp"), nil, "an id that isn't one: nothing")
        check(ClaudeLauncher.appleScript(running: "claude attach 30d0d02c").contains("do script \"claude attach 30d0d02c\""),
              "run in Terminal with do script")
    }

    // MARK: - Through the view model

    @MainActor
    static func viewModelTests() {
        print("Through the view model")
        let suite = "isle.tests.\(UUID().uuidString)"
        let settings = AppSettings(defaults: UserDefaults(suiteName: suite)!)
        settings.mode = .claude
        let vm = NotchViewModel(settings: settings)
        let pid = getpid()
        let own = hook("own", "isle", .working, ago: 3, action: "Edit", target: "/x/A.swift")
        vm.applyTestReading(statuses: [own], sessions: [registry("own", pid: pid)])
        equal(vm.sessionList.count, 1, "one live terminal session")
        equal(vm.otherSessions, ClaudeOtherSessions(), "nothing else counted")

        let blocked = agent("30d0d02c", .blocked, name: "Redesign grid system and modernize app chrome",
                            cwd: "/Users/me/retermina", sessionId: "30d0d02c-03cd-4849-bcfd-5c8c43c49dc9")
        let working = agent("11111111", .working, name: "Fix flaky test", cwd: "/Users/me/app")
        vm.applyTestAgents([blocked, working])
        equal(vm.sessionList.count, 3, "two background sessions join the list")
        equal(vm.otherSessions, ClaudeOtherSessions(working: 1, needYou: 1), "and the counts")
        equal(vm.claudeSessionId, "own", "but the island keeps its own session")
        equal(vm.claudeState, .working, "working")
        check(vm.claudeNeedsYou, "the home tile's needs-you mark is lit")

        vm.pinSession(blocked.sessionId!)
        equal(vm.claudeSessionId, blocked.sessionId, "a background session can be picked")
        equal(vm.pinnedSessionId, blocked.sessionId, "and is pinned")
        equal(vm.claudeState, .needsQuestion, "the face shows it as needing you")
        check(vm.claudeStateFromAgent, "in Claude Code's words")
        equal(vm.claudeBackground?.name, "Redesign grid system and modernize app chrome", "with its name")
        equal(vm.jumpTarget, "Terminal", "Jump attaches in Terminal")
        check(vm.jumpAttaches, "attaching")
        check(!vm.canReply, "and there's no reply to type: no terminal")
        equal(vm.otherSessions, ClaudeOtherSessions(working: 2, needYou: 0), "the island's own is left out of the count")

        // A pinned session yields only to a higher rank rising elsewhere
        // (`ClaudeSelection.Selector`): a question it holds against a new
        // question, but an approval outranks it.
        let questioning = hook("own", "isle", .needsQuestion, ago: 0)
        vm.applyTestReading(statuses: [questioning], sessions: [registry("own", pid: pid)])
        equal(vm.claudeSessionId, blocked.sessionId, "a pinned blocked one holds against a new question")
        let asking = hook("own", "isle", .needsApproval, ago: 0, action: "Bash", target: "npm")
        vm.applyTestReading(statuses: [asking], sessions: [registry("own", pid: pid)])
        equal(vm.claudeSessionId, "own", "but an approval, the higher rank, takes the island from it")

        // A pinned working one yields to it.
        vm.showSessionList()
        vm.applyTestReading(statuses: [own], sessions: [registry("own", pid: pid)])
        vm.pinSession(working.sessionId!)
        equal(vm.claudeSessionId, working.sessionId, "a working background session can be picked")
        equal(vm.claudeState, .working, "and shows working")
        vm.applyTestReading(statuses: [asking], sessions: [registry("own", pid: pid)])
        equal(vm.claudeSessionId, "own", "a terminal session newly needing you takes the face from it")
        equal(vm.pinnedSessionId, nil, "the pin is gone")

        vm.pinSession(blocked.sessionId!)
        equal(vm.claudeSessionId, blocked.sessionId, "picked again")
        vm.applyTestAgents([working])
        equal(vm.pinnedSessionId, nil, "the pin goes when agent view stops listing it")
        equal(vm.claudeSessionId, "own", "and the island goes back")
        equal(vm.sessionList.count, 2, "one background row left")

        vm.applyTestAgents([])
        vm.applyTestReading(statuses: [], sessions: [])
        vm.applyTestAgents([blocked])
        equal(vm.claudeState, .disconnected, "nothing live: the island stays disconnected")
        equal(vm.sessionList.count, 1, "but the list has the background session")
        equal(vm.otherSessions.needYou, 1, "counted as needing you")
        var stale = blocked
        stale.lastChange = Date().addingTimeInterval(-3 * 24 * 60 * 60)
        vm.applyTestAgents([stale])
        equal(vm.sessionList.count, 0, "unchanged for three days with no process: off the list")
        equal(vm.otherSessions.needYou, 0, "and not counted")

        // A live background session the hooks cover, whose turn ended on a
        // question: Claude Code says blocked.
        let liveId = "4a2d55f1-fd4f-4b5e-a896-3c3ef19a1708"
        let liveDone = hook(liveId, "proj-b", .done, ago: 4, said: "Want me to commit it?")
        let bgRecord = registry(liveId, pid: pid, cwd: "/Users/me/proj-b", kind: "bg", jobId: "4a2d55f1",
                                name: "m21-probe-b")
        vm.applyTestAgents([])
        vm.applyTestReading(statuses: [liveDone], sessions: [bgRecord])
        equal(vm.claudeSessionId, liveId, "a live background session the hooks see is on the island")
        equal(vm.claudeState, .done, "as the hook says, before agent view is read")
        equal(vm.claudeBackground?.attachId, "4a2d55f1", "with its attach id from the registry")
        equal(vm.claudeBackground?.name, "m21-probe-b", "and its name")
        equal(vm.jumpTarget, "Terminal", "so Jump attaches")
        vm.applyTestAgents([agent("4a2d55f1", .blocked, name: "m21-probe-b", cwd: "/Users/me/proj-b", pid: pid,
                                  sessionId: liveId)])
        equal(vm.claudeState, .needsQuestion, "then blocked, as Claude Code says")
        check(vm.claudeStateFromAgent, "in its words")
        equal(vm.claudeFinalLine, "Want me to commit it?", "with Claude's question kept")
        equal(vm.sessionList.count, 1, "still one row")
        equal(vm.sessionList.first?.stateTitle, "Needs you", "which says needs you")

        UserDefaults.standard.removePersistentDomain(forName: suite)
    }
}
