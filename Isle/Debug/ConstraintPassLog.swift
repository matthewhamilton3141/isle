//
//  ConstraintPassLog.swift
//
//  Debug builds only: names the window, and the loop, behind a crash that
//  hasn't been reproduced (Debug builds, 9, 11 and 12 Nov 2026):
//
//      NSGenericException: The window has been marked as needing another
//      Update Constraints in Window pass, but it has already had more Update
//      Constraints in Window passes than there are views in the window.
//
//  The reports say neither which window nor what kept asking.
//
//  How AppKit counts (macOS 26, read from its disassembly and measured):
//  each window's private `_auxiliaryStorage` holds the display cycle it last
//  ran an Update Constraints pass in (+0x278), how many passes it has had in
//  that cycle (+0x280), and how many views it has (+0x2d0). The display
//  cycle's observer bumps the count and calls `updateConstraintsIfNeeded`.
//  Anything that marks a view as needing constraints after that, in the same
//  cycle, goes through `-[NSWindow _postWindowNeedsUpdateConstraints]`, which
//  queues one more pass. Once there have been min(100, views + 1) + 5 passes
//  it throws instead: measured, a 2-view window throws on the ask after pass
//  8, a 3-view one after pass 9. A second pass in a cycle is routine (a resize,
//  SwiftUI adding a subview during layout); a third is not, and the crash
//  needs several more. So this logs every ask that would give a window its
//  third pass or later in one cycle: the window, what it belongs to, its
//  view count, the pass, the stack that asked, and what Isle had just done.
//
//  Private layout, so everything fails soft. `install()` checks the ivar,
//  the selectors and their signatures; then the first passes it sees are
//  checked against what can be known without it (the cycle's own
//  identifier, a sane pass count, AppKit's view count against a count of
//  the tree). Anything off and it writes one line saying so and does
//  nothing more. Nothing happens at rest: it runs only when AppKit runs a
//  constraints pass or a view asks for one.
//
//  Reading it:
//      tail -80 /tmp/isle-constraints.log     (or ISLE_CONSTRAINTS_LOG)
//  "--- … on" when it is watching, "--- … off: <why>" when it isn't.
//  "=== <window> asked for pass N in one display cycle" opens each record,
//  then the window's context, its recent events and the asking stack. Later
//  asks in the same cycle are "+++ pass N" with their stack. "THIS ASK
//  THROWS" marks the one AppKit raises on. After a crash, the file's last
//  record is the crashing window. ISLE_CONSTRAINTS_LOG=off turns it off.
//

#if DEBUG

import AppKit
import Darwin

@MainActor
enum ConstraintPassLog {
    /// Where AppKit keeps a window's constraint-pass bookkeeping, as offsets
    /// into `_auxiliaryStorage`. A test sets wrong ones to see it switch off.
    struct Layout {
        var cycle = 0x278
        var passes = 0x280
        var views = 0x2d0
        var end: Int { max(cycle, passes, views) + MemoryLayout<Int>.size }
    }

    static var layout = Layout()

    /// The pass from which an ask is logged.
    static let firstLoggedPass = 3

    static let path: String = {
        let env = ProcessInfo.processInfo.environment["ISLE_CONSTRAINTS_LOG"]
        return env?.isEmpty == false ? env! : "/tmp/isle-constraints.log"
    }()

    enum State: Equatable {
        case notInstalled
        case validating
        case on
        case off(String)
    }

    private(set) static var state = State.notInstalled

    // MARK: - Installing

