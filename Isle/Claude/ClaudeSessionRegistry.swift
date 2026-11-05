//
//  ClaudeSessionRegistry.swift
//
//  The second, hook-free half of the Claude Code bridge. Claude Code writes a
//  record per live session to ~/.claude/sessions/<pid>.json and keeps its
//  `status` field current itself — no hook involved. That makes this a strictly
//  better source than the hook bridge for the things it covers:
//
//    * It works when the hooks don't. An uninstalled helper, a clobbered
//      ~/.claude/settings.json, or a hook that failed to run all leave the
//      status file frozen; the registry keeps updating regardless.
//    * It's keyed by pid, so liveness is a `kill(pid, 0)` rather than a guess.
//      A session killed with SIGKILL fires no SessionEnd, and the old status
//      file would sit on "working" forever — here it simply stops being alive.
//    * It's per session. ~/.isle/claude-status.json is one shared file with
//      last-writer-wins, so a background session's PreToolUse silently
//      overwrites the session the user is actually watching. The registry has
//      one record each, so the app can choose.
//
//  What it deliberately does *not* replace: the hook bridge still owns the
//  detail — which tool is running, against which file, and the terminal states
//  (question / compacting / failed) that `status` has no vocabulary for. The
//  registry is the spine (alive / busy / waiting); the hooks are the enrichment.
//
//  Stability note: ~/.claude/sessions is internal surface, not a documented
//  API — the shape may change between CLI versions. Every field below is
//  optional and a record that won't parse is skipped rather than faulted, so a
//  schema change degrades to "no registry" and the hook bridge carries on
//  alone. `cliVersion` is retained so a future guard can gate on it.
//
//  Freshness note: the CLI rewrites each record *in place* (verified on
//  2.1.292 — same inode, file mtime moves, directory mtime doesn't). A
//  directory watch only fires when an entry is added, removed or renamed, so it
//  sees sessions start and exit and nothing in between: an `idle` → `busy`
//  flip, or a session id changing under the same pid, is invisible to it. A
//  SIGKILLed CLI leaves its record behind and fires nothing either. So the
//  watch is only the cue for start/exit — anyone about to act on `status`,
//  `sessionId` or liveness re-reads (`scan`) first rather than trusting the
//  last snapshot. The view model does that on its background pass (see
//  `NotchViewModel.requestClaudeReading`).
//

import Foundation

/// One live Claude Code session, as the CLI reports it.
struct ClaudeSession: Equatable, Identifiable {
    /// What the CLI says the session is doing. Coarse by design — the hook
    /// bridge supplies the detail.
    enum Status: String {
        case idle
        case busy
        case waiting
        /// A value this build doesn't know. Treated as "alive but unclassified"
        /// rather than dropped, so a new CLI status can't make a session vanish.
        case unknown
    }

    let pid: pid_t
    let sessionId: String
    let cwd: String
    /// The CLI's own derived short name for the session ("isle-cf"). Handy as a
    /// label when more than one session is live in the same project.
    let name: String?
    /// "interactive" for a REPL session; other kinds exist (SDK, print mode).
    let kind: String?
    let status: Status
    /// Note: a session backing off between API retries reports `idle`, not
    /// `busy` — verified against a forced retry storm. Don't treat `busy` as a
    /// proxy for "a turn is in flight".
    /// For `waiting`, what it's waiting on, when the CLI names it.
    let waitingFor: String?
    /// When `status` last changed — not when the record was last touched.
    let statusUpdatedAt: Date?
    let startedAt: Date?
    let cliVersion: String?

    var id: pid_t { pid }

    /// Interactive sessions are the ones the island is about; an SDK or print
    /// run isn't something the user is sitting in front of.
    var isInteractive: Bool { kind == nil || kind == "interactive" }
}

@MainActor
final class ClaudeSessionRegistry {
    /// Called on the main actor when a session record appears or goes — the
    /// cue to re-read (see `scan`). Coalesced, so a burst is one call.
    var onChange: (() -> Void)?

    /// Where the records live. Readable from any thread, so the scan can run
    /// off the main one.
    nonisolated let directoryURL: URL
    private let queue = DispatchQueue(label: "isle.claude-session-registry", qos: .utility)

    private var watch: DirectoryWatch?
    private var coalesceTask: Task<Void, Never>?
    private var isRunning = false

