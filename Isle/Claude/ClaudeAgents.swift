//
//  ClaudeAgents.swift
//
//  Background sessions in the list (Milestone 21). Claude Code's agent view
//  runs sessions with no terminal (`claude --bg`, `claude agents`), hosted by
//  a supervisor process. While one's process is alive it writes a
//  ~/.claude/sessions record (`kind: "bg"`, with its `jobId`) and fires the
//  user's hooks like any other session, so the bridge already sees it. What
//  the bridge can't see:
//
//    * a session whose process has exited: the supervisor stops a finished
//      or idle one after about an hour, a shutdown stops them all, and a
//      session blocked on you can sit for days with no process at all;
//    * the state Claude Code itself gives it — `blocked` in particular, which
//      the hooks have no word for when a turn ended on a question;
//    * the id `claude attach` takes, and the session's own name.
//
//  `claude agents --json --all` is the documented way to read all of that
//  ("the supported way to read session state from outside Claude Code");
//  the files under ~/.claude/jobs are explicitly not a stable interface, so
//  they are only ever the *cue* to read it again — a directory watch, never
//  parsed.
//
//  Measured on 2.1.319 with four sessions listed: 0.09–0.15s wall, ~0.12s
//  CPU, ~150 MB peak RSS for the short-lived process, 1 KB of output. It
//  doesn't start the supervisor. So it is run on a cue only — the jobs
//  directory changing, the registry changing, the panel opening — and at
//  most once every few seconds however many cues arrive. Never on a timer.
//

import Foundation

// MARK: - One entry

/// One session as `claude agents --json` lists it.
struct ClaudeAgent: Equatable {
    /// A background session's `state`: what Claude Code says about it. Its
    /// own five words, plus whatever a later CLI adds, kept verbatim.
    enum State: Equatable {
        case working, blocked, done, failed, stopped
        case other(String)

        init(_ raw: String) {
            switch raw {
            case "working": self = .working
            case "blocked": self = .blocked
            case "done": self = .done
            case "failed": self = .failed
            case "stopped": self = .stopped
            default: self = .other(raw)
            }
        }

        /// Done, failed or stopped: nothing more will happen without you.
        var isFinished: Bool {
            switch self {
            case .done, .failed, .stopped: return true
            case .working, .blocked, .other: return false
            }
        }
    }

    /// The short id `claude attach`, `logs` and `stop` take. Background only.
    var id: String?
    /// The full session UUID — what the hooks call `session_id`.
    var sessionId: String?
    /// The session's display name: given with `--name`, or Claude Code's own.
    var name: String?
    var cwd: String
    /// "interactive" or "background".
    var kind: String
    /// Background only.
    var state: State?
    /// While the process is alive.
    var pid: pid_t?
    /// While the process is alive: busy, waiting or idle.
    var status: String?
    /// When `status` is waiting: "permission prompt", "input needed",
    /// "sandbox request", "worker request" or "dialog open".
    var waitingFor: String?
    var startedAt: Date?

    var isBackground: Bool { kind == "background" }

    /// The working directory's last component — the project, as the hook
    /// records name it.
    var project: String? {
        let last = (cwd as NSString).lastPathComponent
        return last.isEmpty || last == "/" ? nil : last
    }

    /// An id that's safe to put on a command line: what `claude --bg` prints
    /// (8 hex digits today), and nothing a shell would read as syntax.
    var attachId: String? {
        guard let id, !id.isEmpty, id.count <= 64,
              id.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }),
              id.unicodeScalars.allSatisfy({ $0.isASCII }),
              !id.hasPrefix("-")
        else { return nil }
        return id
    }
}

// MARK: - Parsing

