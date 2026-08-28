//
//  IsleTab.swift
//
//  The two faces of the expanded panel when Isle runs in `.both` mode. In
//  single-source modes there are no tabs — the panel just shows that one
//  source — so this only drives the segmented switcher and which content the
//  expanded view renders.
//

import Foundation

enum IsleTab: String, CaseIterable, Identifiable {
    case music
    case claude

    var id: String { rawValue }

    /// The other tab — the one a toggle button switches you to.
    var other: IsleTab {
        switch self {
        case .music: return .claude
        case .claude: return .music
        }
    }

    var title: String {
        switch self {
        case .music: return "Music"
        case .claude: return "Claude"
        }
    }

    var symbolName: String {
        switch self {
        case .music: return "music.note"
        case .claude: return "sparkle"
        }
    }
}
