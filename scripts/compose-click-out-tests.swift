//
//  compose-click-out-tests.swift
//
//  A click on the island outside the Claude face's field that has the keys
//  — a reply, a typed answer, a denial's reason — lets the field go as Esc
//  does: the draft kept, nothing sent, the panel left open. A click in the
//  field keeps it, and so does a press in it dragged out (selecting). A
//  click on a control does the control's job, and the field lets go after.
//  The agenda's quick add isn't touched.
//
//  The shipping NotchRootView in the real NotchWindow and NotchHostingView,
//  wired as NotchWindowController wires them, offscreen and invisible, never
//  key; clicked by synthetic mouse-down/up NSEvents through
//  NSWindow.sendEvent. In every panel background (and the two retired ones,
//  read as Glass), on the notch and off it. Handing the keys back is
//  `giveKeysBack`, which runs on any change of `composing` to nil — the same
//  path Esc takes — and isn't exercised here: that needs a key window.
//
//  Run with scripts/test-compose-click-out.sh. With CLICKOUT_FRAMES=<dir>
//  it also writes each island as a PNG before the clicks.
//
import SwiftUI
import AppKit

@MainActor
final class Island {
    let vm: NotchViewModel
    let presentation: IslandPresentation
    let window: NotchWindow
    let hosting: NotchHostingView<NotchRootView>

    init(_ fixtureName: String, background: String = "black", floating: Bool = false) {
        let defaults = UserDefaults(suiteName: "isle.clickout.\(UUID().uuidString)")!
        defaults.set(background, forKey: "isle.panelBackground")
        let settings = AppSettings(defaults: defaults)
        let fixture = ClaudePanelFixture.all.first { $0.name == fixtureName }!
        fixture.configure(settings)
        vm = NotchViewModel(settings: settings)
        vm.applyPreviewFixture(fixture)
        // An answer or a denial a click sent goes nowhere — never to a
        // hook's files — and is counted (`previewSends`).
        vm.previewRespond = { _, _ in false }
        presentation = IslandPresentation(content: vm)
        let metrics = NotchMetrics(screen: NotchMetrics.preferredScreen()!)
        presentation.metrics = metrics
        if floating { presentation.placement = .floating(anchor: CGPoint(x: 600, y: 500)) }
        let frame = metrics.maximumFrame
        window = NotchWindow(contentRect: frame)
        var ref: NotchHostingView<NotchRootView>?
        hosting = NotchHostingView(rootView: NotchRootView(viewModel: vm, island: presentation) { ref?.activeRect = $0 })
        ref = hosting
        hosting.sizingOptions = []
        window.contentView = hosting
        // As NotchWindowController wires it.
        window.watchClicksOutsideComposeFields(vm)
        window.setFrame(NSRect(x: -20000, y: -20000, width: frame.width, height: frame.height), display: false)
        window.alphaValue = 0
        window.orderFrontRegardless()
        presentation.setHovering(true)
        settle(1.0)
    }

    /// The drawn island, in window coordinates.
    var islandRect: NSRect {
        let r = hosting.activeRect ?? .zero
        return NSRect(x: r.minX, y: hosting.bounds.height - r.maxY, width: r.width, height: r.height)
    }

    /// The field's region, in window coordinates.
    var fieldRect: NSRect? {
        window.composeFields.allObjects.first.map { $0.convert($0.bounds, to: nil) }
    }

    func event(_ type: NSEvent.EventType, at p: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: p, modifierFlags: [],
                           timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil,
                           eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
    }

    /// A press: the down through the window, the rest after it. A text
    /// field's mouse-down tracks the press itself, pulling the drags and
    /// the release off the app's queue — so they're queued first, as the
    /// window server would have them, and whatever no tracking took is
    /// then sent through the window in order.
    func press(_ steps: [(NSEvent.EventType, NSPoint)]) {
        let (downType, downAt) = steps[0]
        for (type, p) in steps.dropFirst() { NSApp.postEvent(event(type, at: p), atStart: false) }
        window.sendEvent(event(downType, at: downAt))
        while let e = NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: Date(),
                                      inMode: .default, dequeue: true) {
            settle(0.05)
            window.sendEvent(e)
        }
        settle(0.5)
    }

    func click(at p: NSPoint) {
        press([(.leftMouseDown, p), (.leftMouseUp, p)])
    }

    /// Down at `from`, dragged to and let go at `to`.
    func drag(from: NSPoint, to: NSPoint) {
        press([(.leftMouseDown, from),
               (.leftMouseDragged, NSPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)),
               (.leftMouseDragged, to), (.leftMouseUp, to)])
    }

    func png(_ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["CLICKOUT_FRAMES"],
              let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
    }

    func close() { window.orderOut(nil) }
}

