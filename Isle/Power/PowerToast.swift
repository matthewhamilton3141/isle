//
//  PowerToast.swift
//
//  The power and battery messages — `IslandToast` factories for the moments
//  `PowerMonitor` and `BluetoothBatteryMonitor` report — plus the two
//  snapshots the monitors diff to produce them.
//
//  Everything here reports what the APIs actually returned. Time-to-full and
//  time-to-empty are IOKit values, and IOKit says "still calculating" for the
//  first minutes after a plug-in — so those are `nil` then and simply absent
//  from the text, never estimated.
//

import SwiftUI

// MARK: - Copy

extension IslandToast {
    /// Warm amber for charging, plain white for the neutral states, red for
    /// the two "you should do something" ones.
    private static let charge = Color(hex: "#5BD16A")
    private static let warn = Color(hex: "#E8842B")
    private static let alarm = Color(hex: "#E5484D")

    static func pluggedIn(percent: Int, minutesToFull: Int?) -> IslandToast {
        IslandToast(
            kind: .pluggedIn,
            glyph: .symbol("bolt.fill"),
            text: fit(
                short: "Charging · \(percent)%",
                long: minutesToFull.map { "Charging · \(percent)% · \(clock($0)) to full" }
            ),
            tint: charge,
            gate: .macBattery
        )
    }

    static func unplugged(percent: Int, minutesToEmpty: Int?) -> IslandToast {
        IslandToast(
            kind: .unplugged,
            glyph: .symbol(batterySymbol(for: percent)),
            text: fit(
                short: "On battery · \(percent)%",
                long: minutesToEmpty.map { "On battery · \(percent)% · \(clock($0)) left" }
            ),
            tint: neutral,
            gate: .macBattery
        )
    }

    static func fullyCharged() -> IslandToast {
        IslandToast(
            kind: .fullyCharged,
            glyph: .symbol("battery.100percent.bolt"),
            text: "Fully charged",
            tint: charge,
            gate: .macBattery
        )
    }

    static func lowBattery(percent: Int) -> IslandToast {
        IslandToast(
            kind: .lowBattery,
            glyph: .symbol(batterySymbol(for: percent)),
            text: "Low battery · \(percent)%",
            tint: percent <= 10 ? alarm : warn,
            gate: .macBattery
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
    static func lowPowerMode(on: Bool, percent: Int) -> IslandToast {
        IslandToast(
            kind: .lowPowerMode,
            glyph: .symbol(batterySymbol(for: percent)),
            text: on ? "Low Power On" : "Low Power Off",
            tint: on ? warn : neutral,
            gate: .macBattery
        )
    }

    static func device(_ battery: PeripheralBattery) -> IslandToast {
        IslandToast(
            kind: .device(address: battery.address),
            glyph: battery.glyph,
            // The device's own name, trimmed to keep the island sane — some
            // are genuinely called "Matthew's AirPods Pro Max (2nd gen)".
            text: name(battery.name, beside: " · \(battery.percent)%"),
            tint: battery.percent <= PeripheralBattery.lowThreshold ? warn : neutral,
            gate: .deviceBattery
        )
    }

    // MARK: - Formatting

    /// `h:mm`, matching how macOS's own battery menu writes a duration.
    private static func clock(_ minutes: Int) -> String {
        String(format: "%d:%02d", minutes / 60, minutes % 60)
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

    var glyph: ToastGlyph {
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
