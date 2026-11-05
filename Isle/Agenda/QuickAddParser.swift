//
//  QuickAddParser.swift
//
//  Reads a line like "Lunch with Sam tomorrow 1pm" into something the agenda
//  can offer to add: what it is (an event or a reminder), its title, and
//  when. Pure — text and a clock in, a draft or a reason out — so it can be
//  tested without a calendar, and so nothing here ever saves: the face shows
//  the draft and the user says Add.
//
//  The date comes from `NSDataDetector`, which knows "tomorrow 1pm", "Friday
//  3:30" and "next Saturday 8pm" in the user's own locale. Around it, three
//  things it doesn't do: "in 30 min" (it finds nothing there), "for 45
//  minutes" (a length, not a time), and "remind me to", which says what to
//  make rather than when.
//
//  An event when there is a clock time; a reminder when there's only a day,
//  no date at all, or "remind me". A clock time means digits with am/pm, a
//  colon, "at 9" next to a day, noon or midnight, or "in N min". "Morning",
//  "tonight" and "lunch" are times the detector will happily pick an hour
//  for, but they are a part of the day, not an appointment, so they make a
//  dated reminder rather than an event at an hour the user never said.
//
//  It refuses rather than guesses: two dates in one line, an hour with no
//  am or pm and no day to hang it on ("Standup at 9"), a day it can see but
//  not place ("on the 1st"), a time already past, or nothing left to call
//  it.
//

import Foundation

struct QuickAddDraft: Equatable {
    enum Kind: Equatable {
        case event
        case reminder
    }

    let kind: Kind
    let title: String
    /// When the event starts or the reminder is due. Nil only for a reminder
    /// with no date at all.
    let date: Date?
    /// Whether `date` carries a time the user gave. A reminder without one
    /// is due on its day, with no hour.
    let hasTime: Bool
    /// An event's length. Zero for reminders.
    let duration: TimeInterval
}

enum QuickAddError: Error, Equatable {
    case empty
    case noTitle
    case twoDates
    case ambiguousHour(String)
    case unreadableDate
    case inThePast
    case tooFar

    /// What the face says instead of a preview.
    var message: String {
        switch self {
        case .empty: return "Type an event or a reminder"
        case .noTitle: return "Add a name as well as a time"
        case .twoDates: return "That has two dates in it — use one"
        case .ambiguousHour(let hour): return "Is \(hour) morning or evening? Add am or pm"
        case .unreadableDate: return "Couldn't tell which day that is"
        case .inThePast: return "That time has already passed"
        case .tooFar: return "That's more than a few years away"
        }
    }
}

enum QuickAddParser {
    /// An event's length when the text doesn't give one: Calendar's own
    /// default for a new event.
    static let defaultDuration: TimeInterval = 3600

    static func parse(_ raw: String, now: Date = Date(), calendar: Calendar = .current) -> Result<QuickAddDraft, QuickAddError> {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure(.empty) }

        // "remind me to …" / "remind me …": a reminder, whatever else it says.
        var forceReminder = false
        if let range = text.range(of: #"^\s*remind me( to| about)?\b"#, options: [.regularExpression, .caseInsensitive]) {
            forceReminder = true
            text.removeSubrange(range)
        }

        // "for 45 minutes", "for 2 hours": the event's length.
        var duration = defaultDuration
        if let (range, seconds) = firstSpan(in: text, pattern: #"\bfor (\d{1,3}|an?|one|half an?) ?(minutes?|mins?|m|hours?|hrs?|h)\b"#) {
            duration = seconds
            text.removeSubrange(range)
        }

        var date: Date?
        var hasTime = false

        // "in 30 min", "in an hour": a moment from now, which the detector
        // doesn't find.
        if let (range, seconds) = firstSpan(in: text, pattern: #"\bin (\d{1,4}|an?|one|half an?) ?(minutes?|mins?|m|hours?|hrs?|h)\b"#) {
            date = Self.wholeMinute(now.addingTimeInterval(seconds))
            hasTime = true
            text.removeSubrange(range)
        }

        let matches = Self.dateMatches(in: text)
        if date != nil, !matches.isEmpty { return .failure(.twoDates) }
        if matches.count > 1 { return .failure(.twoDates) }

