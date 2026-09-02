//
//  AgendaToast.swift
//
//  The calendar and reminder messages — `IslandToast` factories for the two
//  moments `AgendaMonitor` reports: an event about to start, and a reminder
//  coming due.
//
//  Each takes its colour from the calendar or list it belongs to, which is
//  the one piece of colour the user has already chosen for it. The island is
//  10pt text on black, so a dark calendar colour is lifted just enough to
//  read (see `legible`) — hue and saturation are kept, only the brightness
//  is floored. The monitor does that once and passes the result in, so the
//  toast and the agenda list agree on the colour.
//

import SwiftUI
import AppKit

extension IslandToast {
    /// An event starting in `minutesBefore` minutes — or starting now, when
    /// the lead time is zero. `key` identifies the *occurrence*, so a
    /// recurring meeting coalesces with itself today but not with tomorrow's.
    static func event(key: String, title: String, minutesBefore: Int, tint: Color) -> IslandToast {
        let suffix = minutesBefore > 0 ? " · in \(minutesBefore) min" : " · now"
        return IslandToast(
            kind: .event(key: key),
            glyph: .symbol("calendar"),
            text: name(untitled(title, fallback: "Event"), beside: suffix),
            tint: tint,
            gate: .calendar
        )
    }

    /// A reminder that has just come due.
    static func reminder(key: String, title: String, tint: Color) -> IslandToast {
        IslandToast(
            kind: .reminder(key: key),
            glyph: .symbol("checklist"),
            text: name(untitled(title, fallback: "Reminder"), beside: " · now"),
            tint: tint,
            gate: .reminders
        )
    }

    // MARK: - Formatting

    /// Calendar lets an event be saved with no title at all, and the island
    /// can't show a blank — it would read as the glyph having lost its label.
    static func untitled(_ title: String, fallback: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    /// Brightness below which a calendar colour disappears into the housing.
    /// macOS's stock calendar colours all sit well above it; this is for the
    /// custom navy someone picked against a white Calendar window.
    private static let minimumBrightness: CGFloat = 0.72

    /// The calendar's own colour, floored to a brightness that reads on black.
    /// Neutral white when there is no colour to take — a calendar EventKit
    /// couldn't resolve, or a preview with no store.
    static func legible(_ color: CGColor?) -> Color {
        guard let color,
              let nsColor = NSColor(cgColor: color)?.usingColorSpace(.sRGB)
        else { return neutral }

        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        nsColor.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        guard brightness < minimumBrightness else { return Color(nsColor: nsColor) }
        return Color(nsColor: NSColor(
            hue: hue, saturation: saturation, brightness: minimumBrightness, alpha: 1
        ))
    }
}
