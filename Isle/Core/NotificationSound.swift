//
//  NotificationSound.swift
//
//  The sounds Isle can play when something happens that the island is about
//  to show — a Claude alert, a finished turn, a meeting coming up, a Pomodoro
//  interval ending. Each event has its own switch and its own choice, so the
//  chime is per event rather than one global bell: the sound for "Claude
//  needs you" wants to be more insistent than the one for "your turn is done".
//
//  Four sounds from Google's Material product set (CC BY 4.0, see
//  Sounds/ATTRIBUTION.txt), one per event by default, rather than the macOS
//  alert set or the whole pack. They were designed as product notifications —
//  short, tonal, nothing to clash with — where Basso and Sosumi carry thirty
//  years of Mac baggage, and four is a menu you can pick from by ear.
//

import AppKit

enum NotificationSound: String, CaseIterable, Identifiable {
    /// One clear tone. The default for Claude needing you.
    case alert = "alert_simple"
    /// Two soft notes. The default for a calendar event or reminder.
    case simple1 = "notification_simple-01"
    /// A rising pair. The default for a finished turn.
    case simple2 = "notification_simple-02"
    /// A short flourish. The default for a Pomodoro interval ending.
    case fanfare = "hero_decorative-celebration-01"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .alert: return "Alert"
        case .simple1: return "Simple I"
        case .simple2: return "Simple II"
        case .fanfare: return "Fanfare"
        }
    }

    /// One `NSSound` per file, loaded on first play and kept. A chime is a
    /// few dozen kilobytes; re-reading it from the bundle each time would be
    /// pointless, and holding it means the first alert doesn't hitch on disk.
    @MainActor private static var cache: [NotificationSound: NSSound] = [:]

    @MainActor
    func play() {
        let sound: NSSound
        if let cached = Self.cache[self] {
            sound = cached
        } else {
            guard let url = Bundle.main.url(forResource: rawValue, withExtension: "m4a"),
                  let loaded = NSSound(contentsOf: url, byReference: true) else { return }
            Self.cache[self] = loaded
            sound = loaded
        }
        // A sound already playing (two alerts in quick succession) restarts
        // rather than layering: `play()` on a playing NSSound is a no-op.
        if sound.isPlaying { sound.stop() }
        sound.play()
    }
}
