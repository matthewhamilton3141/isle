//
//  PanelBackground.swift
//
//  What the opened panel is drawn on: the flat black Isle has always had,
//  frosted glass, light or smoked, or black that fades into glass toward
//  the panel's bottom edge. Only the open panel changes — the
//  collapsed pill stays flat black in every mode, because as glass it would
//  be a sliver with the camera's black bite in the middle of it.
//
//  Kept free of SwiftUI so the stored-value parsing compiles on its own for
//  scripts/test-island-glass.sh. The drawing is in IslandGlass+SwiftUI.swift.
//

import Foundation

enum PanelBackground: String, CaseIterable, Identifiable {
    /// Flat black — what Isle has always drawn, and the default.
    case black
    /// Frosted glass, darkened just enough over bright windows that white
    /// text stays readable. With the notch glow off, the camera housing
    /// shows as a black cutout hanging from the top edge.
    case glass
    /// The same glass with a fixed heavy black tint: darker and steadier
    /// than `.glass`, at the cost of seeing less through it.
    case smoked
    /// Black where the panel meets the notch, easing into the glass toward
    /// its bottom edge (`IslandGlass.fadeAlpha`): the top stays fused with
    /// the hardware, the bottom shows what's under it.
    case fade

    var id: String { rawValue }

    /// Whether the panel is drawn on glass at all.
    var isGlass: Bool { self != .black }

    /// Whether the "Glow from the notch" setting means anything here. Fade
    /// is already solid black around the camera and well below it, so a
    /// glow would have nothing to fade into.
    var growsNotchGlow: Bool { self == .glass || self == .smoked }

    var title: String {
        switch self {
        case .black: return "Black"
        case .glass: return "Glass"
        case .smoked: return "Smoked"
        case .fade: return "Fade"
        }
    }

    var subtitle: String {
        switch self {
        case .black:
            return "Flat black, like the notch it grows out of."
        case .glass:
            return "Frosted glass when open, darkened over bright windows so text stays readable."
        case .smoked:
            return "Glass with a heavy dark tint when open: steadier over busy windows."
        case .fade:
            return "Black at the notch, easing into frosted glass toward the bottom edge."
        }
    }

    /// The stored preference, read back. Anything absent or unrecognised —
    /// a fresh install, a build from before the setting existed, a value a
    /// later build wrote — is Black, so nobody's panel changes unless they
    /// ask for it.
    static func stored(_ raw: String?) -> PanelBackground {
        raw.flatMap(PanelBackground.init(rawValue:)) ?? .black
    }
}