enum ClaudeAgentsParser {
    /// The entries in `claude agents --json` output. Nil when it isn't a JSON
    /// array at all (an older CLI's error, a crash) — "nothing to say", not
    /// "no sessions". An entry without the fields every entry has (`cwd`,
    /// `kind`) is skipped; every other field is optional, and one of the
    /// wrong type reads as absent, so an extended or trimmed shape degrades
    /// field by field rather than losing the session.
    static func parse(_ data: Data) -> [ClaudeAgent]? {
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return nil }
        return array.compactMap { element in
            guard let object = element as? [String: Any],
                  let cwd = nonEmpty(object["cwd"]),
                  let kind = nonEmpty(object["kind"])
            else { return nil }
            return ClaudeAgent(
                id: nonEmpty(object["id"]),
                sessionId: nonEmpty(object["sessionId"]),
                name: nonEmpty(object["name"]),
                cwd: cwd,
                kind: kind,
                state: nonEmpty(object["state"]).map(ClaudeAgent.State.init),
                pid: (object["pid"] as? NSNumber).flatMap { number in
                    let value = number.int64Value
                    return value > 0 && value <= Int64(Int32.max) ? pid_t(value) : nil
                },
                status: nonEmpty(object["status"]),
                waitingFor: nonEmpty(object["waitingFor"]),
                startedAt: (object["startedAt"] as? NSNumber).map {
                    Date(timeIntervalSince1970: $0.doubleValue / 1000)
                }
            )
        }
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Merging with the bridge

/// What a listed session has from agent view: how to attach to it, its
/// name, and — when the hooks can't say — its state.
struct ClaudeBackgroundInfo: Equatable {
    /// For `claude attach`. Nil when unknown, and then nothing offers Jump.
    var attachId: String?
    /// Claude Code's own name for the session, the row's label.
    var name: String?
    var project: String?
    var cwd: String?
    /// Claude Code's `state`, when `claude agents` has been read.
    var state: ClaudeAgent.State?
    var waitingFor: String?
    /// A hook record is behind the row: the session's process is live and
    /// runs Isle's hooks, so its detail (and any approval) comes from them.
    var hasHookRecord: Bool

    /// Finished, as Claude Code reports it — drawn quieter.
    var isFinished: Bool { state?.isFinished ?? false }
}

enum ClaudeBackground {
    /// The background half of a reading: what each listed background session
    /// adds, by session id, and the sessions only `claude agents` knows of,
    /// as records shaped like a hook's so the list can rank them with the
    /// rest.
    struct Merge: Equatable {
        var info: [String: ClaudeBackgroundInfo] = [:]
        /// Background sessions with no live hook record, already filtered to
        /// the ones worth listing. `updatedAt` is nil: no hook wrote them.
        var agentOnly: [ClaudeStatus] = []

        static let empty = Merge()

        /// A hook record as the list and the island should show it: marked
        /// `fromAgent` when its state is Claude Code's instead.
        ///
        /// A live hook record wins — it is written the moment something
        /// happens, where `claude agents` is read on a cue — with one
        /// exception: a turn the hooks saw finish (Done, Ready, Waiting)
        /// reads as blocked when Claude Code says the session is blocked.
        /// Blocked "always means the session needs something from you": the
        /// turn ended on a question, an expired login, a dialog. Nothing a
        /// hook writes says that. Claude's last words stay, since they are
        /// usually the question.
        func resolve(_ status: ClaudeStatus) -> ClaudeStatus {
            guard let id = status.sessionId, let info = info[id], info.hasHookRecord,
                  info.state == .blocked, [.done, .idle, .waitingInput].contains(status.state)
            else { return status }
            var blocked = status
            blocked.state = ClaudeBackground.codeState(for: .blocked, waitingFor: info.waitingFor)
            blocked.action = nil
            blocked.target = nil
            blocked.requestId = nil
            blocked.toolActive = false
            blocked.fromAgent = true
            return blocked
        }

        /// The agent-only record for `sessionId`, if it's listed.
        func agentOnly(_ sessionId: String?) -> ClaudeStatus? {
            guard let sessionId else { return nil }
            return agentOnly.first { $0.sessionId == sessionId }
        }
    }

    /// The list: the live hook records (already corrected as the island
    /// corrects its own), resolved against `merge`, with the background
    /// sessions only agent view knows of, all in selection's order.
    static func rows(live: [ClaudeStatus], merge: Merge,
                     request: (ClaudeStatus) -> ClaudeRequest?) -> [ClaudeSessionRow] {
        let pool = live.map(merge.resolve) + merge.agentOnly
        return ClaudeSelection.ranked(pool).map { status in
            ClaudeSessionRow(status, request: request(status),
                             background: status.sessionId.flatMap { merge.info[$0] })
        }
    }

