//
//  PanelBackground.swift
//
//  What the opened panel is drawn on: the flat black Isle has always had, or
//  frosted glass, light or smoked. Only the open panel changes — the
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

    var id: String { rawValue }

    /// Whether the panel is drawn on glass at all.
    var isGlass: Bool { self != .black }

    var title: String {
        switch self {
        case .black: return "Black"
        case .glass: return "Glass"
        case .smoked: return "Smoked"
        }
    }

    var subtitle: String {
        switch self {
        case .black:
            return "The opened panel is flat black, like the notch it grows out of."
        case .glass:
            return "The opened panel is frosted glass, darkened over bright windows so text stays readable."
        case .smoked:
            return "Frosted glass with a heavy dark tint: steadier over busy or bright windows, less see-through."
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
