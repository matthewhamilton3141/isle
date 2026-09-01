//
//  ClaudeAccent.swift
//
//  The colour a Claude-only island draws itself in.
//
//  A music island gets its palette from album artwork. A Claude-only one has
//  no artwork to extract from, so `ArtworkColors.palette(from: nil)` returns
//  `.fallback` — three greys — and every `.palette` marker renders flat. This
//  supplies the missing palette instead: the user picks an accent, and it
//  plays exactly the role the artwork plays for music.
//
//  Deliberately *not* an override of the semantic markers. `done` green,
//  `failed` red and `needsQuestion` blue carry information the accent doesn't,
//  and repainting them would delete the fastest signal in the island. The
//  accent supplies a neutral palette; it doesn't recolour meaning.
//
//  The swatches were chosen against the colours the state machine already
//  owns (`MarkerDesign.Hex`), not by eye: every stop clears every semantic
//  colour by more than 30 ΔE (CIE76), which is what keeps a `working` island
//  from reading as `failed`. The last two clear a lower bar against grey —
//  see `Family.muted`.
//

import SwiftUI
import AppKit

enum ClaudeAccent: String, CaseIterable, Identifiable {
    /// Follows the system accent colour from System Settings.
    case system
    case lime, teal, violet, orchid, magenta
    /// Muted rather than grey — see `Family`.
    case slate, stone
    /// A colour the user picked, stored separately on `AppSettings`.
    case custom

    var id: String { rawValue }

    enum Family {
        /// Clears every semantic colour by >30 ΔE on colour alone.
        case chromatic
        /// Reads as neutral, but is not grey. A true grey cannot be separated
        /// from the grey states — `#8E8E93` is used by `disconnected` (0.18),
        /// `paused` (0.70) and `networkOffline` (0.90), and a mid-neutral
        /// secondary stop measured 2.8 ΔE from `paused`, which is the same
        /// colour. Chroma was the only lever, and at the level required these
        /// stop being neutrals: a muted navy and a muted bronze. They clear a
        /// bar of 18 rather than 30, which is acceptable only because the two
        /// states they sit nearest are rare and carry distinct shapes.
        case muted
        /// Resolves to one of the measured swatches, so it inherits that
        /// swatch's guarantee.
        case snapped
        /// Derived at runtime, so it carries no guarantee — `derive` applies
        /// the same floors but the user can still land near a semantic hue.
        case derived
    }

    var family: Family {
        switch self {
        case .custom: return .derived
        case .system: return .snapped
        case .slate, .stone: return .muted
        default: return .chromatic
        }
    }

    var title: String {
        switch self {
        case .system:  return "Match system"
        case .lime:    return "Lime"
        case .teal:    return "Teal"
        case .violet:  return "Violet"
        case .orchid:  return "Orchid"
        case .magenta: return "Magenta"
        case .slate:   return "Slate"
        case .stone:   return "Stone"
        case .custom:  return "Custom"
        }
    }

    /// The swatches shown in the picker, in order. `custom` is presented as a
    /// colour well rather than a chip, so it isn't in this list.
    static var swatches: [ClaudeAccent] {
        [.system, .lime, .teal, .violet, .orchid, .magenta, .slate, .stone]
    }

    /// Hand-tuned stops, or nil for the two that resolve at runtime.
    ///
    /// Ordered as `ArtworkPalette` expects: `primary` is the base, `secondary`
    /// the deep stop, `accent` the highlight. `DotColors.paletteRamp` walks
    /// primary → accent → secondary and wraps, so all three are always on
    /// screen at once across the grid.
    private var fixedPalette: ArtworkPalette? {
        switch self {
        case .lime:    return Self.make("#9DC63F", "#5F8A24", "#CDEA6A")
        case .teal:    return Self.make("#25BFA4", "#127A6B", "#7FE9C8")
        case .violet:  return Self.make("#9438E0", "#6321A6", "#C79BFF")
        case .orchid:  return Self.make("#CE5FD2", "#8F2F96", "#F0A6EE")
        case .magenta: return Self.make("#E44C8E", "#A62760", "#FF95B8")
        case .slate:   return Self.make("#AFB9CB", "#556A8C", "#DCE3ED")
        case .stone:   return Self.make("#C2B096", "#907C58", "#EDE4D8")
        case .system, .custom: return nil
        }
    }

    private static func make(_ p: String, _ s: String, _ a: String) -> ArtworkPalette {
        ArtworkPalette(primary: Color(hex: p), secondary: Color(hex: s), accent: Color(hex: a))
    }

    /// The palette to draw with. `customHex` is only consulted for `.custom`.
    func palette(customHex: String) -> ArtworkPalette {
        if let fixedPalette { return fixedPalette }
        switch self {
        case .system:
            // Snapped, not derived — see `nearestSwatch(to:)` for why the raw
            // system accent can't be used.
            return Self.nearestSwatch(to: .controlAccentColor)
                .palette(customHex: customHex)
        case .custom:
            return Self.derive(from: NSColor(Color(hex: customHex)))
        default:
            return .fallback
        }
    }

    /// The chip colour for the picker — the primary stop.
    func chipColor(customHex: String) -> Color { palette(customHex: customHex).primary }

    // MARK: - Deriving three stops from one colour