    /// How long a background session that Isle saw finish stays listed once
    /// its process has gone. Claude Code itself keeps a finished session's
    /// process for about an hour, and while it's alive the row stays anyway.
    static let finishedListing: TimeInterval = 60 * 60

    /// Merges what `claude agents` says with the bridge's own view.
    ///
    /// - `hookSessionIds`: the session ids with a hook record whose process
    ///   the registry can see — the rows the list already has.
    /// - `registry`: the live ~/.claude/sessions records, for a background
    ///   session's `jobId` and name before `claude agents` has been read, and
    ///   to match a hook record to its job when the ids differ.
    /// - `finishedAt`: when Isle saw each background session finish (see
    ///   `noteFinishes`).
    ///
    /// Interactive entries add nothing: the registry and the hooks already
    /// cover every one of them.
    static func merge(hookSessionIds: [String], registry: [ClaudeSession], agents: [ClaudeAgent],
                      finishedAt: [String: Date], now: Date) -> Merge {
        var merge = Merge()
        let hookIds = Set(hookSessionIds)
        let background = agents.filter(\.isBackground)
        var claimed = Set<Int>()

        for id in hookSessionIds {
            let record = registry.first { $0.sessionId == id }
            // The same session in agent view: by its session id, else by the
            // job the registry names for it, else by its process.
            let match = background.indices.first { index in
                let agent = background[index]
                if agent.sessionId == id { return true }
                if let job = record?.jobId, agent.id == job { return true }
                if let pid = record?.pid, agent.pid == pid { return true }
                return false
            }
            if let match {
                claimed.insert(match)
                let agent = background[match]
                merge.info[id] = ClaudeBackgroundInfo(
                    attachId: agent.attachId ?? record?.attachId, name: agent.name ?? record?.name,
                    project: agent.project, cwd: agent.cwd, state: agent.state,
                    waitingFor: agent.waitingFor ?? record?.waitingFor, hasHookRecord: true)
            } else if let record, record.isBackground {
                // Live, and the registry says it's a background session, but
                // `claude agents` hasn't been read (or doesn't list it yet).
                merge.info[id] = ClaudeBackgroundInfo(
                    attachId: record.attachId, name: record.name,
                    project: (record.cwd as NSString).lastPathComponent, cwd: record.cwd,
                    state: nil, waitingFor: record.waitingFor, hasHookRecord: true)
            }
        }

        for (index, agent) in background.enumerated() where !claimed.contains(index) {
            guard let state = agent.state else { continue }
            let id = agent.sessionId ?? agent.id.map { "job:" + $0 }
            guard let id, !hookIds.contains(id), merge.info[id] == nil,
                  isListed(agent, state: state, finishedAt: finishedAt[id], now: now)
            else { continue }
            merge.info[id] = ClaudeBackgroundInfo(
                attachId: agent.attachId, name: agent.name, project: agent.project, cwd: agent.cwd,
                state: state, waitingFor: agent.waitingFor, hasHookRecord: false)
            merge.agentOnly.append(ClaudeStatus(
                state: codeState(for: state, waitingFor: agent.waitingFor),
                project: agent.project, sessionId: id, updatedAt: nil, fromAgent: true))
        }
        return merge
    }

    /// Whether a background session nothing hooks into is worth a row.
    /// Working and blocked always are — blocked is waiting on you, however
    /// long ago it stopped. A finished one is while its process is alive
    /// (Claude Code keeps it about an hour) or for an hour after Isle saw it
    /// finish; after that it's agent view's history, not Isle's. A state
    /// this build has no word for is listed only while its process runs.
    static func isListed(_ agent: ClaudeAgent, state: ClaudeAgent.State, finishedAt: Date?, now: Date) -> Bool {
        switch state {
        case .working, .blocked: return true
        case .done, .failed, .stopped:
            if agent.pid != nil { return true }
            guard let finishedAt else { return false }
            return now.timeIntervalSince(finishedAt) < finishedListing
        case .other: return agent.pid != nil
        }
    }

