//
//  SettingsPreview.swift
//
//  The island as a live preview while Settings is being configured: change
//  something the island shows and it opens, on the face that setting is
//  about, and stays open while you keep going — no hovering the notch after
//  every click to see what it did.
//
//  The rules, in short:
//
//  - **Only a change opens it**, made while Settings is the window in front
//    (Isle active, Settings key — or the colour panel its accent well
//    opened). Opening Settings doesn't; neither does a setting the open
//    island can't show: shortcut bindings (their recorder holds the keys),
//    updates, sounds, alert behaviour, what the collapsed island says (an
//    open island would hide it), which displays it's on.
//  - **On the face that setting is about**: Music's to Music, Claude's to
//    Claude, Pomodoro's to the timer, Calendar's to the agenda. Appearance
//    and the mode leave the face where it is (or Home), since they show on
//    every one. A face the change took away (Pomodoro switched off) leaves
//    it where it is too.
//  - **Never over real activity**: a Claude approval or question on screen
//    keeps its face; a drop under way or a field taking keys wins outright.
//  - **Held like the shortcut's hold** (`IslandPresentation.isHeldOpen`):
//    the pointer moving about in Settings can't close what it never visited.
//    It ends when Settings closes, when Isle stops being the active app (a
//    click in another app, ⌘-Tab), or when the pointer visits the island and
//    leaves — from the visit on it's an ordinary hover. Nothing is timed.
//
//  All of it pure but the publisher, so scripts/test-settings-preview.sh can
//  check it without a window. Wired up in `NotchWindowController`.
//

import Combine
import Foundation

/// A setting the open island shows, changed. Only these open the preview.
enum SettingsPreviewChange: String, CaseIterable, Equatable {
    // What Isle shows, and how the panel looks.
    case mode
    case panelBackground
    case panelNotchGlow
    case statusLight
    // The closed island: shown on it, not on the open panel.
    case closedIslandShows
    case closedIsland
    case claudeAccent
    case claudeAccentHex
    // Music
    case showScrubber
    case showShuffleRepeat
    case waveformSource
    // Claude Code
    case optionDescriptions
    case answerFromNotch
    // Pomodoro
    case pomodoroEnabled
    case pomodoroFocusMinutes
    case pomodoroShortBreakMinutes
    case pomodoroLongBreakMinutes
    case pomodoroSessionsPerCycle
    // Calendar
    case showCalendarEvents
    case showReminders
    case eventLeadMinutes

    /// The face it's about, or nil for one that shows on every face.
    var face: IsleTab? {
        switch self {
        case .mode, .panelBackground, .panelNotchGlow, .statusLight, .closedIslandShows, .closedIsland,
             .claudeAccent, .claudeAccentHex:
            return nil
        case .showScrubber, .showShuffleRepeat, .waveformSource:
            return .music
        case .optionDescriptions, .answerFromNotch:
            return .claude
        case .pomodoroEnabled, .pomodoroFocusMinutes, .pomodoroShortBreakMinutes,
             .pomodoroLongBreakMinutes, .pomodoroSessionsPerCycle:
            return .pomodoro
        case .showCalendarEvents, .showReminders, .eventLeadMinutes:
            return .agenda
        }
    }
}

enum SettingsPreviewPlan {
    /// The moment, as the preview needs it.
    struct Context: Equatable {
        /// The islands are up.
        var running = true
        /// Isle is the active app and Settings (or its colour panel) is the
        /// key window: the change is the user's, made in Settings.
        var settingsInFront = true
        /// A file drag is over an island.
        var dropInProgress = false
        /// A field in the island has the keyboard.
        var composing = false
        /// A Claude approval or question is on the face the island shows.
        var requestShowing = false
        /// The faces on offer now — after the change has landed.
        var availableTabs: [IsleTab] = IsleTab.allCases
    }

    enum Decision: Equatable {
        /// Leave the island alone.
        case none
        /// Open it, held, if it isn't open — and go to `face` if there is
        /// one (nil: stay where it is).
        case open(face: IsleTab?)
        /// The change shows on the closed island: put away an island the
        /// preview is holding open, so it can be seen.
        case showClosed
    }

