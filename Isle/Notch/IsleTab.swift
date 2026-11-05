//
//  IsleTab.swift
//
//  The faces of the expanded panel. Music and Claude come with the mode;
//  Pomodoro is opt-in from Settings; Agenda comes with the calendar and
//  reminders switches. Which ones are actually offered is
//  `NotchViewModel.availableTabs`, in the order the home grid lays them out
//  and a swipe walks them — when only one is, there's no home and the panel
//  just shows that source.
//
//  A new face is a case here, a place in `availableTabs`, a face view in
//  `ExpandedNotchView` and a glance in `HomeGridView`. The switches over this
//  enum are exhaustive, so leaving one out doesn't build. A face that only
//  exists while it has something in it (a shelf, while it holds items) is
//  offered by `availableTabs` only then, and comes and goes from the grid and
//  the swipe order with it.
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

/// Where the open panel is: the home grid of every face, or inside one.
enum NotchPlace: Equatable {
    case home
    case face(IsleTab)

    /// The face on screen, or nil on the grid.
    var face: IsleTab? {
        if case .face(let tab) = self { return tab }
        return nil
    }
}