    /// Records when each background session is first seen finished, having
    /// been seen unfinished before — Isle's own observation, the only "when"
    /// it can vouch for (`claude agents` gives a start time, not an end).
    /// Entries past `finishedListing`, or for sessions no longer finished,
    /// are dropped.
    static func noteFinishes(previous: [ClaudeAgent], current: [ClaudeAgent],
                             finishedAt: [String: Date], now: Date) -> [String: Date] {
        func key(_ agent: ClaudeAgent) -> String? { agent.sessionId ?? agent.id.map { "job:" + $0 } }
        var before: [String: ClaudeAgent.State] = [:]
        for agent in previous where agent.isBackground {
            if let key = key(agent), let state = agent.state { before[key] = state }
        }
        var next: [String: Date] = [:]
        for agent in current where agent.isBackground {
            guard let key = key(agent), let state = agent.state, state.isFinished else { continue }
            if let at = finishedAt[key] {
                if now.timeIntervalSince(at) < finishedListing { next[key] = at }
            } else if let was = before[key], !was.isFinished {
                next[key] = now
            }
        }
        return next
    }

    /// The island's word for Claude Code's: blocked on a permission prompt
    /// is an approval, any other block reads as a question (an attention
    /// state, ranked with them); a stopped session is at rest.
    static func codeState(for state: ClaudeAgent.State, waitingFor: String?) -> ClaudeCodeState {
        switch state {
        case .working: return .working
        case .blocked: return waitingFor == "permission prompt" ? .needsApproval : .needsQuestion
        case .done: return .done
        case .failed: return .failed
        case .stopped, .other: return .idle
        }
    }

    /// The state in a word or two, as the list says it for a state that
    /// came from `claude agents`.
    static func title(for state: ClaudeAgent.State, waitingFor: String?) -> String {
        switch state {
        case .working: return "Working"
        case .blocked: return waitingFor == "permission prompt" ? "Needs approval" : "Needs you"
        case .done: return "Done"
        case .failed: return "Failed"
        case .stopped: return "Stopped"
        case .other(let raw): return raw.prefix(1).uppercased() + raw.dropFirst()
        }
    }

    /// What it's waiting for, in Claude Code's own words, made a phrase.
    /// Nil when it says nothing (a blocked session with no live process).
    static func waitingPhrase(_ waitingFor: String?) -> String? {
        guard let waitingFor, !waitingFor.isEmpty else { return nil }
        return waitingFor.prefix(1).uppercased() + waitingFor.dropFirst()
    }
}

// MARK: - Reading it

/// Runs `claude agents --json --all` on a cue, and watches ~/.claude/jobs for
/// the cue. Publishes on the main actor, only on a change.
@MainActor
final class ClaudeAgentsMonitor {
    /// The background sessions changed (or the read stopped working: then
    /// it's empty, since nothing backs the old list any more).
    var onAgents: (([ClaudeAgent]) -> Void)?

    private(set) var agents: [ClaudeAgent] = []

    nonisolated let jobsURL: URL
    private let queue = DispatchQueue(label: "isle.claude-agents", qos: .utility)

    private var isRunning = false
    private var jobsWatch: DirectoryWatch?
    /// One per listed background session: its `state.json` is replaced by
    /// rename on every change, which a directory watch sees.
    private var jobWatches: [String: DirectoryWatch] = [:]

    private var pending: Task<Void, Never>?
    private var inFlight = false
    private var wantsAnother = false
    private var lastReadAt: Date = .distantPast
    private var generation = 0

    /// A burst of cues (a job's state file is written twice per change, and
    /// several sessions move at once) is one read.
    private static let coalesce: TimeInterval = 0.4
    /// However many cues arrive, at most one read this often: ~0.1s of CPU
    /// each, so a busy session can't make this a cost.
    private static let minimumInterval: TimeInterval = 3

    init(jobsURL: URL? = nil) {
        self.jobsURL = jobsURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/jobs", isDirectory: true)
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        let watch = DirectoryWatch(url: jobsURL, queue: queue) { [weak self] _ in
            Task { @MainActor in self?.cue() }
        }
        jobsWatch = watch
        watch.start()
        cue()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        generation += 1
        pending?.cancel()
        pending = nil
        inFlight = false
        wantsAnother = false
        jobsWatch?.stop()
        jobsWatch = nil
        jobWatches.values.forEach { $0.stop() }
        jobWatches = [:]
        agents = []
    }

