//
//  ClaudeSessionHost.swift
//
//  Where a Claude Code session is on screen (Milestone 11), worked out from
//  the process tree rather than guessed. The session registry already names
//  the CLI's pid; from there:
//
//    * The CLI's controlling terminal (`e_tdev` → devname) is the tab's tty.
//      Terminal and iTerm2 both script their tabs by tty, so that is enough
//      to pick the exact tab out of every window.
//    * Walking the parent chain upward reaches the app that owns the pty —
//      the first ancestor that is a regular, Dock-visible app. That's the
//      host: Terminal, iTerm2, Ghostty, VS Code's integrated terminal (its
//      helpers are apps too, but not regular ones), and so on.
//    * tmux breaks the chain: the pane's shell is a child of the tmux server,
//      which is a daemon parented to launchd. The CLI's own environment
//      (`TMUX`, `TMUX_PANE`, readable through KERN_PROCARGS2 for a process of
//      the same user) names the server's socket and the pane, and the server
//      knows which client is showing that session — and the *client* sits in
//      the terminal tab. screen breaks it the same way, and screen has no
//      way to ask which terminal shows a session, so a screen-hosted session
//      resolves to nothing.
//
//  Says nothing it can't back up: a chain that doesn't end at an app gives no
//  host, and the face then has no Jump pill — never one aimed at a guess.
//
//  Everything here is read-only. Moving focus and typing live in
//  `TerminalBridge`.
//

import AppKit
import Darwin

/// A terminal whose tabs Isle can address by tty over AppleScript.
enum ScriptableTerminal: String, Equatable {
    case terminal = "com.apple.Terminal"
    case iTerm = "com.googlecode.iterm2"
}

/// A tmux pane, addressed the way tmux itself does.
struct TmuxPane: Equatable {
    /// The tmux binary that answered (the server's own may differ in path but
    /// speaks the same protocol over the socket).
    let binary: String
    /// The server's socket, from `TMUX`.
    let socket: String
    /// The pane id, `%N`, from `TMUX_PANE`. Stable for the pane's life.
    let pane: String
    /// The tty of the client showing the pane's session, when one is attached.
    let clientTTY: String?
}

struct ClaudeSessionHost: Equatable {
    /// The app the session is drawn in.
    struct App: Equatable {
        /// What the pill says: the app's own name, shortened only where its
        /// process name isn't what people call it ("Code" → "VS Code").
        let name: String
        let bundleIdentifier: String?
        let pid: pid_t
        let bundleURL: URL?
    }

    /// How close a jump lands.
    enum Precision: Equatable {
        /// The exact tab (Terminal, iTerm2), or window (kitty by id).
        case tab
        /// The right app, but whichever of its windows it brings forward.
        case app
    }

    /// The hosting app. Nil when the chain ends somewhere that isn't one —
    /// a detached tmux or screen, a daemon, an SSH session — and then
    /// nothing is offered.
    let app: App?
    /// The CLI's own terminal, `/dev/ttysNNN`.
    let sessionTTY: String?
    /// The tty of the terminal tab showing the session: the CLI's own for a
    /// plain terminal, the tmux client's when tmux sits in between.
    let tabTTY: String?
    let tmux: TmuxPane?
    /// kitty's window id and remote-control socket, when the session was
    /// started with remote control listening — the only case kitty can be
    /// asked to focus a window from outside.
    let kitty: (window: String, socket: String)?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.app == rhs.app && lhs.sessionTTY == rhs.sessionTTY && lhs.tabTTY == rhs.tabTTY
            && lhs.tmux == rhs.tmux && lhs.kitty?.window == rhs.kitty?.window
            && lhs.kitty?.socket == rhs.kitty?.socket
    }

    /// The app's tabs can be scripted by tty.
    var scriptable: ScriptableTerminal? {
        app?.bundleIdentifier.flatMap(ScriptableTerminal.init(rawValue:))
    }

    var precision: Precision {
        if scriptable != nil, tabTTY != nil { return .tab }
        if kitty != nil { return .tab }
        return .app
    }

    /// How a reply can be typed into the session, if it can. Only the routes
    /// that address the session's own input without focus: tmux's
    /// `send-keys` to the pane, and Terminal / iTerm2 writing to the tab that
    /// owns the session's tty. Everything else — Ghostty, Warp, VS Code's
    /// terminal — would need keystrokes into a focused window, which is
    /// exactly what Isle won't do.
    var typingRoute: TypingRoute? {
        if let tmux { return .tmux(tmux) }
        if let terminal = scriptable, let tty = sessionTTY, tabTTY == tty {
            return .tab(terminal, tty: tty)
        }
        return nil
    }

    enum TypingRoute: Equatable {
        case tmux(TmuxPane)
        case tab(ScriptableTerminal, tty: String)
    }
}

