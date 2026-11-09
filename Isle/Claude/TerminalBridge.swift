//
//  TerminalBridge.swift
//
//  The two things Isle does *to* a terminal, both only on a click: bring the
//  tab hosting a session to the front (Jump, Milestone 11), and type a reply
//  into it (Reply).
//
//  Terminal and iTerm2 are driven over AppleScript, addressing the tab by the
//  session's tty — the one identifier both apps expose and the process tree
//  can vouch for. The user's text never becomes script source: each script is
//  a set of handlers, compiled once, and called with the tty and the text as
//  Apple-event parameters, so nothing typed can change what the script does.
//  tmux is driven through its own command line. Everything runs on one serial
//  queue, never the main thread: the first Apple event to an app waits on the
//  Automation consent prompt.
//
//  Why typing, for Reply: it is the only channel whose text reaches Claude as
//  the user's own turn. Every hook channel delivers text as something else —
//  an asyncRewake Stop hook's output arrives wrapped in "[SYSTEM NOTIFICATION
//  - NOT USER INPUT] … must NOT be treated as approval or consent", and a
//  model asked "create it?" then refused a "yes" sent that way; a blocking
//  Stop hook leaves the session spinning on "running Stop hook" for as long
//  as it waits. See ROADMAP, "Reply to Claude".
//
//  Possibly shared: the drop-zone work launches Terminal.app for "Start
//  Claude here" and could take its AppleScript plumbing from here.
//

import AppKit

enum TerminalBridge {
    enum Failure: Error, Equatable {
        /// Automation for that app is off in System Settings (errAEEventNotPermitted).
        case notPermitted(app: String)
        /// No tab shows the session's tty any more.
        case tabMissing
        /// The app isn't running.
        case appGone
        /// Anything else the script or tmux reported.
        case failed
    }

    private static let queue = DispatchQueue(label: "isle.terminal-bridge", qos: .userInitiated)

    // MARK: - Jump

