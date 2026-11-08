//
//  Shortcuts.swift
//
//  Global keyboard shortcuts: what each one is, what it's bound to, when it
//  is held, and what a press does. All of it pure — the registering is
//  `HotKeyCenter`'s, the doing `NotchShortcuts`'s — so the rules can be
//  checked without a keyboard, a window or a hook (scripts/test-shortcuts.sh).
//
//  The rules, in short:
//
//  - **Open or close the island** is the one shortcut held all the time.
//  - **Approve, Deny and the option keys are held only while a request is
//    waiting on you** — on the session the island is showing, unanswered,
//    with no field taking keys — and given back the moment it's answered,
//    withdrawn or gone. So they can be easy keys (⌃', ⌃⎋, ⌥1…⌥4) without
//    taking those keys from other apps the rest of the time. Easy, but never
//    a key anyone types for its meaning: a request waits up to five minutes,
//    and a keystroke meant for another app — a newline in another session's
//    terminal — must not answer it. Hence ⌃' and ⌃⎋, not ⌥⏎ (Claude Code's
//    newline) or ⌃⏎ (its send-now).
//  - They are taken half a second after the request appears, not at once:
//    a keystroke already on its way to another app as the request lands must reach
//    that app, not approve something nobody has seen.
//  - **A press does exactly what the face's button does**, through the same
//    view model call — but only on a request in front of you. Where it isn't
//    (closed, or auto-opened on a display you aren't on), or where the face
//    needs a look first and it hasn't had one, the press opens the island to
//    it where you are instead (see `ShortcutFace`, `ShortcutPlan.command`).
//

import Foundation

enum ShortcutAction: String, CaseIterable, Codable {
    case toggleIsland
    case approve
    case deny
    case option1
    case option2
    case option3
    case option4
    // No bare Esc to put a held island away: Esc is vim's and Claude Code's
    // interrupt, and a hold has no timeout. The open shortcut again, a
    // click elsewhere, or a visit and leaving put it away.

    /// The ones Settings lists, in its order: all of them.
    static let configurable: [ShortcutAction] = [.toggleIsland, .approve, .deny, .option1, .option2, .option3, .option4]
    static let options: [ShortcutAction] = [.option1, .option2, .option3, .option4]

    /// Held only while a request waits — not all the time.
    var isWhilePending: Bool {
        switch self {
        case .approve, .deny, .option1, .option2, .option3, .option4: return true
        case .toggleIsland: return false
        }
    }

    /// Which option, from 0, an option key picks.
    var optionIndex: Int? {
        switch self {
        case .option1: return 0
        case .option2: return 1
        case .option3: return 2
        case .option4: return 3
        default: return nil
        }
    }

    var title: String {
        switch self {
        case .toggleIsland: return "Open or close the island"
        case .approve: return "Approve"
        case .deny: return "Deny"
        case .option1: return "Option 1"
        case .option2: return "Option 2"
        case .option3: return "Option 3"
        case .option4: return "Option 4"
        }
    }

    /// The defaults: one modifier, and keys nobody types for their meaning —
    /// Approve and Deny are held while a request waits, so a keystroke meant
    /// for another app would answer it instead. Every one-modifier Return is
    /// someone's: ⌥⏎ is Claude Code's newline, ⌃⏎ its send-now, ⌘⏎ submits
    /// in half the web and toggles full screen in iTerm2 and Ghostty. So
    /// Approve is on the key beside Return, ⌃', and Deny on ⌃⎋ — neither
    /// types anything, and neither macOS nor Claude Code uses them. The
    /// options on their numbers. The island on ⌥⇥ rather than ⌥Space, which
    /// ChatGPT, Claude, Raycast and Alfred all reach for first (ChatGPT is on
    /// ⌥Space out of the box), where Option-Tab types nothing and no part of
    /// macOS uses it.
    var defaultCombo: KeyCombo {
        switch self {
        case .toggleIsland: return KeyCombo(0x30, KeyCombo.option)      // kVK_Tab
        case .approve: return KeyCombo(0x27, KeyCombo.control)          // kVK_ANSI_Quote
        case .deny: return KeyCombo(0x35, KeyCombo.control)             // kVK_Escape
        case .option1: return KeyCombo(0x12, KeyCombo.option)           // kVK_ANSI_1
        case .option2: return KeyCombo(0x13, KeyCombo.option)           // kVK_ANSI_2
        case .option3: return KeyCombo(0x14, KeyCombo.option)           // kVK_ANSI_3
        case .option4: return KeyCombo(0x15, KeyCombo.option)           // kVK_ANSI_4
        }
    }

