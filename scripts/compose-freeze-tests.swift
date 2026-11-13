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
//  The same for a typed answer to a question and a denial's reason, which
//  were not held at first: another session's status, or the session's own
//  reading as something else for a moment, closed the field mid-word —
//  which hands the keyboard back and brings the terminal forward — and
//  threw the text away. And what holding makes possible: the question on
//  the face may be gone by the time Return is pressed, so nothing is sent
//  unless that very request is still pending, never to another, and the
//  face says so and keeps the text.
//
//  Run with scripts/test-compose-freeze.sh. With FREEZE_FRAMES=<dir> it
//  also writes each moment as a PNG.
//

import SwiftUI
import AppKit
import Combine

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
        window.attachContent(hosting)
        window.setFrame(NSRect(x: -20000, y: -20000, width: metrics.maximumFrame.width,
                               height: metrics.maximumFrame.height), display: false)
        window.alphaValue = 0
        window.allowsKey = true
        // Without the style that makes `makeKey()` take the window server's key
        // focus: this runs on a Mac someone may be typing on, and the field only
        // needs AppKit to treat the window as key.
        window.styleMask.remove(.nonactivatingPanel)
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
            said: String? = nil, active: Bool = false, request: String? = nil) -> ClaudeStatus {
    var s = ClaudeStatus(state: state, project: "isle", sessionId: session)
    s.requestId = request
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

        print("Typing an answer to a question")
        do {
            let island = Island("jr_question_type_pill")
            let vm = island.vm
            let id = vm.claudeSessionId!
            let request = vm.pendingRequest!
            vm.previewRespond = { _, _ in true }
            vm.beginCompose(.answer)
            vm.answerDraft = "Mango, and"
            island.settle()
            report(vm.composing == .answer, "the answer's field is open")
            let before = island.pixels("a1-answering")

            // The question written again, as a hook's status re-write does.
            vm.previewReceive(status(.needsQuestion, session: id, request: request.id))
            island.settle()
            report(!vm.claudeNeedsYouWhileComposing, "the question being answered isn't news")
            // The session's state read as something else for a moment — a
            // subagent's tool reporting — which no longer matches the request.
            vm.previewReceive(status(.working, session: id, action: "Bash", target: "swift", active: true))
            island.settle()
            report(vm.composing == .answer, "the session reporting a step doesn't close the field", "\(String(describing: vm.composing))")
            report(vm.pendingRequest?.id == request.id, "nor take the question off the face")
            report(vm.answerDraft == "Mango, and", "nor throw the answer away", vm.answerDraft.debugDescription)
            report(island.differing(before, island.pixels("a2-step-arrives")) == 0, "and moves nothing")

            // Another session needs something.
            vm.previewReceive(status(.needsApproval, session: "another-session", action: "Bash", target: "rm"))
            island.settle()
            report(vm.composing == .answer, "another session needing approval doesn't close the field", "\(String(describing: vm.composing))")
            report(vm.claudeSessionId == id && vm.pendingRequest?.id == request.id, "nor take the island", vm.claudeSessionId ?? "nil")
            report(vm.answerDraft == "Mango, and", "the answer so far stays")
            report(vm.claudeNeedsYouWhileComposing, "that Claude needs you elsewhere is said")
            report(vm.requestGoneWhileComposing == nil, "and nothing says the question is gone: it isn't")

            // Return: to the question it was typed for.
            vm.answerDraft = "Mango, and make it a smoothie"
            vm.sendCompose()
            island.settle()
            report(vm.previewSends.count == 1 && vm.previewSends.first?.request == request.id,
                   "Return sends the answer to the question it was typed for", "\(vm.previewSends.map(\.request))")
            if case .answers(let answers)? = vm.previewSends.first?.reply {
                report(answers.values.contains("Mango, and make it a smoothie"), "as typed", "\(answers)")
            } else {
                report(false, "as typed", "no answers sent")
            }
            report(vm.composing == nil && vm.answerDraft.isEmpty, "and the field closes")
            island.window.orderOut(nil)
        }

        print("The question answered in the terminal while an answer is typed")
        do {
            let island = Island("jr_question_type_pill")
            let vm = island.vm
            let id = vm.claudeSessionId!
            vm.previewRespond = { _, _ in true }
            vm.beginCompose(.answer)
            vm.answerDraft = "Mango"
            island.settle()
            // Its file goes, and the session works on.
            vm.previewReceive(requests: [])
            vm.previewReceive(status(.working, session: id, action: "Read", target: "notes.md"))
            island.settle()
            report(vm.composing == .answer && vm.answerDraft == "Mango", "the field and the text stay")
            report(vm.requestGoneWhileComposing != nil, "the face says the question is gone", "\(String(describing: vm.requestGoneWhileComposing))")
            vm.sendCompose()
            island.settle()
            report(vm.previewSends.isEmpty, "Return sends nothing", "\(vm.previewSends.map(\.request))")
            report(vm.composing == .answer && vm.answerDraft == "Mango", "and keeps the field and the text")
            vm.endCompose()
            island.settle()
            report(vm.pendingRequest == nil && vm.claudeState == .working, "after Esc the face catches up", "\(vm.claudeState)")
            report(vm.requestGoneWhileComposing == nil, "and the notice goes")
            report(vm.answerDraft == "Mango", "what was typed is not thrown away", vm.answerDraft.debugDescription)
            island.window.orderOut(nil)
        }

        print("Another question in its place while an answer is typed")
        do {
            let island = Island("jr_question_type_pill")
            let vm = island.vm
            let id = vm.claudeSessionId!
            let request = vm.pendingRequest!
            vm.previewRespond = { _, _ in true }
            vm.beginCompose(.answer)
            vm.answerDraft = "Mango"
            island.settle()
            // The same questions under a new request: the old one's answer
            // would fit it word for word, and must not reach it.
            let other = ClaudeRequest(id: "preview-session-1762300099-5151", kind: .question, sessionId: id,
                                      toolName: "AskUserQuestion", subject: nil, questions: request.questions)
            vm.previewReceive(requests: [other])
            vm.previewReceive(status(.needsQuestion, session: id, request: other.id))
            island.settle()
            report(vm.composing == .answer && vm.pendingRequest?.id == request.id, "the face still shows the question being answered")
            report(vm.requestGoneWhileComposing != nil, "and says it is gone")
            vm.sendCompose()
            island.settle()
            report(vm.previewSends.isEmpty, "Return sends nothing: not to the question that's gone, not to the new one",
                   "\(vm.previewSends.map(\.request))")
            report(vm.answerDraft == "Mango" && vm.composing == .answer, "the text stays in its field")
            vm.endCompose()
            island.settle()
            report(vm.pendingRequest?.id == other.id, "after Esc the new question is on the face", vm.pendingRequest?.id ?? "nil")
            report(vm.answerDraft.isEmpty, "with none of the old answer in its field", vm.answerDraft.debugDescription)
            vm.beginCompose(.answer)
            island.settle()
            report(vm.composing == .answer && vm.answerDraft.isEmpty, "nor when its field is opened")
            vm.answerDraft = "Papaya"
            vm.sendCompose()
            island.settle()
            report(vm.previewSends.map(\.request) == [other.id], "and its own answer goes to it alone", "\(vm.previewSends.map(\.request))")
            island.window.orderOut(nil)
        }

        print("The request going between the look and the write")
        do {
            let island = Island("jr_question_type_pill")
            let vm = island.vm
            // Still listed, but the hook has let go: the write is refused.
            vm.previewRespond = { _, _ in false }
            vm.beginCompose(.answer)
            vm.answerDraft = "Mango"
            island.settle()
            vm.sendCompose()
            island.settle()
            report(vm.composing == .answer && vm.answerDraft == "Mango", "an answer the hook didn't take leaves the field and the text")
            report(vm.requestGoneWhileComposing != nil, "and the face says the question is gone")
            report(!vm.isAnsweringRequest, "and nothing is claimed sent")
            island.window.orderOut(nil)
        }

        print("The session ending while an answer is typed")
        do {
            let island = Island("jr_question_type_pill")
            let vm = island.vm
            let id = vm.claudeSessionId!
            vm.beginCompose(.answer)
            vm.answerDraft = "Mango"
            island.settle()
            var states: [ClaudeCodeState] = []
            let watching = vm.$claudeState.dropFirst().sink { states.append($0) }
            // It's killed: its request goes, and the island would have moved
            // to another session, through working to done.
            vm.previewReceive(requests: [])
            vm.previewReceive(status(.working, session: "another-session", action: "Bash", target: "make"))
            vm.previewReceive(status(.needsApproval, session: "another-session", action: "Bash", target: "rm"))
            vm.previewReceive(status(.done, session: "another-session", said: "Elsewhere."))
            island.settle()
            report(vm.claudeSessionId == id && vm.composing == .answer && states.isEmpty, "held while the field is open", "\(states)")
            vm.endCompose()
            island.settle()
            report(vm.claudeSessionId == "another-session" && vm.claudeState == .done, "after Esc the face shows what is so now",
                   "\(vm.claudeSessionId ?? "nil") \(vm.claudeState)")
            report(states == [.done], "the latest state once, not everything that was held replayed", "\(states)")
            watching.cancel()
            island.window.orderOut(nil)
        }

        print("Typing a denial's reason")
        do {
            let island = Island("jr_approval_tell_pill")
            let vm = island.vm
            let id = vm.claudeSessionId!
            let request = vm.pendingRequest!
            vm.previewRespond = { _, _ in true }
            vm.beginCompose(.denial)
            vm.denialDraft = "Use pnpm"
            island.settle()
            report(vm.composing == .denial, "the denial's field is open")
            vm.previewReceive(status(.done, session: "another-session", said: "Elsewhere."))
            vm.previewReceive(status(.working, session: id, action: "Read", target: "package.json"))
            island.settle()
            report(vm.composing == .denial && vm.pendingRequest?.id == request.id && vm.denialDraft == "Use pnpm",
                   "statuses arriving leave the field, the request and the reason")
            vm.sendCompose()
            island.settle()
            report(vm.previewSends.map(\.request) == [request.id], "Return denies the call it was typed for", "\(vm.previewSends.map(\.request))")
            report(vm.composing == nil, "and the field closes")
            island.window.orderOut(nil)
        }
        do {
            let island = Island("jr_approval_tell_pill")
            let vm = island.vm
            vm.previewRespond = { _, _ in true }
            vm.beginCompose(.denial)
            vm.denialDraft = "Use pnpm"
            island.settle()
            vm.previewReceive(requests: [])
            island.settle()
            vm.sendCompose()
            island.settle()
            report(vm.previewSends.isEmpty && vm.composing == .denial && vm.denialDraft == "Use pnpm",
                   "a call that's gone is not denied; the field and the reason stay")
            report(vm.requestGoneWhileComposing != nil, "and the face says so")
            island.window.orderOut(nil)
        }

        print(failures == 0 ? "\nthe face held still" : "\n\(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
