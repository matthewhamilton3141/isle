//
//  LiveStrip.swift
//
//  The live strip's rules: the rest of the Mac, glanceable at the foot of
//  the island's primary face. Pure, so they're checked without an app
//  (scripts/test-live-strip.sh); `LiveStripView` draws what they decide and
//  `NotchViewModel+LiveStrip` feeds them.
//
//  - The primary face is Claude whenever a session is live. Without one,
//    the first live thing takes its place: a track, then a started timer.
//    With neither, Claude's face if the mode has it.
//  - The strip holds what's live and isn't the face above it, in grid order:
//    Music · Timer · Agenda · Shelf. Live means a track up, a timer started,
//    an event under way or starting within the hour, a shelf holding
//    something. Nothing live, no strip.
//  - Takeover: while Claude asks (an approval, a question) the strip keeps
//    only what is as pressing as the request: a call you can join now.
//  - The hold: the strip's height, and which face is primary, are fixed for
//    an open. A chip may come or go inside a strip that's up, but the strip
//    itself never arrives under the pointer. A takeover starting or ending,
//    or the setting changing, settles it again: the face is changing then
//    anyway.
//

import Foundation

enum LiveStrip {
    // MARK: - Geometry

    /// A chip's height, and the strip's.
    static let chipHeight: CGFloat = 38
    /// From the face's foot to the chips. The face's own bottom inset (4)
    /// sits above it, so an action row's pills (Approve, Deny) are at least
    /// 16pt clear of a Join.
    static let topGap: CGFloat = 12
    /// What the strip adds to the face it's under.
    static var height: CGFloat { chipHeight + topGap }
    static let chipGap: CGFloat = 6
    /// An event this soon, or under way, earns a chip.
    static let eventHorizon: TimeInterval = 60 * 60

    // MARK: - Inputs

    /// An agenda item, as far as the strip cares.
    struct Event: Equatable {
        var id: String
        var start: Date
        var end: Date?
        var isAllDay: Bool
        /// An event, not a reminder.
        var isEvent: Bool
        /// Its call can be joined now (inside the Join lead).
        var joinable: Bool
    }

    /// The island's moment, as the strip needs it.
    struct Inputs: Equatable {
        /// The faces on offer (`availableTabs`).
        var tabs: [IsleTab]
        /// A Claude session the registry vouches for, or one agent view lists.
        var claudeSession: Bool
        /// An approval or a question on the island's session.
        var claudeAsking: Bool
        var hasTrack: Bool
        /// The timer has been started (running, or paused mid-interval).
        var timerActive: Bool
        /// Today's agenda, in order.
        var events: [Event]
        var shelfCount: Int
        var now: Date
    }

    // MARK: - Content

    /// What the strip holds, in the order it draws them.
    struct Content: Equatable {
        var music = false
        var timer = false
        /// The agenda item's id.
        var event: String?
        /// The event's call can be joined now.
        var joinable = false
        var shelf = 0

        var isEmpty: Bool { !music && !timer && event == nil && shelf == 0 }
        var count: Int { (music ? 1 : 0) + (timer ? 1 : 0) + (event == nil ? 0 : 1) + (shelf > 0 ? 1 : 0) }
    }

    /// The face the island opens to, or nil to leave it where it was (no
    /// face to lead with: the mode has no Claude and nothing is live).
    static func primary(_ i: Inputs) -> IsleTab? {
        if i.tabs.contains(.claude), i.claudeSession { return .claude }
        if i.tabs.contains(.music), i.hasTrack { return .music }
        if i.tabs.contains(.pomodoro), i.timerActive { return .pomodoro }
        if i.tabs.contains(.claude) { return .claude }
        return nil
    }

    /// The strip under `face`.
    static func content(on face: IsleTab, _ i: Inputs) -> Content {
        var c = Content()
        let takeover = face == .claude && i.claudeAsking
        if i.tabs.contains(.agenda), face != .agenda {
            let call = i.events.first { $0.joinable }
            let next = call ?? i.events.first { e in
                e.isEvent && !e.isAllDay && (e.end ?? e.start) > i.now
                    && e.start.timeIntervalSince(i.now) <= eventHorizon
            }
            if let next, !takeover || next.joinable {
                c.event = next.id
                c.joinable = next.joinable
            }
        }
        guard !takeover else { return c }
        if face != .music, i.tabs.contains(.music), i.hasTrack { c.music = true }
        if face != .pomodoro, i.tabs.contains(.pomodoro), i.timerActive { c.timer = true }
        if face != .shelf, i.tabs.contains(.shelf) { c.shelf = i.shelfCount }
        return c
    }

    // MARK: - The hold

    /// What an open settled on.
    struct Hold: Equatable {
        /// The face the strip is under.
        var primary: IsleTab?
        /// The strip is up, at its height.
        var shown: Bool
        /// Claude was asking.
        var takeover: Bool
        /// The setting was on.
        var enabled: Bool
    }

    /// The hold for the moment `live` describes, given what the open settled
    /// on before (`previous`; nil when the island has just opened).
    static func hold(previous: Hold?, live: Hold) -> Hold {
        guard let previous, previous.takeover == live.takeover, previous.enabled == live.enabled else {
            return live
        }
        return previous
    }
}
