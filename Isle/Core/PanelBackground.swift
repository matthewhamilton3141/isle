//
//  PanelBackground.swift
//
//  What the opened panel is drawn on: the flat black Isle has always had,
//  frosted glass, or a clear lens with the music's spectrum lying along its
//  lip. On the notch only the open panel changes — the collapsed pill
//  stays flat black in every mode, because as glass it would be a sliver
//  with the camera's black bite in the middle of it. Taken off the notch
//  (`IslandPlacement.floating`) there's no camera in it, and the closed
//  capsule is the mode's material too (IslandFloat.swift).
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
    /// A clear lens: black over the camera, a tint behind the content, and
    /// below the content a lip of all but bare glass that bends what's
    /// behind it, with a streak of light along it split into a spectrum by
    /// the music (IslandPrism.swift). The one mode whose open panel has a
    /// shape of its own: a lip taller, and rounder at the bottom.
    case prism

    var id: String { rawValue }

    /// Whether the panel is drawn on glass at all.
    var isGlass: Bool { self != .black }

    /// Whether the "Glow from the notch" setting means anything here: only
    /// Glass has a camera cutout biting into frosted glass for a glow to
    /// soften. Prism is black over the camera already.
    var growsNotchGlow: Bool { self == .glass }

    var title: String {
        switch self {
        case .black: return "Black"
        case .glass: return "Glass"
        case .prism: return "Prism"
        }
    }

    var subtitle: String {
        switch self {
        case .black:
            return "Flat black, like the notch it grows out of."
        case .glass:
            return "Frosted glass when open, darkened over bright windows so text stays readable."
        case .prism:
            return "A clear lens that bends what’s behind it, with the music split into a spectrum along its lip."
        }
    }

    /// Stored values of backgrounds that shipped and were later removed,
    /// each read as the nearest thing still on offer. Smoked was Glass with
    /// a heavier tint and Fade was black easing into glass, so both are
    /// Glass now: someone who chose glass keeps glass.
    private static let retired: [String: PanelBackground] = [
        "smoked": .glass,
        "fade": .glass,
    ]

    /// The stored preference, read back. A retired background is its
    /// successor (`retired`). Anything else absent or unrecognised — a
    /// fresh install, a build from before the setting existed, a value a
    /// later build wrote — is Black, so nobody's panel changes unless they
    /// ask for it.
    static func stored(_ raw: String?) -> PanelBackground {
        guard let raw else { return .black }
        return PanelBackground(rawValue: raw) ?? retired[raw] ?? .black
    }
}
