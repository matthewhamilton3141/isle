//
//  IsleTab.swift
//
//  The faces of the expanded panel. Music and Claude come with the mode;
//  Agenda comes with the calendar and reminders switches. When only one face
//  is on there are no tabs — the panel just shows that one — so this only
//  drives the switcher and which content the expanded view renders. Which
//  faces are on right now is `NotchViewModel.availableTabs`.
//

import Foundation

enum IsleTab: String, CaseIterable, Identifiable {
    case music
    case claude
    case agenda

    var id: String { rawValue }

    var title: String {
        switch self {
        case .music: return "Music"
        case .claude: return "Claude"
        case .agenda: return "Agenda"
        }
    }

    var symbolName: String {
        switch self {
        case .music: return "waveform"
        case .claude: return "sparkle"
        case .agenda: return "calendar"
        }
    }
}
