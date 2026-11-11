//
//  island-windows-tests.swift
//
//  The island's two windows — the panel and the glass window under it — built
//  the one way Isle builds them (`NotchWindowController.makePanel`), checked
//  for where they sit and how they're ordered:
//
//  - Both always at `NotchMetrics.maximumFrame`: after setup, an open and a
//    close, a re-place (a screen change), and whatever tries to size them to
//    their content — the bug that drew the island 16pt left of the camera.
//  - The glass window on screen exactly when the panel is, directly below
//    it, at its frame, level and alpha: after every step of the key handoff
//    (`takeKeys` / `giveKeysBack`) and every other way a window is ordered,
//    hidden or faded — never bare glass with the panel missing, never glass
//    over the panel.
//
//  - Off the notch (`IslandPlacement.floating`): what the island draws —
//    the bead, the capsule, a toast, the open panel and the tallest one, in
//    every mode — is at the top centre of the window and inside it, shadow
//    included; the panel's tree and the glass window's report the same
//    outline; and docking puts back exactly what was there.
//
//  The windows are at alpha 0 and ignore the mouse: nothing is shown, nothing
//  is clickable, and they never activate or take keys (key status is driven
//  through `becomeKey`/`resignKey`, as AppKit calls them, without the window
//  server). Run with scripts/test-island-windows.sh.
//

import SwiftUI
import AppKit

var failures = 0
var passes = 0

func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    if ok {
        passes += 1
        print("  ok    \(name)")
    } else {
        failures += 1
        print("  FAIL  \(name) \(detail())")
    }
}

@MainActor
func spin(_ seconds: Double) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

/// The two windows' places in the window server's front-to-back order.
@MainActor
func serverOrder(_ panel: NotchWindow) -> (panel: Int?, glass: Int?) {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    let order = list.compactMap { $0[kCGWindowNumber as String] as? Int }
    return (order.firstIndex(of: panel.windowNumber), order.firstIndex(of: panel.glassWindow.windowNumber))
}

/// The glass window in step with the panel: shown exactly when it is, just
/// below it, at its frame, level and alpha.
@MainActor
func checkInStep(_ w: NotchWindow, _ step: String) {
    let glass = w.glassWindow
    check(glass.isVisible == w.isVisible, "\(step): the glass shows exactly when the panel does",
          "panel \(w.isVisible) glass \(glass.isVisible)")
    if w.isVisible {
        check(glass.parent === w, "\(step): the glass is the panel's child")
        check(glass.frame == w.frame && glass.level == w.level && glass.alphaValue == w.alphaValue,
              "\(step): the glass has the panel's frame, level and alpha",
              "\(glass.frame) \(glass.level.rawValue) \(glass.alphaValue) vs \(w.frame) \(w.level.rawValue) \(w.alphaValue)")
        let o = serverOrder(w)
        if let p = o.panel, let g = o.glass {
            check(p < g, "\(step): the panel is above the glass in the window server", "panel \(p) glass \(g)")
        } else {
            check(false, "\(step): both windows are on screen in the window server", "\(o)")
        }
    } else {
        let o = serverOrder(w)
        check(o.glass == nil, "\(step): no glass on screen without the panel", "\(o)")
    }
}

@MainActor
func checkPlaced(_ w: NotchWindow, _ target: NSRect, _ step: String) {
    check(w.frame == target, "\(step): the panel is at maximumFrame", "\(w.frame) want \(target)")
    check(w.glassWindow.frame == target, "\(step): the glass window is at maximumFrame", "\(w.glassWindow.frame) want \(target)")
}