    /// What the defaults were before the version-2 store (Approve on ⌥⏎,
    /// Deny on ⌥⎋): a version-1 entry on these keys was never recorded —
    /// they were the defaults then, which aren't stored — only switched
    /// off, so it reads as today's default (see `ShortcutBindings.decode`).
    var legacyDefaultCombo: KeyCombo? {
        switch self {
        case .approve: return KeyCombo(0x24, KeyCombo.option)           // kVK_Return
        case .deny: return KeyCombo(0x35, KeyCombo.option)              // kVK_Escape
        default: return nil
        }
    }

    /// The id the hot key is registered under: stable, nonzero, distinct.
    var hotKeyID: UInt32 { UInt32(Self.allCases.firstIndex(of: self)! + 1) }

    init?(hotKeyID: UInt32) {
        guard hotKeyID >= 1, Int(hotKeyID) <= Self.allCases.count else { return nil }
        self = Self.allCases[Int(hotKeyID) - 1]
    }
}

// MARK: - Bindings

/// One shortcut as the user has it: its keys, and whether it's on.
struct ShortcutBinding: Hashable, Codable {
    var combo: KeyCombo
    var isOn: Bool

    private enum CodingKeys: String, CodingKey { case combo, on }

    init(combo: KeyCombo, isOn: Bool = true) {
        self.combo = combo
        self.isOn = isOn
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        combo = try c.decode(KeyCombo.self, forKey: .combo)
        isOn = try c.decodeIfPresent(Bool.self, forKey: .on) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(combo, forKey: .combo)
        try c.encode(isOn, forKey: .on)
    }
}

/// Every configurable shortcut's binding. Stored as one JSON object keyed by
/// action, plus `"v"` (the store's version); anything missing, unreadable or
/// not a valid shortcut reads as that action's default, one action at a
/// time, so a bad entry never costs the others theirs.
///
/// Only what differs from the defaults is stored, so a change of default
/// reaches everyone who never recorded their own keys — and nobody who did.
struct ShortcutBindings: Equatable {
    private var entries: [ShortcutAction: ShortcutBinding] = [:]

    static let defaults = ShortcutBindings()

    subscript(action: ShortcutAction) -> ShortcutBinding {
        get { entries[action] ?? ShortcutBinding(combo: action.defaultCombo) }
        set {
            entries[action] = newValue == ShortcutBinding(combo: action.defaultCombo) ? nil : newValue
        }
    }

    /// The keys an action is on, when it's on.
    func combo(for action: ShortcutAction) -> KeyCombo? {
        let binding = self[action]
        return binding.isOn ? binding.combo : nil
    }

    func isDefault(_ action: ShortcutAction) -> Bool {
        self[action].combo == action.defaultCombo
    }

    mutating func reset(_ action: ShortcutAction) {
        let on = self[action].isOn
        self[action] = ShortcutBinding(combo: action.defaultCombo, isOn: on)
    }

    /// Another action already on `combo`, which would make one press mean
    /// two things. Off shortcuts count too: turning one back on mustn't
    /// make a clash out of nothing.
    func clash(for combo: KeyCombo, besides action: ShortcutAction) -> ShortcutAction? {
        ShortcutAction.configurable.first { $0 != action && self[$0].combo == combo }
    }

    /// What recording `combo` for `action` comes to.
    enum Assignment: Equatable {
        case assigned
        /// Needs ⌥, ⌃ or ⌘ — a bare key is typing.
        case needsModifier
        /// Already `ShortcutAction`'s.
        case clashes(ShortcutAction)
    }

    @discardableResult
    mutating func assign(_ combo: KeyCombo, to action: ShortcutAction) -> Assignment {
        guard combo.isValidShortcut else { return .needsModifier }
        if let other = clash(for: combo, besides: action) { return .clashes(other) }
        self[action] = ShortcutBinding(combo: combo, isOn: self[action].isOn)
        return .assigned
    }

    // MARK: Storage

    /// The store's version. 1 (no `"v"`): Approve and Deny defaulted to ⌥⏎
    /// and ⌥⎋. 2: ⌃' and ⌃⎋.
    static let storeVersion = 2