// MARK: - Resolving

enum ClaudeHostResolver {
    /// The host of the CLI process `pid`, or nil when that process is gone.
    /// Runs `tmux` when tmux is in the chain, so call it off the main thread.
    nonisolated static func resolve(cliPID pid: pid_t) -> ClaudeSessionHost? {
        guard let cli = ProcessSnapshot(pid: pid) else { return nil }
        let environment = ProcessSnapshot.environment(of: pid)

        if let tmux = environment["TMUX"], let pane = environment["TMUX_PANE"] {
            return resolveTmux(cli: cli, tmux: tmux, pane: pane)
        }

        let app = hostingApp(above: cli)
        var kitty: (String, String)?
        if app?.bundleIdentifier == "net.kovidgoyal.kitty",
           let window = environment["KITTY_WINDOW_ID"], let socket = environment["KITTY_LISTEN_ON"] {
            kitty = (window, socket)
        }
        return ClaudeSessionHost(app: app, sessionTTY: cli.ttyPath, tabTTY: app == nil ? nil : cli.ttyPath,
                                 tmux: nil, kitty: kitty)
    }

    /// The first regular app up the parent chain from `process`.
    nonisolated private static func hostingApp(above process: ProcessSnapshot) -> ClaudeSessionHost.App? {
        var pid = process.parent
        // A real chain is a handful of steps (claude → zsh → login →
        // Terminal); the cap only guards against a cycle in a racing table.
        for _ in 0..<32 where pid > 1 {
            if let running = NSRunningApplication(processIdentifier: pid),
               running.activationPolicy == .regular {
                return ClaudeSessionHost.App(
                    name: displayName(of: running),
                    bundleIdentifier: running.bundleIdentifier,
                    pid: pid,
                    bundleURL: running.bundleURL
                )
            }
            guard let next = ProcessSnapshot(pid: pid) else { return nil }
            pid = next.parent
        }
        return nil
    }