    /// Something may have changed: read again, soon, once.
    func cue() {
        guard isRunning else { return }
        if inFlight {
            wantsAnother = true
            return
        }
        guard pending == nil else { return }
        let wait = max(Self.coalesce, Self.minimumInterval - Date().timeIntervalSince(lastReadAt))
        pending = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, let self else { return }
            self.pending = nil
            self.read()
        }
    }

    private func read() {
        guard isRunning else { return }
        inFlight = true
        lastReadAt = Date()
        let generation = self.generation
        queue.async { [weak self] in
            let agents = ClaudeCLI.agents()
            Task { @MainActor in self?.finish(agents, generation: generation) }
        }
    }

    private func finish(_ read: [ClaudeAgent]?, generation: Int) {
        guard generation == self.generation, isRunning else { return }
        inFlight = false
        let next = read ?? []
        watchJobs(next.filter(\.isBackground).compactMap(\.attachId))
        if next != agents {
            agents = next
            onAgents?(next)
        }
        if wantsAnother {
            wantsAnother = false
            cue()
        }
    }

    private func watchJobs(_ ids: [String]) {
        let wanted = Set(ids)
        for (id, watch) in jobWatches where !wanted.contains(id) {
            watch.stop()
            jobWatches[id] = nil
        }
        for id in wanted where jobWatches[id] == nil {
            let watch = DirectoryWatch(url: jobsURL.appendingPathComponent(id, isDirectory: true),
                                       queue: queue) { [weak self] _ in
                Task { @MainActor in self?.cue() }
            }
            jobWatches[id] = watch
            watch.start()
        }
    }
}

/// The `claude` binary, found once, and the one command Isle runs with it.
enum ClaudeCLI {
    private static let lock = NSLock()
    private static var located: URL?
    private static var lastMiss: Date?

    /// Where `claude` is. Isle is launched by launchd, not a shell, so its
    /// PATH has none of the user's: the usual install places first, then the
    /// user's own login shell asked once. A miss is remembered for ten
    /// minutes rather than costing a shell on every cue.
    static func locate() -> URL? {
        lock.lock()
        defer { lock.unlock() }
        if let located, FileManager.default.isExecutableFile(atPath: located.path) { return located }
        located = nil
        if let lastMiss, Date().timeIntervalSince(lastMiss) < 600 { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.npm-global/bin/claude",
            "\(home)/.bun/bin/claude",
        ]
        if let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
            ?? loginShellLookup() {
            located = URL(fileURLWithPath: path)
            return located
        }
        lastMiss = Date()
        return nil
    }

    /// `command -v claude` in the user's login shell. The last line that is
    /// an executable path, since a login shell's profile can print.
    private static func loginShellLookup() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? "/bin/zsh"
        guard let output = run(URL(fileURLWithPath: shell), ["-lc", "command -v claude"], timeout: 5) else { return nil }
        return String(decoding: output, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Every session `claude agents --json --all` lists, or nil when there's
    /// no `claude`, it failed, or it printed something that isn't the list.
    static func agents() -> [ClaudeAgent]? {
        guard let binary = locate(),
              let output = run(binary, ["agents", "--json", "--all"], timeout: 8)
        else { return nil }
        return ClaudeAgentsParser.parse(output)
    }

    /// Runs `binary` to completion, or kills it at `timeout`. Its stdout,
    /// when it exited 0. Never on the main thread.
    static func run(_ binary: URL, _ arguments: [String], timeout: TimeInterval) -> Data? {
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        // Isle isn't run from a Claude session, but if it ever is, the CLI
        // mustn't think it's nested in one.
        var environment = ProcessInfo.processInfo.environment
        for key in environment.keys where key == "CLAUDECODE" || key == "CLAUDE_PID" || key.hasPrefix("CLAUDE_CODE_") {
            environment[key] = nil
        }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        do { try process.run() } catch { return nil }
        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        killer.cancel()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else { return nil }
        return data
    }
}
