//
//  ClaudeStatusWatcher.swift
//
//  The Claude Code side of the bridge (build spec §3.3). Claude's hooks call
//  `isle-cli`, which writes ~/.isle/claude-status.json; this class watches
//  that file with DispatchSource file-system events — not polling — and
//  reports the parsed status the moment it changes.
//
//  Robustness note: a file watch bound to one inode goes stale the instant
//  the file is deleted or atomically replaced. So we watch the *directory*
//  as well, and every event funnels through `refresh()`, which reconciles the
//  file watch against the file's actual existence and re-reads. That keeps the
//  watch alive across create/delete/replace without polling. `isle-cli`
//  rewrites the file in place (`cat >`), so ordinary updates land as `.write`
//  on the file itself.
//

import Foundation

/// A parsed snapshot of the Claude Code status file.
struct ClaudeStatus: Equatable {
    var state: ClaudeCodeState
    var project: String?
    var sessionId: String?
    /// The tool Claude is about to run, when known (Edit / Bash / Read / …).
    var action: String?
    /// A best-effort target for that tool (file path, command, pattern).
    var target: String?
    /// For `.failed`, the API `error_type` from `StopFailure` (rate_limit,
    /// overloaded, server_error, …). Nil otherwise.
    var errorType: String?

    static let disconnected = ClaudeStatus(state: .disconnected, project: nil, sessionId: nil)
}

@MainActor
final class ClaudeStatusWatcher {
    /// Called on the main actor whenever the resolved status changes.
    var onStatus: ((ClaudeStatus) -> Void)?

    private let directoryURL: URL
    private let fileURL: URL
    private let queue = DispatchQueue(label: "isle.claude-status-watcher", qos: .utility)

    private var directorySource: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?

    private var lastStatus: ClaudeStatus = .disconnected
    private var isRunning = false

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        directoryURL = home.appendingPathComponent(".isle", isDirectory: true)
        fileURL = directoryURL.appendingPathComponent("claude-status.json")
    }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true

        // Ensure ~/.isle exists so the directory watch is always valid. It's
        // Isle's own directory and isle-cli creates it too — doing it here just
        // removes a first-launch ordering race where Isle starts before Claude
        // has ever run a hook.
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
        tearDown(&fileSource)
        tearDown(&directorySource)
        lastStatus = .disconnected
    }

    // MARK: - Watches

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
            // A directory event means the status file was created, deleted, or
            // replaced — reconcile the file watch and re-read.
            Task { @MainActor in self?.refresh() }
        }
        // The cancel handler owns closing the fd, so it's closed exactly once.
        source.setCancelHandler { close(fd) }
        directorySource = source
        source.resume()
    }

    private func startFileWatch() {
        guard fileSource == nil else { return }
        let fd = open(fileURL.path, O_EVTONLY)
        guard fd >= 0 else { return }   // file doesn't exist yet

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename, .revoke],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        source.setCancelHandler { close(fd) }
        fileSource = source
        source.resume()
    }

    private func tearDown(_ source: inout DispatchSourceFileSystemObject?) {
        source?.cancel()   // cancel handler closes the fd
        source = nil
    }

    // MARK: - Refresh

    /// Reconciles the file watch with the file's existence and publishes the
    /// current status. Every event funnels here, so it must be idempotent.
    private func refresh() {
        guard isRunning else { return }

        if FileManager.default.fileExists(atPath: fileURL.path) {
            startFileWatch()
        } else {
            // The inode we were watching is gone; drop the now-stale file
            // watch. The directory watch re-establishes it when the file
            // reappears.
            tearDown(&fileSource)
        }

        publish(readStatus())
    }

    private func publish(_ status: ClaudeStatus) {
        guard status != lastStatus else { return }
        lastStatus = status
        onStatus?(status)
    }

    /// Reads and parses the status file. Any failure — missing file, unreadable
    /// bytes, malformed JSON, unknown state string — resolves to
    /// `.disconnected`, per the hook-event table in the build spec.
    private func readStatus() -> ClaudeStatus {
        guard let data = try? Data(contentsOf: fileURL),
              let payload = try? JSONDecoder().decode(StatusPayload.self, from: data)
        else {
            return .disconnected
        }
        return ClaudeStatus(
            state: payload.claudeState,
            project: payload.project,
            sessionId: payload.session_id,
            action: payload.action.flatMap { $0.isEmpty ? nil : $0 },
            target: payload.target.flatMap { $0.isEmpty ? nil : $0 },
            errorType: payload.error_type.flatMap { $0.isEmpty ? nil : $0 }
        )
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