    func encoded() -> Data? {
        guard !entries.isEmpty else { return nil }
        var stored: [String: Any] = ["v": Self.storeVersion]
        let encoder = JSONEncoder()
        for (action, binding) in entries {
            guard let data = try? encoder.encode(binding),
                  let object = try? JSONSerialization.jsonObject(with: data) else { continue }
            stored[action.rawValue] = object
        }
        return try? JSONSerialization.data(withJSONObject: stored, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    static func decode(_ data: Data?) -> ShortcutBindings {
        var bindings = ShortcutBindings()
        guard let data,
              let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return bindings }
        let version = (raw["v"] as? Int) ?? 1
        for (key, value) in raw {
            guard let action = ShortcutAction(rawValue: key),
                  let entry = try? JSONSerialization.data(withJSONObject: value),
                  var binding = try? JSONDecoder().decode(ShortcutBinding.self, from: entry),
                  binding.combo.isValidShortcut
            else { continue }
            // Version 1 stored the old default's keys only with the switch
            // off: the keys were never chosen, so they move to the new ones.
            if version < 2, binding.combo == action.legacyDefaultCombo {
                binding.combo = action.defaultCombo
            }
            bindings[action] = binding
        }
        // Two actions on one combo (an edited plist, or a recording that
        // has since become another action's default): keys someone chose
        // win over a default, and among those the earlier in Settings
        // order. The loser goes back to its default — or, if that's taken
        // too, off — so a press never means two things.
        var seen: [KeyCombo: ShortcutAction] = [:]
        let chosen = ShortcutAction.configurable.filter { !bindings.isDefault($0) }
        let defaulted = ShortcutAction.configurable.filter { bindings.isDefault($0) }
        for action in chosen + defaulted {
            if seen[bindings[action].combo] != nil {
                let on = bindings[action].isOn
                bindings[action] = ShortcutBinding(combo: action.defaultCombo, isOn: on)
                if seen[action.defaultCombo] != nil {
                    bindings.entries[action] = ShortcutBinding(combo: action.defaultCombo, isOn: false)
                }
            }
            seen[bindings[action].combo] = action
        }
        return bindings
    }
}

// MARK: - Known clashes

/// Other well-known owners of a combo, said as a note under its row: a
/// registration can succeed and still lose the key to an app that took it
/// first, which the registration can't report. Only ones worth saying.
enum ShortcutNotes {
    static func note(for combo: KeyCombo) -> String? {
        let o = KeyCombo.option, c = KeyCombo.control, cmd = KeyCombo.command
        switch (Int(combo.keyCode), combo.modifiers) {
        case (0x31, o): return "ChatGPT, Claude, Raycast and Alfred often use ⌥Space; whichever app took it first may keep it."
        case (0x31, cmd): return "macOS uses ⌘Space for Spotlight."
        case (0x31, c): return "macOS uses ⌃Space to switch input sources."
        case (0x31, o | cmd): return "macOS uses ⌥⌘Space for Finder search."
        case (0x30, cmd): return "macOS uses ⌘⇥ to switch apps."
        case (0x30, o): return "AltTab and other window switchers use ⌥⇥, if you have one."
        case (0x35, o): return "Also macOS’s Speak Selection key, when that’s on (Accessibility › Spoken Content)."
        case (0x35, o | cmd): return "macOS uses ⌥⌘⎋ for Force Quit."
        case (0x24, o): return "Claude Code uses ⌥⏎ for a newline: while a request waits, one typed in any terminal would answer it instead."
        case (0x24, c): return "Claude Code uses ⌃⏎ to send a message now: while a request waits, one typed in any terminal would answer it instead."
        case (0x33, c): return "Many terminals and editors delete a word on ⌃⌫."
        // Not a clash: the default Approve, whose ' is a speck in the field.
        case (0x27, c): return "Control and the key just left of Return."
        default:
            if combo.modifiers == cmd || combo.modifiers == cmd | KeyCombo.shift {
                return "⌘ shortcuts belong to every app’s menus; this one would be Isle’s everywhere."
            }
            return nil
        }
    }
}

// MARK: - When they're held

/// What the shortcuts need to know about the moment.
struct ShortcutContext: Equatable {
    enum Request: Equatable {
        /// An approval: whether Isle's guard is why it asks, and whether the
        /// face is reviewing "Always…".
        case approval(guarded: Bool, reviewing: Bool)
        /// The question on screen: how many options, and whether it takes
        /// more than one.
        case question(options: Int, multiSelect: Bool)
    }