@MainActor func settle(_ seconds: TimeInterval) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

var failures = 0
var passes = 0
func report(_ ok: Bool, _ name: String, _ detail: String = "") {
    if ok { passes += 1 } else { failures += 1 }
    print("  \(ok ? "ok  " : "FAIL")  \(name)\(detail.isEmpty ? "" : "  [\(detail)]")")
}

/// The three fields, with how to read each one's draft.
struct Field {
    let fixture: String
    let kind: ComposeKind
    let draft: @MainActor (NotchViewModel) -> String
}

@main
enum ClickOutProbe {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        // A press that something tracks and never lets go of would hang the
        // run; it fails instead.
        DispatchQueue.global().asyncAfter(deadline: .now() + 600) {
            print("\nFAIL  timed out, \(failures) failed and \(passes) passed before")
            exit(2)
        }

        let fields = [
            Field(fixture: "jr_reply_composing", kind: .reply) { $0.replyDraft },
            Field(fixture: "jr_question_typing", kind: .answer) { $0.answerDraft },
            Field(fixture: "jr_approval_denying", kind: .denial) { $0.denialDraft },
        ]

        // Every background, the retired two read as Glass; on the notch and off it.
        for background in ["black", "glass", "prism", "smoked", "fade"] {
            for floating in [false, true] {
                for field in fields {
                    let label = "\(field.kind) · \(background)\(floating ? " · floating" : "")"
                    let island = Island(field.fixture, background: background, floating: floating)
                    island.png("\(field.fixture)-\(background)\(floating ? "-floating" : "")")
                    let draft = field.draft(island.vm)
                    guard island.vm.composing == field.kind, let fieldRect = island.fieldRect else {
                        report(false, "\(label): the field is up", "composing \(String(describing: island.vm.composing))")
                        island.close()
                        continue
                    }
                    let isle = island.islandRect
                    // On the field's text, at its leading end: it's the field's.
                    island.click(at: NSPoint(x: fieldRect.minX + 30, y: fieldRect.midY))
                    report(island.vm.composing == field.kind, "\(label): a click in the field keeps it")
                    // Pressed in the field, let go well outside it — a selection.
                    island.drag(from: NSPoint(x: fieldRect.minX + 30, y: fieldRect.midY),
                                to: NSPoint(x: fieldRect.minX + 30, y: fieldRect.maxY + 40))
                    report(island.vm.composing == field.kind, "\(label): a press in the field dragged out keeps it")

                    // The panel's own space below the field, where nothing is drawn.
                    let below = NSPoint(x: fieldRect.midX, y: (isle.minY + fieldRect.minY) / 2)
                    report(isle.contains(below) && !fieldRect.contains(below), "\(label): the spot below the field is on the island")
                    island.click(at: below)
                    report(island.vm.composing == nil, "\(label): a click below the field lets it go",
                           "composing \(String(describing: island.vm.composing))")
                    report(field.draft(island.vm) == draft && !draft.isEmpty, "\(label): the draft is kept",
                           "\(field.draft(island.vm))")
                    report(island.presentation.isHovering && island.presentation.state.isExpanded,
                           "\(label): the panel stays open")

                    // Opened again, then a click up in the band (the camera, or
                    // off the notch, the grabber).
                    island.vm.beginCompose(field.kind)
                    settle(0.6)
                    report(island.vm.composing == field.kind && field.draft(island.vm) == draft,
                           "\(label): opened again, with the draft")
                    island.click(at: NSPoint(x: isle.midX, y: isle.maxY - 8))
                    report(island.vm.composing == nil, "\(label): a click in the band lets it go")

                    // Opened again, then a click in the face's own space just
                    // above the field — under the card's click, which
                    // retracts a panel an alert opened, but never while a
                    // field is open.
                    island.vm.beginCompose(field.kind)
                    settle(0.6)
                    let picks = island.vm.questionPicks
                    let above = NSPoint(x: fieldRect.midX, y: fieldRect.maxY + 3)
                    island.click(at: above)
                    report(island.vm.composing == nil, "\(label): a click just above the field lets it go")
                    report(island.vm.questionPicks == picks, "\(label): no option was picked")
                    report(island.presentation.isHovering, "\(label): the panel stays open")
                    // The card's own click (which retracts a panel an alert
                    // opened) reads this, and does nothing for a press that
                    // went down while the field was open. SwiftUI's tap
                    // gestures don't fire for synthetic clicks here, so the
                    // mark is what's checked.
                    report(island.vm.pressBeganComposing, "\(label): the click-out is marked as pressed while composing")
                    island.click(at: above)
                    report(!island.vm.pressBeganComposing, "\(label): the next click, with no field open, isn't")
                    report(island.vm.previewSends.isEmpty, "\(label): nothing was sent")
                    island.close()
                }
            }
        }

