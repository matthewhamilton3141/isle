// The child of scripts/test-constraint-pass-log.sh: one case per run, named
// by the first argument, with ConstraintPassLog writing to
// $ISLE_CONSTRAINTS_LOG. The script reads that file afterwards.
//
// The control is a window that asks for another constraints pass after
// each of its passes, in the same display cycle: what a loop does to AppKit,
// and what ends, after min(100, views + 1) + 5 passes, in the exception of the
// 9, 11 and 12 Nov crashes. Every window is transparent, click-through, at
// desktop level and never key; the process never activates.

import AppKit
import SwiftUI

@MainActor func spin(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

/// Asks for another pass after each pass, `reasks` times (-1: forever).
final class ControlWindow: NSWindow {
    var reasks = 0
    override func updateConstraintsIfNeeded() {
        super.updateConstraintsIfNeeded()
        guard reasks != 0 else { return }
        if reasks > 0 { reasks -= 1 }
        contentView?.needsUpdateConstraints = true
    }
}

let desktop = Int(CGWindowLevelForKey(.desktopIconWindow))

@MainActor
func hidden<W: NSWindow>(_ type: W.Type, _ rect: NSRect) -> W {
    let w = W(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
    w.isOpaque = false
    w.backgroundColor = .clear
    w.alphaValue = 0
    w.ignoresMouseEvents = true
    w.level = NSWindow.Level(rawValue: desktop + 1)
    let hosting = NSHostingView(rootView: Color.red.frame(width: 40, height: 20))
    hosting.sizingOptions = []
    w.contentView = hosting
    return w
}

/// Resizes the window over a few display cycles until the log has checked
/// AppKit's counter (or given up on it).
@MainActor
func settle(_ w: NSWindow) {
    for i in 0..<40 where ConstraintPassLog.state == .validating {
        w.setContentSize(NSSize(width: 200 + (i % 2) * 10, height: 100))
        spin(0.03)
    }
    print("STATE \(ConstraintPassLog.state)")
}

@MainActor
func run() {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let mode = CommandLine.arguments.dropFirst().first ?? "quiet"
    if mode == "off" {
        // A macOS that moved the views count: the check must catch it.
        ConstraintPassLog.layout.views = 0x2c8
    }
    ConstraintPassLog.install()
    let w = hidden(ControlWindow.self, NSRect(x: 60, y: 60, width: 200, height: 100))
    w.orderFrontRegardless()
    spin(0.2)
    settle(w)
    ConstraintPassLog.watch(w, as: "control window", describe: { "the control, re-asking \(w.reasks)" })

    switch mode {
    case "quiet":
        // A resize: two passes in its cycle at most, so nothing is logged.
        w.setContentSize(NSSize(width: 260, height: 120))
        spin(0.3)
        w.setFrameOrigin(NSPoint(x: 80, y: 70))
        spin(0.3)
    case "loop", "off":
        w.reasks = 4
        w.contentView?.needsUpdateConstraints = true
        spin(0.4)
        print("survived: \(w.reasks) re-asks left")
    case "throw":
        NSSetUncaughtExceptionHandler { exception in
            print("THROWN: \(exception.name.rawValue): \(exception.reason ?? "")")
            exit(3)
        }
        w.reasks = -1
        w.contentView?.needsUpdateConstraints = true
        spin(0.6)
        print("NOT THROWN")
    case "notch":
        // The real panel and glass window, registered as the controller
        // registers them: open and close, re-placed at another size.
        guard let screen = NotchMetrics.preferredScreen() else { print("no screen"); exit(0) }
        let settings = AppSettings(defaults: UserDefaults(suiteName: "isle.constraintlog.\(UUID().uuidString)")!)
        settings.mode = .both
        let vm = NotchViewModel(settings: settings)
        let island = IslandPresentation(content: vm)
        let metrics = NotchMetrics(screen: screen)
        island.metrics = metrics
        let (panel, hosting) = NotchWindowController.makePanel(viewModel: vm, presentation: island, metrics: metrics) { _ in }
        panel.alphaValue = 0
        panel.ignoresMouseEvents = true
        panel.level = NSWindow.Level(rawValue: desktop + 2)
        let describe = { "\(island.state) placement \(island.placement) face \(vm.expandedPlace) background \(vm.panelBackground.rawValue)" }
        ConstraintPassLog.watch(panel, as: "notch panel", describe: describe)
        ConstraintPassLog.watch(panel.glassWindow, as: "island glass", describe: describe)
        panel.contentView = hosting
        let target = metrics.maximumFrame
        panel.place(target)
        panel.orderFrontRegardless()
        spin(0.6)
        island.setHovering(true); spin(0.9)
        island.setHovering(false); spin(0.9)
        panel.place(NSRect(x: target.minX, y: target.minY + 20, width: target.width - 60, height: target.height - 20)); spin(0.3)
        panel.place(target); spin(0.3)
        panel.orderOut(nil)
        print("notch done")
    default:
        print("unknown case \(mode)")
        exit(2)
    }
    w.orderOut(nil)
    exit(0)
}

@main enum Main {
    static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        MainActor.assumeIsolated { run() }
    }
}
