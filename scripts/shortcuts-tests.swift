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
    var isAnyIslandExpanded = false
    var isIslandHeldOpen = false
    var calls: [String] = []
    func toggleIslandFromShortcut() { calls.append("toggle") }
    func openIslandFromShortcut() { calls.append("open") }
    func closeHeldIsland() { calls.append("close") }
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

func cmdFor(_ action: A, _ ctx: Ctx, visible: Bool) -> ShortcutCommand {
    ShortcutPlan.command(for: action, context: ctx, faceVisible: visible)
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
        check(!A.dismiss.defaultCombo.hasCommandingModifier, "the island's own Esc is bare — and never a user's combo")

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
        check(!A.configurable.contains(.dismiss), "Esc isn't in Settings")

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
        equal(mixed.combo(for: .dismiss), KeyCombo(kVK_Escape, 0), "Esc can't be rebound from the plist")
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
        equal(r.assign(KeyCombo(kVK_Escape, 0), to: .dismiss), .needsModifier, "Esc isn't recordable")
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
        check(ShortcutNotes.note(for: A.approve.defaultCombo) == nil, "⌃' has nothing to say")
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

        print("Held: the island's own Esc")
        equal(plan(Ctx(running: true, heldOpen: true)), [.toggleIsland, .dismiss], "held open by a shortcut: Esc")
        equal(plan(Ctx(running: true, composing: true, heldOpen: true)), [.toggleIsland], "not while a field takes keys")
        equal(ShortcutPlan.active(Ctx(running: true, heldOpen: true), bindings: defaults)[.dismiss], KeyCombo(kVK_Escape, 0),
              "it's bare Esc")

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
        equal(cmdFor(.approve, approvalCtx(), visible: true), .approve, "Approve, on screen")
        equal(cmdFor(.approve, approvalCtx(), visible: false), .approve, "Approve, island closed: one press, as the button")
        equal(cmdFor(.deny, approvalCtx(), visible: false), .deny, "Deny, island closed")
        equal(cmdFor(.option1, approvalCtx(), visible: true), .none, "an option key on an approval: nothing")

        print("Press: a guarded command (M17)")
        equal(cmdFor(.approve, approvalCtx(guarded: true), visible: false), .reveal,
              "island closed: the first press opens it to the command, and approves nothing")
        equal(cmdFor(.approve, approvalCtx(guarded: true), visible: true), .approve, "in view: the next press approves")
        equal(cmdFor(.deny, approvalCtx(guarded: true), visible: false), .deny, "Deny stays one press: refusing is safe")

        print("Press: Always…'s review")
        equal(cmdFor(.approve, approvalCtx(reviewing: true), visible: true), .confirmRemember, "Approve is the review's Confirm")
        equal(cmdFor(.deny, approvalCtx(reviewing: true), visible: true), .cancelRemember, "Deny is the review's Back")
        equal(cmdFor(.approve, approvalCtx(reviewing: true), visible: false), .reveal,
              "out of view, saving a rule is never a blind press: reveal")
        equal(cmdFor(.deny, approvalCtx(reviewing: true), visible: false), .reveal, "nor Back")

        print("Press: a question")
        equal(cmdFor(.option2, questionCtx(3), visible: true), .pick(1), "⌥2 on screen picks the second option")
        equal(cmdFor(.option2, questionCtx(3), visible: false), .reveal, "⌥2 unseen opens the island to the question")
        equal(cmdFor(.option4, questionCtx(3), visible: true), .none, "⌥4 with three options: nothing")
        equal(cmdFor(.approve, questionCtx(3), visible: true), .none, "⌥⏎ on a single-select: nothing (picking sends)")
        equal(cmdFor(.approve, questionCtx(3, multi: true), visible: true), .submit, "⌥⏎ on a multi-select: Done")
        equal(cmdFor(.approve, questionCtx(3, multi: true), visible: false), .reveal, "unseen: reveal")
        equal(cmdFor(.option1, questionCtx(3, multi: true), visible: true), .pick(0), "multi-select: ⌥1 toggles")
        equal(cmdFor(.deny, questionCtx(3), visible: true), .none, "⌥⎋ on a question: nothing")

        print("Press: a press that arrives late")
        var late = approvalCtx()
        late.answering = true
        equal(cmdFor(.approve, late, visible: true), .none, "already answered: nothing (never twice)")
        late = approvalCtx(); late.armed = false
        equal(cmdFor(.approve, late, visible: true), .none, "not armed: nothing")
        late = approvalCtx(); late.composing = true
        equal(cmdFor(.approve, late, visible: true), .none, "a field has the keys: nothing")
        equal(cmdFor(.approve, Ctx(running: true), visible: true), .none, "the request is gone: nothing")

        print("Press: the island")
        equal(cmdFor(.toggleIsland, Ctx(running: true), visible: false), .toggleIsland, "open/close")
        equal(cmdFor(.toggleIsland, approvalCtx(), visible: true), .toggleIsland, "open/close, a request or not")
        equal(cmdFor(.toggleIsland, Ctx(), visible: false), .none, "not running: nothing")
        equal(cmdFor(.dismiss, Ctx(running: true, heldOpen: true), visible: false), .closeHeld, "Esc closes a held island")
        equal(cmdFor(.dismiss, Ctx(running: true), visible: false), .none, "Esc does nothing once the hold has ended")
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
        host.isAnyIslandExpanded = false
        reg.press(.option1); spin()
        equal(host.calls, ["open"], "⌥1 with the island closed opens it")
        equal(vm.questionPicks.first ?? [], [], "and picks nothing")
        host.isAnyIslandExpanded = true
        reg.press(.option1); spin()
        equal(vm.questionPicks.first ?? [], [ClaudePanelFixture.multiSelect.options[0].label], "in view, ⌥1 toggles option 1")
        reg.press(.option1); spin()
        equal(vm.questionPicks.first ?? [], [], "and again, off")

        vm.applyPreviewFixture(ClaudePanelFixture(name: "g2", state: .needsApproval, action: "Bash", target: "git",
                                                  request: guarded))
        spin(ShortcutPlan.armDelay + 0.15)
        host.calls = []
        host.isAnyIslandExpanded = false
        reg.press(.approve); spin()
        equal(host.calls, ["open"], "⌥⏎ on a guarded command, island closed: opens it")
        check(!vm.isAnsweringRequest, "and sends nothing")
        check(vm.shortcutNotice == nil, "and claims nothing")

        print("End to end: the island")
        host.calls = []
        reg.press(.toggleIsland); spin()
        equal(host.calls, ["toggle"], "⌥⇥ toggles")
        host.isIslandHeldOpen = true
        shortcuts.refresh(); spin()
        check(reg.heldActions.contains(.dismiss), "held open: Esc taken")
        reg.press(.dismiss); spin()
        equal(host.calls.last, "close", "Esc closes it")
        host.isIslandHeldOpen = false
        shortcuts.refresh(); spin()
        check(!reg.heldActions.contains(.dismiss), "hold over: Esc given back")
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