    /// The islands are up.
    var running = false
    /// The request the island is showing — the one the face's buttons answer.
    var request: Request? = nil
    /// The request has been up long enough to be meant (`ShortcutPlan.armDelay`).
    var armed = false
    /// An answer has gone and is waiting for the hook to take it.
    var answering = false
    /// A field in the island has the keyboard.
    var composing = false
}

/// Where the open island is, as far as the user goes. Read off the islands
/// by their owner (`ShortcutIslandHost`).
enum ShortcutIslandPresence: Equatable {
    /// No island open (a file drag's drop face doesn't count).
    case closed
    /// Open only on displays the pointer isn't on, and nobody went to it:
    /// an alert's auto-open on a screen the user may not be looking at.
    case elsewhere
    /// Open on the display the pointer is on.
    case pointerScreen
    /// Open because the user went to it: the pointer is in it, or a
    /// shortcut opened it.
    case visited
}

/// The request's face, as a press sees it.
enum ShortcutFace: Equatable {
    /// Not in front of the user: the island is closed, on another face or
    /// the list, or auto-opened on a display the pointer isn't on and never
    /// visited.
    case hidden
    /// In front of the user, but for less than `ShortcutPlan.seenDelay`.
    case shown
    /// In front of the user for at least `ShortcutPlan.seenDelay` — looked at,
    /// as near as Isle can tell.
    case seen
}

/// When the request's face came up in front of the user, so a press can
/// tell `shown` from `seen`. Fed on every look at the moment (`update`);
/// pure, so the tests drive it with their own clock.
///
/// In front of the user: an island is open on the Claude face with this
/// request on it, and it's on the pointer's display, or the user went to it
/// (hovered it, or opened it by shortcut). Having gone to it once, the
/// request's auto-opened panel stays in front of them when the pointer
/// moves to another display. The clock starts when it comes up and starts
/// again whenever it goes down, a new request takes its place, or a press
/// had to reveal it (`restart`).
struct ShortcutFaceTracker {
    private(set) var request: String?
    private(set) var since: Date?
    private(set) var visited = false

    mutating func update(request id: String?, showsFace: Bool, presence: ShortcutIslandPresence,
                         now: Date) -> ShortcutFace {
        if id != request {
            request = id
            since = nil
            visited = false
        }
        guard id != nil else { return .hidden }
        if showsFace, presence == .visited { visited = true }
        let inView: Bool
        switch presence {
        case .closed: inView = false
        case .elsewhere: inView = showsFace && visited
        case .pointerScreen, .visited: inView = showsFace
        }
        guard inView else {
            since = nil
            return .hidden
        }
        if since == nil { since = now }
        return now.timeIntervalSince(since!) >= ShortcutPlan.seenDelay ? .seen : .shown
    }

    /// A press had to reveal the request: the look it was waiting for
    /// starts now, whatever was on screen before.
    mutating func restart(now: Date) {
        if since != nil { since = now }
    }
}

/// What a press comes to.
enum ShortcutCommand: Equatable {
    case approve
    case deny
    /// The review's Confirm: allow, and save what Always… offered.
    case confirmRemember
    /// The review's Back.
    case cancelRemember
    /// Tap option `n` (from 0) of the question on screen.
    case pick(Int)
    /// Next / Done on a multi-select.
    case submit
    /// Open the island to the request, and do nothing else yet.
    case reveal
    case toggleIsland
    case none
}

enum ShortcutPlan {
    /// How long a request is up before its keys are taken.
    static let armDelay: TimeInterval = 0.5
    /// How long the request's face must have been in front of the user
    /// before a press that needs a look first counts as made after one.
    static let seenDelay: TimeInterval = 0.5

    /// The shortcuts to hold right now, and their keys.
    static func active(_ context: ShortcutContext, bindings: ShortcutBindings) -> [ShortcutAction: KeyCombo] {
        guard context.running else { return [:] }
        var wanted: [ShortcutAction] = [.toggleIsland]
        if let request = context.request, context.armed, !context.answering, !context.composing {
            switch request {
            case .approval:
                wanted += [.approve, .deny]
            case .question(let options, let multiSelect):
                wanted += ShortcutAction.options.prefix(max(0, min(options, 4)))
                if multiSelect { wanted.append(.approve) }
            }
        }
        var active: [ShortcutAction: KeyCombo] = [:]
        for action in wanted {
            guard let combo = bindings.combo(for: action) else { continue }
            // Never two actions on one key — the bindings refuse it.
            guard !active.values.contains(combo) else { continue }
            active[action] = combo
        }
        return active
    }

