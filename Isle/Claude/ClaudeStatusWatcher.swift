//
//  ClaudeStatusWatcher.swift
//
//  The Claude Code side of the bridge (build spec §3.3). Claude's hooks call
//  `isle-cli`, which writes one status file per session under
//  ~/.isle/sessions/<session-id>.json; this class watches that directory with
//  DispatchSource file-system events — not polling — and reports every live
//  session's status the moment anything changes.
//
//  Why per session: there used to be a single ~/.isle/claude-status.json that
//  every session wrote to, last writer wins. That meant a *quiescent* event
//  from a background session — its `Stop`, or the "waiting for your input"
//  notification Claude Code fires after ~60s idle — silently overwrote the live
//  state of the session the user was actually watching. Choosing between
//  sessions is the app's job (see `NotchViewModel.selectStatus`), and it can't
//  choose if the data was already clobbered on disk.
//
//  Robustness note: a watch bound to one inode goes stale the instant that file
//  is replaced, and session files come and go constantly, so this watches the
//  *directory* only and re-reads every entry on each event. Several sessions
//  can move at once, so events are coalesced into one scan.
//
//  The contract that makes that work: `isle-cli` must write each status file by
//  **rename**, never in place. A directory vnode event fires when an entry is
//  added, removed or renamed — not when the bytes inside an existing entry
//  change. An in-place `cat > file` is therefore completely silent here, and
//  the island simply keeps showing whatever it read last: every state change
//  after a session\'s first write was invisible until some *other* session file
//  happened to be created or deleted and triggered a full re-scan. If a state
//  ever looks frozen on the island, check that end of the bridge first.
//

import Foundation

/// A parsed snapshot of one session's status file.
struct ClaudeStatus: Equatable {
    var state: ClaudeCodeState
    var project: String?
    var sessionId: String?
    /// The tool Claude is about to run, when known (Edit / Bash / Read / …).
    var action: String?
    /// A best-effort target for that tool (file path, command, pattern).
    var target: String?
    /// For `.failed`, the API failure kind from `StopFailure` (rate_limit,
    /// overloaded, server_error, …). Nil otherwise.
    var errorType: String?
    /// A tool is executing right now — set between a `PreToolUse` and its
    /// `PostToolUse`. A long Bash or MCP call is silent on every other signal
    /// (no hook writes, no transcript growth), so this is what stops it being
    /// read as a model that has gone quiet. False on an older `isle-cli` that
    /// doesn't emit the field, which only costs a suppression, never a wrong
    /// state.
    var toolActive: Bool = false
    /// For a `usage_limit` failure, the moment the limit resets: from the
    /// transcript's `quotaLimits.resetsAt`, else from Claude Code's own words
    /// ("resets 6:50pm (America/Toronto)"). Nil when neither said (the face
    /// then gives no time).
    var resetAt: Date?
    /// When the hook wrote this record. Breaks ties between sessions of equal
    /// urgency — see `NotchViewModel.selectStatus`.
    var updatedAt: Date?
    /// While `ask` / `ask-question` is blocked waiting on the notch, the id of
    /// its request (see ClaudeRequestWatcher). Any other write clears it, which
    /// is half of how a request that resolved elsewhere retires its buttons.
    var requestId: String?
    /// For `.done`, the start of what Claude said last: up to 300 characters
    /// of its final message, as the `Stop` hook carried it. Raw — the face
    /// takes its first sentence (see `ClaudeDoneLine`). Nil when there was
    /// nothing to quote, or on a helper older than v10.
    var lastMessage: String?
    /// For a usage limit, the window that was hit (`five_hour`, `seven_day`,
    /// …), and — on the limit or the turn that continued after it — what
    /// Claude Code said comes next (Milestone 19, helper v12). Nil when
    /// nothing said.
    var limitKind: String? = nil
    var limitNext: ClaudeLimitNext? = nil
    /// The subagents this session has running (Milestone 22, helper v13):
    /// each one's type (`Explore`, `Plan`, a custom agent's name), oldest
    /// first, one entry per agent. Only agents whose `SubagentStart` the
    /// helper saw and whose `SubagentStop` hasn't come; cleared when the turn
    /// ends. Empty on an older helper or Claude Code.
    var subagents: [String] = []
    /// The last call auto mode's classifier blocked in this session since
    /// the last prompt, and how many it has (Milestone 23, helper v14). An
    /// event the record carries, never its state. Nil when there's been
    /// none, or on an older helper.
    var blocked: ClaudeBlock? = nil
    /// What the last turn left running or scheduled when it ended
    /// (Milestone 20, helper v15): Stop's `background_tasks` and
    /// `session_crons`, as of that Stop. Nil when it left nothing, after the
    /// next prompt, or on an older helper.
    var left: ClaudeLeftovers? = nil
    /// The state is Claude Code's own, from `claude agents` (Milestone 21),
    /// rather than this record's: a background session no hook writes for,
    /// or one Claude Code says is blocked after the hooks saw its turn end.
    /// Never set on a record read from disk.
    var fromAgent = false

