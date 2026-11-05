//
//  ClaudeRequestWatcher.swift
//
//  The talk-back half of the bridge (Milestone 7). When Isle is answering,
//  `isle-cli ask` (PermissionRequest) and `isle-cli ask-question` (PreToolUse
//  on AskUserQuestion) don't just report that Claude is waiting — they block,
//  and leave the hook's raw stdin at ~/.isle/requests/<id>.json for as long as
//  they do. Isle answers by renaming the hook's complete stdout payload into
//  place at <id>.response.json; the hook `cat`s it and exits.
//
//  Three files, all written by rename, for the reason spelled out in
//  ClaudeStatusWatcher: the watch is on the *directory*, and an in-place
//  rewrite changes no directory entry, so it fires nothing.
//
//    run/answering            Isle → hook   Isle's pid. Present only while Isle
//                                           runs with the setting on. A crash
//                                           leaves it, and its dead pid gates
//                                           the hook *off*.
//    requests/<id>.json       hook → Isle   The raw stdin. Its existence *is*
//                                           "a hook is waiting".
//    requests/<id>.response.json  Isle → hook  What the hook prints.
//
//  Isle builds the payload; the script never builds JSON. It stays jq-free,
//  and the one detail that sank the first attempt at this — `decision` is an
//  object, `{"behavior": "allow"}`, not the string "allow" — lives in Swift,
//  next to the code that uses it.
//

import Foundation

/// One hook that is blocked waiting on the notch, decoded from its stdin.
struct ClaudeRequest: Equatable, Identifiable {
    enum Kind: Equatable {
        /// A tool permission prompt (`PermissionRequest`): Approve / Deny.
        case approval
        /// An `AskUserQuestion` (`PreToolUse`): pick an answer.
        case question
    }

    /// `<session-id>-<epoch>-<hook pid>`, as the hook minted it. Also the
    /// filename, which is what the hook validates a response against.
    let id: String
    let kind: Kind
    let sessionId: String?
    /// The raw `tool_name` (Bash / Edit / AskUserQuestion / …).
    let toolName: String
    /// For an approval, the exact thing being authorised — the full command,
    /// the path, the URL — read from the *full* `tool_input`. The status
    /// file's `target` is trimmed to 48 hygienic characters for the collapsed
    /// island; a decision needs the real thing.
    let subject: String?
    /// For a question, what was asked, one entry per question.
    let questions: [ClaudeQuestion]

    /// The pid of the blocked hook, from the tail of the id. A hook killed
    /// with SIGKILL never runs its cleanup trap, so its request file outlives
    /// it; this is how such a file is told from a live one.
    var hookPID: pid_t? {
        id.split(separator: "-").last.flatMap { pid_t($0) }
    }
}

/// One `AskUserQuestion` question, as the tool was called with it.
struct ClaudeQuestion: Equatable {
    struct Option: Equatable {
        let label: String
        let description: String?
    }

    let question: String
    let header: String?
    let options: [Option]
    let multiSelect: Bool
}

@MainActor
final class ClaudeRequestWatcher {
    /// Called on the main actor whenever the set of waiting requests changes.
    var onRequests: (([ClaudeRequest]) -> Void)?

    private let directoryURL: URL
    private let queue = DispatchQueue(label: "isle.claude-request-watcher", qos: .utility)

    private var directorySource: DispatchSourceFileSystemObject?
    private var coalesceTask: Task<Void, Never>?

    private var lastRequests: [ClaudeRequest] = []
    private var isRunning = false

    /// The status watcher's interval, on purpose. After a click the hook
    /// rewrites its status (to `working`) a moment *before* it exits and its
    /// request goes; matching intervals keep that order on screen, so the
    /// panel goes straight from the buttons to the next state instead of
    /// flashing the bare prompt in between.
    private static let coalesceInterval: Duration = .milliseconds(80)

    /// How long an answer may sit with nobody to read it before it is swept.
    /// A hook that gave up (its deadline, Esc in the terminal) a moment before
    /// the click landed leaves the response behind, and nothing else would
    /// ever remove it.
    private static let orphanResponseAge: TimeInterval = 5

    init(directoryURL: URL? = nil) {
        self.directoryURL = directoryURL ?? Self.defaultDirectory
    }