    /// Several sessions can start or exit at once (and each start creates a
    /// `.key` file beside its record). Coalescing collapses that burst into
    /// one rescan.
    private static let coalesceInterval: Duration = .milliseconds(120)

    /// The directory is injectable so the watch can be exercised against a
    /// scratch directory in tests; production always uses the default.
    init(directoryURL: URL? = nil) {
        self.directoryURL = directoryURL ?? FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/sessions", isDirectory: true)
    }

    // MARK: - Lifecycle

    /// Watches the directory rather than individual files: records appear and
    /// vanish as sessions start and exit, so there's no stable inode to hold.
    /// By path, too: Claude Code creates the directory on its first run, so
    /// before then this waits on the nearest folder that exists, and a
    /// directory deleted and made again is picked up rather than leaving the
    /// watch on the dead one.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        let watch = DirectoryWatch(url: directoryURL, queue: queue) { [weak self] _ in
            Task { @MainActor in self?.scheduleChange() }
        }
        self.watch = watch
        watch.start()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        coalesceTask?.cancel()
        coalesceTask = nil
        watch?.stop()
        watch = nil
    }

    private func scheduleChange() {
        guard isRunning else { return }
        coalesceTask?.cancel()
        coalesceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.coalesceInterval)
            guard !Task.isCancelled, let self, self.isRunning else { return }
            self.onChange?()
        }
    }

    // MARK: - Reading

    /// Every live session, read now, on the calling thread. Cheap — one small
    /// record per live session — but still file I/O: the view model reads it
    /// on its background pass, and on the main thread only at a click that
    /// has to act on fresh state.
    func currentSessions() -> [ClaudeSession] {
        guard isRunning else { return [] }
        return Self.scan(directoryURL)
    }

    /// The live sessions recorded in `directoryURL`, by pid. Every reader goes
    /// through here, since the directory watch can't see records being
    /// rewritten in place — see the freshness note above.
    nonisolated static func scan(_ directoryURL: URL) -> [ClaudeSession] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directoryURL.path)) ?? []
        return names
            .compactMap { record(named: $0, in: directoryURL) }
            // A record outlives its process when the CLI is killed rather than
            // exiting, so the file's existence proves nothing — the pid does.
            .filter { isAlive($0.pid) }
            .sorted { $0.pid < $1.pid }
    }

    /// Parses one `<pid>.json`. Returns nil for anything else in the directory
    /// — the per-session `.key` files live here too — and for a record that
    /// won't decode.
    nonisolated private static func record(named name: String, in directoryURL: URL) -> ClaudeSession? {
        let url = URL(fileURLWithPath: name, relativeTo: directoryURL)
        guard url.pathExtension == "json",
              // `<pid>.json`, not `<pid>.<hash>.key` — guard the stem so a
              // future sibling file can't be mistaken for a session record.
              let pid = pid_t(url.deletingPathExtension().lastPathComponent),
              let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(RecordPayload.self, from: data)
        else {
            return nil
        }
        return ClaudeSession(
            pid: pid,
            sessionId: payload.sessionId,
            cwd: payload.cwd,
            name: payload.name.flatMap { $0.isEmpty ? nil : $0 },
            kind: payload.kind,
            status: payload.status.flatMap(ClaudeSession.Status.init(rawValue:)) ?? .unknown,
            waitingFor: payload.waitingFor.flatMap { $0.isEmpty ? nil : $0 },
            statusUpdatedAt: payload.statusUpdatedAt.map(date(fromMillis:)),
            startedAt: payload.startedAt.map(date(fromMillis:)),
            cliVersion: payload.version
        )
    }

    /// Signal 0 performs the permission and existence checks without delivering
    /// anything. EPERM means the process is alive but owned by someone else —
    /// still alive, so it counts.
    nonisolated private static func isAlive(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    nonisolated private static func date(fromMillis millis: Double) -> Date {
        Date(timeIntervalSince1970: millis / 1000)
    }
}

// MARK: - Wire format

/// The on-disk shape of `~/.claude/sessions/<pid>.json`. Only `sessionId` and
/// `cwd` are required — everything else is optional so a trimmed or extended
/// record still parses. Timestamps are epoch milliseconds.
private struct RecordPayload: Decodable {
    let sessionId: String
    let cwd: String
    let name: String?
    let kind: String?
    let status: String?
    let waitingFor: String?
    let statusUpdatedAt: Double?
    let startedAt: Double?
    let version: String?
}
