//
//  DeviceSymbol.swift
//
//  Apple's own SF Symbols for the devices Isle names — an AirPods pair, a
//  Beats headset, a Magic Mouse, this Mac — shared by the output list on the
//  music face and the battery toasts, so a pair of AirPods Pro is the same
//  glyph in both.
//
//  A model's symbol is only used when the device itself says which model it
//  is. Apple and Beats accessories report Apple's Bluetooth vendor ID and a
//  product ID per model; `system_profiler` passes both through, and Core
//  Audio carries them in a Bluetooth output's model UID. Without them the
//  name is the fallback, and only for the three names macOS gives AirPods
//  ("… AirPods", "… AirPods Pro", "… AirPods Max") — never for a device
//  whose vendor is known to be someone else, since a clone can call itself
//  anything. Anything less certain gets the plain glyph for its kind.
//
//  Symbols arrive with the OS (`airpods.gen4` is newer than the deployment
//  target), so every choice is a list, newest first, and the first one this
//  Mac can draw wins. The last entry in every list predates macOS 14, so the
//  answer is never a name that renders blank.
//

import AppKit
import IOKit.ps

enum DeviceSymbol {
    /// Apple's company identifier from the Bluetooth SIG. Apple and Beats
    /// accessories report it as their vendor ID.
    static let appleVendorID = 0x004C

    /// Apple and Beats product IDs, with the symbols that draw each model,
    /// most specific first. Only models SF Symbols has a drawing for; any
    /// other product ID falls through to the name and then the kind.
    /// 0x2024 was read from a real pair (AirPods Pro 2, USB-C); the rest
    /// are the IDs those devices publish over Apple's Continuity protocol.
    private static let appleProducts: [Int: [String]] = [
        0x2002: ["airpods"],                                // AirPods
        0x200F: ["airpods"],                                // AirPods (2nd generation)
        0x2013: ["airpods.gen3", "airpods"],                // AirPods (3rd generation)
        0x2019: ["airpods.gen4", "airpods.gen3", "airpods"], // AirPods 4
        0x201B: ["airpods.gen4", "airpods.gen3", "airpods"], // AirPods 4 (ANC)
        0x200E: ["airpodspro"],                             // AirPods Pro
        0x2014: ["airpodspro"],                             // AirPods Pro 2
        0x2024: ["airpodspro"],                             // AirPods Pro 2 (USB-C)
        0x200A: ["airpodsmax"],                             // AirPods Max
        0x201F: ["airpodsmax"],                             // AirPods Max (USB-C)
        0x2003: ["beats.powerbeats3", "earbuds"],           // Powerbeats3
        0x200D: ["beats.powerbeats", "earbuds"],            // Powerbeats
        0x200B: ["beats.powerbeatspro", "earbuds"],         // Powerbeats Pro
        0x201D: ["beats.powerbeatspro", "earbuds"],         // Powerbeats Pro 2
        0x2005: ["beats.earphones", "earbuds"],             // BeatsX
        0x2010: ["beats.earphones", "earbuds"],             // Beats Flex
        0x2011: ["beats.studiobuds", "earbuds"],            // Beats Studio Buds
        0x2016: ["beats.studiobuds.plus", "beats.studiobuds", "earbuds"], // Beats Studio Buds +
        0x2012: ["beats.fitpro", "earbuds"],                // Beats Fit Pro
        0x2026: ["beats.solobuds", "earbuds"],              // Beats Solo Buds
        0x2006: ["beats.headphones", "headphones"],         // Beats Solo3
        0x200C: ["beats.headphones", "headphones"],         // Beats Solo Pro
        0x2025: ["beats.headphones", "headphones"],         // Beats Solo 4
        0x2009: ["beats.headphones", "headphones"],         // Beats Studio3
        0x2017: ["beats.headphones", "headphones"],         // Beats Studio Pro
    ]

