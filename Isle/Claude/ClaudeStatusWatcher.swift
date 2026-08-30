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
    /// For a `usage_limit` failure, the moment the limit resets, recovered from
    /// the limit message's embedded Unix epoch. Nil when the message carried no
    /// reset time (the island then pins "Limit reached" with no countdown).
    var resetAt: Date?
    /// When the hook wrote this record. Breaks ties between sessions of equal
    /// urgency — see `NotchViewModel.selectStatus`.
    var updatedAt: Date?
    /// For a `.needsApproval` raised by the `ask` (PermissionRequest) hook, the
    /// id of the blocked request. Nil when the approval didn't come from `ask`.
    var requestId: String?

    static let disconnected = ClaudeStatus(state: .disconnected, project: nil, sessionId: nil)
}

@MainActor
final class ClaudeStatusWatcher {
    /// Called on the main actor whenever any session's status changes. Carries
    /// every session that currently has a file; the view model picks.
    var onStatuses: (([ClaudeStatus]) -> Void)?

    private let directoryURL: URL
    private let queue = DispatchQueue(label: "isle.claude-status-watcher", qos: .utility)

    private var directorySource: DispatchSourceFileSystemObject?
    private var coalesceTask: Task<Void, Never>?

    private var lastStatuses: [ClaudeStatus] = []
    private var isRunning = false

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

        startDirectoryWatch()
        refresh()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        coalesceTask?.cancel()
        coalesceTask = nil
        directorySource?.cancel()   // cancel handler closes the fd
        directorySource = nil
        lastStatuses = []
    }

    // MARK: - Watch

    private func startDirectoryWatch() {
        guard directorySource == nil else { return }
        let fd = open(directoryURL.path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.scheduleRefresh() }
        }
        source.setCancelHandler { close(fd) }
        directorySource = source
        source.resume()
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

    /// Re-reads every session file and publishes. Every event funnels here, so
    /// it must be idempotent.
    private func refresh() {
        guard isRunning else { return }

        let names = (try? FileManager.default.contentsOfDirectory(atPath: directoryURL.path)) ?? []
        let statuses = names
            .compactMap(status(named:))
            .sorted { ($0.sessionId ?? "") < ($1.sessionId ?? "") }

        guard statuses != lastStatuses else { return }
        lastStatuses = statuses
        onStatuses?(statuses)
    }

    /// Parses one `<session-id>.json`. Any failure — unreadable bytes, malformed
    /// JSON, unknown state string — drops that one record rather than faulting
    /// the whole scan, so a single bad file can't blind the island to the rest.
    /// The filename is the fallback session id, since it *is* the session id.
    private func status(named name: String) -> ClaudeStatus? {
        let url = URL(fileURLWithPath: name, relativeTo: directoryURL)
        guard url.pathExtension == "json",
              let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(StatusPayload.self, from: data)
        else {
            return nil
        }
        return ClaudeStatus(
            state: payload.claudeState,
            project: payload.project,
            sessionId: payload.session_id.flatMap { $0.isEmpty ? nil : $0 }
                ?? url.deletingPathExtension().lastPathComponent,
            action: payload.action.flatMap { $0.isEmpty ? nil : $0 },
            target: payload.target.flatMap { $0.isEmpty ? nil : $0 },
            errorType: payload.error_type.flatMap { $0.isEmpty ? nil : $0 },
            toolActive: payload.tool_active ?? false,
            resetAt: payload.resetDate,
            updatedAt: payload.updated_at.flatMap(Self.timestamp(from:)),
            requestId: payload.request_id.flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    private static let timestampFormatter = ISO8601DateFormatter()

    private static func timestamp(from string: String) -> Date? {
        string.isEmpty ? nil : timestampFormatter.date(from: string)
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
