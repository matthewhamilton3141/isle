//
//  IsleTab.swift
//
//  The faces of the expanded panel. Music and Claude come with the mode;
//  Pomodoro is opt-in from Settings; Agenda comes with the calendar and
//  reminders switches. Which ones are actually offered is
//  `NotchViewModel.availableTabs` — when only one is, there's no switcher and
//  the panel just shows that source.
//

import Foundation

enum IsleTab: String, CaseIterable, Identifiable {
    case music
    case claude
    case pomodoro
    case agenda

    var id: String { rawValue }

    var title: String {
        switch self {
        case .music: return "Music"
        case .claude: return "Claude"
        case .pomodoro: return "Pomodoro"
        case .agenda: return "Agenda"
        }
    }

    var symbolName: String {
        switch self {
        case .music: return "waveform"
        case .claude: return "sparkle"
        case .pomodoro: return "timer"
        case .agenda: return "calendar"
        }
    }
}