        // An empty field: Send is disabled, and a click on it is still the
        // field's — nothing is sent, the field stays.
        for (fixture, kind) in [("jr_reply_composing_empty", ComposeKind.reply), ("jr_approval_denying_empty", .denial)] {
            let island = Island(fixture)
            if let fieldRect = island.fieldRect {
                island.click(at: NSPoint(x: fieldRect.maxX - 20, y: fieldRect.midY))
                report(island.vm.composing == kind, "\(kind), empty: a click on the disabled Send keeps the field")
                if kind == .reply { report(island.vm.replyDelivery == .none, "\(kind), empty: nothing sent") }
            } else {
                report(false, "\(kind), empty: the field is up")
            }
            island.close()
        }

        // A control: an option of a multi-select question, clicked while an
        // answer is typed. It's toggled — its job — and then the field lets
        // go, with the draft.
        do {
            let island = Island("jr_question_multi_typing")
            island.png("jr_question_multi_typing")
            let picksBefore = island.vm.questionPicks
            let draft = island.vm.answerDraft
            if let fieldRect = island.fieldRect {
                // The option rows run from the top of the face down to the
                // field; the first row sits well above it.
                var toggled = false
                var y = fieldRect.maxY + 14
                while y < island.islandRect.maxY - 40, !toggled {
                    island.vm.beginCompose(.answer)
                    settle(0.4)
                    island.click(at: NSPoint(x: fieldRect.minX + 40, y: y))
                    toggled = island.vm.questionPicks != picksBefore
                    y += 6
                }
                report(toggled, "control: the option was toggled", "\(island.vm.questionPicks)")
                report(island.vm.composing == nil, "control: then the field let go")
                report(island.vm.answerDraft == draft, "control: the draft is kept")
                report(island.vm.questionIndex == 1, "control: still on the same question")
            } else {
                report(false, "control: the field is up")
            }
            island.close()
        }

        // A control that opens a field: the reply bar, clicked with no
        // field open, opens it — and the click that did so doesn't close it.
        do {
            let island = Island("jr_reply_draft_kept")
            let isle = island.islandRect
            var opened = false
            var y = isle.minY + 8
            while y < isle.maxY - 30, !opened {
                // At the bar's trailing end, well clear of the app pill
                // at its leading side.
                island.click(at: NSPoint(x: isle.maxX - 60, y: y))
                opened = island.vm.composing == .reply
                y += 6
            }
            report(opened, "the reply bar's own click opens the field and leaves it open")
            island.close()
        }

        // The agenda's quick add keeps to Esc: not a Claude face field.
        report(!NotchViewModel.clickOutLetsGo(.quickAdd), "quick add: not let go by a click outside")
        report(NotchViewModel.clickOutLetsGo(.reply) && NotchViewModel.clickOutLetsGo(.answer)
               && NotchViewModel.clickOutLetsGo(.denial), "reply, answer, denial: let go by a click outside")

        print(failures == 0 ? "\nall \(passes) passed" : "\n\(failures) failed, \(passes) passed")
        exit(failures == 0 ? 0 : 1)
    }
}