    static let disconnected = ClaudeStatus(state: .disconnected, project: nil, sessionId: nil)
}

@MainActor
final class ClaudeStatusWatcher {
    /// Called on the main actor whenever any session's status changes. Carries
    /// every session that currently has a file; the view model picks.
    var onStatuses: (([ClaudeStatus]) -> Void)?

    private let directoryURL: URL
    /// Where the watch's events land, and where every scan runs: reading and
    /// decoding each session file is file I/O and JSON, and none of it needs
    /// the main thread. Serial, so scans run in the order they were asked for.
    private let queue = DispatchQueue(label: "isle.claude-status-watcher", qos: .utility)

    private var watch: DirectoryWatch?
    private var coalesceTask: Task<Void, Never>?

    private var lastStatuses: [ClaudeStatus] = []
    private var isRunning = false
    /// Bumped by every scan asked for, and by `stop`. A scan publishes only if
    /// it is still the newest one when it lands, so a slow scan can never
    /// overwrite what a newer one already reported — nor one from before a
    /// stop reach a watcher that has since been restarted.
    private var generation = 0

    private static let coalesceInterval: Duration = .milliseconds(80)

    /// The directory is injectable so the watch can be exercised against a
    /// scratch directory in tests; production always uses the default.
    init(directoryURL: URL? = nil) {
        self.directoryURL = directoryURL ?? FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".isle/sessions", isDirectory: true)
    }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true

        // Ensure the directory exists so the watch is always valid. `isle-cli`
        // creates it too — doing it here removes a first-launch ordering race
        // where Isle starts before Claude has ever run a hook.
        try? FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )

        // By path, not by vnode: a reinstall that deletes and recreates the
        // directory would otherwise leave this watching the dead one.
        let watch = DirectoryWatch(url: directoryURL, queue: queue) { [weak self] _ in
            Task { @MainActor in self?.scheduleRefresh() }
        }
        self.watch = watch
        watch.start()
        refresh()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        generation += 1
        coalesceTask?.cancel()
        coalesceTask = nil
        watch?.stop()
        watch = nil
        lastStatuses = []
    }

    // MARK: - Refresh

    private func scheduleRefresh() {
        guard isRunning else { return }
        coalesceTask?.cancel()
        coalesceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.coalesceInterval)
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    /// Re-reads every session file off the main thread and publishes the
    /// result, if it's still the newest and anything changed. Every event
    /// funnels here, so it must be idempotent.
    private func refresh() {
        guard isRunning else { return }
        generation += 1
        let generation = generation
        let directoryURL = directoryURL
        queue.async { [weak self] in
            let statuses = Self.scan(directoryURL)
            Task { @MainActor in
                guard let self, self.isRunning, self.generation == generation,
                      statuses != self.lastStatuses
                else { return }
                self.lastStatuses = statuses
                self.onStatuses?(statuses)
            }
        }
    }

    /// Every session file in `directoryURL`, decoded, in session-id order.
    nonisolated private static func scan(_ directoryURL: URL) -> [ClaudeStatus] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directoryURL.path)) ?? []
        return names
            .compactMap { name -> ClaudeStatus? in
                let url = URL(fileURLWithPath: name, relativeTo: directoryURL)
                guard url.pathExtension == "json", let data = try? Data(contentsOf: url) else { return nil }
                return decode(data, fileStem: url.deletingPathExtension().lastPathComponent)
            }
            .sorted { ($0.sessionId ?? "") < ($1.sessionId ?? "") }
    }

    /// Parses one `<session-id>.json`. Any failure — malformed JSON, unknown
    /// state string — drops that one record rather than faulting the whole
    /// scan, so a single bad file can't blind the island to the rest. The
    /// filename is the fallback session id, since it *is* the session id.
    nonisolated static func decode(_ data: Data, fileStem: String) -> ClaudeStatus? {
        guard let payload = try? JSONDecoder().decode(StatusPayload.self, from: data) else {
            return nil
        }
        return ClaudeStatus(
            state: payload.claudeState,
            project: payload.project,
            sessionId: payload.session_id.flatMap { $0.isEmpty ? nil : $0 } ?? fileStem,
            action: payload.action.flatMap { $0.isEmpty ? nil : $0 },
            target: payload.target.flatMap { $0.isEmpty ? nil : $0 },
            errorType: payload.error_type.flatMap { $0.isEmpty ? nil : $0 },
            toolActive: payload.tool_active ?? false,
            resetAt: payload.resetDate,
            updatedAt: payload.updated_at.flatMap(timestamp(from:)),
            requestId: payload.request_id.flatMap { $0.isEmpty ? nil : $0 },
            lastMessage: payload.last_message.flatMap { $0.isEmpty ? nil : $0 },
            limitKind: payload.limit_kind.flatMap { $0.isEmpty ? nil : $0 },
            limitNext: payload.limit_next.flatMap(ClaudeLimitNext.init(rawValue:)),
            subagents: payload.subagents ?? [],
            blocked: payload.blocked?.value?.block,
            left: payload.left?.value?.leftovers
        )
    }

    nonisolated private static func timestamp(from string: String) -> Date? {
        // A formatter per call: this runs on the scan queue, where a shared
        // one would need a lock, and making one is cheap next to the read.
        string.isEmpty ? nil : ISO8601DateFormatter().date(from: string)
    }
}

