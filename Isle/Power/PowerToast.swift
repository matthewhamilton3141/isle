//
//  PowerToast.swift
//
//  The power and battery messages — `IslandToast` factories for the moments
//  `PowerMonitor` and `BluetoothBatteryMonitor` report — plus the two
//  snapshots the monitors diff to produce them.
//
//  Each toast leads with the device whose battery it is, in Apple's own
//  drawing where the device says what it is: this Mac, a pair of AirPods
//  Pro, a Magic Mouse (see `DeviceSymbol`). The state is in the words and
//  the tint, so the glyph never has to stand for it.
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
            glyph: .thisMac,
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
            glyph: .thisMac,
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
            glyph: .thisMac,
            text: "Fully charged",
            tint: charge,
            gate: .macBattery
        )
    }

    static func lowBattery(percent: Int) -> IslandToast {
        IslandToast(
            kind: .lowBattery,
            glyph: .thisMac,
            text: "Low battery · \(percent)%",
            tint: percent <= 10 ? alarm : warn,
            gate: .macBattery
        )
    }

    /// Orange while on, matching the warm tint Isle already uses for "worth
    /// noticing, not urgent" — the same one a peripheral under 20% gets.
    /// macOS's own Low Power Mode indicator is a yellow battery for the same
    /// reason.
    static func lowPowerMode(on: Bool) -> IslandToast {
        IslandToast(
            kind: .lowPowerMode,
            glyph: .thisMac,
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
    /// `device_vendorID` and `device_productID`, when it gives them. Apple
    /// and Beats accessories do, and they're what names the model.
    var vendorID: Int? = nil
    var productID: Int? = nil

    /// At or below this, a peripheral is worth mentioning unprompted (i.e. on
    /// a charger plug-in, not just on connect).
    static let lowThreshold = 20

    /// The model's own symbol when the device names it — the same one the
    /// output list draws (see `DeviceSymbol`) — else the glyph for its kind.
    var glyph: ToastGlyph {
        if let model = DeviceSymbol.accessory(name: name, vendorID: vendorID, productID: productID) {
            return .symbol(model)
        }
        switch minorType?.lowercased() {
        case let type? where type.contains("headphone") || type.contains("headset"):
            return .symbol("headphones")
        case let type? where type.contains("keyboard"):
            return .symbol("keyboard")
        case let type? where type.contains("mouse"):
            return .symbol(DeviceSymbol.mouse(name: name, vendorID: vendorID))
        case let type? where type.contains("speaker"):
            return .symbol("hifispeaker.fill")
        case let type? where type.contains("gamepad") || type.contains("joystick"):
            return .symbol("gamecontroller.fill")
        default:
            // A device macOS won't name gets the Bluetooth mark itself — the
            // one thing that is certainly true about it. Hand-drawn, because
            // SF Symbols doesn't carry the rune; see `BluetoothRune`.
            return .bluetoothRune
        }
    }
}
