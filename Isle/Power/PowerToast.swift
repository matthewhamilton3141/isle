//
//  PowerToast.swift
//
//  The display model for a momentary power/battery message in the collapsed
//  island, plus the two snapshots the monitors diff to produce them.
//
//  A toast is deliberately *not* a third seat in the collapsed island. Music
//  and Claude each hold a standing side of the camera cutout (see
//  `NotchViewModel.collapsedSideWidths`); a power event is transient by
//  nature, so it borrows the whole island for a few seconds and hands it
//  straight back. That's the only reason this is a value type with a
//  pre-rendered `text` rather than a state enum the views switch on.
//
//  Everything here reports what the APIs actually returned. Time-to-full and
//  time-to-empty are IOKit values, and IOKit says "still calculating" for the
//  first minutes after a plug-in — so those are `nil` then and simply absent
//  from the text, never estimated.
//

import SwiftUI

// MARK: - Toast

/// What a toast draws to the left of the camera cutout. An enum rather than a
/// symbol name because one of the glyphs isn't a system symbol: SF Symbols has
/// no Bluetooth mark, so that case is drawn by `BluetoothRune`.
enum PowerGlyph: Equatable {
    case symbol(String)
    case bluetoothRune
}

struct PowerToast: Equatable, Identifiable {
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
    }

    let id = UUID()
    let kind: Kind
    let glyph: PowerGlyph
    /// Already formatted for display — see `PowerToast` factory methods below.
    let text: String
    let tint: Color

    /// The SF Symbol name, when this toast uses one. Nil for the hand-drawn
    /// rune — which is exactly the distinction callers need to make.
    var symbolName: String? {
        if case let .symbol(name) = glyph { return name }
        return nil
    }

    /// Which of the two settings governs this message. The split is by the
    /// hardware being reported on, not by how the reading was obtained: a
    /// device level is about a peripheral whatever prompted the read, so a
    /// level surfaced by plugging the Mac in is still a device update.
    var isDeviceUpdate: Bool {
        if case .device = kind { return true }
        return false
    }

    static func == (lhs: PowerToast, rhs: PowerToast) -> Bool {
        lhs.id == rhs.id
    }

    /// True when this toast and another are the same *kind* of message, and so
    /// should replace rather than queue. Not `==`, which is identity.
    func coalesces(with other: PowerToast) -> Bool {
        kind == other.kind
    }
}

// MARK: - Copy

extension PowerToast {
    /// Warm amber for charging, plain white for the neutral states, red for
    /// the two "you should do something" ones. Deliberately a small palette:
    /// the island is 10pt text on black and colour is the only other channel.
    private static let charge = Color(hex: "#5BD16A")
    private static let neutral = Color(white: 0.92)
    private static let warn = Color(hex: "#E8842B")
    private static let alarm = Color(hex: "#E5484D")

    static func pluggedIn(percent: Int, minutesToFull: Int?) -> PowerToast {
        PowerToast(
            kind: .pluggedIn,
            glyph: .symbol("bolt.fill"),
            text: fit(
                short: "Charging · \(percent)%",
                long: minutesToFull.map { "Charging · \(percent)% · \(clock($0)) to full" }
            ),
            tint: charge
        )
    }

    static func unplugged(percent: Int, minutesToEmpty: Int?) -> PowerToast {
        PowerToast(
            kind: .unplugged,
            glyph: .symbol(batterySymbol(for: percent)),
            text: fit(
                short: "On battery · \(percent)%",
                long: minutesToEmpty.map { "On battery · \(percent)% · \(clock($0)) left" }
            ),
            tint: neutral
        )
    }

    static func fullyCharged() -> PowerToast {
        PowerToast(
            kind: .fullyCharged,
            glyph: .symbol("battery.100percent.bolt"),
            text: "Fully charged",
            tint: charge
        )
    }

    static func lowBattery(percent: Int) -> PowerToast {
        PowerToast(
            kind: .lowBattery,
            glyph: .symbol(batterySymbol(for: percent)),
            text: "Low battery · \(percent)%",
            tint: percent <= 10 ? alarm : warn
        )
    }

    /// A filled battery, no bolt. The bolt is macOS's glyph for *plugged in
    /// and charging*, so wearing it here made a Low Power Mode toast read as a
    /// charging one — the island appearing to think a battery-powered Mac was
    /// on the adapter. macOS's own Low Power Mode indicator is the ordinary
    /// battery tinted yellow for the same reason: the bolt means charging and
    /// nothing else.
    ///
    /// Orange rather than that yellow, matching the warm tint Isle already
    /// uses for "worth noticing, not urgent" — the same one a peripheral under
    /// 20% gets.
    /// Takes the level so the glyph tracks the real battery through the same
    /// `batterySymbol` ladder the on-battery and low-battery toasts use — a
    /// Mac at 30% shows a nearly empty battery here too, rather than a full
    /// one that contradicts the reason Low Power Mode came on.
    static func lowPowerMode(on: Bool, percent: Int) -> PowerToast {
        PowerToast(
            kind: .lowPowerMode,
            glyph: .symbol(batterySymbol(for: percent)),
            text: on ? "Low Power On" : "Low Power Off",
            tint: on ? warn : neutral
        )
    }

    static func device(_ battery: PeripheralBattery) -> PowerToast {
        PowerToast(
            kind: .device(address: battery.address),
            glyph: battery.glyph,
            // The device's own name, trimmed to keep the island sane — some
            // are genuinely called "Matthew's AirPods Pro Max (2nd gen)".
            text: name(battery.name, beside: " · \(battery.percent)%"),
            tint: battery.percent <= PeripheralBattery.lowThreshold ? warn : neutral
        )
    }