    /// Hooks AppKit's two methods, once. Safe to call more than once and on
    /// any macOS: anything unexpected switches the log off with one line.
    static func install() {
        guard state == .notInstalled else { return }
        if path == "off" {
            state = .off("ISLE_CONSTRAINTS_LOG=off")
            return
        }
        trimIfLarge()
        guard let ivar = class_getInstanceVariable(NSWindow.self, "_auxiliaryStorage") else {
            return turnOff("NSWindow has no _auxiliaryStorage")
        }
        auxOffset = ivar_getOffset(ivar)
        guard let cycleClass = NSClassFromString("NSDisplayCycle"),
              let cycleGetter = class_getClassMethod(cycleClass, NSSelectorFromString("currentDisplayCycle")),
              returnType(cycleGetter) == "@",
              let identifier = class_getInstanceMethod(cycleClass, NSSelectorFromString("identifier")),
              returnType(identifier) == "Q" else {
            return turnOff("no +[NSDisplayCycle currentDisplayCycle] / -identifier as expected")
        }
        displayCycleClass = cycleClass
        let updateSel = #selector(NSWindow.updateConstraintsIfNeeded)
        let askSel = NSSelectorFromString("_postWindowNeedsUpdateConstraints")
        guard let update = class_getInstanceMethod(NSWindow.self, updateSel), isVoidNoArgs(update),
              let ask = class_getInstanceMethod(NSWindow.self, askSel), isVoidNoArgs(ask) else {
            return turnOff("-[NSWindow updateConstraintsIfNeeded] or -_postWindowNeedsUpdateConstraints missing or changed")
        }

        typealias Fn = @convention(c) (NSWindow, Selector) -> Void
        let originalUpdate = unsafeBitCast(method_getImplementation(update), to: Fn.self)
        let originalAsk = unsafeBitCast(method_getImplementation(ask), to: Fn.self)
        let updateBlock: @convention(block) (NSWindow) -> Void = { window in
            guard Thread.isMainThread else { return originalUpdate(window, updateSel) }
            MainActor.assumeIsolated { willPass(window); passDepth += 1 }
            originalUpdate(window, updateSel)
            MainActor.assumeIsolated { passDepth -= 1; didPass(window) }
        }
        let askBlock: @convention(block) (NSWindow) -> Void = { window in
            if Thread.isMainThread { MainActor.assumeIsolated { asked(window) } }
            originalAsk(window, askSel)
        }
        method_setImplementation(update, imp_implementationWithBlock(updateBlock))
        method_setImplementation(ask, imp_implementationWithBlock(askBlock))
        state = .validating
        write("--- Isle \(version) pid \(getpid()): constraint pass log installed, checking AppKit's counter")
    }

    private static func turnOff(_ why: String) {
        state = .off(why)
        write("--- Isle \(version) pid \(getpid()): constraint pass log off: \(why)")
    }

    private static func returnType(_ method: Method) -> String {
        let raw = method_copyReturnType(method)
        defer { free(raw) }
        return String(cString: raw)
    }

    private static func isVoidNoArgs(_ method: Method) -> Bool {
        method_getNumberOfArguments(method) == 2 && returnType(method) == "v"
    }

    private static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    // MARK: - Windows Isle describes

    /// Gives a window a name and a description of what it is showing, for
    /// its records and its event history. Weak: a window that goes is
    /// forgotten.
    static func watch(_ window: NSWindow, as name: String, describe: @escaping () -> String) {
        install()
        if case .off = state { return }
        watched[ObjectIdentifier(window)] = Watched(window: window, name: name, describe: describe)
        observeFrames(of: window)
    }

    private struct Watched {
        weak var window: NSWindow?
        let name: String
        let describe: () -> String
        var lastState: String?
    }

    private static var watched: [ObjectIdentifier: Watched] = [:]

    private static func observeFrames(of window: NSWindow) {
        for (name, what) in [(NSWindow.didResizeNotification, "resized"), (NSWindow.didMoveNotification, "moved")] {
            NotificationCenter.default.addObserver(forName: name, object: window, queue: nil) { note in
                guard let window = note.object as? NSWindow else { return }
                MainActor.assumeIsolated {
                    guard state == .on || state == .validating else { return }
                    event(window, "\(what) to \(rect(window.frame))\(passDepth > 0 ? " during a constraints pass" : "")")
                }
            }
        }
    }

    // MARK: - Events

    private struct Event {
        let time: CFTimeInterval
        let cycle: UInt?
        let window: String
        let text: String
    }

    private static var events: [Event] = []
    private static let eventLimit = 24

    private static func event(_ window: NSWindow, _ text: String) {
        events.append(Event(time: CACurrentMediaTime(), cycle: currentCycle(), window: label(window), text: text))
        if events.count > eventLimit { events.removeFirst(events.count - eventLimit) }
    }

    // MARK: - AppKit's counter

    private static var auxOffset = 0
    private static var displayCycleClass: AnyClass?
    private static var passDepth = 0

    private struct Counter {
        let cycle: UInt
        let passes: Int
        let views: Int
    }

