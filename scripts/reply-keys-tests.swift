//
//  reply-keys-tests.swift
//
//  The reply as typed: what goes into the terminal (a multi-line reply as
//  one bracketed paste, newlines kept, nothing that could end the paste or
//  submit half of it), and the keys in the field — Shift-Return a new line,
//  Return sends. The keys through the shipping NotchRootView in the real
//  NotchWindow, made key as NotchWindowController makes it for a field,
//  offscreen and invisible, with key events sent through NSWindow.sendEvent.
//
//  Run with scripts/test-reply-keys.sh.
//
import SwiftUI
import AppKit

@MainActor
func island(_ fixtureName: String) -> (NotchViewModel, NotchWindow) {
    let defaults = UserDefaults(suiteName: "isle.keyprobe.\(UUID().uuidString)")!
    let settings = AppSettings(defaults: defaults)
    let fixture = ClaudePanelFixture.all.first { $0.name == fixtureName }!
    fixture.configure(settings)
    let vm = NotchViewModel(settings: settings)
    vm.applyPreviewFixture(fixture)
    let presentation = IslandPresentation(content: vm)
    let metrics = NotchMetrics(screen: NotchMetrics.preferredScreen()!)
    presentation.metrics = metrics
    let window = NotchWindow(contentRect: metrics.maximumFrame)
    var ref: NotchHostingView<NotchRootView>?
    let hosting = NotchHostingView(rootView: NotchRootView(viewModel: vm, island: presentation) { ref?.activeRect = $0 })
    ref = hosting
    hosting.sizingOptions = []
    window.contentView = hosting
    window.setFrame(NSRect(x: -20000, y: -20000, width: metrics.maximumFrame.width, height: metrics.maximumFrame.height), display: false)
    window.alphaValue = 0
    window.allowsKey = true
    window.orderFrontRegardless()
    window.makeKey()
    presentation.setHovering(true)
    RunLoop.main.run(until: Date().addingTimeInterval(1.2))
    return (vm, window)
}

@MainActor
func key(_ window: NSWindow, _ chars: String, code: UInt16 = 0, shift: Bool = false) {
    for type in [NSEvent.EventType.keyDown, .keyUp] {
        let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: shift ? [.shift] : [],
                                 timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                 context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                 isARepeat: false, keyCode: code)!
        window.sendEvent(e)
    }
    RunLoop.main.run(until: Date().addingTimeInterval(0.15))
}

var failures = 0
func report(_ ok: Bool, _ name: String, _ detail: String = "") {
    if !ok { failures += 1 }
    print("  \(ok ? "ok  " : "FAIL")  \(name)\(detail.isEmpty ? "" : "  [\(detail)]")")
}

@main
enum KeyProbe {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        // What's typed into the terminal.
        let esc = "\u{1B}"
        report(TerminalBridge.bracketedPaste("one\ntwo") == esc + "[200~one\ntwo" + esc + "[201~",
               "a newline stays inside the paste")
        report(TerminalBridge.bracketedPaste("one\r\ntwo\rthree") == esc + "[200~one\ntwo\nthree" + esc + "[201~",
               "CRs become newlines, so none can submit half the reply")
        report(TerminalBridge.bracketedPaste("a" + esc + "[201~b\tc") == esc + "[200~a[201~bc" + esc + "[201~",
               "an ESC of its own can't end the paste early; other controls go")
        report(NotchViewModel.replyText("  \n hi\r\nthere \n\n") == "hi\nthere", "the reply trimmed, its lines kept")

        // A reply typed mid-turn, as the transcript says Claude Code took it
        // (the entries' shape as 2.1.321 wrote them in a real run).
        func entry(_ op: String, _ at: String, _ content: String) -> Data {
            Data(#"{"type":"queue-operation","operation":"\#(op)","timestamp":"2026-11-09T20:\#(at).000Z","sessionId":"s","content":"\#(content)"}"#.utf8)
        }
        let since = ISO8601DateFormatter().date(from: "2026-11-09T20:36:58Z")!
        let lines = [entry("remove", "37:23", "Run the tests too.\\nThen open a PR."),
                     entry("enqueue", "37:01", "Something else"),
                     entry("enqueue", "36:59", "Run the tests too.\\nThen open a PR.")]
        let text = "Run the tests too.\nThen open a PR."
        report(NotchViewModel.queueOperation(["enqueue"], text, in: lines, since: since) != nil,
               "a reply typed mid-turn is queued, by the transcript")
        report(NotchViewModel.queueOperation(["remove", "dequeue"], text, in: lines, since: since) != nil,
               "and taken")
        report(NotchViewModel.queueOperation(["remove"], text, in: Array(lines.dropFirst()), since: since) == nil,
               "not taken until the transcript says so")
        report(NotchViewModel.queueOperation(["enqueue"], "Something else entirely", in: lines, since: since) == nil,
               "only its own text")
        let later = ISO8601DateFormatter().date(from: "2026-11-09T20:37:10Z")!
        report(NotchViewModel.queueOperation(["enqueue"], text, in: lines, since: later) == nil,
               "nothing from before it was sent")
        // The reply field: typing lands; Shift-Return is a new line; Return
        // is not.
        do {
            let (vm, window) = island("rp_done_empty")
            vm.replyDraft = ""
            vm.beginCompose(.reply)
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
            for c in "abc" { key(window, String(c)) }
            report(vm.replyDraft == "abc", "typing lands in the reply field", vm.replyDraft.debugDescription)
            key(window, "\r", code: 36, shift: true)
            key(window, "d")
            report(vm.replyDraft == "abc\nd", "Shift-Return starts a new line", vm.replyDraft.debugDescription)
            key(window, "\r", code: 36)
            report(!vm.replyDraft.hasSuffix("\n"), "Return doesn't add a line", vm.replyDraft.debugDescription)
            window.orderOut(nil)
        }
        // The answer field, same ComposeField: Return sends (the typed
        // answer is taken and the field closes).
        do {
            let (vm, window) = island("jr_question_type_pill")
            vm.answerDraft = ""
            vm.beginCompose(.answer)
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
            for c in "Mango" { key(window, String(c)) }
            report(vm.answerDraft == "Mango", "typing lands in the answer field", vm.answerDraft.debugDescription)
            key(window, "\r", code: 36)
            report(vm.composing == nil && vm.answerDraft.isEmpty, "Return sends", "composing \(String(describing: vm.composing))")
            window.orderOut(nil)
        }
        print(failures == 0 ? "\nall keys did what they should" : "\n\(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