    /// What pressing `action` does, with the request's face where `face`
    /// says.
    ///
    /// Mirrors the face, on a request in front of you:
    /// - **Approve** is one press with the request shown where you are. With
    ///   the island closed, or auto-opened on a display you aren't on, the
    ///   first press opens it there and approves nothing.
    /// - **A guarded command** asks every time so that someone looks at it:
    ///   Approve takes it only once it's been `seen` — in front of you for
    ///   half a second. Before that a press reveals it (again) and the half
    ///   second starts over, so neither an alert's auto-open nor a fast
    ///   double-tap on a closed island approves it unread.
    /// - **Deny** stays one press: refusing is never what the guard is for.
    /// - **Always…'s review** and **a question's options** need `seen` too:
    ///   saving a rule, or picking an answer, is never a blind press.
    static func command(for action: ShortcutAction, context: ShortcutContext, face: ShortcutFace) -> ShortcutCommand {
        switch action {
        case .toggleIsland:
            return context.running ? .toggleIsland : .none
        default:
            break
        }
        guard context.running, let request = context.request, context.armed,
              !context.answering, !context.composing else { return .none }
        switch request {
        case .approval(let guarded, let reviewing):
            if reviewing {
                guard face == .seen else { return action == .approve || action == .deny ? .reveal : .none }
                switch action {
                case .approve: return .confirmRemember
                case .deny: return .cancelRemember
                default: return .none
                }
            }
            switch action {
            case .approve:
                if guarded { return face == .seen ? .approve : .reveal }
                return face == .hidden ? .reveal : .approve
            case .deny: return .deny
            default: return .none
            }
        case .question(let options, let multiSelect):
            if let index = action.optionIndex {
                guard index < options else { return .none }
                return face == .seen ? .pick(index) : .reveal
            }
            if action == .approve, multiSelect {
                return face == .seen ? .submit : .reveal
            }
            return .none
        }
    }
}

// MARK: - Hints on the buttons

/// The keys the face's buttons carry beside their words: "Approve ⌃'",
/// "Deny ⌃⎋", "⌥1" at an option's end. Faint, and only ever the truth:
///
/// - **Which keys** (`keys`) are the user's own bindings, as Settings has
///   them, for the shortcuts that are on. A shortcut turned off has no hint
///   and no room kept for one. The room a hint takes is kept whenever its key
///   is bound, shown or not, so a hint coming or going never moves a button.
/// - **Shown** (`live`) only while a press would do what the button does:
///   held (taken from the other apps, not refused), armed, and — for a
///   guarded command, Always…'s review and a question's options — the face
///   seen. Until then the hint's room is empty, since a press would only
///   reveal the request, or reach another app.
struct ShortcutHints: Equatable {
    var keys: [ShortcutAction: String] = [:]
    var live: Set<ShortcutAction> = []

    /// The keys an action's button shows, nil when it has none bound.
    func key(_ action: ShortcutAction) -> String? { keys[action] }

    func isLive(_ action: ShortcutAction) -> Bool { live.contains(action) && keys[action] != nil }

    /// Every pending-only shortcut that's on, as the face writes its keys.
    static func keys(_ bindings: ShortcutBindings,
                     display: (KeyCombo) -> String = { $0.display() }) -> [ShortcutAction: String] {
        var keys: [ShortcutAction: String] = [:]
        for action in ShortcutAction.configurable where action.isWhilePending {
            if let combo = bindings.combo(for: action) { keys[action] = display(combo) }
        }
        return keys
    }
}

extension ShortcutPlan {
    /// The held shortcuts a press of which would do its button's own thing
    /// right now — not reveal the request, not nothing.
    static func live(_ context: ShortcutContext, face: ShortcutFace,
                     held: [ShortcutAction: KeyCombo]) -> Set<ShortcutAction> {
        Set(held.keys.filter { action in
            switch command(for: action, context: context, face: face) {
            case .approve, .deny, .confirmRemember, .cancelRemember, .pick, .submit: return true
            case .reveal, .toggleIsland, .none: return false
            }
        })
    }
}