    static func decide(_ change: SettingsPreviewChange, context: Context) -> Decision {
        guard context.running, context.settingsInFront else { return .none }
        // What's under way in the island wins outright.
        guard !context.dropInProgress, !context.composing else { return .none }
        // The closed island's look shows on the closed island itself.
        if change.showsOnClosedIsland { return .showClosed }
        // A request on screen keeps its face; the change still shows on it
        // where it can (the panel's look, the option descriptions).
        guard !context.requestShowing else { return .open(face: nil) }
        guard let face = change.face, context.availableTabs.contains(face) else { return .open(face: nil) }
        return .open(face: face)
    }
}

extension SettingsPreviewChange {
    /// A setting of the closed island's, which the preview shows by leaving
    /// the island closed rather than opening it.
    var showsOnClosedIsland: Bool {
        self == .closedIslandShows || self == .closedIsland
    }
}

/// How a preview ends, besides the pointer visiting the island.
enum SettingsPreviewEnd: Equatable {
    /// The Settings window closed.
    case settingsClosed
    /// Isle stopped being the active app.
    case appResignedActive
    /// A closed-island setting changed: the island the preview holds goes
    /// back to closed to show it.
    case closedIslandChange
}

/// Which island the preview is holding open, if any. `ID` is the island's
/// key (a display ID); generic so the tests can use anything.
///
/// The preview claims only a hold it made: an island already open (by
/// hover, or held by the shortcut) isn't its to close. Any other end of the
/// hold — the pointer's visit, the shortcut, a click in another app —
/// releases it, so a later shortcut hold on the same island is never taken
/// for the preview's.
struct SettingsPreviewHold<ID: Hashable> {
    private(set) var island: ID?

    /// The preview opened `id` and holds it.
    mutating func opened(_ id: ID) { island = id }

    /// `id`'s hold ended some other way.
    mutating func released(_ id: ID) {
        if island == id { island = nil }
    }

    /// The preview is over: the island to put away, if it still holds one.
    mutating func end(_ reason: SettingsPreviewEnd) -> ID? {
        defer { island = nil }
        return island
    }
}

extension AppSettings {
    /// Every change to a setting the preview shows (`SettingsPreviewChange`),
    /// as it's made — not the values already there, and not an assignment
    /// of the same value. Fires before the new value is stored, as
    /// `@Published` does: read the moment a turn later.
    var previewChanges: AnyPublisher<SettingsPreviewChange, Never> {
        func watch<V: Equatable>(_ publisher: Published<V>.Publisher,
                                 _ change: SettingsPreviewChange) -> AnyPublisher<SettingsPreviewChange, Never> {
            publisher.removeDuplicates().dropFirst().map { _ in change }.eraseToAnyPublisher()
        }
        let all: [AnyPublisher<SettingsPreviewChange, Never>] = [
            watch($mode, .mode),
            watch($panelBackground, .panelBackground),
            watch($panelNotchGlow, .panelNotchGlow),
            watch($statusLight, .statusLight),
            watch($closedIslandShows, .closedIslandShows),
            watch($closedIsland, .closedIsland),
            watch($claudeAccent, .claudeAccent),
            watch($claudeAccentHex, .claudeAccentHex),
            watch($showScrubber, .showScrubber),
            watch($showShuffleRepeat, .showShuffleRepeat),
            watch($waveformSource, .waveformSource),
            watch($optionDescriptions, .optionDescriptions),
            watch($answerFromNotch, .answerFromNotch),
            watch($pomodoroEnabled, .pomodoroEnabled),
            watch($pomodoroFocusMinutes, .pomodoroFocusMinutes),
            watch($pomodoroShortBreakMinutes, .pomodoroShortBreakMinutes),
            watch($pomodoroLongBreakMinutes, .pomodoroLongBreakMinutes),
            watch($pomodoroSessionsPerCycle, .pomodoroSessionsPerCycle),
            watch($showCalendarEvents, .showCalendarEvents),
            watch($showReminders, .showReminders),
            watch($eventLeadMinutes, .eventLeadMinutes),
        ]
        return Publishers.MergeMany(all).eraseToAnyPublisher()
    }
}
