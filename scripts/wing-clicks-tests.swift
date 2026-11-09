//
//  wing-clicks-tests.swift
//
//  The controls the Claude face draws in the housing band beside the camera
//  — the sessions chip, the list's way back — take clicks. They're drawn
//  above the face's box, and a content shape or clip on the way bounds
//  hit-testing to that box, which left them drawn but dead (fixed with this
//  test). The shipping NotchRootView in the real NotchWindow and
//  NotchHostingView, wired as NotchWindowController wires them, offscreen
//  and invisible; clicked by synthetic mouse-down/up NSEvents through
//  NSWindow.sendEvent, the window's own hit-testing path, at the controls'
//  places from ClaudePanelLayout. The crumb, always up there, is the control.
//
//  Run with scripts/test-wing-clicks.sh.
//
import SwiftUI
import AppKit

@MainActor
func makeIsland(_ fixtureName: String, mode: IsleMode) -> (NotchViewModel, IslandPresentation, NotchWindow, NotchHostingView<NotchRootView>) {
    let defaults = UserDefaults(suiteName: "isle.clickprobe.\(UUID().uuidString)")!
    defaults.set("black", forKey: "isle.panelBackground")
    let settings = AppSettings(defaults: defaults)
    let fixture = ClaudePanelFixture.all.first { $0.name == fixtureName }!
    fixture.configure(settings)
    settings.mode = mode
    let vm = NotchViewModel(settings: settings)
    vm.applyPreviewFixture(fixture)
    let island = IslandPresentation(content: vm)
    let metrics = NotchMetrics(screen: NotchMetrics.preferredScreen()!)
    island.metrics = metrics
    let frame = metrics.maximumFrame
    let window = NotchWindow(contentRect: frame)
    var hostingRef: NotchHostingView<NotchRootView>?
    let hosting = NotchHostingView(rootView: NotchRootView(viewModel: vm, island: island) { rect in
        hostingRef?.activeRect = rect
    })
    hostingRef = hosting
    hosting.sizingOptions = []
    window.contentView = hosting
    window.setFrame(NSRect(x: -20000, y: -20000, width: frame.width, height: frame.height), display: false)
    window.alphaValue = 0
    window.orderFrontRegardless()
    island.setHovering(true)
    RunLoop.main.run(until: Date().addingTimeInterval(1.0))
    return (vm, island, window, hosting)
}

/// A click at `p`, top-left points in the hosting view.
@MainActor
func click(_ window: NotchWindow, _ hosting: NSView, at p: CGPoint) {
    let inWindow = NSPoint(x: p.x, y: hosting.bounds.height - p.y)
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        let e = NSEvent.mouseEvent(with: type, location: inWindow, modifierFlags: [],
                                   timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: window.windowNumber, context: nil,
                                   eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
        window.sendEvent(e)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    RunLoop.main.run(until: Date().addingTimeInterval(0.4))
}

var failures = 0
func report(_ ok: Bool, _ name: String) {
    if !ok { failures += 1 }
    print("  \(ok ? "ok  " : "FAIL")  \(name)")
}

@main
enum ClickProbe {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let metrics = NotchMetrics(screen: NotchMetrics.preferredScreen()!)
        let W = metrics.maximumFrame.width
        let panelX = (W - NotchMetrics.expandedSize.width) / 2
        let faceX = panelX + (NotchMetrics.expandedSize.width - ClaudePanelLayout.faceWidth) / 2
        let faceRight = faceX + ClaudePanelLayout.faceWidth
        let bandMid = metrics.notchSize.height / 2
        print("window \(W) face \(faceX)…\(faceRight) band \(metrics.notchSize.height)")

        // The sessions chip, ending where the right wing ends: just short of
        // the gear (Claude mode) or the crumb (both).
        for (mode, label) in [(IsleMode.claude, "claude mode"), (.both, "both mode")] {
            let (vm, _, window, hosting) = makeIsland("sl_entry_busy", mode: mode)
            let wing = ClaudePanelLayout.wings(notch: metrics.notchSize.width, band: metrics.notchSize.height,
                                               physical: metrics.hasPhysicalNotch,
                                               crumb: ClaudePanelLayout.crumbWidth(showsHome: vm.showsHome))
            let chipRight = faceRight - wing.trailing
            report(!vm.sessionListShown, "\(label): list closed to start")
            click(window, hosting, at: CGPoint(x: chipRight - 12, y: bandMid))
            report(vm.sessionListShown, "\(label): a click on the sessions chip opens the list")
            // The list's back button, at the left wing's start — from the
            // list, opened by its action if the click above didn't.
            if !vm.sessionListShown { vm.showSessionList(); RunLoop.main.run(until: Date().addingTimeInterval(0.4)) }
            click(window, hosting, at: CGPoint(x: faceX + 20, y: bandMid))
            report(!vm.sessionListShown, "\(label): a click on the list's back button closes it")
            if mode == .both {
                // Control: the crumb, which has always been up here.
                // The home mark, at the crumb's leading end.
                click(window, hosting, at: CGPoint(x: faceRight - ClaudePanelLayout.crumbWidth(showsHome: true) + 10, y: bandMid))
                report(vm.expandedPlace == .home, "\(label): a click on the crumb goes home (control)")
            }
            window.orderOut(nil)
        }
        print(failures == 0 ? "\nall clicks landed" : "\n\(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