    private static func counter(_ window: NSWindow) -> Counter? {
        let base = Unmanaged.passUnretained(window).toOpaque()
        guard let aux = base.load(fromByteOffset: auxOffset, as: UnsafeRawPointer?.self),
              malloc_size(aux) >= layout.end else { return nil }
        return Counter(cycle: aux.load(fromByteOffset: layout.cycle, as: UInt.self),
                       passes: aux.load(fromByteOffset: layout.passes, as: Int.self),
                       views: aux.load(fromByteOffset: layout.views, as: Int.self))
    }

    private static func currentCycle() -> UInt? {
        guard let cls = displayCycleClass as? NSObject.Type,
              let cycle = cls.perform(NSSelectorFromString("currentDisplayCycle"))?.takeUnretainedValue() as? NSObject else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> UInt
        let sel = NSSelectorFromString("identifier")
        return unsafeBitCast(cycle.method(for: sel), to: Getter.self)(cycle, sel)
    }

    private static func viewCount(_ window: NSWindow) -> Int {
        func count(_ view: NSView) -> Int { 1 + view.subviews.reduce(0) { $0 + count($1) } }
        guard let root = window.contentView?.superview ?? window.contentView else { return 0 }
        return count(root)
    }

    // MARK: - Checking the counter

    private static var goodSamples = 0
    private static var unmatchedSamples = 0
    private static var badSamples: [String] = []

    /// A pass AppKit's display cycle ran: the counter must say this cycle,
    /// a pass count it could have, and the window's own number of views.
    private static func validate(_ window: NSWindow) {
        guard let c = counter(window) else { return turnOff("a window's _auxiliaryStorage is smaller than expected") }
        guard let now = currentCycle(), now == c.cycle else {
            // Not run by the display cycle (a layout asked for it), or the
            // offsets are wrong. Wrong offsets never match.
            unmatchedSamples += 1
            if unmatchedSamples >= 200, goodSamples == 0 {
                turnOff("the pass counter never named the current display cycle in 200 passes")
            }
            return
        }
        let views = viewCount(window)
        if (1...100).contains(c.passes), c.views == views {
            goodSamples += 1
            if goodSamples >= 3 {
                state = .on
                write("--- constraint pass log on: AppKit's counter checked against \(goodSamples) passes; asks for pass \(firstLoggedPass) or later in one display cycle are logged here")
            }
        } else {
            // A window whose views AppKit counts differently is tolerated a
            // while; wrong offsets never give three exact matches.
            badSamples.append("\(label(window)): passes \(c.passes), AppKit's views \(c.views), counted \(views)")
            if badSamples.count >= 20 || !(1...100).contains(c.passes) {
                turnOff("AppKit's counter doesn't read as expected (\(badSamples.prefix(3).joined(separator: "; ")))")
            }
        }
    }

    // MARK: - The hooks

    private static func willPass(_ window: NSWindow) {
        guard state == .on, var w = watched[ObjectIdentifier(window)],
              let c = counter(window), c.passes == 1, c.cycle == currentCycle() else { return }
        // The first pass of a cycle: what the island is showing, if that
        // changed since its last one.
        let now = w.describe()
        if now != w.lastState {
            w.lastState = now
            watched[ObjectIdentifier(window)] = w
            event(window, "showing: \(now)")
        }
    }

    private static func didPass(_ window: NSWindow) {
        if state == .validating { validate(window) }
    }

    /// Per window, the last (cycle, pass) an ask was logged for: several
    /// asks inside one pass make one more pass between them.
    private static var lastLogged: [ObjectIdentifier: (cycle: UInt, passes: Int)] = [:]

    private static func asked(_ window: NSWindow) {
        guard state == .on, let c = counter(window), c.passes >= firstLoggedPass - 1,
              let now = currentCycle(), now == c.cycle else { return }
        let id = ObjectIdentifier(window)
        if let last = lastLogged[id], last.cycle == now, last.passes == c.passes { return }
        let first = lastLogged[id]?.cycle != now
        lastLogged[id] = (now, c.passes)
        guard allowRecord() else { return }

        let next = c.passes + 1
        // Measured: AppKit raises on the ask made after pass
        // min(100, views + 1) + 5.
        let throwsAt = min(100, c.views + 1) + 5
        let throwing = c.passes >= throwsAt ? "  THIS ASK THROWS" : ""
        if first {
            write("=== \(label(window)) asked for pass \(next) in one display cycle (\(c.views) views; AppKit throws on the ask after pass \(throwsAt))\(throwing)")
            write("   window: \(String(describing: type(of: window))) #\(window.windowNumber) frame \(rect(window.frame)) visible \(window.isVisible) key \(window.isKeyWindow) alpha \(window.alphaValue)")
            if let w = watched[id] {
                write("   showing: \(w.describe())")
            }
            writeEvents(now: now)
        } else {
            write("+++ \(label(window)) asked for pass \(next)\(throwing)")
        }
        write("   from:\n      " + stack().joined(separator: "\n      "))
    }