        if let match = matches.first, let found = match.date, let range = Range(match.range, in: text) {
            var span = range
            // The detector reads a meal as a time of day — "Lunch tomorrow"
            // is noon tomorrow — and takes the word with it. The word is the
            // title; give it back.
            if let meal = text[span].range(of: #"^(breakfast|brunch|lunch|dinner|supper)\b\s*"#,
                                           options: [.regularExpression, .caseInsensitive]) {
                span = meal.upperBound..<span.upperBound
            }
            let phrase = String(text[span])
            hasTime = Self.namesClockTime(phrase)
            date = hasTime ? found : calendar.startOfDay(for: found)
            if match.duration > 0 { duration = match.duration }
            text.removeSubrange(span)
        } else if date == nil, let hour = Self.bareHour(in: text) {
            // "Standup at 9": no day for the detector to anchor it, and no
            // am or pm. Nine in the morning is a fair guess, but a guess.
            return .failure(.ambiguousHour(hour))
        } else if date == nil,
                  text.range(of: #"\b\d{1,2}(st|nd|rd|th)\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
            // "Pay rent on the 1st": plainly a date, but not one the detector
            // could place. Saying so beats a reminder titled "on the 1st".
            return .failure(.unreadableDate)
        }

        let title = Self.title(from: text, capitalise: forceReminder)
        guard !title.isEmpty else { return .failure(.noTitle) }

        if let date {
            if hasTime, date < now.addingTimeInterval(-60) { return .failure(.inThePast) }
            if !hasTime, date < calendar.startOfDay(for: now) { return .failure(.inThePast) }
            if date > now.addingTimeInterval(4 * 366 * 86400) { return .failure(.tooFar) }
        }

        let kind: QuickAddDraft.Kind = (forceReminder || !hasTime) ? .reminder : .event
        return .success(QuickAddDraft(
            kind: kind,
            title: title,
            date: date,
            hasTime: hasTime,
            duration: kind == .event ? duration : 0
        ))
    }

    // MARK: - Pieces

    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)

    private static func dateMatches(in text: String) -> [NSTextCheckingResult] {
        guard let detector else { return [] }
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .filter { $0.date != nil }
    }

    /// A clock time, as opposed to a day or a part of one.
    static func namesClockTime(_ phrase: String) -> Bool {
        let patterns = [
            #"\d{1,2}(:\d{2})?\s*(am|pm|a\.m\.|p\.m\.)"#,
            #"\b\d{1,2}[:.]\d{2}\b"#,
            #"\b(at|@)\s*\d{1,2}\b"#,
            #"\b(noon|midday|midnight)\b"#,
            #"\b\d{1,2}\s*[-–]\s*\d{1,2}"#,
        ]
        return patterns.contains { phrase.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
    }

    /// "at 9", "at 10:30", with no am or pm after it.
    private static func bareHour(in text: String) -> String? {
        guard let range = text.range(of: #"\b(at|@)\s*\d{1,2}(:\d{2})?\b(?!\s*(am|pm|a\.m|p\.m))"#,
                                     options: [.regularExpression, .caseInsensitive])
        else { return nil }
        return text[range].replacingOccurrences(of: #"^(at|@)\s*"#, with: "", options: [.regularExpression, .caseInsensitive])
    }

    /// The first match of a "N minutes / hours" pattern, and how many
    /// seconds it says.
    private static func firstSpan(in text: String, pattern: String) -> (Range<String.Index>, TimeInterval)? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text),
              let countRange = Range(match.range(at: 1), in: text),
              let unitRange = Range(match.range(at: 2), in: text)
        else { return nil }
        let countWord = text[countRange].lowercased()
        let count: Double
        switch countWord {
        case "a", "an", "one": count = 1
        case let word where word.hasPrefix("half"): count = 0.5
        default: count = Double(countWord) ?? 0
        }
        guard count > 0 else { return nil }
        let unit = text[unitRange].lowercased()
        let seconds = unit.hasPrefix("h") ? count * 3600 : count * 60
        // "in half a minute" isn't a time anyone schedules; "half an hour" is.
        guard seconds >= 60 else { return nil }
        return (range, seconds)
    }

    /// Rounded up to the next whole minute, so "in 30 min" lands on a time
    /// a calendar would show.
    private static func wholeMinute(_ date: Date) -> Date {
        let seconds = date.timeIntervalSinceReferenceDate
        let floored = (seconds / 60).rounded(.down) * 60
        return Date(timeIntervalSinceReferenceDate: floored == seconds ? seconds : floored + 60)
    }

    /// What's left once the date is out: joining words that were holding on
    /// to it ("at", "on", "by") trimmed from the ends, spaces closed up.
    private static func title(from text: String, capitalise: Bool) -> String {
        var words = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        let joiners: Set<String> = ["at", "on", "by", "for", "from", "to", "in", "this", "next", "@", "-", "–", "—", ",", "and"]
        while let last = words.last, joiners.contains(last.lowercased()) { words.removeLast() }
        while let first = words.first, joiners.contains(first.lowercased()) { words.removeFirst() }
        var title = words.joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,;:-–—"))
        if capitalise, let first = title.first {
            title = first.uppercased() + title.dropFirst()
        }
        return title
    }
}
