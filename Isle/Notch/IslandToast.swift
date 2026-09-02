//
//  IslandToast.swift
//
//  The display model for a momentary message in the collapsed island.
//
//  A toast is deliberately *not* a third seat in the collapsed island. Music
//  and Claude each hold a standing side of the camera cutout (see
//  `NotchViewModel.collapsedSideWidths`); a toast is transient by nature —
//  a charger going in, a meeting about to start — so it borrows the whole
//  island for a few seconds and hands it straight back. That's the only
//  reason this is a value type with a pre-rendered `text` rather than a
//  state enum the views switch on.
//
//  Two sources produce them today: the power monitors (`PowerToast.swift`)
//  and the calendar/reminders monitor (`AgendaToast.swift`). Each supplies
//  its own factory methods in an extension; this file is the shape they
//  share and the formatting they both need to fit the island.
//

import SwiftUI

/// What a toast draws to the left of the camera cutout. An enum rather than a
/// symbol name because one of the glyphs isn't a system symbol: SF Symbols has
/// no Bluetooth mark, so that case is drawn by `BluetoothRune`.
enum ToastGlyph: Equatable {
    case symbol(String)
    case bluetoothRune
}

struct IslandToast: Equatable, Identifiable {
    /// What produced the toast. Used for coalescing — a second event of the
    /// same kind replaces the first rather than queueing behind it, so
    /// jiggling a loose MagSafe connector can't stack up six toasts.
    enum Kind: Equatable {
        case pluggedIn
        case unplugged
        case fullyCharged
        case lowBattery
        /// A Bluetooth peripheral's level, keyed by address so two different
        /// devices connecting in quick succession don't coalesce into one.
        case device(address: String)
        case lowPowerMode
        /// A calendar event about to start, keyed by occurrence so two
        /// meetings at the same time both get their say.
        case event(key: String)
        /// A reminder coming due, keyed the same way.
        case reminder(key: String)
    }

    /// Which Settings switch governs a message. The split is by what is being
    /// reported on, not by how the reading was obtained: a device level is
    /// about a peripheral whatever prompted the read, so a level surfaced by
    /// plugging the Mac in is still a device update.
    enum Gate: Equatable {
        case macBattery
        case deviceBattery
        case calendar
        case reminders
    }

    let id = UUID()
    let kind: Kind
    let glyph: ToastGlyph
    /// Already formatted for display — see the factory methods in
    /// `PowerToast.swift` and `AgendaToast.swift`.
    let text: String
    let tint: Color
    let gate: Gate

    /// The SF Symbol name, when this toast uses one. Nil for the hand-drawn
    /// rune — which is exactly the distinction callers need to make.
    var symbolName: String? {
        if case let .symbol(name) = glyph { return name }
        return nil
    }

    static func == (lhs: IslandToast, rhs: IslandToast) -> Bool {
        lhs.id == rhs.id
    }

    /// True when this toast and another are the same *kind* of message, and so
    /// should replace rather than queue. Not `==`, which is identity.
    func coalesces(with other: IslandToast) -> Bool {
        kind == other.kind
    }
}

// MARK: - Formatting

extension IslandToast {
    /// Plain white, for the states that carry no colour of their own.
    /// Deliberately a small palette across every source: the island is 10pt
    /// text on black and colour is the only other channel.
    static let neutral = Color(white: 0.92)

    /// Widest the toast's text is allowed to get, in points at the collapsed
    /// status font. The island sizes itself to its content, so an unbounded
    /// string would grow the collapsed pill toward the expanded panel's 520pt
    /// and stop reading as a glance. Anything longer falls back to the short
    /// form — which is why every toast has one.
    static let maxTextWidth: CGFloat = 150

    /// Prefers the fuller string, but only when it fits the island's budget.
    /// Nothing is elided mid-string: it's the whole optional clause or none.
    static func fit(short: String, long: String?) -> String {
        guard let long, width(of: long) <= maxTextWidth else { return short }
        return long
    }

    /// A name plus a suffix, trimmed so the pair fits the island's budget.
    /// Names are written by their owners — a device is genuinely called
    /// "Matthew's AirPods Pro Max (2nd generation)", a meeting "Weekly sync
    /// with the platform team (optional)" — and the suffix is the part that
    /// must survive, so the name yields to it.
    ///
    /// Trimmed by measured width rather than character count — a name in wide
    /// glyphs and one in narrow glyphs don't fit the same number of them.
    static func name(_ name: String, beside suffix: String) -> String {
        let budget = maxTextWidth - width(of: suffix)
        guard width(of: name) > budget else { return name + suffix }

        var trimmed = Substring(name)
        while !trimmed.isEmpty && width(of: trimmed + "…") > budget {
            trimmed = trimmed.dropLast()
        }
        return trimmed.trimmingCharacters(in: .whitespaces) + "…" + suffix
    }

    /// Measured at the collapsed status font, so `fit` and the island's width
    /// calculation agree about how wide the toast is.
    private static let font = NSFont.systemFont(
        ofSize: CollapsedSize.statusFontSize, weight: .semibold
    )

    /// Cached, for the same reason `NotchViewModel.textWidth` is: the island's
    /// width is read several times per body evaluation while a toast is up,
    /// and each read laid the string out again. Toast strings carry live
    /// numbers ("Charging · 42%") so the set grows slowly; it's emptied past a
    /// modest size rather than left to accumulate for the life of the process.
    private static var widthCache: [String: CGFloat] = [:]

    static func width(of string: String) -> CGFloat {
        guard !string.isEmpty else { return 0 }
        if let cached = widthCache[string] { return cached }
        if widthCache.count >= 256 { widthCache.removeAll(keepingCapacity: true) }
        let width = ceil((string as NSString).size(withAttributes: [.font: font]).width)
        widthCache[string] = width
        return width
    }
}
