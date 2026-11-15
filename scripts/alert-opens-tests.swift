//
//  alert-opens-tests.swift
//
//  An island off its notch opens the way its place calls for *now*, however
//  it opens — a hover, a click, a shortcut, a drop, or an alert, which opens
//  every island at once. All of them go through one step
//  (`IslandPresentation.expand`), which asks the island's carry to turn it
//  for its place before it opens. An alert used to open it the way it last
//  opened. And what an alert must leave alone: an island on its notch, the
//  island on another display, an island in the hand or gliding to where it
//  was put down.
//
//  The shipping NotchRootView, NotchWindow and IslandCarry, wired as
//  NotchWindowController wires them, on fake displays far off any real one
//  (-20000, -30000): windows at alpha 0 that ignore the mouse and are never
//  key. Presses are synthetic NSEvents handed straight to the window's
//  sendEvent, never posted. One view model behind both displays, as in Isle.
//
//  Run with scripts/test-alert-opens.sh.
//

import SwiftUI
import AppKit

final class FakeScreen: NSScreen {
    let f: NSRect
    init(x: CGFloat) {
        f = NSRect(x: x, y: -20000, width: 1512, height: 982)
        super.init()
    }
    override var frame: NSRect { f }
    override var visibleFrame: NSRect { NSRect(x: f.minX, y: f.minY, width: f.width, height: f.height - 38) }
    override var backingScaleFactor: CGFloat { 2 }
    override var safeAreaInsets: NSEdgeInsets { NSEdgeInsets() }
    override var deviceDescription: [NSDeviceDescriptionKey: Any] { NSScreen.screens[0].deviceDescription }
}