/// The island off its notch, in the same two windows. Each tree reports the
/// outline it drew (`onActiveRectChange`), so the two can be compared with
/// each other and with the window.
@MainActor
func floatingChecks(_ w: NotchWindow, vm: NotchViewModel, island: IslandPresentation, settings: AppSettings,
                    metrics: NotchMetrics, target: NSRect) {
    print("off the notch")
    final class Reported { var panel = CGRect.null; var glass = CGRect.null }
    let reported = Reported()
    let panelHost = NSHostingView(rootView: NotchRootView(viewModel: vm, island: island, glassLayer: .withoutMaterial) { reported.panel = $0 })
    panelHost.sizingOptions = []
    let glassHost = NSHostingView(rootView: NotchRootView(viewModel: vm, island: island, glassLayer: .materialOnly) { reported.glass = $0 })
    glassHost.sizingOptions = []
    // The window's own two views go back when this is done.
    let ownPanel = w.contentView, ownGlass = w.glassWindow.contentView
    defer {
        w.contentView = ownPanel
        if let ownGlass { w.attachGlass(ownGlass) }
        spin(0.3)
    }
    w.contentView = panelHost
    w.attachGlass(glassHost)
    func fixture(_ name: String) -> ClaudePanelFixture { ClaudePanelFixture.all.first { $0.name == name }! }
    let bounds = CGRect(origin: .zero, size: target.size)
    let flare = IslandMotion.openCorners.top
    let reach = IslandFloat.shadowReach

    /// What the two trees drew, against the window and each other.
    func checkDrawn(_ what: String, shadow: Bool) {
        let r = reported.panel
        check(r == reported.glass, "\(what): the panel's tree and the glass window's draw the same outline", "\(r) vs \(reported.glass)")
        check(bounds.contains(r), "\(what): inside the window", "\(r) in \(bounds)")
        check(r.minY == 0 && abs(r.midX - bounds.midX) < 0.01, "\(what): hanging from the window's top centre", "\(r)")
        if shadow {
            let fallen = CGRect(x: r.minX - reach.side, y: r.minY, width: r.width + 2 * reach.side, height: r.height + reach.below)
            check(bounds.contains(fallen), "\(what): and its shadow with it", "\(fallen) in \(bounds)")
        }
        checkPlaced(w, target, what)
    }

    island.setHovering(false)
    vm.applyPreviewFixture(fixture("idle"))
    spin(1.0)
    let dockedIdle = reported.panel
    check(dockedIdle.size == metrics.notchSize, "on the notch, with nothing live: the camera's own size", "\(dockedIdle)")

    for background in PanelBackground.allCases {
        settings.panelBackground = background
        let name = background.title
        let black = background == .black
        withAnimation(.notchOpen) { island.placement = .floating(anchor: CGPoint(x: target.midX, y: target.maxY - 200)) }
        vm.applyPreviewFixture(fixture("idle"))
        spin(0.9)
        check(reported.panel.size == IslandFloat.bead, "\(name), nothing live: the bead", "\(reported.panel)")
        checkDrawn("\(name), bead", shadow: black)

        vm.applyPreviewFixture(fixture("working_tool"))
        spin(0.9)
        let pill = FloatingPillLayout.pill(for: vm)
        check(pill.claude != nil && pill.music == nil && !pill.isBead, "\(name), Claude working: a capsule with Claude's cluster")
        check(reported.panel.size == pill.size && pill.size.height == IslandFloat.pillHeight, "\(name), capsule: as wide as what it holds, and the capsule's height",
              "\(reported.panel) vs \(pill.size)")
        check(reported.panel.width > IslandFloat.bead.width, "\(name), capsule: wider than the bead")
        checkDrawn("\(name), capsule", shadow: black)

        island.setHovering(true)
        spin(1.2)
        let lips = background == .prism ? (side: IslandPrism.sideLip, bottom: IslandPrism.lip) : (side: 0, bottom: 0)
        let open = CGSize(width: NotchMetrics.expandedSize.width - 2 * flare + 2 * lips.side, height: NotchMetrics.expandedSize.height + lips.bottom)
        check(reported.panel.size == open, "\(name), open: the docked panel less its flares", "\(reported.panel) vs \(open)")
        checkDrawn("\(name), open", shadow: black)
        checkInStep(w, "\(name), open off the notch")

        // The tallest: a question with four options.
        vm.applyPreviewFixture(fixture("question_4"))
        spin(1.2)
        check(reported.panel.height > open.height && reported.panel.height <= NotchMetrics.panelMaxHeight + lips.bottom,
              "\(name), a question: taller, within the cap", "\(reported.panel)")
        checkDrawn("\(name), the tall panel", shadow: black)

        island.setHovering(false)
        vm.applyPreviewFixture(fixture("idle"))
        spin(1.0)
        check(reported.panel.size == IslandFloat.bead, "\(name): closed again, the bead", "\(reported.panel)")

        withAnimation(.notchClose) { island.placement = .docked }
        spin(0.9)
        check(reported.panel.height == metrics.notchSize.height && reported.panel == reported.glass,
              "\(name): docked again, back at the camera band's height", "\(reported.panel)")
    }
    // A toast borrows the capsule. (Last: a pinned preview toast stays up.)
    settings.panelBackground = .black
    island.placement = .floating(anchor: CGPoint(x: target.midX, y: target.maxY - 200))
    vm.pinPreviewToast(NotchViewModel.previewToasts()[0])
    spin(0.9)
    let toast = FloatingPillLayout.pill(for: vm)
    check(toast.toast != nil && reported.panel.size == toast.size, "a toast: the capsule sized to its message", "\(reported.panel) vs \(toast.size)")
    checkDrawn("a toast", shadow: true)
    island.placement = .docked
    settings.panelBackground = .glass
    spin(0.9)
}

