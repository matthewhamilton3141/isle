//
//  KeyCombo.swift
//
//  One global keyboard shortcut: a key, by its position on the keyboard (a
//  Carbon virtual key code, which is what `RegisterEventHotKey` takes), and
//  the modifiers held with it (Carbon's masks). Pure value: how it's written
//  down, read back and shown. Registering it is `HotKeyCenter`'s job.
//
//  Stored as JSON — `{"key":36,"mods":["option"]}` — so `defaults read`
//  shows something a person can read, and a value from a newer build that
//  this one can't make sense of reads as absent rather than as a wrong key.
//

import Carbon.HIToolbox
import Foundation

struct KeyCombo: Hashable, Codable {
    /// The key's virtual key code (`kVK_…`): a position, not a character, so
    /// the same combo stays on the same key whatever the layout types there.
    let keyCode: UInt32
    /// Carbon modifier masks (`optionKey`, `cmdKey`, …), and only those four.
    let modifiers: UInt32

    static let control = UInt32(controlKey)
    static let option = UInt32(optionKey)
    static let shift = UInt32(shiftKey)
    static let command = UInt32(cmdKey)
    static let allModifiers = control | option | shift | command

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers & Self.allModifiers
    }

    init(_ keyCode: Int, _ modifiers: UInt32) {
        self.init(keyCode: UInt32(keyCode), modifiers: modifiers)
    }

    // MARK: - Rules

    /// What a global shortcut must hold: ⌥, ⌃ or ⌘. A bare key, or one with
    /// only ⇧, is typing — taking it from every app would break writing.
    /// (The island's own Esc, taken only while a shortcut holds it open, is
    /// the one bare key, and it is never a user's combo.)
    var hasCommandingModifier: Bool {
        modifiers & (Self.option | Self.control | Self.command) != 0
    }

    /// Keys that are never a shortcut's key: the modifiers themselves, Caps
    /// Lock and Fn, which arrive as flag changes rather than key presses.
    var isModifierKey: Bool {
        switch Int(keyCode) {
        case kVK_Command, kVK_RightCommand, kVK_Shift, kVK_RightShift, kVK_Option, kVK_RightOption,
             kVK_Control, kVK_RightControl, kVK_CapsLock, kVK_Function:
            return true
        default:
            return false
        }
    }

    /// Something the recorder may accept.
    var isValidShortcut: Bool { hasCommandingModifier && !isModifierKey }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey { case key, mods }

    private static let modifierNames: [(String, UInt32)] = [
        ("control", control), ("option", option), ("shift", shift), ("command", command),
    ]

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(keyCode, forKey: .key)
        try c.encode(Self.modifierNames.filter { modifiers & $0.1 != 0 }.map(\.0), forKey: .mods)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let key = try c.decode(UInt32.self, forKey: .key)
        guard key <= 0x7F else {
            throw DecodingError.dataCorruptedError(forKey: .key, in: c, debugDescription: "not a key code")
        }
        var mods: UInt32 = 0
        for name in try c.decode([String].self, forKey: .mods) {
            guard let mask = Self.modifierNames.first(where: { $0.0 == name })?.1 else {
                throw DecodingError.dataCorruptedError(forKey: .mods, in: c, debugDescription: "unknown modifier \(name)")
            }
            mods |= mask
        }
        self.init(keyCode: key, modifiers: mods)
    }

    // MARK: - From AppKit

    /// The combo a key press in the recorder makes: `flags` is
    /// `NSEvent.ModifierFlags.rawValue`, whose device-independent bits are
    /// the same on every Mac.
    init(keyCode: UInt16, cocoaFlags flags: UInt) {
        var mods: UInt32 = 0
        if flags & (1 << 18) != 0 { mods |= Self.control }   // .control
        if flags & (1 << 19) != 0 { mods |= Self.option }    // .option
        if flags & (1 << 17) != 0 { mods |= Self.shift }     // .shift
        if flags & (1 << 20) != 0 { mods |= Self.command }   // .command
        self.init(keyCode: UInt32(keyCode), modifiers: mods)
    }

    // MARK: - Display

    /// "⌥⏎", "⌃⌥⇧⌘K": the modifiers in the order macOS menus write them,
    /// then the key. `character` names a printing key by what the current
    /// layout types there; nil falls back to the US layout's keycap.
    func display(character: (UInt32) -> String? = KeyCombo.layoutCharacter) -> String {
        modifierSymbols + Self.keyName(keyCode, character: character)
    }

    var modifierSymbols: String {
        var s = ""
        if modifiers & Self.control != 0 { s += "⌃" }
        if modifiers & Self.option != 0 { s += "⌥" }
        if modifiers & Self.shift != 0 { s += "⇧" }
        if modifiers & Self.command != 0 { s += "⌘" }
        return s
    }

    /// Read aloud, for VoiceOver and tooltips: "Option-Return".
    var spoken: String {
        var parts: [String] = []
        if modifiers & Self.control != 0 { parts.append("Control") }
        if modifiers & Self.option != 0 { parts.append("Option") }
        if modifiers & Self.shift != 0 { parts.append("Shift") }
        if modifiers & Self.command != 0 { parts.append("Command") }
        let key = Self.specialNames[Int(keyCode)]?.spoken
            ?? Self.usKeycaps[Int(keyCode)].map { $0.uppercased() }
            ?? "Key \(keyCode)"
        parts.append(key)
        return parts.joined(separator: "-")
    }

    static func keyName(_ keyCode: UInt32, character: (UInt32) -> String?) -> String {
        if let special = specialNames[Int(keyCode)] { return special.symbol }
        // A layout's dead key or control character says nothing on a keycap.
        if let typed = character(keyCode), let first = typed.unicodeScalars.first,
           !CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains(first) {
            return typed.uppercased()
        }
        return usKeycaps[Int(keyCode)]?.uppercased() ?? "#\(keyCode)"
    }

    /// Keys that type nothing, or whitespace, by their symbol.
    private static let specialNames: [Int: (symbol: String, spoken: String)] = {
        var names: [Int: (String, String)] = [
            kVK_Return: ("⏎", "Return"), kVK_ANSI_KeypadEnter: ("⌤", "Enter"),
            kVK_Escape: ("⎋", "Escape"), kVK_Tab: ("⇥", "Tab"), kVK_Space: ("Space", "Space"),
            kVK_Delete: ("⌫", "Delete"), kVK_ForwardDelete: ("⌦", "Forward Delete"),
            kVK_LeftArrow: ("←", "Left Arrow"), kVK_RightArrow: ("→", "Right Arrow"),
            kVK_UpArrow: ("↑", "Up Arrow"), kVK_DownArrow: ("↓", "Down Arrow"),
            kVK_Home: ("↖", "Home"), kVK_End: ("↘", "End"),
            kVK_PageUp: ("⇞", "Page Up"), kVK_PageDown: ("⇟", "Page Down"),
        ]
        let fKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                     kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
        for (i, code) in fKeys.enumerated() { names[code] = ("F\(i + 1)", "F\(i + 1)") }
        return names
    }()

    /// What a US keyboard's keycaps say, for when the layout can't be asked.
    static let usKeycaps: [Int: String] = [
        kVK_ANSI_A: "a", kVK_ANSI_B: "b", kVK_ANSI_C: "c", kVK_ANSI_D: "d", kVK_ANSI_E: "e",
        kVK_ANSI_F: "f", kVK_ANSI_G: "g", kVK_ANSI_H: "h", kVK_ANSI_I: "i", kVK_ANSI_J: "j",
        kVK_ANSI_K: "k", kVK_ANSI_L: "l", kVK_ANSI_M: "m", kVK_ANSI_N: "n", kVK_ANSI_O: "o",
        kVK_ANSI_P: "p", kVK_ANSI_Q: "q", kVK_ANSI_R: "r", kVK_ANSI_S: "s", kVK_ANSI_T: "t",
        kVK_ANSI_U: "u", kVK_ANSI_V: "v", kVK_ANSI_W: "w", kVK_ANSI_X: "x", kVK_ANSI_Y: "y",
        kVK_ANSI_Z: "z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
        kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_ANSI_Grave: "`", kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[",
        kVK_ANSI_RightBracket: "]", kVK_ANSI_Backslash: "\\", kVK_ANSI_Semicolon: ";",
        kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/",
        kVK_ISO_Section: "§",
    ]

    /// What the current keyboard layout types on `keyCode` with no
    /// modifiers, or nil when the layout can't say (no Unicode layout data).
    static func layoutCharacter(_ keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        return data.withUnsafeBytes { buffer -> String? in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var deadKeys: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                                        UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                        &deadKeys, chars.count, &length, &chars)
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: chars, count: length)
        }
    }
}
