//
//  compose-freeze-tests.swift
//
//  While a reply is being written the Claude face holds still: what
//  arrives — Done, a new step, an approval, another session — is held and
//  applied once the field lets go, and the draft is never touched. The
//  shipping NotchRootView in the real NotchWindow, made key as for a reply,
//  offscreen and invisible; statuses arrive through the view model's own
//  path. "Unchanged" is pixels: the panel drawn before and after.
//
//  Run with scripts/test-compose-freeze.sh. With FREEZE_FRAMES=<dir> it
//  also writes each moment as a PNG.
//

import SwiftUI
import AppKit

var failures = 0
func report(_ ok: Bool, _ name: String, _ detail: String = "") {
    if !ok { failures += 1 }
    print("  \(ok ? "ok  " : "FAIL")  \(name)\(detail.isEmpty ? "" : "  [\(detail)]")")
}

@MainActor
final class Island {
    let vm: NotchViewModel
    let presentation: IslandPresentation
    let window: NotchWindow
    let hosting: NotchHostingView<NotchRootView>

    init(_ fixtureName: String, hover: Bool = true) {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "isle.freeze.\(UUID().uuidString)")!)
        let fixture = ClaudePanelFixture.all.first { $0.name == fixtureName }!
        fixture.configure(settings)
        vm = NotchViewModel(settings: settings)
        vm.applyPreviewFixture(fixture)
        presentation = IslandPresentation(content: vm)
        let metrics = NotchMetrics(screen: NotchMetrics.preferredScreen()!)
        presentation.metrics = metrics
        window = NotchWindow(contentRect: metrics.maximumFrame)
        var ref: NotchHostingView<NotchRootView>?
        hosting = NotchHostingView(rootView: NotchRootView(viewModel: vm, island: presentation) { ref?.activeRect = $0 })
        ref = hosting
        hosting.sizingOptions = []
        window.contentView = hosting
        window.setFrame(NSRect(x: -20000, y: -20000, width: metrics.maximumFrame.width,
                               height: metrics.maximumFrame.height), display: false)
        window.alphaValue = 0
        window.allowsKey = true
        window.orderFrontRegardless()
        window.makeKey()
        if hover { presentation.setHovering(true) }
        settle(1.2)
    }

    func settle(_ seconds: Double = 0.7) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    /// The panel as drawn, RGBA at 2x, top-left origin.
    func pixels(_ name: String) -> [UInt8] {
        hosting.layoutSubtreeIfNeeded()
        hosting.display()
        let w = Int(hosting.bounds.width) * 2, h = Int(hosting.bounds.height) * 2
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.scaleBy(x: 2, y: 2)
        ctx.translateBy(x: 0, y: hosting.bounds.height)
        ctx.scaleBy(x: 1, y: -1)
        hosting.layer!.render(in: ctx)
        if let dir = ProcessInfo.processInfo.environment["FREEZE_FRAMES"] {
            let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
            try? rep.representation(using: .png, properties: [:])!
                .write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
        }
        let data = ctx.data!.bindMemory(to: UInt8.self, capacity: w * h * 4)
        return Array(UnsafeBufferPointer(start: data, count: w * h * 4))
    }

    /// Pixels that differ between two drawings, inside `rect` (points,
    /// top-left), or everywhere.
    func differing(_ a: [UInt8], _ b: [UInt8], in rect: CGRect? = nil) -> Int {
        let w = Int(hosting.bounds.width) * 2
        let area = rect.map { CGRect(x: $0.minX * 2, y: $0.minY * 2, width: $0.width * 2, height: $0.height * 2) }
        var count = 0
        for i in stride(from: 0, to: min(a.count, b.count), by: 4) {
            let p = i / 4, x = p % w, y = p / w
            if let area, !area.contains(CGPoint(x: x, y: y)) { continue }
            if a[i] != b[i] || a[i + 1] != b[i + 1] || a[i + 2] != b[i + 2] || a[i + 3] != b[i + 3] { count += 1 }
        }
        return count
    }
}