    // MARK: - Rate

    /// At most `burst` records a minute, whatever a busy cycle does.
    private static let burst = 120
    private static var windowStart: CFTimeInterval = 0
    private static var recordsThisWindow = 0
    private static var suppressed = 0

    private static func allowRecord() -> Bool {
        let now = CACurrentMediaTime()
        if now - windowStart > 60 {
            if suppressed > 0 { write("--- \(suppressed) records left out in the last minute (more than \(burst))") }
            windowStart = now
            recordsThisWindow = 0
            suppressed = 0
        }
        recordsThisWindow += 1
        if recordsThisWindow > burst {
            suppressed += 1
            return false
        }
        return true
    }

    // MARK: - Describing

    static func label(_ window: NSWindow) -> String {
        if let w = watched[ObjectIdentifier(window)] { return "\(w.name) #\(window.windowNumber)" }
        let title = window.title.isEmpty ? "" : " \"\(window.title)\""
        return "\(String(describing: type(of: window)))\(title) #\(window.windowNumber)"
    }

    static func rect(_ r: NSRect) -> String {
        String(format: "(%.1f,%.1f %.1f×%.1f)", r.minX, r.minY, r.width, r.height)
    }

    private static func writeEvents(now: UInt) {
        guard !events.isEmpty else { return write("   events: none") }
        write("   events, oldest first (age, and whether in this display cycle):")
        let t = CACurrentMediaTime()
        for e in events {
            write(String(format: "     %8.1fms %@ %@ %@", (t - e.time) * 1000, e.cycle == now ? "this cycle" : "earlier   ", e.window, e.text))
        }
    }

    private static func stack() -> [String] {
        Thread.callStackSymbols.dropFirst(1).compactMap { line -> String? in
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count > 3 else { return nil }
            let image = String(parts[1])
            let symbol = parts[3...].joined(separator: " ").replacingOccurrences(of: #" \+ \d+$"#, with: "", options: .regularExpression)
            return "\(image)  \(demangle(symbol))"
        }
        .filter { !$0.contains("ConstraintPassLog") && !$0.contains("reabstraction thunk") && !$0.contains("assumeIsolated") }
        .prefix(28)
        .map { $0 }
    }

    private static func demangle(_ symbol: String) -> String {
        typealias Demangle = @convention(c) (UnsafePointer<CChar>?, Int, UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<Int>?, UInt32) -> UnsafeMutablePointer<CChar>?
        guard symbol.hasPrefix("$s"), let f = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "swift_demangle") else { return symbol }
        guard let out = symbol.withCString({ unsafeBitCast(f, to: Demangle.self)($0, strlen($0), nil, nil, 0) }) else { return symbol }
        defer { free(out) }
        let text = String(cString: out)
        return text.count > 160 ? String(text.prefix(160)) + "…" : text
    }

    // MARK: - Writing

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    private static var handle: FileHandle?

    /// Appended and flushed to disk at once: the next thing may be the crash.
    private static func write(_ text: String) {
        guard path != "off", let data = "\(stamp.string(from: Date())) \(text)\n".data(using: .utf8) else { return }
        if handle == nil {
            if !FileManager.default.fileExists(atPath: path) {
                FileManager.default.createFile(atPath: path, contents: nil)
            }
            handle = FileHandle(forWritingAtPath: path)
            _ = try? handle?.seekToEnd()
        }
        try? handle?.write(contentsOf: data)
        try? handle?.synchronize()
    }

    /// Past 8 MB the file starts again, the old one kept beside it.
    private static func trimIfLarge() {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int, size > 8_000_000 else { return }
        let old = path + ".old"
        try? FileManager.default.removeItem(atPath: old)
        try? FileManager.default.moveItem(atPath: path, toPath: old)
    }
}

#endif