    // MARK: - Formatting

    /// Widest the toast's text is allowed to get, in points at the collapsed
    /// status font. The island sizes itself to its content, so an unbounded
    /// string would grow the collapsed pill toward the expanded panel's 520pt
    /// and stop reading as a glance. Anything longer falls back to the short
    /// form — which is why every toast has one.
    static let maxTextWidth: CGFloat = 150

    /// Prefers the fuller string, but only when it fits the island's budget.
    /// Nothing is elided mid-string: it's the whole optional clause or none.
    private static func fit(short: String, long: String?) -> String {
        guard let long, PowerToast.width(of: long) <= maxTextWidth else { return short }
        return long
    }

    /// `h:mm`, matching how macOS's own battery menu writes a duration.
    private static func clock(_ minutes: Int) -> String {
        String(format: "%d:%02d", minutes / 60, minutes % 60)
    }

    /// A device's name plus its level, trimmed so the pair fits the island's
    /// budget. Devices are named by their owner and some are genuinely called
    /// "Matthew's AirPods Pro Max (2nd generation)"; the level is the part
    /// that must survive, so the name yields to it.
    ///
    /// Trimmed by measured width rather than character count — a name in wide
    /// glyphs and one in narrow glyphs don't fit the same number of them.
    private static func name(_ name: String, beside suffix: String) -> String {
        let budget = maxTextWidth - width(of: suffix)
        guard width(of: name) > budget else { return name + suffix }

        var trimmed = Substring(name)
        while !trimmed.isEmpty && width(of: trimmed + "…") > budget {
            trimmed = trimmed.dropLast()
        }
        return trimmed.trimmingCharacters(in: .whitespaces) + "…" + suffix
    }

    /// Rounded down to the nearest fifth, which is how SF Symbols quantises
    /// its battery glyphs — there is no `battery.42percent`.
    private static func batterySymbol(for percent: Int) -> String {
        switch percent {
        case 88...: return "battery.100percent"
        case 63...: return "battery.75percent"
        case 38...: return "battery.50percent"
        case 13...: return "battery.25percent"
        default:    return "battery.0percent"
        }
    }

    /// Measured at the collapsed status font, so `fit` and the island's width
    /// calculation agree about how wide the toast is.
    private static let font = NSFont.systemFont(
        ofSize: CollapsedSize.statusFontSize, weight: .semibold
    )

    static func width(of string: String) -> CGFloat {
        guard !string.isEmpty else { return 0 }
        return ceil((string as NSString).size(withAttributes: [.font: font]).width)
    }
}

// MARK: - Mac battery

/// One reading of the Mac's own power source. Diffed against the previous
/// reading to decide whether anything worth saying happened — see
/// `PowerMonitor.events(from:to:)`.
struct MacPowerSnapshot: Equatable {
    /// 0...100. IOKit reports capacity against a max that is itself 100 on
    /// every Mac observed, but it's normalised rather than assumed.
    var percent: Int

    /// The battery is actively taking charge. Distinct from `isPluggedIn`:
    /// a Mac held at 80% by optimised charging is plugged in and not charging.
    var isCharging: Bool

    /// Running on the adapter rather than the battery.
    var isPluggedIn: Bool

    /// Minutes, and only when IOKit gave a real figure. It returns -1 for
    /// "still calculating" and 0 when the field doesn't apply, and both of
    /// those become `nil` here rather than a number Isle can't stand behind.
    var minutesToFull: Int?
    var minutesToEmpty: Int?

    /// Read from `ProcessInfo`, not IOKit — it arrives on its own notification
    /// (`NSProcessInfoPowerStateDidChange`) rather than through the power
    /// source callback. Carried in the snapshot anyway so it diffs through the
    /// same pure function as everything else, instead of becoming a side
    /// channel with its own comparison logic.
    var isLowPowerMode: Bool
}

// MARK: - Peripherals

/// A Bluetooth device that reports a battery level. Devices that report none
/// never become one of these — the island says nothing rather than showing a
/// placeholder or an "unknown".
struct PeripheralBattery: Equatable {
    var name: String
    /// Colon-separated, as `system_profiler` writes it. Identity for coalescing.
    var address: String
    /// The level worth reporting. For a two-bud device that's the *lower* of
    /// left and right, since that's the one that dies first and ends the
    /// session; the case is excluded because it isn't what runs out on you.
    var percent: Int
    /// `system_profiler`'s `device_minorType`, when it gives one.
    var minorType: String?

    /// At or below this, a peripheral is worth mentioning unprompted (i.e. on
    /// a charger plug-in, not just on connect).
    static let lowThreshold = 20

    var glyph: PowerGlyph {
        switch minorType?.lowercased() {
        case let type? where type.contains("headphone") || type.contains("headset"):
            return .symbol("headphones")
        case let type? where type.contains("keyboard"):
            return .symbol("keyboard")
        case let type? where type.contains("mouse"):
            return .symbol("computermouse.fill")
        case let type? where type.contains("speaker"):
            return .symbol("hifispeaker.fill")
        default:
            // A device macOS won't name gets the Bluetooth mark itself — the
            // one thing that is certainly true about it. Hand-drawn, because
            // SF Symbols doesn't carry the rune; see `BluetoothRune`.
            return .bluetoothRune
        }
    }
}
