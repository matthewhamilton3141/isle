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
//  - Off the notch (`offTheNotch`): both windows at whatever frame a
//    floating placement means, through opens, closes and stray moves; the
//    glass in step with the panel at every step of a drag; and the whole
//    press — a click, a hold that runs the line and lifts the island, the
//    carry, the notch taking it back, the put-down — driven through the
//    window's own `sendEvent` with synthetic mouse events, the real timers,
//    and a pointer the test supplies (never the real one).
//
//  - What an island off its notch draws (`floatingChecks`) —
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
        let open = CGSize(width: NotchMetrics.expandedSize.width - 2 * flare + 2 * lips.side,
                          height: NotchMetrics.expandedSize.height + lips.bottom + IslandFloat.roof)
        check(reported.panel.size == open, "\(name), open: the docked panel less its flares, and its roof taller", "\(reported.panel) vs \(open)")
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
    // The line that runs round a held island (`DetachTrace`) is cut from
    // whatever outline is drawn. Off the notch that is these: each has to
    // give it a start at the bottom centre and two equal halves that meet
    // at the top centre.
    print("off the notch: the held line's path round each outline")
    let outlines: [(String, CGSize, (top: CGFloat, bottom: CGFloat, crown: CGFloat))] = [
        ("the bead", IslandFloat.bead, IslandFloat.corners(open: false, prism: false, closedHeight: IslandFloat.bead.height)),
        ("a capsule", CGSize(width: 240, height: IslandFloat.pillHeight), IslandFloat.corners(open: false, prism: false, closedHeight: IslandFloat.pillHeight)),
        ("the open panel", CGSize(width: NotchMetrics.expandedSize.width - 2 * flare, height: NotchMetrics.expandedSize.height),
         IslandFloat.corners(open: true, prism: false, closedHeight: IslandFloat.pillHeight)),
        ("Prism's tallest panel", CGSize(width: NotchMetrics.expandedSize.width - 2 * flare + 2 * IslandPrism.sideLip, height: NotchMetrics.panelMaxHeight + IslandPrism.lip),
         IslandFloat.corners(open: true, prism: true, closedHeight: IslandFloat.pillHeight)),
        ("half way off the notch", CGSize(width: NotchMetrics.expandedSize.width - flare, height: NotchMetrics.expandedSize.height), (flare / 2, 25, 14)),
    ]
    for (name, size, corners) in outlines {
        let shape = NotchShape(topCornerRadius: corners.top, bottomCornerRadius: corners.bottom, crownRadius: corners.crown)
        let path = shape.path(in: CGRect(origin: .zero, size: size)).cgPath
        let box = path.boundingBoxOfPath
        // The walls stand the flare's radius inside the frame: nothing,
        // once the island is off the notch.
        let wall = corners.top
        check(abs(box.minX - wall) < 0.01 && abs(box.maxX - (size.width - wall)) < 0.01 && abs(box.minY) < 0.01 && abs(box.maxY - size.height) < 0.01,
              "\(name): the outline runs wall to wall and top to bottom", "\(box)")
        check(!path.contains(CGPoint(x: wall + 0.5, y: 0.5)) && !path.contains(CGPoint(x: size.width - wall - 0.5, y: 0.5)),
              "\(name): nothing in the top corners — no flare past the walls, no square top")
        check(path.contains(CGPoint(x: size.width / 2, y: 0.5)) && path.contains(CGPoint(x: wall + 0.5, y: size.height / 2)),
              "\(name): and all of the top edge's middle and the walls")
        guard let halves = DetachTraceGeometry.halves(of: path) else {
            check(false, "\(name): the line has a path round it")
            continue
        }
        check(abs(halves.start.x - size.width / 2) < 0.01 && abs(halves.start.y - size.height) < 0.01, "\(name): the line starts at the bottom centre", "\(halves.start)")
        check(abs(halves.leftEnd.x - size.width / 2) < 0.01 && abs(halves.leftEnd.y) < 0.01
              && abs(halves.rightEnd.x - halves.leftEnd.x) < 0.01 && abs(halves.rightEnd.y - halves.leftEnd.y) < 0.01,
              "\(name): and its two ends meet at the top centre", "\(halves.leftEnd) \(halves.rightEnd)")
        check(abs(halves.leftLength - halves.rightLength) < 0.5 && halves.leftLength > size.width / 2 + size.height / 2,
              "\(name): by two halves of the same length, each all the way round its side", "\(halves.leftLength) \(halves.rightLength)")
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

// MARK: - Off the notch

/// A mouse event for `window` at `point`, in screen coordinates, as the
/// window server would make it.
@MainActor
func mouse(_ type: NSEvent.EventType, _ window: NSWindow, at point: CGPoint) -> NSEvent {
    NSEvent.mouseEvent(with: type, location: window.convertPoint(fromScreen: point), modifierFlags: [],
                       timestamp: ProcessInfo.processInfo.systemUptime,
                       windowNumber: window.windowNumber, context: nil,
                       eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
}

@MainActor
func find<V: NSView>(_ type: V.Type, in view: NSView?) -> V? {
    guard let view else { return nil }
    if let hit = view as? V { return hit }
    for sub in view.subviews {
        if let hit = find(type, in: sub) { return hit }
    }
    return nil
}

@MainActor
func offTheNotch(_ screen: NSScreen) {
    let defaults = UserDefaults(suiteName: "isle.windowtests.floating.\(UUID().uuidString)")!
    let settings = AppSettings(defaults: defaults)
    settings.mode = .both
    let vm = NotchViewModel(settings: settings)
    let island = IslandPresentation(content: vm)
    let metrics = NotchMetrics(screen: screen)
    island.metrics = metrics
    let bounds = metrics.placementBounds
    let docked = metrics.maximumFrame

    var activeRect: CGRect?
    var hostingRef: NotchHostingView<NotchRootView>?
    let (w, hosting) = NotchWindowController.makePanel(viewModel: vm, presentation: island, metrics: metrics) { rect in
        activeRect = rect
        hostingRef?.activeRect = rect
    }
    hostingRef = hosting
    w.alphaValue = 0
    w.ignoresMouseEvents = true
    w.contentView = hosting

    // The carry, wired as the controller wires it, but with a pointer of
    // the test's own: where it says, with the button as it says.
    let carry = IslandCarry(presentation: island, window: w)
    var pointer = IslandCarry.Pointer(location: .zero, buttonDown: false)
    var haptics: [IslandCarry.Haptic] = []
    var placed: [IslandPlacement] = []
    var arrivals = 0
    carry.pointer = { pointer }
    carry.reduceMotion = { false }
    carry.haptic = { haptics.append($0) }
    carry.onPlaced = { placed.append($0) }
    carry.onArrived = { arrivals += 1 }
    carry.drawnRect = {
        guard let rect = activeRect else { return nil }
        return CGRect(x: w.frame.minX + rect.minX, y: w.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }
    w.pressInterceptor = { carry.handle($0) }

    /// The button goes down at `point` (screen), and the pointer is there.
    func pressDown(at point: CGPoint) {
        pointer = .init(location: point, buttonDown: true)
        w.sendEvent(mouse(.leftMouseDown, w, at: point))
    }
    /// The pointer moves to `point` with the button down.
    func drag(to point: CGPoint) {
        pointer.location = point
        w.sendEvent(mouse(.leftMouseDragged, w, at: point))
    }
    func release() {
        pointer.buttonDown = false
        w.sendEvent(mouse(.leftMouseUp, w, at: pointer.location))
    }

    print("off the notch: the frame for a placement")
    check(metrics.frame(for: .docked) == docked, "docked is maximumFrame")
    let anchor = bounds.resting(CGPoint(x: bounds.dock.x - 180, y: bounds.dock.y - 320))
    let floating = metrics.frame(for: .floating(anchor: anchor))
    check(floating.size == docked.size, "floating is the same size: the window is never resized", "\(floating.size)")
    check(NotchMetrics.anchor(of: floating) == anchor, "with its top centre on the anchor", "\(floating) \(anchor)")
    check(NotchMetrics.anchor(of: docked) == bounds.dock, "and docked, on the screen's top centre")

    print("off the notch: the windows follow the placement")
    carry.place(.docked)
    w.orderFrontRegardless()
    spin(0.4)
    checkPlaced(w, docked, "docked")
    carry.place(.floating(anchor: anchor))
    spin(0.2)
    check(island.placement == .floating(anchor: anchor), "the placement is published")
    check(w.frame == floating && w.glassWindow.frame == floating, "the panel and its glass are at the floating frame",
          "\(w.frame) \(w.glassWindow.frame) want \(floating)")
    checkInStep(w, "floating")
    island.setHovering(true)
    spin(1.0)
    check(w.frame == floating && w.glassWindow.frame == floating, "open, floating: still there")
    checkInStep(w, "floating, open")
    island.setHovering(false)
    spin(1.0)
    check(w.frame == floating && w.glassWindow.frame == floating, "closed again: still there")
    w.setFrameOrigin(NSPoint(x: floating.minX + 60, y: floating.minY - 40))
    spin(0.2)
    check(w.frame == floating && w.glassWindow.frame == floating, "a move that didn't come from the carry is put back",
          "\(w.frame)")
    w.setFrame(docked, display: true)
    spin(0.2)
    check(w.frame == floating, "even one back to the notch: the placement decides", "\(w.frame)")
    w.setContentSize(NSSize(width: NotchMetrics.expandedSize.width, height: floating.height))
    spin(0.2)
    check(w.frame == floating && w.glassWindow.frame == floating, "and nothing sizes it there either")

    print("off the notch: the glass moves with the panel")
    var inStep = true
    var frame = floating
    for i in 0..<60 {
        frame.origin.x += 5
        frame.origin.y += i < 30 ? 3 : -3
        w.slide(to: frame)
        // Asked at once, in the same turn of the run loop as the move.
        if w.frame != frame || w.glassWindow.frame != frame { inStep = false }
    }
    check(inStep, "at every one of 60 moves, the glass has the panel's frame before the move returns",
          "\(w.frame) \(w.glassWindow.frame)")
    spin(0.2)
    check(w.frame == frame && w.glassWindow.frame == frame, "and both stay where the last one put them")
    checkInStep(w, "after sliding")
    w.setFrameOrigin(floating.origin)
    spin(0.2)
    check(w.frame == frame, "where it slid to is now the frame that's held", "\(w.frame)")

    print("off the notch: a click on the open panel is still a click")
    carry.place(.docked)
    island.setHovering(true)
    spin(1.0)
    check(vm.expandedPlace == .home, "the panel opens on Home")
    guard let drawn = carry.drawnRect() else {
        check(false, "the island reports where it's drawn")
        return
    }
    // A Home tile: the tiles fill the content area under the band.
    let tile = CGPoint(x: drawn.minX + 70, y: drawn.maxY - metrics.notchSize.height - 50)
    pressDown(at: tile)
    spin(0.06)
    release()
    spin(0.6)
    check(vm.expandedPlace != .home, "a quick click on a Home tile goes into its face (control)", "\(vm.expandedPlace)")
    check(island.detachTrace.phase == .idle && island.placement == .docked, "with no line and nothing moved")
    vm.selectHome()
    spin(0.6)

    print("off the notch: held, the line runs")
    pressDown(at: tile)
    spin(0.15)
    check(island.detachTrace.phase == .idle, "nothing shows inside the grace")
    spin(0.5)
    let housing = metrics.hasPhysicalNotch ? metrics.notchSize.width : 0
    check(island.detachTrace.phase == .running(duration: 1.1, topGap: housing),
          "then the line is running, for 1.1s, up to the housing", "\(island.detachTrace.phase)")
    let systemReduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    if let trace = find(DetachTraceView.self, in: hosting) {
        let inWindow = trace.convert(trace.bounds, to: nil)
        let onScreen = w.convertToScreen(inWindow)
        check(abs(onScreen.minX - drawn.minX) < 0.5 && abs(onScreen.maxY - drawn.maxY) < 0.5
              && abs(onScreen.width - drawn.width) < 0.5 && abs(onScreen.height - drawn.height) < 0.5,
              "the line's view lies exactly over the drawn panel", "\(onScreen) vs \(drawn)")
        let shown = trace.shown
        if systemReduceMotion {
            check(shown.left == 1 && shown.right == 1 && shown.opacity > 0.05 && shown.opacity < 0.95,
                  "Reduce Motion: the whole outline, part way through fading up", "\(shown)")
        } else {
            check(shown.left > 0.05 && shown.left < 0.95 && abs(shown.left - shown.right) < 0.001 && shown.opacity == 1,
                  "both halves are part way round, level with each other", "\(shown)")
            let animations = trace.runningAnimations
            check(animations.count == 2 && animations.allSatisfy {
                $0.keyPath == "strokeEnd" && $0.duration == 1.1 && ($0.fromValue as? CGFloat) == 0 && ($0.toValue as? CGFloat) == 1
            }, "each as one strokeEnd animation, 0 to 1 over 1.1s, in the render server's hands", "\(animations)")
        }
        check(trace.hitTest(NSPoint(x: 10, y: 10)) == nil, "the line's view takes no clicks")
    } else {
        check(false, "the line's view is in the panel's tree while it runs")
    }
    check(find(DetachTraceView.self, in: w.glassWindow.contentView) == nil, "and not in the glass window's")
    check(island.placement == .docked && w.frame == docked, "the island hasn't moved yet")

    print("off the notch: let go early")
    release()
    check(island.detachTrace.phase == .retracting, "the line runs back", "\(island.detachTrace.phase)")
    spin(0.6)
    check(island.detachTrace.phase == .idle, "and is gone")
    check(find(DetachTraceView.self, in: hosting) == nil, "with its view out of the tree")
    check(vm.expandedPlace == .home, "the tile under the pointer did not fire", "\(vm.expandedPlace)")
    check(island.placement == .docked && w.frame == docked && haptics.isEmpty && placed.isEmpty, "and nothing else happened")
    // The views were told the press ended: the next click is a click.
    pressDown(at: tile)
    spin(0.06)
    release()
    spin(0.6)
    check(vm.expandedPlace != .home, "the next quick click works as ever", "\(vm.expandedPlace)")
    vm.selectHome()
    spin(0.6)

    print("off the notch: a drag is not a hold")
    pressDown(at: tile)
    spin(0.05)
    drag(to: CGPoint(x: tile.x + 30, y: tile.y))
    spin(1.6)
    check(island.detachTrace.phase == .idle && island.placement == .docked && haptics.isEmpty,
          "pressed and dragged: no line, and the island stays, however long it's held")
    release()
    spin(0.3)

    print("off the notch: held all the way, the island comes loose and follows")
    vm.selectHome()
    spin(0.4)
    pressDown(at: tile)
    spin(1.6)
    check(island.placement == .floating(anchor: bounds.dock), "the island is floating, anchored exactly where it hung",
          "\(island.placement)")
    check(w.frame == docked && w.glassWindow.frame == docked, "so nothing has jumped")
    check(haptics == [.lifted], "with one tap", "\(haptics)")
    check(island.detachTrace.phase == .completed || island.detachTrace.phase == .idle, "the line has met and is fading",
          "\(island.detachTrace.phase)")
    check(carry.isBusy, "it's in the hand")
    // Carried a little: still within reach of the notch, but free of it.
    var steps = true
    for step in 1...10 {
        let p = CGPoint(x: tile.x - CGFloat(step) * 3, y: tile.y - CGFloat(step) * 4)
        drag(to: p)
        let want = docked.offsetBy(dx: p.x - tile.x, dy: p.y - tile.y)
        if w.frame != want || w.glassWindow.frame != want { steps = false }
    }
    check(steps, "each drag moves the panel by exactly what the pointer moved, the glass with it", "\(w.frame)")
    check(island.placement == .floating(anchor: bounds.dock) && haptics == [.lifted],
          "the notch doesn't pull it straight back: it has to be carried clear first")
    // Clear of the notch, down and to the left.
    let away = CGPoint(x: tile.x - 260, y: tile.y - 300)
    drag(to: away)
    let carried = docked.offsetBy(dx: -260, dy: -300)
    check(w.frame == carried && w.glassWindow.frame == carried, "carried clear: the windows are there", "\(w.frame)")
    check(placed.isEmpty, "nothing is remembered while it's in the hand")
    release()
    let rested = IslandPlacement.floating(anchor: bounds.resting(NotchMetrics.anchor(of: carried)))
    check(island.placement == rested, "let go: it rests where it was put", "\(island.placement) want \(rested)")
    check(placed == [rested], "which is remembered at once", "\(placed)")
    spin(0.8)
    check(w.frame == metrics.frame(for: rested) && w.glassWindow.frame == w.frame, "and that's where the windows are")
    check(arrivals == 1 && !carry.isBusy, "the controller is told once it has stopped")
    check(vm.expandedPlace == .home, "the tile it was held by did not fire", "\(vm.expandedPlace)")
    checkInStep(w, "put down")
    w.setFrameOrigin(docked.origin)
    spin(0.2)
    check(w.frame == metrics.frame(for: rested), "and the frame it was put down at is held")

    print("off the notch: picked up again with a short hold")
    let grip = CGPoint(x: tile.x - 260, y: tile.y - 300)
    pressDown(at: grip)
    spin(0.06)
    release()
    spin(0.6)
    check(vm.expandedPlace != .home && island.placement == rested, "a quick click on a floating panel is still a click")
    vm.selectHome()
    spin(0.6)
    haptics = []
    pressDown(at: grip)
    spin(0.3)
    check(island.detachTrace.phase == .running(duration: 0.2, topGap: 0), "a quick line, all the way to the top centre",
          "\(island.detachTrace.phase)")
    spin(0.3)
    check(haptics == [.lifted] && carry.isBusy && island.placement == rested, "then it's in the hand, where it was")

    print("off the notch: the notch takes it back")
    // Up toward the notch: the anchor follows the pointer by the grab.
    let anchorNow = NotchMetrics.anchor(of: w.frame)
    let toDock = CGPoint(x: grip.x + (bounds.dock.x - anchorNow.x) + 20, y: grip.y + (bounds.dock.y - anchorNow.y) - 30)
    drag(to: CGPoint(x: toDock.x - 120, y: toDock.y - 120))
    check(island.placement == rested && haptics == [.lifted], "not yet within reach: still floating")
    drag(to: toDock)
    check(island.placement == .docked, "within reach, the island is on the notch", "\(island.placement)")
    check(haptics == [.lifted, .snapped], "with a tap of its own", "\(haptics)")
    spin(0.7)
    check(w.frame == docked && w.glassWindow.frame == docked, "and its windows are pulled to the notch", "\(w.frame)")
    drag(to: CGPoint(x: toDock.x + 10, y: toDock.y - 10))
    check(island.placement == .docked && w.frame == docked, "it stays while carried about inside the zone")
    let clear = CGPoint(x: toDock.x - 200, y: toDock.y - 150)
    drag(to: clear)
    check(island.placement.isFloating, "carried clear again, it comes off", "\(island.placement)")
    let want = docked.offsetBy(dx: clear.x - toDock.x + 20, dy: clear.y - toDock.y - 30)
    check(w.frame == want && w.glassWindow.frame == want, "and is back under the pointer by the same grip", "\(w.frame) want \(want)")
    drag(to: toDock)
    spin(0.1)
    release()
    check(island.placement == .docked && placed.last == .docked, "let go on the notch: docked, and remembered as docked",
          "\(island.placement)")
    spin(0.8)
    check(w.frame == docked && w.glassWindow.frame == docked && !carry.isBusy, "the windows are home")
    checkInStep(w, "docked again")

    print("off the notch: taken off and let go at once")
    vm.selectHome()
    island.setHovering(true)
    spin(0.8)
    placed = []
    pressDown(at: tile)
    spin(1.6)
    check(island.placement.isFloating, "it comes loose")
    drag(to: CGPoint(x: tile.x + 12, y: tile.y - 20))
    release()
    check(island.placement == .docked && placed == [.docked], "never carried clear of the notch: it goes back", "\(island.placement)")
    spin(0.8)
    check(w.frame == docked && w.glassWindow.frame == docked, "to exactly where it hung")

    print("off the notch: put down over the menu bar")
    pressDown(at: tile)
    spin(1.6)
    // Out sideways along the very top of the screen.
    drag(to: CGPoint(x: tile.x - 300, y: tile.y - 100))
    drag(to: CGPoint(x: tile.x - 300, y: tile.y))
    check(w.frame == docked.offsetBy(dx: -300, dy: 0), "carried, it may lie over the menu bar")
    release()
    let below = IslandPlacement.floating(anchor: bounds.resting(CGPoint(x: bounds.dock.x - 300, y: bounds.dock.y)))
    check(island.placement == below, "let go there, it rests clear of it", "\(island.placement)")
    if bounds.visible.maxY < bounds.screen.maxY {
        check(carry.isBusy, "gliding down the last few points")
        spin(0.15)
        let mid = w.frame
        check(mid.maxY < docked.maxY && mid.maxY > metrics.frame(for: below).maxY && w.glassWindow.frame == mid,
              "part way there, the glass with it", "\(mid)")
    }
    spin(0.8)
    check(w.frame == metrics.frame(for: below) && w.glassWindow.frame == w.frame && !carry.isBusy, "and arrives")

    print("off the notch: returned to the notch")
    carry.returnToNotch()
    check(island.placement == .docked && placed.last == .docked, "docked at once, and remembered")
    spin(0.8)
    check(w.frame == docked && w.glassWindow.frame == docked, "the windows glide home")
    checkInStep(w, "returned")
    carry.returnToNotch()
    check(island.placement == .docked && !carry.isBusy, "on the notch already: nothing to do")

    print("off the notch: what a hold is refused for")
    island.setHovering(false)
    spin(0.8)
    pressDown(at: CGPoint(x: bounds.dock.x, y: bounds.dock.y - 10))
    spin(1.6)
    check(island.placement == .docked && island.detachTrace.phase == .idle, "a closed island on its notch isn't taken")
    release()
    island.setHovering(true)
    spin(0.8)
    island.beginDrop()
    pressDown(at: tile)
    spin(1.6)
    check(island.placement == .docked && island.detachTrace.phase == .idle, "nor one showing the drop face")
    release()
    island.endDrop(collapse: false)
    carry.canArm = { false }
    pressDown(at: tile)
    spin(1.6)
    check(island.placement == .docked && island.detachTrace.phase == .idle, "nor while the controller says no (a reply, a file drag)")
    release()
    carry.canArm = { true }
    spin(0.3)

    print("off the notch: Reduce Motion's line")
    do {
        let host = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 520, height: 146),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        host.alphaValue = 0
        host.ignoresMouseEvents = true
        let trace = DetachTraceView(frame: NSRect(x: 0, y: 0, width: 520, height: 146))
        host.contentView = trace
        host.orderFrontRegardless()
        let outline = NotchShape(topCornerRadius: 12, bottomCornerRadius: 22)
            .path(in: CGRect(x: 0, y: 0, width: 520, height: 146)).cgPath
        trace.update(outline: outline, phase: .running(duration: 1.0, topGap: 185), reduceMotion: true)
        spin(0.5)
        let shown = trace.shown
        check(shown.left == 1 && shown.right == 1, "nothing travels: the whole outline is drawn from the start", "\(shown)")
        check(shown.opacity > 0.2 && shown.opacity < 0.8, "and fades up over the same time", "\(shown.opacity)")
        check(trace.runningAnimations.isEmpty, "with no stroke animation at all")
        trace.update(outline: outline, phase: .retracting, reduceMotion: true)
        spin(0.4)
        check(trace.shown.opacity == 0, "let go early, it fades away")
        host.orderOut(nil)
    }

    w.orderOut(nil)
    spin(0.1)
    checkInStep(w, "floating island hidden")

    print("off the notch: remembered across launches")
    do {
        let suite = "isle.windowtests.offsets.\(UUID().uuidString)"
        let store = UserDefaults(suiteName: suite)!
        let first = AppSettings(defaults: store)
        check(first.islandOffsets.isEmpty, "nothing remembered to begin with: every island on its notch")
        first.islandOffsets["DISPLAY-A"] = bounds.offset(of: .floating(anchor: anchor))
        let second = AppSettings(defaults: store)
        check(second.islandOffsets.count == 1
              && bounds.placement(restoring: second.islandOffsets["DISPLAY-A"]) == .floating(anchor: anchor),
              "a display's island is where it was left after a relaunch", "\(second.islandOffsets)")
        check(bounds.placement(restoring: second.islandOffsets["DISPLAY-B"]) == .docked, "another display's is on its notch")
        second.islandOffsets["DISPLAY-A"] = nil
        check(AppSettings(defaults: store).islandOffsets.isEmpty && store.object(forKey: "isle.islandOffsets") == nil,
              "put back on the notch, nothing is kept")
        store.set(["X": "nonsense", "Y": [1.0], "Z": [10.0, -200.0]], forKey: "isle.islandOffsets")
        check(AppSettings(defaults: store).islandOffsets == ["Z": CGPoint(x: 10, y: -200)],
              "anything on disk that isn't a pair of numbers is dropped")
        store.removePersistentDomain(forName: suite)
    }
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

    offTheNotch(screen)

    print("\n\(passes) passed, \(failures) failed")
    exit(failures == 0 ? 0 : 1)
}

@main
enum Tests {
    static func main() {
        MainActor.assumeIsolated { run() }
    }
}
