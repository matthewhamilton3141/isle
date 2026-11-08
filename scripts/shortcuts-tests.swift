//
//  shortcuts-tests.swift
//
//  Tests for the global keyboard shortcuts: key combos and how they're
//  stored, the bindings and their clashes, when each shortcut is held (the
//  register-only-while-pending state machine), what a press does — guarded
//  commands, Always…'s review, questions — and `HotKeyCenter`'s handling of
//  refusals. Compiled with every Isle source by scripts/test-shortcuts.sh.
//
//  Nothing here takes a key from the session it runs in: every
//  `HotKeyCenter` is built on `FakeRegistrar`, which records calls and never
//  reaches Carbon, and `HotKeyCenter.shared` is never touched.
//

import AppKit
import Carbon.HIToolbox
import Foundation

var failures = 0
var passes = 0

func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    if ok {
        passes += 1
        print("  ok    \(name)")
    } else {
        failures += 1
        let more = detail()
        print("  FAIL  \(name)" + (more.isEmpty ? "" : "\n        \(more)"))
    }
}

func equal<T: Equatable>(_ got: T, _ want: T, _ name: String) {
    check(got == want, name, "want \(want)\n        got  \(got)")
}

/// Records every call; refuses the combos in `taken`.
@MainActor
final class FakeRegistrar: HotKeyRegistrar {
    var onPress: ((UInt32) -> Void)?
    var taken: Set<KeyCombo> = []
    var held: [UInt32: KeyCombo] = [:]
    var log: [String] = []

    func register(_ combo: KeyCombo, id: UInt32) -> OSStatus {
        log.append("+\(id)")
        if taken.contains(combo) { return OSStatus(eventHotKeyExistsErr) }
        // As Carbon: a combo this process already holds under another id
        // is refused like anyone else's.
        if held.contains(where: { $0.key != id && $0.value == combo }) { return OSStatus(eventHotKeyExistsErr) }
        held[id] = combo
        return noErr
    }

    func unregister(id: UInt32) {
        log.append("-\(id)")
        held[id] = nil
    }

    func press(_ action: ShortcutAction) { onPress?(action.hotKeyID) }
    var heldActions: Set<ShortcutAction> { Set(held.keys.compactMap(ShortcutAction.init(hotKeyID:))) }
}

@MainActor
final class FakeHost: ShortcutIslandHost {
    var shortcutsRunning = true
    var islandPresence: ShortcutIslandPresence = .closed
    var isAnyIslandExpanded: Bool { islandPresence != .closed }
    var calls: [String] = []
    func toggleIslandFromShortcut() { calls.append("toggle") }
    func openIslandFromShortcut() { calls.append("open") }
}

let o = KeyCombo.option, c = KeyCombo.control, s = KeyCombo.shift, cmd = KeyCombo.command
let defaults = ShortcutBindings.defaults
typealias A = ShortcutAction
typealias Ctx = ShortcutContext

func json(_ combo: KeyCombo) -> String {
    let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
    return String(decoding: try! e.encode(combo), as: UTF8.self)
}

func decodeCombo(_ text: String) -> KeyCombo? {
    try? JSONDecoder().decode(KeyCombo.self, from: Data(text.utf8))
}

/// The plan's keys, as a set of actions.
func plan(_ ctx: Ctx, _ bindings: ShortcutBindings = defaults) -> Set<A> {
    Set(ShortcutPlan.active(ctx, bindings: bindings).keys)
}

func approvalCtx(guarded: Bool = false, reviewing: Bool = false) -> Ctx {
    Ctx(running: true, request: .approval(guarded: guarded, reviewing: reviewing), armed: true)
}

func questionCtx(_ options: Int, multi: Bool = false) -> Ctx {
    Ctx(running: true, request: .question(options: options, multiSelect: multi), armed: true)
}

func cmdFor(_ action: A, _ ctx: Ctx, _ face: ShortcutFace) -> ShortcutCommand {
    ShortcutPlan.command(for: action, context: ctx, face: face)
}