    /// The model's own symbol, from what the accessory reports: its product
    /// ID when the vendor is Apple, else the AirPods names. Nil when neither
    /// pins a model down — the caller then draws the plain glyph for the
    /// device's kind.
    static func accessory(name: String, vendorID: Int?, productID: Int?) -> String? {
        if vendorID == appleVendorID, let productID,
           let candidates = appleProducts[productID],
           let symbol = firstAvailable(candidates) {
            return symbol
        }
        // A vendor that is known and isn't Apple rules the names out.
        guard vendorID == nil || vendorID == appleVendorID else { return nil }
        let lowered = name.lowercased()
        if lowered.contains("airpods max") { return "airpodsmax" }
        if lowered.contains("airpods pro") { return "airpodspro" }
        if lowered.contains("airpods") { return "airpods" }
        return nil
    }

    /// Apple's mouse, when the device says it is one: Apple's vendor ID,
    /// under either the Bluetooth SIG's numbering or the USB-IF's (0x05AC),
    /// or with no vendor reported, Magic Mouse in its name.
    static func mouse(name: String, vendorID: Int?) -> String {
        let isApple = vendorID == appleVendorID || vendorID == 0x05AC
            || (vendorID == nil && name.lowercased().contains("magic mouse"))
        return isApple ? firstAvailable(["magicmouse.fill", "computermouse.fill"])! : "computermouse.fill"
    }

    /// This Mac, for its own battery. Only ever asked about a Mac with a
    /// battery, so a laptop; drawn with the notch once a screen with a
    /// camera housing has been seen, since that can only be this Mac's own
    /// display. Until then — a notchless MacBook, or one that has run with
    /// its lid shut since launch — the plain laptop, which claims nothing
    /// about the display.
    @MainActor
    static var thisMac: String {
        if !hasSeenNotch {
            hasSeenNotch = NSScreen.screens.contains { $0.safeAreaInsets.top > 0 }
        }
        return hasSeenNotch
            ? firstAvailable(["macbook.gen2", "laptopcomputer"])!
            : "laptopcomputer"
    }

    @MainActor private static var hasSeenNotch = false

    /// This Mac's own speakers: the Mac itself when it's a laptop, the
    /// plain speaker on a desktop, where there's no telling an iMac from a
    /// Mac mini driving its own speaker.
    @MainActor
    static var builtInSpeakers: String {
        isLaptop ? thisMac : "speaker.wave.2"
    }

    /// Whether this Mac has an internal battery — the same test the power
    /// monitor makes before it reports anything — which, for a Mac, is
    /// whether it's a laptop. Read once: it can't change while Isle runs.
    static let isLaptop: Bool = {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return false }
        return sources.contains { source in
            guard let description = IOPSGetPowerSourceDescription(blob, source)?
                .takeUnretainedValue() as? [String: Any] else { return false }
            return description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
        }
    }()

    // MARK: - Availability

    private static let lock = NSLock()
    nonisolated(unsafe) private static var drawable: [String: Bool] = [:]

    /// The first of `names` this Mac's symbol set has. Cached: it's asked
    /// from view bodies, and the answer can't change while Isle runs.
    static func firstAvailable(_ names: [String]) -> String? {
        lock.lock()
        defer { lock.unlock() }
        for name in names {
            if let known = drawable[name] {
                if known { return name }
                continue
            }
            let found = NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
            drawable[name] = found
            if found { return name }
        }
        return nil
    }

    // MARK: - Parsing

    /// A hex ID as `system_profiler` writes it ("0x2024").
    static func hexID(_ value: Any?) -> Int? {
        guard let string = value as? String else { return value as? Int }
        let digits = string.lowercased().hasPrefix("0x") ? String(string.dropFirst(2)) : string
        return Int(digits, radix: 16)
    }

    /// The product and vendor IDs in a Bluetooth output's Core Audio model
    /// UID, which reads "2024 4c" for a pair of AirPods Pro: two hex fields,
    /// product then vendor. Anything else in that property is left alone.
    static func bluetoothIDs(modelUID: String?) -> (vendorID: Int, productID: Int)? {
        guard let parts = modelUID?.split(separator: " "), parts.count == 2,
              let product = Int(parts[0], radix: 16),
              let vendor = Int(parts[1], radix: 16)
        else { return nil }
        return (vendor, product)
    }
}