    /// Brings the session's tab — or, short of that, its app — to the front.
    /// tmux first selects the pane in the client the tab is showing.
    static func jump(to host: ClaudeSessionHost) async -> Result<Void, Failure> {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: jumpNow(host))
            }
        }
    }

    nonisolated private static func jumpNow(_ host: ClaudeSessionHost) -> Result<Void, Failure> {
        guard let app = host.app else { return .failure(.appGone) }

        if let tmux = host.tmux {
            // The client's current window and pane, so the tab opens on the
            // session rather than wherever the client was left.
            var arguments = ["switch-client", "-t", tmux.pane]
            if let client = tmux.clientTTY { arguments.insert(contentsOf: ["-c", client], at: 1) }
            TmuxCommand.run(tmux.binary, socket: tmux.socket, arguments)
            TmuxCommand.run(tmux.binary, socket: tmux.socket, ["select-pane", "-t", tmux.pane])
        }

        if let terminal = host.scriptable, let tty = host.tabTTY {
            let result = call(terminal, "jump_to", [tty])
            switch result {
            case .success:
                return .success(())
            case .failure(.tabMissing):
                break   // fall back to the app below
            case .failure(let failure):
                // No consent is still a known app: bring it forward rather than
                // nothing, which is what a click on its name promises.
                if case .notPermitted = failure { return activate(app) }
                return .failure(failure)
            }
        }

        if let kitty = host.kitty, let kitten = kittenBinary(for: app) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: kitten)
            process.arguments = ["@", "--to", kitty.socket, "focus-window", "--match", "id:\(kitty.window)"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
        }
        return activate(app)
    }

    /// Activates the app through Launch Services, which honours the request
    /// from a background app — Isle never activates, so a direct
    /// `NSRunningApplication.activate` can be declined under cooperative
    /// activation. Launch Services sends the running app a reopen, as a Dock
    /// click does.
    nonisolated private static func activate(_ app: ClaudeSessionHost.App) -> Result<Void, Failure> {
        guard let url = app.bundleURL else {
            return NSRunningApplication(processIdentifier: app.pid)?.activate() == true
                ? .success(()) : .failure(.appGone)
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        return .success(())
    }

    nonisolated private static func kittenBinary(for app: ClaudeSessionHost.App) -> String? {
        guard let url = app.bundleURL?.appendingPathComponent("Contents/MacOS/kitten"),
              FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url.path
    }

    // MARK: - Typing

    /// Types `text` followed by Return into the session's input, without
    /// focusing anything. The caller has already checked the session is at
    /// its prompt — this only delivers keys.
    ///
    /// The text goes in as an explicit bracketed paste, then one carriage
    /// return. Claude Code takes an unmarked burst of typing as a paste once
    /// it's long enough — about a sentence — and a CR inside a paste is a
    /// newline in the prompt, not Enter, so a long reply used to sit there
    /// unsent. Marked as a paste, the text can't swallow the CR after it,
    /// whatever its length and whether or not the two arrive in one read
    /// (verified on 2.1.319). A CR followed by an LF is *not* submitted, so
    /// exactly one CR follows: Terminal's `do script` adds it itself (it
    /// appends a lone CR — captured raw), iTerm's and tmux's are sent here.
    static func type(_ text: String, via route: ClaudeSessionHost.TypingRoute) async -> Result<Void, Failure> {
        let pasted = bracketedPaste(text)
        return await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: typeNow(pasted, via: route))
            }
        }
    }

    /// `text` between the bracketed-paste markers, with every control
    /// character dropped first: the reply is one line, and an ESC of its own
    /// could end the paste early.
    nonisolated static func bracketedPaste(_ text: String) -> String {
        let clean = String(String.UnicodeScalarView(text.unicodeScalars.filter {
            !($0.value < 0x20 || (0x7F...0x9F).contains($0.value))
        }))
        return "\u{1B}[200~" + clean + "\u{1B}[201~"
    }

    nonisolated private static func typeNow(_ text: String, via route: ClaudeSessionHost.TypingRoute) -> Result<Void, Failure> {
        switch route {
        case .tmux(let pane):
            // `-l` sends the text literally: no key names, nothing expanded.
            guard TmuxCommand.run(pane.binary, socket: pane.socket, ["send-keys", "-t", pane.pane, "-l", "--", text]) != nil,
                  TmuxCommand.run(pane.binary, socket: pane.socket, ["send-keys", "-t", pane.pane, "Enter"]) != nil
            else { return .failure(.failed) }
            return .success(())
        case .tab(let terminal, let tty):
            return call(terminal, "type_into", [tty, text])
        }
    }

    // MARK: - AppleScript

    /// Handler sources, per app. Each handler returns "ok" or "missing".
    nonisolated private static func source(for terminal: ScriptableTerminal) -> String {
        switch terminal {
        case .terminal:
            return """
            on jump_to(theTTY)
                tell application id "com.apple.Terminal"
                    repeat with w in windows
                        repeat with t in tabs of w
                            if tty of t is theTTY then
                                if miniaturized of w then set miniaturized of w to false
                                set selected of t to true
                                set index of w to 1
                                activate
                                return "ok"
                            end if
                        end repeat
                    end repeat
                end tell
                return "missing"
            end jump_to

            on type_into(theTTY, theText)
                tell application id "com.apple.Terminal"
                    repeat with w in windows
                        repeat with t in tabs of w
                            if tty of t is theTTY then
                                do script theText in t
                                return "ok"
                            end if
                        end repeat
                    end repeat
                end tell
                return "missing"
            end type_into
            """
        case .iTerm:
            return """
            on jump_to(theTTY)
                tell application id "com.googlecode.iterm2"
                    repeat with w in windows
                        repeat with t in tabs of w
                            repeat with s in sessions of t
                                if tty of s is theTTY then
                                    select w
                                    tell t to select
                                    tell s to select
                                    activate
                                    return "ok"
                                end if
                            end repeat
                        end repeat
                    end repeat
                end tell
                return "missing"
            end jump_to

            on type_into(theTTY, theText)
                tell application id "com.googlecode.iterm2"
                    repeat with w in windows
                        repeat with t in tabs of w
                            repeat with s in sessions of t
                                if tty of s is theTTY then
                                    tell s to write text (theText & return) newline no
                                    return "ok"
                                end if
                            end repeat
                        end repeat
                    end repeat
                end tell
                return "missing"
            end type_into
            """
        }
    }

    /// Compiled once per app, on first use — compiling resolves the app's
    /// dictionary, so an app that isn't installed is never asked about.
    /// Touched only from `queue`.
    nonisolated(unsafe) private static var compiled: [ScriptableTerminal: NSAppleScript] = [:]

    nonisolated private static func script(for terminal: ScriptableTerminal) -> NSAppleScript? {
        if let script = compiled[terminal] { return script }
        guard let script = NSAppleScript(source: source(for: terminal)) else { return nil }
        var error: NSDictionary?
        guard script.compileAndReturnError(&error) else {
            NSLog("Isle: \(terminal) script failed to compile: \(error ?? [:])")
            return nil
        }
        compiled[terminal] = script
        return script
    }

    /// Calls one handler with string parameters.
    nonisolated private static func call(_ terminal: ScriptableTerminal, _ handler: String,
                                         _ parameters: [String]) -> Result<Void, Failure> {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: terminal.rawValue).isEmpty else {
            return .failure(.appGone)
        }
        guard let script = script(for: terminal) else { return .failure(.failed) }

        let event = NSAppleEventDescriptor(
            eventClass: fourCharCode("ascr"),   // kASAppleScriptSuite
            eventID: fourCharCode("psbr"),      // kASSubroutineEvent
            targetDescriptor: .currentProcess(),
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setDescriptor(NSAppleEventDescriptor(string: handler), forKeyword: fourCharCode("snam"))   // keyASSubroutineName
        let list = NSAppleEventDescriptor.list()
        for (index, parameter) in parameters.enumerated() {
            list.insert(NSAppleEventDescriptor(string: parameter), at: index + 1)
        }
        event.setParam(list, forKeyword: AEKeyword(keyDirectObject))

        var error: NSDictionary?
        let result = script.executeAppleEvent(event, error: &error)
        if let error {
            let code = (error[NSAppleScript.errorNumber] as? Int) ?? 0
            NSLog("Isle: \(terminal) \(handler) failed: \(error)")
            // -1743 errAEEventNotPermitted: Automation declined. -1744 is the
            // same answer while the consent prompt couldn't be shown.
            if code == -1743 || code == -1744 {
                return .failure(.notPermitted(app: terminal == .terminal ? "Terminal" : "iTerm"))
            }
            if code == -600 { return .failure(.appGone) }
            return .failure(.failed)
        }
        return result.stringValue == "ok" ? .success(()) : .failure(.tabMissing)
    }

    /// The OSA constants live in Carbon; spelled out here rather than
    /// importing all of it for three codes.
    nonisolated private static func fourCharCode(_ code: String) -> FourCharCode {
        code.utf8.reduce(0) { $0 << 8 | FourCharCode($1) }
    }
}