@main
enum ShortcutsTests {
    @MainActor
    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        combos()
        bindings()
        notes()
        heldWhile()
        commands()
        faceTracking()
        center()
        endToEnd()
        persistence()
        print("\n\(passes) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - Key combos

    @MainActor
    static func combos() {
        print("Key combos: encoding and decoding")
        let optReturn = KeyCombo(kVK_Return, o)
        equal(json(optReturn), #"{"key":36,"mods":["option"]}"#, "⌥⏎ is stored readably")
        equal(json(KeyCombo(kVK_ANSI_K, c | o | s | cmd)), #"{"key":40,"mods":["control","option","shift","command"]}"#,
              "every modifier, in menu order")
        equal(decodeCombo(#"{"key":36,"mods":["option"]}"#), optReturn, "⌥⏎ reads back")
        equal(decodeCombo(#"{"mods":["command","option"],"key":49}"#), KeyCombo(kVK_Space, o | cmd),
              "modifier order and key order don't matter")
        for combo in [A.toggleIsland, .approve, .deny, .option1, .option4].map(\.defaultCombo) + [KeyCombo(kVK_F5, c | s)] {
            equal(decodeCombo(json(combo)), combo, "\(combo.display(character: { _ in nil })) round-trips")
        }
        check(decodeCombo(#"{"key":36,"mods":["hyper"]}"#) == nil, "an unknown modifier is no combo, not a guess")
        check(decodeCombo(#"{"key":300,"mods":["option"]}"#) == nil, "a key code past 0x7F is refused")
        check(decodeCombo(#"{"key":-1,"mods":["option"]}"#) == nil, "a negative key code is refused")
        check(decodeCombo(#"{"mods":["option"]}"#) == nil, "no key, no combo")
        check(decodeCombo(#"{"key":36}"#) == nil, "no mods list, no combo")
        check(decodeCombo("garbage") == nil, "garbage is no combo")
        equal(KeyCombo(keyCode: 36, modifiers: o | 0x0001 | 0x4000).modifiers, o, "only the four modifier bits are kept")

        print("Key combos: from a key press")
        let flags: UInt = (1 << 19)             // .option
        equal(KeyCombo(keyCode: UInt16(kVK_Return), cocoaFlags: flags), optReturn, "⌥⏎ from NSEvent flags")
        equal(KeyCombo(keyCode: UInt16(kVK_ANSI_1), cocoaFlags: (1 << 18) | (1 << 17) | (1 << 20) | (1 << 16)).modifiers,
              c | s | cmd, "⌃⇧⌘, with Caps Lock ignored")
        equal(KeyCombo(keyCode: 36, cocoaFlags: NSEvent.ModifierFlags([.option, .command]).rawValue).modifiers,
              o | cmd, "the bit positions are AppKit's")

        print("Key combos: what's a shortcut")
        check(optReturn.isValidShortcut, "⌥⏎ is")
        check(KeyCombo(kVK_ANSI_K, cmd).isValidShortcut, "⌘K is (with a note)")
        check(!KeyCombo(kVK_Return, 0).isValidShortcut, "bare ⏎ isn't: that's typing")
        check(!KeyCombo(kVK_ANSI_A, s).isValidShortcut, "⇧A isn't: that's a capital")
        check(!KeyCombo(kVK_Option, o).isValidShortcut, "a modifier alone isn't")
        check(!KeyCombo(kVK_CapsLock, cmd).isValidShortcut, "Caps Lock isn't")
        check(A.allCases.allSatisfy { $0.defaultCombo.hasCommandingModifier }, "no shortcut is a bare key — Esc included")

        print("Key combos: display")
        let us: (UInt32) -> String? = { _ in nil }
        equal(optReturn.display(character: us), "⌥⏎", "⌥⏎")
        equal(A.deny.defaultCombo.display(character: us), "⌃⎋", "⌃⎋")
        equal(A.approve.defaultCombo.display(character: us), "⌃'", "⌃'")
        equal(A.approve.defaultCombo.spoken, "Control-'", "spoken, ⌃'")
        equal(A.toggleIsland.defaultCombo.display(character: us), "⌥⇥", "⌥⇥")
        equal(A.option3.defaultCombo.display(character: us), "⌥3", "⌥3")
        equal(KeyCombo(kVK_Space, o).display(character: us), "⌥Space", "⌥Space")
        equal(KeyCombo(kVK_ANSI_K, c | o | s | cmd).display(character: us), "⌃⌥⇧⌘K", "modifiers in menu order")
        equal(KeyCombo(kVK_F12, cmd).display(character: us), "⌘F12", "F keys")
        equal(KeyCombo(kVK_ANSI_Z, o).display(character: { $0 == UInt32(kVK_ANSI_Z) ? "y" : nil }), "⌥Y",
              "a printing key is named by the layout (QWERTZ's Y on the Z key)")
        equal(KeyCombo(kVK_ANSI_Grave, o).display(character: { _ in "\u{0}" }), "⌥`",
              "a control character from the layout falls back to the keycap")
        equal(optReturn.spoken, "Option-Return", "spoken")
        equal(KeyCombo(kVK_ANSI_1, o | s).spoken, "Option-Shift-1", "spoken, with a digit")
    }

    // MARK: - Bindings

    @MainActor
    static func bindings() {
        print("Bindings: defaults")
        equal(defaults[.toggleIsland].combo, KeyCombo(kVK_Tab, o), "open/close is ⌥⇥")
        equal(defaults[.approve].combo, KeyCombo(kVK_ANSI_Quote, c), "Approve is ⌃' (the key beside Return)")
        equal(defaults[.deny].combo, KeyCombo(kVK_Escape, c), "Deny is ⌃⎋")
        for a in [A.approve, .deny] {
            check(defaults[a].combo != KeyCombo(kVK_Return, o), "\(a.title) isn't ⌥⏎: Claude Code's newline")
            check(defaults[a].combo != KeyCombo(kVK_Return, c), "\(a.title) isn't ⌃⏎: Claude Code's send-now")
            check(defaults[a].combo.modifiers.nonzeroBitCount == 1, "\(a.title) is one modifier and a key")
        }
        equal(A.options.map { defaults[$0].combo }, [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4].map { KeyCombo($0, o) },
              "options are ⌥1…⌥4")
        check(A.configurable.allSatisfy { defaults[$0].isOn }, "all on out of the box")
        check(A.configurable.allSatisfy { $0.defaultCombo.isValidShortcut }, "every default is a valid shortcut")
        equal(Set(A.configurable.map(\.defaultCombo)).count, A.configurable.count, "no two defaults share keys")
        check(defaults.encoded() == nil, "the defaults store nothing")
        equal(Set(A.allCases.map(\.hotKeyID)).count, A.allCases.count, "hot key ids are distinct")
        check(A.allCases.allSatisfy { $0.hotKeyID > 0 && A(hotKeyID: $0.hotKeyID) == $0 }, "ids are nonzero and round-trip")
        check(A(hotKeyID: 0) == nil && A(hotKeyID: 99) == nil, "unknown ids are no action")
        equal(A.configurable, A.allCases, "Settings lists every shortcut: there's no hidden one")
        check(!A.allCases.contains { $0.defaultCombo == KeyCombo(kVK_Escape, 0) }, "and none is bare Esc")

        print("Bindings: storage")
        var b = defaults
        b[.approve] = ShortcutBinding(combo: KeyCombo(kVK_ANSI_Y, o))
        b[.toggleIsland].isOn = false
        let data = b.encoded()!
        let text = String(decoding: data, as: UTF8.self)
        equal(text, #"{"approve":{"combo":{"key":16,"mods":["option"]},"on":true},"toggleIsland":{"combo":{"key":48,"mods":["option"]},"on":false},"v":2}"#,
              "only what differs is stored, as JSON, with the store's version")
        equal(ShortcutBindings.decode(data), b, "and reads back the same")
        b[.approve] = ShortcutBinding(combo: A.approve.defaultCombo)
        check(!(String(decoding: b.encoded()!, as: UTF8.self).contains("approve")), "set back to its default, an entry goes")
        equal(ShortcutBindings.decode(nil), defaults, "nothing stored: defaults")
        equal(ShortcutBindings.decode(Data("not json".utf8)), defaults, "garbage: defaults")
        equal(ShortcutBindings.decode(Data("[1,2]".utf8)), defaults, "the wrong shape: defaults")
        let mixed = ShortcutBindings.decode(Data(#"""
            {"approve":{"combo":{"key":16,"mods":["option"]}},
             "deny":{"combo":{"key":36,"mods":["shift"]},"on":true},
             "option2":{"combo":{"key":19,"mods":["warp"]},"on":true},
             "dismiss":{"combo":{"key":53,"mods":["option"]},"on":true},
             "futureThing":{"combo":{"key":1,"mods":["option"]},"on":true}}
            """#.utf8))
        equal(mixed[.approve], ShortcutBinding(combo: KeyCombo(kVK_ANSI_Y, o), isOn: true), "a missing \"on\" reads as on")
        equal(mixed[.deny].combo, A.deny.defaultCombo, "a stored combo that isn't a shortcut (⇧⏎) reads as the default")
        equal(mixed[.option2].combo, A.option2.defaultCombo, "an unreadable entry reads as the default, alone")
        check(!A.allCases.contains { mixed.combo(for: $0)?.keyCode == UInt32(kVK_Escape) && mixed.combo(for: $0)?.modifiers == o },
              "an old plist's \"dismiss\" entry is ignored")
        let dupes = ShortcutBindings.decode(Data(#"{"approve":{"combo":{"key":16,"mods":["option"]},"on":true},"deny":{"combo":{"key":16,"mods":["option"]},"on":true},"v":2}"#.utf8))
        check(dupes[.approve].combo != dupes[.deny].combo, "an edited plist putting Deny on Approve's ⌥Y never makes one press mean two")
        equal(dupes[.approve].combo, KeyCombo(kVK_ANSI_Y, o), "the earlier action in Settings order keeps it")
        equal(dupes[.deny].combo, A.deny.defaultCombo, "the later goes back to its default")
        let onDefault = ShortcutBindings.decode(Data(#"{"deny":{"combo":{"key":39,"mods":["control"]},"on":true},"v":2}"#.utf8))
        equal(onDefault[.deny].combo, KeyCombo(kVK_ANSI_Quote, c), "keys someone chose win over another action's default")
        check(!onDefault[.approve].isOn && onDefault.combo(for: .approve) == nil, "and that action goes off rather than share them")

        print("Bindings: the move off ⌥⏎ and ⌥⎋ (store version 1 to 2)")
        let untouched = ShortcutBindings.decode(Data(#"{"toggleIsland":{"combo":{"key":34,"mods":["option"]},"on":true}}"#.utf8))
        equal(untouched[.approve].combo, A.approve.defaultCombo, "never customised: the new Approve")
        equal(untouched[.deny].combo, A.deny.defaultCombo, "and the new Deny")
        equal(untouched[.toggleIsland].combo, KeyCombo(kVK_ANSI_I, o), "what they did record stays")
        let switchedOff = ShortcutBindings.decode(Data(#"{"approve":{"combo":{"key":36,"mods":["option"]},"on":false},"deny":{"combo":{"key":53,"mods":["option"]},"on":false}}"#.utf8))
        equal(switchedOff[.approve], ShortcutBinding(combo: A.approve.defaultCombo, isOn: false),
              "only switched off (version 1 stored the old default then): the new keys, still off")
        equal(switchedOff[.deny], ShortcutBinding(combo: A.deny.defaultCombo, isOn: false), "Deny the same")
        check(switchedOff.encoded().map { String(decoding: $0, as: UTF8.self) }?.contains(#""v":2"#) == true,
              "written back as version 2")
        let recordedV1 = ShortcutBindings.decode(Data(#"{"approve":{"combo":{"key":16,"mods":["option"]},"on":true},"deny":{"combo":{"key":45,"mods":["control"]},"on":true}}"#.utf8))
        equal(recordedV1[.approve].combo, KeyCombo(kVK_ANSI_Y, o), "recorded their own Approve: kept")
        equal(recordedV1[.deny].combo, KeyCombo(kVK_ANSI_N, c), "and their own Deny")
        let recordedV2 = ShortcutBindings.decode(Data(#"{"approve":{"combo":{"key":36,"mods":["option"]},"on":true},"v":2}"#.utf8))
        equal(recordedV2[.approve].combo, KeyCombo(kVK_Return, o), "⌥⏎ recorded after the move is theirs: kept")
        var roundTrip = defaults
        roundTrip.assign(KeyCombo(kVK_Return, o), to: .approve)
        equal(ShortcutBindings.decode(roundTrip.encoded()), roundTrip, "and survives a relaunch")

        print("Bindings: recording")
        var r = defaults
        equal(r.assign(KeyCombo(kVK_ANSI_Y, o), to: .approve), .assigned, "⌥Y for Approve")
        equal(r[.approve].combo, KeyCombo(kVK_ANSI_Y, o), "is stored")
        equal(r.assign(KeyCombo(kVK_ANSI_Y, 0), to: .deny), .needsModifier, "bare Y is refused")
        equal(r.assign(KeyCombo(kVK_ANSI_Y, s), to: .deny), .needsModifier, "⇧Y is refused")
        equal(r.assign(KeyCombo(kVK_ANSI_Y, o), to: .deny), .clashes(.approve), "⌥Y for Deny clashes with Approve")
        equal(r.assign(KeyCombo(kVK_Tab, o), to: .approve), .clashes(.toggleIsland), "⌥⇥ is the island's")
        r[.toggleIsland].isOn = false
        equal(r.assign(KeyCombo(kVK_Tab, o), to: .approve), .clashes(.toggleIsland),
              "an off shortcut still owns its keys (turning it on can't make a clash)")
        equal(r.assign(KeyCombo(kVK_ANSI_Y, o), to: .approve), .assigned, "an action may take its own keys again")
        equal(r.assign(KeyCombo(kVK_Escape, 0), to: .deny), .needsModifier, "bare Esc isn't recordable")
        r[.deny].isOn = false
        r.assign(KeyCombo(kVK_ANSI_N, o), to: .deny)
        check(!r[.deny].isOn, "recording keeps a shortcut's on/off")
        r.reset(.deny)
        equal(r[.deny], ShortcutBinding(combo: A.deny.defaultCombo, isOn: false), "reset restores the keys, not the switch")
        check(r.isDefault(.deny) && !r.isDefault(.approve), "isDefault is about the keys")
        check(r.combo(for: .deny) == nil, "an off shortcut has no keys to hold")
    }

    // MARK: - Notes

    @MainActor
    static func notes() {
        print("Known clashes")
        check(ShortcutNotes.note(for: KeyCombo(kVK_Space, o))?.contains("ChatGPT") == true, "⌥Space names the launchers")
        check(ShortcutNotes.note(for: KeyCombo(kVK_Space, cmd))?.contains("Spotlight") == true, "⌘Space is Spotlight")
        check(ShortcutNotes.note(for: KeyCombo(kVK_Space, c))?.contains("input") == true, "⌃Space is input sources")
        check(ShortcutNotes.note(for: A.toggleIsland.defaultCombo)?.contains("AltTab") == true, "⌥⇥ says AltTab, honestly")
        check(ShortcutNotes.note(for: KeyCombo(kVK_Escape, o))?.contains("Speak Selection") == true, "⌥⎋ says Speak Selection")
        check(ShortcutNotes.note(for: KeyCombo(kVK_Return, o))?.contains("Claude Code uses ⌥⏎ for a newline") == true,
              "recording ⌥⏎ says it's Claude Code's newline")
        check(ShortcutNotes.note(for: KeyCombo(kVK_Return, c))?.contains("send a message now") == true,
              "recording ⌃⏎ says it's Claude Code's send-now")
        check(ShortcutNotes.note(for: A.approve.defaultCombo)?.contains("left of Return") == true, "⌃' says which key it is")
        check(ShortcutNotes.note(for: A.deny.defaultCombo) == nil, "⌃⎋ has nothing to say")
        check(ShortcutNotes.note(for: KeyCombo(kVK_ANSI_K, cmd)) != nil, "⌘K is every app's menus")
        check(ShortcutNotes.note(for: A.option1.defaultCombo) == nil, "⌥1 has nothing to say")
        check(ShortcutNotes.note(for: KeyCombo(kVK_ANSI_I, c | o)) == nil, "⌃⌥I has nothing to say")
    }

    // MARK: - When they're held

    @MainActor
    static func heldWhile() {
        print("Held: register only while pending")
        equal(plan(Ctx()), [], "not running: nothing at all")
        equal(plan(Ctx(running: true)), [.toggleIsland], "nothing waiting: only open/close")
        var ctx = approvalCtx()
        ctx.armed = false
        equal(plan(ctx), [.toggleIsland], "an approval this instant: not yet (the arm delay)")
        ctx.armed = true
        equal(plan(ctx), [.toggleIsland, .approve, .deny], "armed: Approve and Deny")
        ctx.answering = true
        equal(plan(ctx), [.toggleIsland], "answered, hook not yet gone: let go")
        equal(plan(Ctx(running: true)), [.toggleIsland], "cleared or expired: let go")
        var composing = approvalCtx()
        composing.composing = true
        equal(plan(composing), [.toggleIsland], "a field has the keys (No, and tell Claude…): let go")
        equal(plan(approvalCtx(guarded: true)), [.toggleIsland, .approve, .deny], "guarded: held (a press reveals first)")
        equal(plan(approvalCtx(reviewing: true)), [.toggleIsland, .approve, .deny], "Always…'s review: held, as Confirm and Back")
        var notRunning = approvalCtx()
        notRunning.running = false
        equal(plan(notRunning), [], "islands hidden from the menu bar: nothing, even with a request")

        print("Held: questions")
        equal(plan(questionCtx(2)), [.toggleIsland, .option1, .option2], "two options: ⌥1 ⌥2")
        equal(plan(questionCtx(4)), [.toggleIsland, .option1, .option2, .option3, .option4], "four: ⌥1…⌥4")
        equal(plan(questionCtx(6)), [.toggleIsland, .option1, .option2, .option3, .option4], "six (past the tool's limit): still four keys")
        equal(plan(questionCtx(0)), [.toggleIsland], "no options: none")
        equal(plan(questionCtx(3, multi: true)), [.toggleIsland, .option1, .option2, .option3, .approve],
              "multi-select: the options and ⌥⏎ for Done")
        check(!plan(questionCtx(3)).contains(.deny), "a question has no Deny")

        print("Held: never a bare key")
        for ctx in [Ctx(running: true), approvalCtx(), approvalCtx(guarded: true), questionCtx(4, multi: true)] {
            check(ShortcutPlan.active(ctx, bindings: defaults).values.allSatisfy(\.hasCommandingModifier),
                  "\(ctx.request.map { "\($0)" } ?? "idle"): every held key has ⌥, ⌃ or ⌘ — Esc stays vim's and Claude Code's")
        }

        print("Held: on/off")
        var b = defaults
        b[.toggleIsland].isOn = false
        equal(plan(Ctx(running: true), b), [], "open/close off: nothing all the time")
        b[.approve].isOn = false
        equal(plan(approvalCtx(), b), [.deny], "Approve off: Deny alone while pending")
        for a in A.options { b[a].isOn = false }
        equal(plan(questionCtx(4, multi: true), b), [], "options and Approve off: nothing for a question")
        equal(ShortcutPlan.active(approvalCtx(), bindings: { var x = defaults; x.assign(KeyCombo(kVK_ANSI_Y, o), to: .approve); return x }())[.approve],
              KeyCombo(kVK_ANSI_Y, o), "a recorded combo is what's held")
    }

    // MARK: - What a press does

    @MainActor
    static func commands() {
        print("Press: an approval")
        equal(cmdFor(.approve, approvalCtx(), .shown), .approve, "Approve, in front of you: one press, as the button")
        equal(cmdFor(.approve, approvalCtx(), .seen), .approve, "and once looked at")
        equal(cmdFor(.approve, approvalCtx(), .hidden), .reveal,
              "closed, or auto-opened on another display: the first press opens it where you are, approves nothing")
        equal(cmdFor(.deny, approvalCtx(), .hidden), .deny, "Deny, unseen: one press (refusing is safe)")
        equal(cmdFor(.option1, approvalCtx(), .seen), .none, "an option key on an approval: nothing")

        print("Press: a guarded command (M17)")
        equal(cmdFor(.approve, approvalCtx(guarded: true), .hidden), .reveal,
              "island closed: the first press opens it to the command, and approves nothing")
        equal(cmdFor(.approve, approvalCtx(guarded: true), .shown), .reveal,
              "just come up (a fast double-tap, or an alert's auto-open): still nothing")
        equal(cmdFor(.approve, approvalCtx(guarded: true), .seen), .approve, "in front of you for half a second: approves")
        equal(cmdFor(.deny, approvalCtx(guarded: true), .hidden), .deny, "Deny stays one press: refusing is safe")

        print("Press: Always…'s review")
        equal(cmdFor(.approve, approvalCtx(reviewing: true), .seen), .confirmRemember, "Approve is the review's Confirm")
        equal(cmdFor(.deny, approvalCtx(reviewing: true), .seen), .cancelRemember, "Deny is the review's Back")
        equal(cmdFor(.approve, approvalCtx(reviewing: true), .hidden), .reveal,
              "out of view, saving a rule is never a blind press: reveal")
        equal(cmdFor(.approve, approvalCtx(reviewing: true), .shown), .reveal, "nor a moment after it comes up")
        equal(cmdFor(.deny, approvalCtx(reviewing: true), .hidden), .reveal, "nor Back")

        print("Press: a question")
        equal(cmdFor(.option2, questionCtx(3), .seen), .pick(1), "⌥2 on screen picks the second option")
        equal(cmdFor(.option2, questionCtx(3), .hidden), .reveal, "⌥2 unseen opens the island to the question")
        equal(cmdFor(.option2, questionCtx(3), .shown), .reveal, "⌥2 the instant it's up: not yet")
        equal(cmdFor(.option4, questionCtx(3), .seen), .none, "⌥4 with three options: nothing")
        equal(cmdFor(.approve, questionCtx(3), .seen), .none, "Approve on a single-select: nothing (picking sends)")
        equal(cmdFor(.approve, questionCtx(3, multi: true), .seen), .submit, "Approve on a multi-select: Done")
        equal(cmdFor(.approve, questionCtx(3, multi: true), .shown), .reveal, "only once looked at")
        equal(cmdFor(.option1, questionCtx(3, multi: true), .seen), .pick(0), "multi-select: ⌥1 toggles")
        equal(cmdFor(.deny, questionCtx(3), .seen), .none, "Deny on a question: nothing")

        print("Press: a press that arrives late")
        var late = approvalCtx()
        late.answering = true
        equal(cmdFor(.approve, late, .seen), .none, "already answered: nothing (never twice)")
        late = approvalCtx(); late.armed = false
        equal(cmdFor(.approve, late, .seen), .none, "not armed: nothing")
        late = approvalCtx(); late.composing = true
        equal(cmdFor(.approve, late, .seen), .none, "a field has the keys: nothing")
        equal(cmdFor(.approve, Ctx(running: true), .seen), .none, "the request is gone: nothing")

        print("Press: the island")
        equal(cmdFor(.toggleIsland, Ctx(running: true), .hidden), .toggleIsland, "open/close")
        equal(cmdFor(.toggleIsland, approvalCtx(), .seen), .toggleIsland, "open/close, a request or not")
        equal(cmdFor(.toggleIsland, Ctx(), .hidden), .none, "not running: nothing")
    }

    // MARK: - In front of the user

    @MainActor
    static func faceTracking() {
        print("Seen: when the face is in front of the user")
        let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
        func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
        let half = ShortcutPlan.seenDelay

        var f = ShortcutFaceTracker()
        equal(f.update(request: nil, showsFace: true, presence: .pointerScreen, now: at(0)), .hidden, "no request: hidden")
        equal(f.update(request: "r1", showsFace: false, presence: .closed, now: at(0)), .hidden, "closed: hidden")
        equal(f.update(request: "r1", showsFace: true, presence: .pointerScreen, now: at(1)), .shown,
              "open on the pointer's display: shown, from now")
        equal(f.update(request: "r1", showsFace: true, presence: .pointerScreen, now: at(1 + half - 0.01)), .shown,
              "not yet half a second")
        equal(f.update(request: "r1", showsFace: true, presence: .pointerScreen, now: at(1 + half)), .seen, "half a second: seen")
        equal(f.update(request: "r1", showsFace: false, presence: .pointerScreen, now: at(2)), .hidden,
              "switched to another face: hidden")
        equal(f.update(request: "r1", showsFace: true, presence: .pointerScreen, now: at(2.1)), .shown,
              "back on it: the half second starts over")

        print("Seen: an alert's auto-open on another display")
        f = ShortcutFaceTracker()
        equal(f.update(request: "r2", showsFace: true, presence: .elsewhere, now: at(0)), .hidden,
              "auto-opened where the pointer isn't: hidden — nobody may be looking")
        equal(f.update(request: "r2", showsFace: true, presence: .elsewhere, now: at(5)), .hidden,
              "however long it's been up there")
        equal(f.update(request: "r2", showsFace: true, presence: .pointerScreen, now: at(6)), .shown,
              "the pointer comes to its display: shown, from then")
        equal(f.update(request: "r2", showsFace: true, presence: .pointerScreen, now: at(6 + half)), .seen, "and seen after")
        equal(f.update(request: "r2", showsFace: true, presence: .elsewhere, now: at(7)), .hidden,
              "pointer away again, never having gone to it: hidden")

        print("Seen: visited")
        f = ShortcutFaceTracker()
        equal(f.update(request: "r3", showsFace: true, presence: .visited, now: at(0)), .shown, "hovered: shown")
        equal(f.update(request: "r3", showsFace: true, presence: .elsewhere, now: at(0.3)), .shown,
              "then the pointer goes to another display: still in front of them (they went to it)")
        equal(f.update(request: "r3", showsFace: true, presence: .elsewhere, now: at(0 + half)), .seen,
              "and the half second runs on")
        equal(f.update(request: "r3", showsFace: false, presence: .closed, now: at(1)), .hidden, "closed: hidden")
        equal(f.update(request: "r4", showsFace: true, presence: .elsewhere, now: at(2)), .hidden,
              "a new request: the visit was to the old one")

        print("Seen: a reveal starts the look over")
        f = ShortcutFaceTracker()
        _ = f.update(request: "r5", showsFace: true, presence: .pointerScreen, now: at(0))
        f.restart(now: at(0.4))
        equal(f.update(request: "r5", showsFace: true, presence: .pointerScreen, now: at(0.6)), .shown,
              "a press that revealed at 0.4s: not seen at 0.6s")
        equal(f.update(request: "r5", showsFace: true, presence: .pointerScreen, now: at(0.4 + half)), .seen,
              "seen half a second after the reveal")
        var closed = ShortcutFaceTracker()
        closed.restart(now: at(0))
        equal(closed.update(request: "r6", showsFace: true, presence: .visited, now: at(0.1)), .shown,
              "a reveal of a closed island: the look starts when it's up")

        print("Seen: the two holes this closes")
        // (A) expandOnAlert: an approval opens itself; a press 0.5s later
        // (the arm delay) mustn't approve a guarded command unread.
        f = ShortcutFaceTracker()
        let autoOpen = f.update(request: "g", showsFace: true, presence: .elsewhere, now: at(0.5))
        equal(cmdFor(.approve, approvalCtx(guarded: true), autoOpen), .reveal,
              "(A) guarded, auto-opened on a display you aren't on: the press reveals, approves nothing")
        let plainElsewhere = f.update(request: "g", showsFace: true, presence: .elsewhere, now: at(0.6))
        equal(cmdFor(.approve, approvalCtx(), plainElsewhere), .reveal, "(A) a plain approval there: the same")
        // (B) island closed: a fast double-tap.
        f = ShortcutFaceTracker()
        let first = f.update(request: "g", showsFace: false, presence: .closed, now: at(1))
        equal(cmdFor(.approve, approvalCtx(guarded: true), first), .reveal, "(B) first tap: reveal")
        f.restart(now: at(1))
        let second = f.update(request: "g", showsFace: true, presence: .visited, now: at(1.12))
        equal(cmdFor(.approve, approvalCtx(guarded: true), second), .reveal,
              "(B) second tap 120ms later, panel still opening: still nothing")
        let third = f.update(request: "g", showsFace: true, presence: .visited, now: at(1.12 + half))
        equal(cmdFor(.approve, approvalCtx(guarded: true), third), .approve, "a press after a real look approves")
    }

    // MARK: - HotKeyCenter

    @MainActor
    static func center() {
        print("HotKeyCenter: diffing")
        let reg = FakeRegistrar()
        let center = HotKeyCenter(registrar: reg)
        var pressed: [A] = []
        center.onAction = { pressed.append($0) }
        let toggle = A.toggleIsland.defaultCombo, approve = A.approve.defaultCombo, deny = A.deny.defaultCombo

        center.apply([.toggleIsland: toggle])
        equal(reg.heldActions, [.toggleIsland], "takes what it's told")
        reg.log = []
        center.apply([.toggleIsland: toggle])
        equal(reg.log, [], "the same set again: no calls at all")
        center.apply([.toggleIsland: toggle, .approve: approve, .deny: deny])
        equal(reg.heldActions, [.toggleIsland, .approve, .deny], "a request: two more")
        equal(reg.log.filter { $0.hasPrefix("-") }, [], "without letting go of the first")
        center.apply([.toggleIsland: toggle])
        equal(reg.heldActions, [.toggleIsland], "answered: exactly those two let go")
        center.apply([.toggleIsland: KeyCombo(kVK_ANSI_I, o)])
        equal(reg.held[A.toggleIsland.hotKeyID], KeyCombo(kVK_ANSI_I, o), "new keys: re-registered on them")
        reg.log = []
        center.apply([.approve: toggle])
        equal(reg.log, ["-\(A.toggleIsland.hotKeyID)", "+\(A.approve.hotKeyID)"], "lets go before it takes")
        center.apply([:])
        equal(reg.held, [:], "nothing wanted: nothing held")

        print("HotKeyCenter: presses")
        center.apply([.toggleIsland: toggle])
        reg.press(.toggleIsland)
        equal(pressed, [.toggleIsland], "a held key's press reaches the action")
        reg.press(.approve)
        equal(pressed, [.toggleIsland], "a press for a key it doesn't hold is dropped")
        reg.onPress?(999)
        equal(pressed, [.toggleIsland], "an unknown id is dropped")

        print("HotKeyCenter: refusals")
        reg.taken = [approve]
        center.apply([.toggleIsland: toggle, .approve: approve, .deny: deny])
        equal(center.status[.approve], .refused(OSStatus(eventHotKeyExistsErr)), "⌥⏎ taken: refused, with Carbon's status")
        equal(center.status[.deny], .held, "the others still held")
        check(center.held[.approve] == nil, "a refused key isn't held")
        reg.log = []
        center.apply([.toggleIsland: toggle, .approve: approve, .deny: deny])
        equal(reg.log, [], "a refusal isn't retried on every pass")
        center.apply([.toggleIsland: toggle])
        equal(center.status[.approve], .refused(OSStatus(eventHotKeyExistsErr)),
              "let go, the refusal is kept, so Settings can say so between requests")
        check(center.status[.deny] == nil, "let go, a held one says nothing")
        reg.taken = []
        center.apply([.toggleIsland: toggle, .approve: approve])
        equal(center.status[.approve], .held, "the next request: tried again, and held now")
        reg.taken = [approve]
        center.apply([.toggleIsland: toggle])
        center.apply([.toggleIsland: toggle, .approve: approve])
        center.apply([.toggleIsland: toggle, .approve: KeyCombo(kVK_ANSI_Y, o)])
        equal(center.status[.approve], .held, "new keys: the old refusal goes, and the new keys are tried")
        center.apply([.toggleIsland: toggle])
        center.clearStatus(.approve)
        check(center.status[.approve] == nil, "clearStatus forgets it")
        equal(HotKeyCenter.describe(OSStatus(eventHotKeyExistsErr)), "Another app already has this shortcut.", "said plainly")

        print("HotKeyCenter: probe and suspend")
        reg.taken = [KeyCombo(kVK_Space, o)]
        let heldBefore = reg.held
        equal(center.probe(KeyCombo(kVK_Space, o)), OSStatus(eventHotKeyExistsErr), "probe: a taken combo says so")
        equal(center.probe(KeyCombo(kVK_ANSI_J, o)), noErr, "probe: a free one says so")
        equal(reg.held, heldBefore, "and holds nothing afterwards")
        check(!reg.log.suffix(3).contains { $0 == "+\(A.toggleIsland.hotKeyID)" }, "under an id no action uses")
        center.apply([.toggleIsland: toggle, .deny: deny])
        center.isSuspended = true
        equal(reg.held, [:], "recording: everything let go")
        center.apply([.toggleIsland: toggle, .deny: deny, .approve: approve])
        equal(reg.held, [:], "and stays let go while it records")
        reg.taken = []
        center.isSuspended = false
        equal(reg.heldActions, [.toggleIsland, .deny, .approve], "done: what's wanted now is held")

        print("Recording: onto its own keys")
        reg.taken = []
        center.apply([.toggleIsland: toggle, .approve: approve, .deny: deny])
        var bindings = defaults
        equal(center.probe(approve), OSStatus(eventHotKeyExistsErr),
              "(why it mattered: a probe of a combo Isle holds reads as taken)")
        reg.log = []
        equal(ShortcutRecording.record(approve, for: .approve, into: &bindings, center: center), .unchanged,
              "re-recording Approve's own keys: no change, no false conflict")
        check(!reg.log.contains("+\(A.allCases.count + 1)"), "and no probe at all")
        // The recorder's order: still suspended when it records.
        center.isSuspended = true
        equal(ShortcutRecording.record(approve, for: .approve, into: &bindings, center: center), .unchanged,
              "while recording (suspended): the same")
        equal(ShortcutRecording.record(KeyCombo(kVK_ANSI_J, c), for: .approve, into: &bindings, center: center), .recorded,
              "new keys, suspended: probed and recorded")
        equal(bindings[.approve].combo, KeyCombo(kVK_ANSI_J, c), "and stored")
        equal(ShortcutRecording.record(toggle, for: .approve, into: &bindings, center: center),
              .refused("\(toggle.display()) is already \(A.toggleIsland.title)’s."), "another action's keys: said so")
        reg.taken = [KeyCombo(kVK_ANSI_K, c)]
        if case .refused(let why) = ShortcutRecording.record(KeyCombo(kVK_ANSI_K, c), for: .deny, into: &bindings, center: center) {
            check(why.contains("Another app"), "keys another app holds: refused, by the probe")
        } else {
            check(false, "keys another app holds: refused, by the probe")
        }
        equal(ShortcutRecording.record(KeyCombo(kVK_ANSI_K, 0), for: .deny, into: &bindings, center: center),
              .refused("Hold ⌥, ⌃ or ⌘ with the key — a bare key is typing."), "a bare key: refused")
        center.isSuspended = false
        reg.taken = []
        center.apply([:])
    }

    // MARK: - End to end

    /// The real view model, a fixture's request, `NotchShortcuts` reading
    /// it, and the fake registrar: what's held across a request's life.
    @MainActor
    static func endToEnd() {
        print("End to end: an approval's life")
        let suite = "isle.shortcut-tests.\(UUID().uuidString)"
        let settings = AppSettings(defaults: UserDefaults(suiteName: suite)!)
        settings.mode = .claude
        let vm = NotchViewModel(settings: settings)
        let reg = FakeRegistrar()
        let center = HotKeyCenter(registrar: reg)
        let host = FakeHost()
        let shortcuts = NotchShortcuts(viewModel: vm, settings: settings, center: center, host: host)
        func spin(_ seconds: TimeInterval = 0.05) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

        shortcuts.refresh(); spin()
        equal(reg.heldActions, [.toggleIsland], "idle: open/close only")

        vm.applyPreviewFixture(ClaudePanelFixture(
            name: "t", state: .needsApproval, action: "Bash", target: "git",
            request: ClaudePanelFixture.approval("Bash", "git status")))
        spin()
        equal(reg.heldActions, [.toggleIsland], "the instant it lands: not yet")
        spin(ShortcutPlan.armDelay + 0.15)
        equal(reg.heldActions, [.toggleIsland, .approve, .deny], "half a second on: ⌥⏎ and ⌥⎋ held, with no prompt to refresh")

        vm.beginCompose(.denial); spin()
        equal(reg.heldActions, [.toggleIsland], "No, and tell Claude…: the field has the keys")
        vm.endCompose(); spin()
        equal(reg.heldActions, [.toggleIsland, .approve, .deny], "field closed: back")

        let guarded = ClaudePanelFixture.guardedApproval("Bash", command: "git push origin main", pattern: "git push")
        vm.applyPreviewFixture(ClaudePanelFixture(name: "g", state: .needsApproval, action: "Bash", target: "git",
                                                  request: guarded))
        spin()
        equal(shortcuts.context().request, .approval(guarded: true, reviewing: false), "a guarded approval reads as guarded")

        // A different request: armed afresh.
        let other = ClaudeRequest(id: "preview-session-1762300099-4242", kind: .approval, sessionId: "preview-session",
                              toolName: "Bash", subject: "ls", questions: [])
        vm.applyPreviewFixture(ClaudePanelFixture(name: "o", state: .needsApproval, action: "Bash", target: "ls",
                                                  request: other))
        spin()
        equal(reg.heldActions, [.toggleIsland], "the next request is armed afresh")
        spin(ShortcutPlan.armDelay + 0.15)
        equal(reg.heldActions, [.toggleIsland, .approve, .deny], "and held half a second on")

        vm.applyPreviewFixture(ClaudePanelFixture(name: "w", state: .working, action: "Bash", target: "ls"))
        spin()
        equal(reg.heldActions, [.toggleIsland], "answered elsewhere, or expired: let go at once")

        print("End to end: a question")
        vm.applyPreviewFixture(ClaudePanelFixture(name: "q", state: .needsQuestion,
                                                  request: ClaudePanelFixture.question([ClaudePanelFixture.threeOptions])))
        spin(ShortcutPlan.armDelay + 0.15)
        equal(reg.heldActions, [.toggleIsland, .option1, .option2, .option3], "three options: ⌥1…⌥3")
        vm.applyPreviewFixture(ClaudePanelFixture(name: "m", state: .needsQuestion,
                                                  request: ClaudePanelFixture.question([ClaudePanelFixture.multiSelect])))
        spin(ShortcutPlan.armDelay + 0.15)
        let multi = ClaudePanelFixture.multiSelect.options.count
        equal(reg.heldActions, Set([.toggleIsland, .approve] + A.options.prefix(multi)), "multi-select: and ⌥⏎ for Done")

        print("End to end: presses that only reveal")
        host.islandPresence = .closed
        reg.press(.option1); spin()
        equal(host.calls, ["open"], "⌥1 with the island closed opens it")
        equal(vm.questionPicks.first ?? [], [], "and picks nothing")
        host.islandPresence = .visited
        shortcuts.refresh(); spin()
        reg.press(.option1); spin()
        equal(vm.questionPicks.first ?? [], [], "⌥1 again at once, the panel just up: still nothing")
        equal(host.calls, ["open", "open"], "it reveals again")
        spin(ShortcutPlan.seenDelay + 0.1)
        reg.press(.option1); spin()
        equal(vm.questionPicks.first ?? [], [ClaudePanelFixture.multiSelect.options[0].label],
              "after half a second in view, ⌥1 toggles option 1")
        reg.press(.option1); spin()
        equal(vm.questionPicks.first ?? [], [], "and again, off")

        vm.applyPreviewFixture(ClaudePanelFixture(name: "g2", state: .needsApproval, action: "Bash", target: "git",
                                                  request: guarded))
        spin(ShortcutPlan.armDelay + 0.15)
        host.calls = []
        host.islandPresence = .closed
        shortcuts.refresh(); spin()
        reg.press(.approve); spin()
        equal(host.calls, ["open"], "Approve on a guarded command, island closed: opens it")
        check(!vm.isAnsweringRequest, "and sends nothing")
        check(vm.shortcutNotice == nil, "and claims nothing")
        host.islandPresence = .visited
        reg.press(.approve); spin()
        check(!vm.isAnsweringRequest, "a fast second press, panel just open: sends nothing")
        equal(host.calls, ["open", "open"], "it reveals again, and the look starts over")

        // That request was visited; a fresh one, auto-opened elsewhere.
        vm.applyPreviewFixture(ClaudePanelFixture(name: "w2", state: .working, action: "Bash", target: "ls"))
        spin()
        host.islandPresence = .elsewhere
        vm.applyPreviewFixture(ClaudePanelFixture(name: "g3", state: .needsApproval, action: "Bash", target: "git",
                                                  request: guarded))
        spin(max(ShortcutPlan.armDelay, ShortcutPlan.seenDelay) + 0.15)
        host.calls = []
        reg.press(.approve); spin()
        equal(host.calls, ["open"], "auto-opened on another display, however long: the press reveals it where you are")
        check(!vm.isAnsweringRequest, "and sends nothing")
        check(shortcuts.face() != .seen, "not seen")
        host.islandPresence = .pointerScreen
        shortcuts.refresh(); spin()
        equal(shortcuts.face(), .shown, "on the pointer's display: shown")
        spin(ShortcutPlan.seenDelay + 0.1)
        equal(shortcuts.face(), .seen, "and seen half a second on, with no press to ask")

        print("End to end: the island")
        host.calls = []
        reg.press(.toggleIsland); spin()
        equal(host.calls, ["toggle"], "⌥⇥ toggles")
        host.islandPresence = .visited
        shortcuts.refresh(); spin()
        check(!reg.held.values.contains { $0.keyCode == UInt32(kVK_Escape) && $0.modifiers == 0 },
              "open by shortcut: bare Esc is never taken")
        reg.press(.toggleIsland); spin()
        equal(host.calls.last, "toggle", "the open shortcut is what puts it away")
        host.shortcutsRunning = false
        shortcuts.refresh(); spin()
        equal(reg.held, [:], "islands hidden: everything let go")

        print("End to end: settings")
        host.shortcutsRunning = true
        settings.shortcuts[.toggleIsland].isOn = false
        spin()
        check(!reg.heldActions.contains(.toggleIsland), "switching open/close off lets go of it at once")
        settings.shortcuts[.toggleIsland].isOn = true
        settings.shortcuts.assign(KeyCombo(kVK_ANSI_I, o), to: .toggleIsland)
        spin()
        equal(reg.held[A.toggleIsland.hotKeyID], KeyCombo(kVK_ANSI_I, o), "a new combo is held at once")
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }

    // MARK: - Persistence

    @MainActor
    static func persistence() {
        print("Persistence through AppSettings")
        let suite = "isle.shortcut-tests.\(UUID().uuidString)"
        let store = UserDefaults(suiteName: suite)!
        let settings = AppSettings(defaults: store)
        equal(settings.shortcuts, defaults, "a fresh install: defaults")
        check(store.object(forKey: "isle.shortcuts") == nil, "and nothing written")
        settings.shortcuts.assign(KeyCombo(kVK_ANSI_Y, o), to: .approve)
        settings.shortcuts[.deny].isOn = false
        let stored = store.string(forKey: "isle.shortcuts")
        check(stored?.contains(#""approve":{"combo":{"key":16,"mods":["option"]},"on":true}"#) == true,
              "stored as a JSON string `defaults read` can show", stored ?? "nil")
        let again = AppSettings(defaults: store)
        equal(again.shortcuts, settings.shortcuts, "a relaunch reads the same bindings")
        again.shortcuts.reset(.approve)
        again.shortcuts[.deny].isOn = true
        check(store.object(forKey: "isle.shortcuts") == nil, "back to the defaults: the key goes")
        store.set(#"{"approve":"#, forKey: "isle.shortcuts")
        equal(AppSettings(defaults: store).shortcuts, defaults, "a truncated value reads as the defaults")
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }
}