var failures = 0
var passes = 0
func report(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    if ok { passes += 1 } else { failures += 1 }
    print("  \(ok ? "ok  " : "FAIL")  \(name) \(ok ? "" : detail())")
}
func spin(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

/// One display's island.
@MainActor
final class Island {
    let screen: FakeScreen
    let island: IslandPresentation
    let metrics: NotchMetrics
    let window: NotchWindow
    let carry: IslandCarry
    var active: CGRect?
    var pointer = CGPoint.zero, buttonDown = false

    init(_ vm: NotchViewModel, x: CGFloat) {
        screen = FakeScreen(x: x)
        island = IslandPresentation(content: vm)
        metrics = NotchMetrics(screen: screen)
        island.metrics = metrics
        var me: Island?
        let (w, hosting) = NotchWindowController.makePanel(viewModel: vm, presentation: island, metrics: metrics) { me?.active = $0 }
        window = w
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        carry = IslandCarry(presentation: island, window: window)
        me = self
        window.pressInterceptor = { [unowned self] in self.carry.handle($0) }
        carry.drawnRect = { [unowned self] in self.drawn() }
        carry.pointer = { [unowned self] in IslandCarry.Pointer(location: self.pointer, buttonDown: self.buttonDown) }
        carry.canArm = { true }
        carry.reduceMotion = { false }
        window.contentView = hosting
        window.orderFrontRegardless()
    }

    func drawn() -> CGRect? {
        guard let a = active else { return nil }
        let f = window.frame
        return CGRect(x: f.minX + a.minX, y: f.maxY - a.maxY, width: a.width, height: a.height)
    }

    func send(_ type: NSEvent.EventType) {
        let e = NSEvent.mouseEvent(with: type, location: window.convertPoint(fromScreen: pointer), modifierFlags: [],
                                   timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                   context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
        window.sendEvent(e)
    }

    func press(at p: CGPoint) { pointer = p; buttonDown = true; send(.leftMouseDown); spin(0.02) }
    func move(to p: CGPoint, steps: Int = 10) {
        let from = pointer
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            pointer = CGPoint(x: from.x + (p.x - from.x) * t, y: from.y + (p.y - from.y) * t)
            send(.leftMouseDragged); spin(0.016)
        }
    }
    func release() { buttonDown = false; send(.leftMouseUp) }

    /// The closed capsule dragged by its middle to `to`, and let go.
    func dragPill(to: CGPoint) {
        guard let p = drawn() else { return }
        press(at: CGPoint(x: p.midX, y: p.midY)); move(to: to, steps: 20); release(); spin(0.7)
    }

    /// The open card dragged by its header so the header lands at `to`.
    func dragCard(headerTo to: CGPoint) {
        guard let c = drawn() else { return }
        press(at: CGPoint(x: c.midX, y: c.maxY - 4)); move(to: to, steps: 20); release(); spin(0.7)
    }

    var open: Bool { island.state.isExpanded }

    /// Closed in the middle of the screen still pinned right, as it was at
    /// the right wall when it was opened and carried open to here: a place
    /// that calls for growing from its middle, which the next open turns it to.
    func pinnedRightInTheMiddle() {
        let f = screen.f
        dragPill(to: CGPoint(x: f.maxX + 300, y: f.minY + 500))
        island.setHovering(true); spin(0.8)
        dragCard(headerTo: CGPoint(x: f.midX - 100, y: f.minY + 700))
        island.setHovering(false); spin(0.8)
    }
    var describe: String { "\(island.state) \(island.placement) up \(island.opening.upward) pin \(island.opening.pin)" }
}

@MainActor
func alert(_ vm: NotchViewModel, _ on: Bool) {
    vm.claudeState = on ? .needsApproval : .working
    spin(0.8)
}

/// The alert's news without its opening: the capsule changes what it says
/// (and so its width) for an approval, which is drawn before the alert
/// opens anything. Taken apart here so where the panel opens can be
/// measured against the capsule it opens from.
@MainActor
func alertNews(_ vm: NotchViewModel, _ settings: AppSettings) {
    settings.expandOnAlert = false
    vm.claudeState = .needsApproval
    spin(0.8)
}

/// Then the opening: the alert as it is, now allowed to open the island.
@MainActor
func alertOpens(_ settings: AppSettings) {
    settings.expandOnAlert = true
    spin(0.8)
}

@main
enum AlertOpens {
    @MainActor static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        NSApplication.shared.setActivationPolicy(.prohibited)
        let defaults = UserDefaults(suiteName: "isle.alertopens.\(UUID().uuidString)")!
        defaults.set("black", forKey: "isle.panelBackground")
        let settings = AppSettings(defaults: defaults)
        let fx = ClaudePanelFixture.all.first { $0.name == "sl_entry_busy" }!
        fx.configure(settings)
        settings.mode = .both
        settings.expandOnAlert = true
        let vm = NotchViewModel(settings: settings)
        vm.applyPreviewFixture(fx)

        let a = Island(vm, x: -20000)
        let b = Island(vm, x: -30000)
        let f = a.screen.f, v = a.screen.visibleFrame
        a.carry.place(.floating(anchor: CGPoint(x: f.midX, y: f.minY + 600)))
        b.carry.place(.docked)
        spin(0.8)
        report(!vm.autoExpandsForActivity && !a.open && !b.open, "to start: no alert, both closed", "\(a.describe) / \(b.describe)")

        print("An alert opens a floating island the way its place calls for")
        // At the bottom it opens up. Opened by a hover, carried open up to
        // the top and put down, closed: it still opens up until something
        // decides again.
        a.dragPill(to: CGPoint(x: f.midX, y: f.minY - 300))
        a.island.setHovering(true); spin(0.8)
        report(a.island.opening.upward, "at the bottom it opens up", a.describe)
        a.dragCard(headerTo: CGPoint(x: f.midX + 200, y: v.maxY - 150))
        report(a.island.opening.upward, "carried open to the top it keeps opening up while open", a.describe)
        a.island.setHovering(false); spin(0.8)
        alertNews(vm, settings)
        report(!a.open, "the approval's news shows in the capsule first", a.describe)
        let restedTop = a.drawn()
        alertOpens(settings)
        report(a.open && !a.island.opening.upward, "an alert opens it down, as its place now calls for", a.describe)
        if let c = a.drawn(), let p = restedTop {
            report(abs(c.maxY - p.maxY) < 0.6 && abs(c.midX - p.midX) < 0.6, "hanging from the capsule as it rested", "\(c) from \(p)")
            report(v.insetBy(dx: -0.5, dy: -0.5).contains(c), "wholly on the screen", "\(c)")
        }
        report(b.open && b.island.placement == .docked && b.island.opening == .down,
               "the other display's island, on its notch, opens as ever", b.describe)
        report(b.window.frame == b.metrics.frame(for: .docked), "its window untouched", "\(b.window.frame)")
        alert(vm, false)
        report(!a.open && !b.open, "the alert over, both close")

        // Pinned right, carried open into the middle, closed: an alert opens
        // it from its middle.
        a.dragPill(to: CGPoint(x: f.maxX + 300, y: f.minY + 500))
        report(a.island.opening.pin == .trailing, "against the right wall it's pinned right", a.describe)
        a.island.setHovering(true); spin(0.8)
        a.dragCard(headerTo: CGPoint(x: f.midX - 100, y: f.minY + 700))
        a.island.setHovering(false); spin(0.8)
        report(a.island.opening.pin == .trailing, "carried open to the middle and closed, it's still pinned right", a.describe)
        alertNews(vm, settings)
        let restedMid = a.drawn()
        alertOpens(settings)
        report(a.open && a.island.opening.pin == .centre, "an alert opens it from its middle", a.describe)
        if let c = a.drawn(), let p = restedMid {
            report(abs(c.midX - p.midX) < 0.6, "centred on the capsule as it rested", "\(c) from \(p)")
        }
        alert(vm, false)

        print("An alert leaves alone what's in the hand")
        // Somewhere that calls for a turn the next time it opens.
        a.pinnedRightInTheMiddle()
        let before = a.island.opening
        report(before.pin == .trailing, "set up: pinned right in the middle", a.describe)
        report(a.carry.isBusy == false && !a.open, "closed, at rest", a.describe)
        guard let pill = a.drawn() else { report(false, "no layout"); exit(1) }
        a.press(at: CGPoint(x: pill.midX, y: pill.midY))
        a.move(to: CGPoint(x: pill.midX + 60, y: pill.midY + 40))
        let grip = CGPoint(x: a.window.frame.minX - a.pointer.x, y: a.window.frame.minY - a.pointer.y)
        vm.claudeState = .needsApproval
        a.island.takeInActivity()
        report(a.open, "an alert arriving mid-carry opens it")
        report(a.island.opening == before, "but doesn't turn it under the pointer", a.describe)
        report(a.window.frame.minX - a.pointer.x == grip.x && a.window.frame.minY - a.pointer.y == grip.y,
               "the window still where the pointer holds it", "\(a.window.frame) pointer \(a.pointer)")
        a.move(to: CGPoint(x: pill.midX + 120, y: pill.midY + 200))
        report(abs(a.window.frame.minX - a.pointer.x - grip.x) < 1.5, "and still follows the pointer by the same grip")
        a.release(); spin(0.8)
        report(a.island.placement.isFloating && a.open, "put down open, it stays open", a.describe)
        alert(vm, false)
        report(!a.open, "the alert over, it closes")

        // Let go closed over the menu bar, and an alert arrives while it
        // glides down to rest below it.
        if let p = a.drawn() {
            a.press(at: CGPoint(x: p.midX, y: p.midY)); a.move(to: CGPoint(x: f.minX + 400, y: f.maxY - 5), steps: 16); a.release()
            let placed = a.island.placement, turned = a.island.opening
            report(a.carry.isBusy, "let go: gliding to where it was put")
            vm.claudeState = .needsApproval
            a.island.takeInActivity()
            report(a.island.placement == placed && a.island.opening == turned, "an alert mid-glide doesn't re-anchor it", a.describe)
            spin(0.8)
            report(!a.carry.isBusy && a.window.frame == a.metrics.frame(for: placed, opening: turned), "it arrives where it was put", "\(a.window.frame)")
            report(a.open, "and is open for the alert")
            alert(vm, false)
        }

        print("Every way of opening goes through the one step")
        // A hover, a shortcut, a click on the capsule, an alert: each turns
        // it for its place first.
        for way in ["hover", "shortcut", "click", "alert"] {
            a.pinnedRightInTheMiddle()
            if way == "alert" { alertNews(vm, settings) }
            let stale = a.island.opening
            let rested = a.drawn()
            if way == "alert" { settings.expandOnAlert = true }
            switch way {
            case "hover": a.island.setHovering(true)
            case "shortcut": a.island.openFromShortcut()
            case "click": a.island.openFromClick()
            default: break
            }
            spin(0.8)
            let o = a.island.opening
            report(a.open && stale.pin == .trailing && o.pin == .centre, "\(way): opens from its middle, as the middle calls for", "\(stale) → \(a.describe)")
            if let c = a.drawn(), let p = rested { report(abs(c.midX - p.midX) < 0.6, "\(way): centred on the capsule as it rested", "\(c) from \(p)") }
            if way == "alert" { alert(vm, false) } else { a.island.setHovering(false); spin(0.8) }
        }
        report(b.island.placement == .docked && b.island.opening == .down && b.window.frame == b.metrics.frame(for: .docked),
               "through all of it the docked island on the other display never moved", b.describe)

        a.window.orderOut(nil)
        b.window.orderOut(nil)
        print("\n\(passes) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