// MARK: - Wire format

/// The on-disk shape written by `isle-cli`. `session_id` is optional — older
/// installs of the helper don't emit it (added for the multi-session and
/// parked Scheduled Prompts work).
private struct StatusPayload: Decodable {
    let state: String
    let project: String?
    let updated_at: String?
    let session_id: String?
    let action: String?
    let target: String?
    let error_type: String?
    let tool_active: Bool?
    let reset_at: String?
    let request_id: String?
    /// The start of Claude's final message, written on `Stop` (helper v10).
    let last_message: String?
    /// A usage limit's window and what comes next (helper v12).
    let limit_kind: String?
    let limit_next: String?
    /// The running subagents' types, oldest first (helper v13).
    let subagents: [String]?
    /// The last call auto mode blocked (helper v14); `null` when none.
    /// Lenient: a block that doesn't read is no block, never a lost record.
    let blocked: Lenient<BlockedPayload>?
    /// What the turn left running or scheduled (helper v15); `null` when
    /// nothing. Lenient, like `blocked`.
    let left: Lenient<LeftPayload>?

    struct LeftPayload: Decodable {
        struct Task: Decodable {
            let type: String?
            let name: String?
            let run: String?
            let cut: Bool?
        }
        struct Cron: Decodable {
            let schedule: String?
            let recurring: Bool?
        }
        let tasks: [Lenient<Task>]?
        let more: Int?
        let crons: [Lenient<Cron>]?
        let more_crons: Int?
        let at: String?

        /// Each field on its own, so one that doesn't read loses only itself.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            tasks = try? c.decode([Lenient<Task>].self, forKey: .tasks)
            more = try? c.decode(Int.self, forKey: .more)
            crons = try? c.decode([Lenient<Cron>].self, forKey: .crons)
            more_crons = try? c.decode(Int.self, forKey: .more_crons)
            at = try? c.decode(String.self, forKey: .at)
        }

        private enum CodingKeys: String, CodingKey { case tasks, more, crons, more_crons, at }

        /// Nil when it holds nothing to say.
        var leftovers: ClaudeLeftovers? {
            func text(_ s: String?) -> String? { s.flatMap { $0.isEmpty ? nil : $0 } }
            let tasks = (tasks ?? []).compactMap(\.value).compactMap { task -> ClaudeLeftovers.Task? in
                guard let type = text(task.type) else { return nil }
                return .init(type: type, name: text(task.name), run: text(task.run), cut: task.cut ?? false)
            }
            let wakes = (crons ?? []).compactMap(\.value).compactMap { cron -> ClaudeLeftovers.Wake? in
                guard let schedule = text(cron.schedule) else { return nil }
                return .init(schedule: schedule, recurring: cron.recurring ?? false)
            }
            let left = ClaudeLeftovers(
                tasks: tasks, more: max(0, more ?? 0), wakes: wakes, moreWakes: max(0, more_crons ?? 0),
                at: text(at).flatMap { ISO8601DateFormatter().date(from: $0) })
            return left.isEmpty ? nil : left
        }
    }

    struct Lenient<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
    }

    struct BlockedPayload: Decodable {
        let id: String?
        let tool: String?
        let target: String?
        let command: String?
        let cut: Bool?
        let reason: String?
        let count: Int?
        let at: String?

        /// Nil without a tool: there's nothing to say about a block that
        /// doesn't say what it blocked.
        var block: ClaudeBlock? {
            guard let tool, !tool.isEmpty else { return nil }
            func text(_ s: String?) -> String? { s.flatMap { $0.isEmpty ? nil : $0 } }
            return ClaudeBlock(
                id: id ?? "", tool: tool, target: text(target), command: text(command),
                commandCut: cut ?? false, reason: text(reason), count: max(1, count ?? 1),
                at: text(at).flatMap { ISO8601DateFormatter().date(from: $0) })
        }
    }

    /// The usage-limit reset moment, parsed from the epoch string the helper
    /// writes. Accepts seconds (10-digit) or milliseconds (13-digit); anything
    /// else — empty, non-numeric, older helper with no field — is nil.
    var resetDate: Date? {
        guard let raw = reset_at, let value = Double(raw), value > 0 else { return nil }
        let seconds = value > 1_000_000_000_000 ? value / 1000 : value
        return Date(timeIntervalSince1970: seconds)
    }

    var claudeState: ClaudeCodeState {
        switch state {
        case "idle": return .idle
        case "working": return .working
        case "needs_approval": return .needsApproval
        case "needs_question": return .needsQuestion
        case "waiting_input": return .waitingInput
        case "done": return .done
        case "error": return .failed
        case "compacting": return .compacting
        default: return .disconnected
        }
    }
}
