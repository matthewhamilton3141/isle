//
//  ShelfActions.swift
//
//  What a drop, or the shelf, can do with files: start Claude in a folder,
//  and AirDrop them.
//
//  Start Claude opens a new Terminal.app window in the folder running
//  `claude`, over AppleScript. That's an Apple event to Terminal, so the
//  first use asks for the Automation permission (Isle-Info.plist's
//  NSAppleEventsUsageDescription says what for). Claude is started plain —
//  no flags — exactly as the user would type it.
//

import AppKit

enum ClaudeLauncher {
    /// Whether "Start Claude here" can be offered for this folder. A path
    /// with a control character in it (a newline is legal in a file name)
    /// can't be typed into a shell as one line, so it isn't offered rather
    /// than offered and mangled.
    static func canStart(in folder: URL) -> Bool {
        folder.isFileURL && !folder.path.unicodeScalars.contains {
            $0.value < 0x20 || $0.value == 0x7F
        }
    }

    /// The command line Terminal runs: `cd -- '<folder>' && claude`.
    ///
    /// The path is single-quoted, with the two characters that a single
    /// quote doesn't neutralise in every shell taken outside the quotes and
    /// backslash-escaped: `'` itself, and `\`, which fish (unlike sh, bash
    /// and zsh) still reads as an escape inside single quotes. The result is
    /// one literal word in sh, bash, zsh and fish, whatever the login shell
    /// Terminal opens. `--` so a folder named `-P` isn't taken as a flag.
    static func shellCommand(for folder: URL) -> String {
        "cd -- \(shellQuoted(folder.path)) && claude"
    }

    static func shellQuoted(_ string: String) -> String {
        var quoted = "'"
        for character in string {
            switch character {
            case "'": quoted += "'\\''"
            case "\\": quoted += "'\\\\'"
            default: quoted.append(character)
            }
        }
        return quoted + "'"
    }

    /// The command as an AppleScript string literal: inside double quotes,
    /// only `\` and `"` mean anything, so those two are escaped and nothing
    /// else is touched (control characters never get this far — see
    /// `canStart`).
    static func appleScriptLiteral(_ string: String) -> String {
        var literal = "\""
        for character in string {
            switch character {
            case "\\": literal += "\\\\"
            case "\"": literal += "\\\""
            default: literal.append(character)
            }
        }
        return literal + "\""
    }

    /// The whole script. A new window every time, never a tab in whatever
    /// the user has open — except on Terminal's own launch: `do script`
    /// always makes a window, and a Terminal that wasn't running has just
    /// opened its startup window too, so the command goes into that one
    /// rather than leaving an empty window behind it.
    static func appleScript(for folder: URL) -> String {
        let command = appleScriptLiteral(shellCommand(for: folder))
        return """
        set wasRunning to application "Terminal" is running
        tell application "Terminal"
            if not wasRunning and (count of windows) is 1 then
                do script \(command) in window 1
            else
                do script \(command)
            end if
            activate
        end tell
        """
    }

    private static let queue = DispatchQueue(label: "com.isle.claude-launcher")

    /// Opens the window. Off the main thread: the first run waits on the
    /// Automation prompt, and every run waits on Terminal.
    static func start(in folder: URL) {
        guard canStart(in: folder) else { return }
        let source = appleScript(for: folder)
        queue.async {
            guard let script = NSAppleScript(source: source) else { return }
            var error: NSDictionary?
            script.executeAndReturnError(&error)
            if let error {
                // -1743 is the Automation permission refused. Nothing on the
                // notch claims the window opened, so there's nothing to take
                // back; the log says why.
                NSLog("Isle: couldn't start Claude in Terminal: \(error)")
            }
        }
    }
}

/// AirDrop, through the system's own sheet.
///
/// The sheet is a window of Isle's, and Isle is an agent app that never
/// activates: left that way, the sheet comes up behind the app you're in,
/// can't take Escape, and — with no Dock icon — there's no way to bring it
/// forward. So this is the one place Isle activates itself, for exactly as
/// long as the sheet is up, and hands the front back to the app that had it
/// when the sheet finishes or is cancelled. The notch panel itself still
/// never becomes key.
@MainActor
final class AirDropSender: NSObject, NSSharingServiceDelegate {
    static let shared = AirDropSender()

    private var service: NSSharingService?
    private var previousApp: NSRunningApplication?

    /// Whether AirDrop can take these items on this Mac at all, for the
    /// drop face and the shelf to offer it only when it can.
    static func canSend(_ urls: [URL]) -> Bool {
        guard !urls.isEmpty, let service = NSSharingService(named: .sendViaAirDrop) else { return false }
        return service.canPerform(withItems: urls)
    }

    func send(_ urls: [URL]) {
        guard !urls.isEmpty,
              let service = NSSharingService(named: .sendViaAirDrop),
              service.canPerform(withItems: urls)
        else { return }
        // One sheet at a time.
        guard self.service == nil else { return }
        self.service = service
        service.delegate = self

        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        NSApp.activate()
        service.perform(withItems: urls)
    }

    nonisolated func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        MainActor.assumeIsolated { finish() }
    }

    nonisolated func sharingService(
        _ sharingService: NSSharingService, didFailToShareItems items: [Any], error: any Error
    ) {
        // Cancelling the sheet lands here too.
        MainActor.assumeIsolated { finish() }
    }

    private func finish() {
        service = nil
        if let previousApp, !previousApp.isTerminated {
            previousApp.activate()
        }
        previousApp = nil
    }
}