func status(_ state: ClaudeCodeState, session: String, action: String? = nil, target: String? = nil,
            said: String? = nil, active: Bool = false) -> ClaudeStatus {
    var s = ClaudeStatus(state: state, project: "isle", sessionId: session)
    s.action = action
    s.target = target
    s.toolActive = active
    s.lastMessage = said
    s.updatedAt = Date()
    return s
}

@main
enum FreezeTests {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)

        print("Writing a reply on the working face")
        do {
            let island = Island("rp_working_empty")
            let vm = island.vm
            let id = vm.claudeSessionId!
            vm.beginCompose(.reply)
            vm.replyDraft = "Half a thought, and"
            island.settle()
            let before = island.pixels("1-composing")
            let word = vm.workingWord

            // A step finishes, and another starts.
            vm.previewReceive(status(.working, session: id, action: "Grep", target: "activeRect"))
            vm.previewReceive(status(.working, session: id, action: "Bash", target: "swift", active: true))
            island.settle()
            report(island.differing(before, island.pixels("2-steps-arrive")) == 0, "steps arriving move nothing")

            // The turn ends.
            vm.previewReceive(status(.done, session: id, said: "All finished: the tests pass."))
            island.settle()
            report(island.differing(before, island.pixels("3-done-arrives")) == 0, "Done arriving doesn't swap the face")
            report(vm.claudeState == .working && vm.workingWord == word, "the state and its word hold")

            // Another session takes the island.
            vm.previewReceive(status(.done, session: "another-session", said: "Elsewhere."))
            island.settle()
            report(vm.claudeSessionId == id, "another session doesn't take the island", vm.claudeSessionId ?? "nil")
            report(island.differing(before, island.pixels("4-session-switch")) == 0, "nor move the face")

            // Claude asks for approval.
            vm.previewReceive(status(.needsApproval, session: id, action: "Bash", target: "npm"))
            island.settle()
            let asked = island.pixels("5-approval-arrives")
            report(vm.claudeNeedsYouWhileComposing, "an approval arriving is said")
            // Everything below the notice's row is as it was.
            let body = CGRect(x: 0, y: 60, width: island.hosting.bounds.width, height: island.hosting.bounds.height - 60)
            report(island.differing(before, asked, in: body) == 0, "and moves nothing", "\(island.differing(before, asked, in: body)) px")
            report(vm.composing == .reply && vm.replyDraft == "Half a thought, and", "the field and the draft stay")

            // Esc: everything held lands, and the draft is kept.
            vm.endCompose()
            island.settle()
            let after = island.pixels("6-after-esc")
            // The control: the same drawing does change once it's let go.
            report(island.differing(before, after) > 0, "(control) the face does redraw once the field lets go")
            report(vm.claudeState == .needsApproval, "after Esc the face catches up", "\(vm.claudeState)")
            report(!vm.claudeNeedsYouWhileComposing, "and the notice goes")
            report(vm.replyDraft == "Half a thought, and", "the draft is still there")
            island.window.orderOut(nil)
        }

        print("An island an alert opened")
        do {
            let island = Island("rp_failed", hover: false)
            let vm = island.vm
            let id = vm.claudeSessionId!
            report(island.presentation.state.isExpanded, "the alert opened it")
            vm.beginCompose(.reply)
            vm.replyDraft = "Retry with"
            island.settle()
            report(vm.composing == .reply, "the reply's field is open")
            // The failure eases off: unheld, the alert's panel would close.
            vm.previewReceive(status(.idle, session: id))
            island.settle()
            report(island.presentation.state.isExpanded, "it stays open while the reply is written")
            report(vm.replyDraft == "Retry with", "the draft stays")
            vm.endCompose()
            island.settle()
            report(vm.replyDraft == "Retry with", "and survives the field letting go")
            island.window.orderOut(nil)
        }

        print(failures == 0 ? "\nthe face held still" : "\n\(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