    static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".isle/requests", isDirectory: true)
    }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        startDirectoryWatch()
        refresh()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        coalesceTask?.cancel()
        coalesceTask = nil
        directorySource?.cancel()
        directorySource = nil
        lastRequests = []
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

    private func scheduleRefresh() {
        guard isRunning else { return }
        coalesceTask?.cancel()
        coalesceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.coalesceInterval)
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    /// Re-reads the directory and publishes on a change. Every event funnels
    /// here, so it must be idempotent.
    func refresh() {
        guard isRunning else { return }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directoryURL.path)) ?? []

        let requestIDs = Set(names.compactMap(Self.requestID(fromName:)))
        sweepOrphanResponses(in: names, live: requestIDs)

        let requests = requestIDs.sorted().compactMap(request(id:))
        guard requests != lastRequests else { return }
        lastRequests = requests
        onRequests?(requests)
    }

    /// `<id>.json` → id; responses and temp files → nil.
    private static func requestID(fromName name: String) -> String? {
        guard name.hasSuffix(".json"), !name.hasSuffix(".response.json"), !name.hasPrefix(".") else {
            return nil
        }
        return String(name.dropLast(".json".count))
    }

    private func sweepOrphanResponses(in names: [String], live: Set<String>) {
        let fm = FileManager.default
        for name in names where name.hasSuffix(".response.json") {
            let id = String(name.dropLast(".response.json".count))
            guard !live.contains(id) else { continue }
            let url = directoryURL.appendingPathComponent(name)
            let modified = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
            guard let modified, Date().timeIntervalSince(modified) > Self.orphanResponseAge else { continue }
            try? fm.removeItem(at: url)
        }
    }

    // MARK: - Decoding

    /// Decodes one request. Anything unreadable, of an unknown shape, or left
    /// by a hook that is no longer running is skipped, so a stray file can
    /// never put buttons on screen that nothing is waiting behind.
    private func request(id: String) -> ClaudeRequest? {
        let url = directoryURL.appendingPathComponent("\(id).json")
        guard let data = try? Data(contentsOf: url),
              let request = Self.decode(stdin: data, id: id)
        else { return nil }
        guard Self.isAlive(request) else {
            // Its hook was killed outright and its trap never ran: nothing will
            // ever answer this or clean it up, so do it here.
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return request
    }

    /// The request a hook's stdin describes, or nil for anything the notch
    /// can't offer buttons for. Pure — no file, no liveness — so the debug
    /// fixtures decode the very payloads Claude Code sent.
    nonisolated static func decode(stdin data: Data, id: String) -> ClaudeRequest? {
        guard let stdin = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let toolName = stdin["tool_name"] as? String
        else { return nil }

        let event = stdin["hook_event_name"] as? String ?? ""
        let input = stdin["tool_input"] as? [String: Any] ?? [:]
        let sessionId = (stdin["session_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }

        let kind: ClaudeRequest.Kind
        var questions: [ClaudeQuestion] = []
        switch (event, toolName) {
        case ("PreToolUse", "AskUserQuestion"):
            kind = .question
            questions = Self.questions(from: input)
            // A question with nothing to pick can only be answered in the
            // terminal — don't offer an empty face for it.
            guard !questions.isEmpty, questions.allSatisfy({ !$0.options.isEmpty }) else { return nil }
        case ("PermissionRequest", let tool) where tool != "AskUserQuestion":
            kind = .approval
        default:
            return nil
        }

        return ClaudeRequest(
            id: id,
            kind: kind,
            sessionId: sessionId,
            toolName: toolName,
            subject: kind == .approval ? Self.subject(of: input) : nil,
            questions: questions
        )
    }

    private static func isAlive(_ request: ClaudeRequest) -> Bool {
        // No pid to check means a request id this build didn't mint; trust the
        // file, which the hook's trap removes on every ordinary exit.
        guard let pid = request.hookPID, pid > 0 else { return true }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    /// The tool input's subject, in the order a person would want to read
    /// it. Unknown tools fall back to the whole input, compact — something
    /// exact always beats something friendly when the click authorises it.
    nonisolated private static func subject(of input: [String: Any]) -> String? {
        for key in ["command", "file_path", "notebook_path", "url", "query", "pattern", "path", "description", "prompt"] {
            if let value = input[key] as? String, !value.isEmpty { return value }
        }
        guard !input.isEmpty,
              let data = try? JSONSerialization.data(
                withJSONObject: input,
                options: [.sortedKeys, .withoutEscapingSlashes]
              )
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    nonisolated private static func questions(from input: [String: Any]) -> [ClaudeQuestion] {
        guard let raw = input["questions"] as? [[String: Any]] else { return [] }
        return raw.compactMap { q in
            guard let text = q["question"] as? String else { return nil }
            let options = (q["options"] as? [[String: Any]] ?? []).compactMap { o -> ClaudeQuestion.Option? in
                guard let label = o["label"] as? String, !label.isEmpty else { return nil }
                let description = (o["description"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                return ClaudeQuestion.Option(label: label, description: description)
            }
            return ClaudeQuestion(
                question: text,
                header: (q["header"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                options: options,
                multiSelect: q["multiSelect"] as? Bool ?? false
            )
        }
    }

    // MARK: - Responding

    /// What the notch can say back to a blocked hook.
    enum Reply {
        case allow
        case deny
        /// Labels keyed by question text; a multi-select's labels are joined
        /// with ", " by the caller.
        case answers([String: String])
        /// No decision: the hook prints nothing and Claude shows its own UI.
        case terminal
    }

    /// Writes the response for `request`, by rename. Returns false when the
    /// request is already gone (the hook gave up first) or the write failed —
    /// in both cases the hook is left to its own deadline and nothing is
    /// claimed.
    @discardableResult
    func respond(_ reply: Reply, to request: ClaudeRequest) -> Bool {
        let fm = FileManager.default
        let requestURL = directoryURL.appendingPathComponent("\(request.id).json")
        guard fm.fileExists(atPath: requestURL.path),
              let payload = payload(for: reply, to: request, requestURL: requestURL),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.withoutEscapingSlashes])
        else { return false }

        let finalURL = directoryURL.appendingPathComponent("\(request.id).response.json")
        // Not ending in .json, so neither side can mistake it for a request or
        // a response while it's half-written.
        let tempURL = directoryURL.appendingPathComponent(".\(request.id).response.tmp")
        do {
            try data.write(to: tempURL)
        } catch {
            return false
        }
        guard rename(tempURL.path, finalURL.path) == 0 else {
            try? fm.removeItem(at: tempURL)
            return false
        }
        return true
    }

    /// The hook's complete stdout for each reply. Exactly the shapes verified
    /// against Claude Code (see ROADMAP, Milestone 7).
    private func payload(for reply: Reply, to request: ClaudeRequest, requestURL: URL) -> [String: Any]? {
        switch reply {
        case .allow:
            guard request.kind == .approval else { return nil }
            return ["hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": ["behavior": "allow"],
            ]]
        case .deny:
            guard request.kind == .approval else { return nil }
            // No `interrupt`: Claude hears the denial and can try another way,
            // as after a "No" in the terminal.
            return ["hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": ["behavior": "deny", "message": "Denied from the Isle notch"],
            ]]
        case .answers(let answers):
            // `updatedInput` replaces the tool's input wholesale, so it starts
            // from the input exactly as Claude sent it — the questions echoed
            // verbatim, re-read from the request rather than rebuilt from the
            // decoded copy — and only adds the answers.
            guard request.kind == .question,
                  let data = try? Data(contentsOf: requestURL),
                  let stdin = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  var input = stdin["tool_input"] as? [String: Any]
            else { return nil }
            input["answers"] = answers
            return ["hookSpecificOutput": [
                "hookEventName": "PreToolUse",
                "permissionDecision": "allow",
                "updatedInput": input,
            ]]
        case .terminal:
            return [:]
        }
    }
}

/// The `run/answering` marker: Isle's say-so that a blocked hook will be
/// answered. Its whole contract is the pid inside it, so the hook can tell a
/// running Isle from a stale file left by a crash.
enum ClaudeAnsweringMarker {
    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".isle/run/answering")
    }

    /// Writes this process's pid, by rename.
    static func write() {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let temp = dir.appendingPathComponent(".answering.tmp")
        guard (try? Data("\(getpid())\n".utf8).write(to: temp)) != nil else { return }
        if rename(temp.path, url.path) != 0 {
            try? fm.removeItem(at: temp)
        }
    }

    /// Removes the marker. Every waiting hook notices within a tick and hands
    /// its prompt back to the terminal.
    static func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