@MainActor
func run() {
    NSApplication.shared.setActivationPolicy(.prohibited)
    guard let screen = NotchMetrics.preferredScreen() else {
        print("no screen: skipped")
        exit(0)
    }
    let defaults = UserDefaults(suiteName: "isle.windowtests.\(UUID().uuidString)")!
    // A background from before Smoked and Fade were removed: read as Glass.
    defaults.set("fade", forKey: "isle.panelBackground")
    let settings = AppSettings(defaults: defaults)
    check(settings.panelBackground == .glass, "a stored Fade starts up as Glass", "\(settings.panelBackground)")
    settings.mode = .both
    let vm = NotchViewModel(settings: settings)
    let island = IslandPresentation(content: vm)
    let metrics = NotchMetrics(screen: screen)
    island.metrics = metrics
    let target = metrics.maximumFrame

    print("setup")
    let (w, hosting) = NotchWindowController.makePanel(viewModel: vm, presentation: island, metrics: metrics) { _ in }
    // Invisible and click-through, whatever the controller would make of it.
    w.alphaValue = 0
    w.ignoresMouseEvents = true
    w.contentView = hosting
    w.place(target)
    w.orderFrontRegardless()
    spin(0.5)
    check(hosting.sizingOptions.isEmpty, "the panel's hosting view doesn't size the window")
    check((w.glassWindow.contentView as? NSHostingView<NotchRootView>)?.sizingOptions.isEmpty == true,
          "nor does the glass window's")
    check(target.width > NotchMetrics.expandedSize.width, "maximumFrame is wider than the open panel (the side pads)")
    checkPlaced(w, target, "after setup")
    checkInStep(w, "after setup")
    check(!w.glassWindow.canBecomeKey && !w.glassWindow.canBecomeMain && w.glassWindow.ignoresMouseEvents,
          "the glass window never becomes key or main, and never takes a click")
    check(w.animationBehavior == .none && w.glassWindow.animationBehavior == .none,
          "the panel and its glass go on and off screen without the system's fade",
          "panel \(w.animationBehavior.rawValue) glass \(w.glassWindow.animationBehavior.rawValue)")

    print("open and close")
    island.setHovering(true)
    spin(1.0)
    checkPlaced(w, target, "open")
    checkInStep(w, "open")
    island.setHovering(false)
    spin(1.0)
    checkPlaced(w, target, "closed")
    checkInStep(w, "closed")

    print("screen change")
    let moved = target.offsetBy(dx: -40, dy: 0)
    w.place(moved)
    spin(0.2)
    checkPlaced(w, moved, "re-placed")
    w.place(target)
    w.orderFrontRegardless()
    spin(0.2)
    checkPlaced(w, target, "placed back")
    checkInStep(w, "placed back")

    print("nothing sizes the window")
    w.contentMaxSize = NSSize(width: NotchMetrics.expandedSize.width, height: target.height)
    w.maxSize = NSSize(width: NotchMetrics.expandedSize.width, height: target.height)
    w.setContentSize(NSSize(width: NotchMetrics.expandedSize.width, height: target.height))
    spin(0.2)
    checkPlaced(w, target, "content size set to the open panel's")
    w.setFrame(NSRect(origin: target.origin, size: NSSize(width: NotchMetrics.expandedSize.width, height: target.height)), display: true)
    spin(0.2)
    checkPlaced(w, target, "frame set to the open panel's width")
    // The original bug: a hosting view left to size its window.
    let sized = NSHostingView(rootView: NotchRootView(viewModel: vm, island: island, glassLayer: .withoutMaterial))
    w.contentView = sized
    island.setHovering(true)
    spin(1.0)
    checkPlaced(w, target, "a hosting view left on its default sizing, open")
    island.setHovering(false)
    spin(1.0)
    checkPlaced(w, target, "a hosting view left on its default sizing, closed")
    w.contentView = hosting
    spin(0.2)

    print("key handoff")
    island.setHovering(true)
    spin(0.8)
    // takeKeys
    w.allowsKey = true
    w.becomeKey()
    spin(0.2)
    checkInStep(w, "takeKeys")
    checkPlaced(w, target, "takeKeys")
    // giveKeysBack
    w.allowsKey = false
    w.makeFirstResponder(nil)
    w.resignKey()
    spin(0.2)
    checkInStep(w, "keys given back")
    w.orderOut(nil)
    spin(0.2)
    checkInStep(w, "giveKeysBack: ordered out")
    w.orderFrontRegardless()
    spin(0.2)
    checkInStep(w, "giveKeysBack: ordered back")
    checkPlaced(w, target, "giveKeysBack: ordered back")
    // The same out-and-back in one turn, as the async block does.
    w.orderOut(nil)
    w.orderFrontRegardless()
    spin(0.2)
    checkInStep(w, "out and back in one turn")
    // Several handoffs in a row, as a reply after a reply.
    for i in 1...3 {
        w.allowsKey = true; w.becomeKey(); spin(0.05)
        w.allowsKey = false; w.resignKey(); w.orderOut(nil); w.orderFrontRegardless(); spin(0.1)
        checkInStep(w, "handoff \(i)")
    }

    print("every other way a window is ordered or faded")
    w.order(.out, relativeTo: 0); spin(0.1); checkInStep(w, "order(.out)")
    w.order(.above, relativeTo: 0); spin(0.1); checkInStep(w, "order(.above)")
    w.setIsVisible(false); spin(0.1); checkInStep(w, "setIsVisible(false)")
    w.setIsVisible(true); spin(0.1); checkInStep(w, "setIsVisible(true)")
    w.orderBack(nil); spin(0.1); checkInStep(w, "orderBack")
    w.orderFront(nil); spin(0.1); checkInStep(w, "orderFront")
    w.glassWindow.orderFrontRegardless(); spin(0.1)
    w.orderFrontRegardless(); spin(0.1); checkInStep(w, "glass brought forward on its own, then the panel")
    w.alphaValue = 0.5; spin(0.1); checkInStep(w, "alpha changed")
    w.alphaValue = 0; spin(0.1)
    let level = w.level
    w.level = NSWindow.Level(rawValue: level.rawValue + 1); spin(0.1); checkInStep(w, "level changed")
    w.level = level
    NotificationCenter.default.post(name: NSWindow.didChangeScreenNotification, object: w)
    spin(0.1)
    checkInStep(w, "screen changed")
    checkPlaced(w, target, "at the end")

    print("prism: the lens")
    check(target.height >= NotchMetrics.panelMaxHeight + IslandPrism.lip,
          "the window has room for Prism's lip under the tallest panel", "\(target.height)")
    check(!w.glassWindow.lensed, "Glass's glass is the frosted one: the glass window isn't lensed")
    settings.panelBackground = .prism
    spin(0.4)
    if #available(macOS 26.0, *) {
        check(w.glassWindow.lensed, "Prism asks the glass window for the lens")
        check(!w.glassWindow.canBecomeKey && !w.glassWindow.canBecomeMain && w.glassWindow.ignoresMouseEvents,
              "which still can't become key or main, or take a click")
        check(NSApp.keyWindow !== w.glassWindow && NSApp.mainWindow !== w.glassWindow,
              "and is nobody's key or main window")
        // AppKit taking the keys away from it, as when another of Isle's
        // windows becomes key or the app deactivates.
        w.glassWindow.resignKey(); spin(0.2)
        check(w.glassWindow.lensed, "a resignKey leaves it lensed")
        island.setHovering(true); spin(1.0)
        checkPlaced(w, target, "prism, open")
        checkInStep(w, "prism, open")
        w.orderOut(nil); spin(0.1); w.orderFrontRegardless(); spin(0.2)
        check(w.glassWindow.lensed, "off screen and back, still lensed")
        checkInStep(w, "prism, off screen and back")
        island.setHovering(false); spin(1.0)
        checkInStep(w, "prism, closed")
        settings.panelBackground = .glass
        spin(0.4)
        check(!w.glassWindow.lensed, "leaving Prism puts the frosted glass back")
    } else {
        check(!w.glassWindow.lensed, "before Liquid Glass there's no lens to ask for")
        settings.panelBackground = .glass
        spin(0.2)
    }

    floatingChecks(w, vm: vm, island: island, settings: settings, metrics: metrics, target: target)

    w.orderOut(nil)
    spin(0.1)
    checkInStep(w, "hidden")
    print("\n\(passes) passed, \(failures) failed")
    exit(failures == 0 ? 0 : 1)
}

@main
enum Tests {
    static func main() {
        MainActor.assumeIsolated { run() }
    }
}