    /// The pane's session's attached client, and through it the tab.
    nonisolated private static func resolveTmux(cli: ProcessSnapshot, tmux: String, pane: String) -> ClaudeSessionHost {
        // TMUX is "<socket>,<server pid>,<session index>".
        let socket = String(tmux.split(separator: ",", maxSplits: 1).first ?? "")
        guard !socket.isEmpty, let binary = TmuxCommand.binary() else {
            return ClaudeSessionHost(app: nil, sessionTTY: cli.ttyPath, tabTTY: nil, tmux: nil, kitty: nil)
        }
        let session = TmuxCommand.run(binary, socket: socket,
                                      ["display-message", "-p", "-t", pane, "#{session_name}"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // The client showing that session most recently. Several can be
        // attached to one session; the most recently active is the one the
        // user last looked at.
        var client: (pid: pid_t, tty: String)?
        if let session, !session.isEmpty,
           let listing = TmuxCommand.run(binary, socket: socket,
                                         ["list-clients", "-F", "#{client_pid}\t#{client_tty}\t#{client_session}\t#{client_activity}"]) {
            var best: (pid: pid_t, tty: String, activity: Int)?
            for line in listing.split(separator: "\n") {
                let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard fields.count == 4, fields[2] == session, let pid = pid_t(fields[0]) else { continue }
                let activity = Int(fields[3]) ?? 0
                if best == nil || activity > best!.activity { best = (pid, fields[1], activity) }
            }
            if let best { client = (best.pid, best.tty) }
        }

        let pane = TmuxPane(binary: binary, socket: socket, pane: pane, clientTTY: client?.tty)
        guard let client, let snapshot = ProcessSnapshot(pid: client.pid) else {
            // Detached: nothing on screen to jump to, but the pane still takes
            // keys, so a reply can go.
            return ClaudeSessionHost(app: nil, sessionTTY: cli.ttyPath, tabTTY: nil, tmux: pane, kitty: nil)
        }
        let app = hostingApp(above: snapshot)
        return ClaudeSessionHost(app: app, sessionTTY: cli.ttyPath,
                                 tabTTY: app == nil ? nil : client.tty, tmux: pane, kitty: nil)
    }

    /// What the pill calls the app. The bundle's own name, except where
    /// that isn't the name people use.
    nonisolated static func displayName(of app: NSRunningApplication) -> String {
        switch app.bundleIdentifier {
        case "com.googlecode.iterm2": return "iTerm"
        case "com.microsoft.VSCode": return "VS Code"
        case "com.microsoft.VSCodeInsiders": return "VS Code"
        case "net.kovidgoyal.kitty": return "kitty"
        default: return app.localizedName ?? "Terminal"
        }
    }
}

// MARK: - Processes

/// One process, as `sysctl(KERN_PROC_PID)` reports it. Readable for any pid,
/// root's included (Terminal's `login` sits between the shell and the app).
struct ProcessSnapshot {
    let pid: pid_t
    let parent: pid_t
    let processGroup: pid_t
    /// The foreground process group of the process's controlling terminal.
    let terminalForeground: pid_t
    /// `/dev/ttysNNN`, or nil for a process with no controlling terminal.
    let ttyPath: String?
    let command: String

    nonisolated init?(pid: pid_t) {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0,
              info.kp_proc.p_pid == pid
        else { return nil }
        self.pid = pid
        parent = info.kp_eproc.e_ppid
        processGroup = info.kp_eproc.e_pgid
        terminalForeground = info.kp_eproc.e_tpgid
        let device = info.kp_eproc.e_tdev
        if device != -1, let name = devname(device, S_IFCHR) {
            ttyPath = "/dev/" + String(cString: name)
        } else {
            ttyPath = nil
        }
        command = withUnsafeBytes(of: info.kp_proc.p_comm) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    /// Whether the process's group owns its terminal — that is, it is what
    /// keys typed into the tab reach, not a shell it has given way to or a
    /// job in the background.
    var ownsTerminal: Bool { ttyPath != nil && terminalForeground == processGroup }

    /// The process's environment, read through KERN_PROCARGS2: argc, the exec
    /// path, padding, argv, then the environment, all NUL-separated. Only for
    /// processes of the same user; empty otherwise.
    nonisolated static func environment(of pid: pid_t) -> [String: String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [:] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [:] }

        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        // The exec path, then NUL padding up to argv[0].
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }

        var strings: [String] = []
        var start = index
        while index < size {
            if buffer[index] == 0 {
                if index > start {
                    strings.append(String(decoding: buffer[start..<index], as: UTF8.self))
                } else if strings.count >= Int(argc) {
                    break   // the environment ends at the first empty string
                }
                start = index + 1
            }
            index += 1
        }

        var environment: [String: String] = [:]
        for entry in strings.dropFirst(Int(argc)) {
            guard let equals = entry.firstIndex(of: "=") else { continue }
            environment[String(entry[..<equals])] = String(entry[entry.index(after: equals)...])
        }
        return environment
    }
}

// MARK: - tmux

enum TmuxCommand {
    /// The first tmux on the usual paths. An app launched from the Dock has
    /// no shell PATH, so this can't just be `tmux`.
    nonisolated static func binary() -> String? {
        ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/opt/local/bin/tmux", "/usr/bin/tmux"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Runs one tmux command against `socket` and returns its stdout, or nil
    /// when it failed. Short commands that return at once; blocking.
    @discardableResult
    nonisolated static func run(_ binary: String, socket: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["-S", socket] + arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