    /// Builds a full palette from a single picked colour.
    ///
    /// A lone hue is not enough: the ramp needs three stops that differ, and
    /// they have to survive the notch's black ground. So the base is floored
    /// into a legible band first, then the other two are taken off it — the
    /// deep stop darker and a little more saturated, the highlight lighter and
    /// a lot less. Each is rotated a few degrees so the ramp moves in hue and
    /// not only in lightness; a ramp that only changes brightness reads as a
    /// flicker, which is the flat look this whole feature exists to replace.
    static func derive(from color: NSColor) -> ArtworkPalette {
        guard let base = color.usingColorSpace(.sRGB) else { return .fallback }

        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        base.getHue(&h, saturation: &s, brightness: &b, alpha: &a)

        // Floors, not clamps: a near-black or washed-out pick would otherwise
        // collapse all three stops into nearly one colour.
        let sat = max(s, 0.35)
        let val = max(b, 0.58)

        let primary = NSColor(hue: h, saturation: sat, brightness: val, alpha: 1)
        let secondary = NSColor(
            hue: rotate(h, by: -6),
            saturation: min(1, sat * 1.12),
            brightness: max(0.30, val * 0.62),
            alpha: 1
        )
        let accent = NSColor(
            hue: rotate(h, by: 8),
            saturation: max(0.10, sat * 0.60),
            brightness: min(1, val * 1.30),
            alpha: 1
        )
        return ArtworkPalette(
            primary: Color(primary), secondary: Color(secondary), accent: Color(accent)
        )
    }

    /// Hue arithmetic on the 0…1 scale AppKit uses, wrapping at both ends.
    private static func rotate(_ hue: CGFloat, by degrees: CGFloat) -> CGFloat {
        let shifted = hue + degrees / 360
        return shifted - shifted.rounded(.down)
    }
}

// MARK: - Measuring against the states that own the wheel

extension ClaudeAccent {
    /// The colours a user-chosen accent must not impersonate, and the words to
    /// describe them with. Taken from `MarkerDesign.Hex` so there is one source
    /// of truth; `gray` is deliberately absent, because the muted swatches are
    /// allowed to sit near it (see `Family.muted`).
    static let reservedColours: [(name: String, hex: String)] = [
        ("errors", MarkerDesign.Hex.red),
        ("rate limits", MarkerDesign.Hex.amber),
        ("success", MarkerDesign.Hex.green),
        ("questions", MarkerDesign.Hex.blue),
        ("plan review", MarkerDesign.Hex.cyan),
    ]

    /// Below this, two colours are close enough to be confused at the size the
    /// island actually draws — 16pt in a split island, 22pt solo.
    static let collisionThreshold: Double = 30

    /// The swatch closest to a given colour, which is how `.system` resolves.
    ///
    /// The system accent cannot be used directly: five of the eight macOS
    /// accents — Blue, Red, Orange, Yellow and Green — land inside the reserved
    /// set, and Blue, which is the macOS default, measures 8 ΔE from the colour
    /// Isle uses for questions. Snapping to the nearest safe swatch keeps the
    /// island coherent with the rest of the system without letting `working`
    /// dress up as `needsQuestion`.
    static func nearestSwatch(to color: NSColor) -> ClaudeAccent {
        let target = Lab(color)
        let candidates = swatches.filter { $0 != .system }
        return candidates.min {
            target.distance(to: Lab(NSColor($0.chipColor(customHex: "")))) <
            target.distance(to: Lab(NSColor($1.chipColor(customHex: ""))))
        } ?? .violet
    }

    /// The reserved colour a custom accent is close enough to be confused with,
    /// or nil when it's clear of all of them.
    ///
    /// Custom is deliberately *not* snapped or rejected — an explicit picker
    /// should honour what the user chose — so this exists to say so plainly
    /// instead of silently substituting a different colour.
    static func collision(forCustom hex: String) -> String? {
        let stops = derive(from: NSColor(Color(hex: hex)))
        let labs = [stops.primary, stops.secondary, stops.accent].map { Lab(NSColor($0)) }

        var nearest: (name: String, distance: Double)?
        for reserved in reservedColours {
            let target = Lab(NSColor(Color(hex: reserved.hex)))
            for stop in labs {
                let d = stop.distance(to: target)
                guard d < collisionThreshold else { continue }
                if d < (nearest?.distance ?? .infinity) {
                    nearest = (reserved.name, d)
                }
            }
        }
        return nearest?.name
    }
}

/// Just enough CIELAB to answer "would these two be confused".
///
/// CIE76 rather than CIE2000: the swatch set was chosen on CIE76 margins wide
/// enough (>30, against a ~2.3 just-noticeable difference) that the refinement
/// wouldn't change any decision here.
private struct Lab {
    let l, a, b: Double

    init(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? .white
        func lin(_ v: Double) -> Double {
            v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        let r = lin(Double(c.redComponent))
        let g = lin(Double(c.greenComponent))
        let bl = lin(Double(c.blueComponent))

        let x = (0.4124 * r + 0.3576 * g + 0.1805 * bl) / 0.95047
        let y =  0.2126 * r + 0.7152 * g + 0.0722 * bl
        let z = (0.0193 * r + 0.1192 * g + 0.9505 * bl) / 1.08883

        func f(_ t: Double) -> Double {
            t > 0.008856 ? pow(t, 1.0 / 3) : (7.787 * t + 16.0 / 116)
        }
        let fx = f(x), fy = f(y), fz = f(z)
        l = 116 * fy - 16
        a = 500 * (fx - fy)
        b = 200 * (fy - fz)
    }

    func distance(to other: Lab) -> Double {
        let dl = l - other.l, da = a - other.a, db = b - other.b
        return (dl * dl + da * da + db * db).squareRoot()
    }
}
