//
//  AgendaLayout.swift
//
//  The agenda face's numbers, and the small pieces of reasoning its views
//  share: when a call's Join comes forward, what window of the day the
//  timeline spans, how overlapping events stack in it, and the one line
//  that says whether you're free. Pure, so the face, the home tile and a
//  render all reach the same answers.
//

import Foundation

enum AgendaLayout {
    // MARK: - Size

    /// The face's content height — what it asks the panel for (see
    /// `NotchViewModel.faceContentHeight`). The date card and the way between
    /// views on the left; on the right five lines of the day, and the
    /// quick-add field along the bottom, level with the switcher. 146pt of
    /// panel holds four lines and nothing else; this is that plus a line and
    /// the field, and well inside the shared cap.
    static let contentHeight: CGFloat = 144

    /// The date card's side: the album's footprint, so the panel keeps its
    /// weight where it was switching faces.
    static let cardSide: CGFloat = 114

    /// Lifted into the housing band, as the album is. Safe: the card is left
    /// of the camera cutout, on ordinary screen. The album is centred in the
    /// 104pt content area and raised 11, which lands its top 16 above the
    /// content's; this face is pinned to the top, so it's raised the 16.
    static let cardRaise: CGFloat = 16

    /// The right-hand column.
    static let columnWidth: CGFloat = 340

    /// How far the column's contents stop short of its right edge.
    static let trailingInset: CGFloat = 8

    /// One line of the list.
    static let rowHeight: CGFloat = 22

    /// The quick-add field and the view switcher: one height, one baseline.
    static let barHeight: CGFloat = 24

    /// Hard edges in the column — the week strip's selection, the timeline
    /// bar, its now line — sit under the camera cutout, whose hardware edge
    /// is a point below the band the safe area reports. They keep this much
    /// clear of the band; the content area already starts 2pt below it.
    static let cutoutClearance: CGFloat = 4

    // MARK: - Join

    enum JoinState: Equatable {
        /// A call starting soon or under way: the Join button.
        case now(URL)
        /// A call later on: a quiet camera mark, which joins too.
        case later(URL)
        case none
    }

    /// Whether, and how loudly, an item offers Join at `now`. Only events
    /// `MeetingLink` found a link in; none once the event is over.
    static func join(for item: AgendaItem, at now: Date, lead: TimeInterval) -> JoinState {
        guard item.kind == .event, let url = item.joinURL, let end = item.end, end > now else { return .none }
        return item.date.addingTimeInterval(-lead) <= now ? .now(url) : .later(url)
    }

    /// The call the home tile offers Join for: the first one in `items`
    /// whose Join is forward.
    static func joinable(_ items: [AgendaItem], at now: Date, lead: TimeInterval) -> (AgendaItem, URL)? {
        for item in items {
            if case .now(let url) = join(for: item, at: now, lead: lead) { return (item, url) }
        }
        return nil
    }

    // MARK: - Timeline

    /// The stretch of `day` the timeline draws. Today, from an hour before
    /// now — what's past is past — to the end of the last event; another
    /// day, the working day widened to whatever is on it. Never less than
    /// six hours, so an empty afternoon still reads as an afternoon, and
    /// never past the day's own ends.
    static func timelineWindow(for events: [AgendaItem], day: Date, now: Date,
                               calendar: Calendar = .current) -> DateInterval {
        let dayStart = calendar.startOfDay(for: day)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86400)
        let timed = events.filter { !$0.isAllDay && $0.kind == .event }
        let hour: TimeInterval = 3600
        func floorHour(_ d: Date) -> Date { calendar.dateInterval(of: .hour, for: d)?.start ?? d }
        func ceilHour(_ d: Date) -> Date {
            let f = floorHour(d)
            return f == d ? d : f.addingTimeInterval(hour)
        }

        var start: Date
        var end: Date
        if calendar.isDate(day, inSameDayAs: now) {
            start = floorHour(now.addingTimeInterval(-hour))
            end = timed.compactMap(\.end).filter { $0 > start }.max().map(ceilHour) ?? start
        } else {
            let nine = dayStart.addingTimeInterval(9 * hour)
            let six = dayStart.addingTimeInterval(18 * hour)
            start = min(nine, timed.map(\.date).min().map(floorHour) ?? nine)
            end = max(six, timed.compactMap(\.end).max().map(ceilHour) ?? six)
        }
        start = max(start, dayStart)
        end = min(max(end, start.addingTimeInterval(6 * hour)), dayEnd)
        if end.timeIntervalSince(start) < 6 * hour {
            start = max(dayStart, end.addingTimeInterval(-6 * hour))
        }
        return DateInterval(start: start, end: end)
    }

    /// Where one event sits in the timeline's height: its lane, and how
    /// many lanes the run of overlapping events it belongs to needs.
    struct Placement {
        let item: AgendaItem
        let lane: Int
        let lanes: Int
    }

    /// Timed events placed in lanes so overlapping ones sit one above the
    /// other rather than on top of each other — counted per run of
    /// overlapping events, so a meeting that overlaps nothing keeps the
    /// bar's full height. Three lanes at most; a fourth overlapping event
    /// shares the last.
    static func lanes(_ events: [AgendaItem]) -> [Placement] {
        let timed = events.filter { !$0.isAllDay && $0.kind == .event }.sorted { $0.date < $1.date }
        var result: [Placement] = []
        var run: [(AgendaItem, Int)] = []
        var runEnd = Date.distantPast
        var laneEnds: [Date] = []

        func close() {
            let count = max(1, laneEnds.count)
            result += run.map { Placement(item: $0.0, lane: $0.1, lanes: count) }
            run = []
            laneEnds = []
        }

        for item in timed {
            let end = max(item.end ?? item.date, item.date)
            if item.date >= runEnd { close() }
            runEnd = run.isEmpty ? end : max(runEnd, end)
            if let lane = laneEnds.firstIndex(where: { $0 <= item.date }) {
                laneEnds[lane] = end
                run.append((item, lane))
            } else if laneEnds.count < 3 {
                laneEnds.append(end)
                run.append((item, laneEnds.count - 1))
            } else {
                laneEnds[2] = max(laneEnds[2], end)
                run.append((item, 2))
            }
        }
        close()
        return result
    }

    /// The one line under the timeline. Today: what you're in, or how long
    /// you're free and what ends it. Another day: how much is on it. Only
    /// from events on the calendar — "free" means nothing booked, which is
    /// all the calendar can say.
    static func summary(for events: [AgendaItem], day: Date, now: Date, calendar: Calendar = .current) -> String {
        let timed = events.filter { !$0.isAllDay && $0.kind == .event }.sorted { $0.date < $1.date }
        let time = { (d: Date) in d.formatted(date: .omitted, time: .shortened) }

        guard calendar.isDate(day, inSameDayAs: now) else {
            guard let first = timed.first else {
                let allDay = events.filter { $0.isAllDay && $0.kind == .event }.count
                return allDay > 0 ? "All-day only" : "Nothing booked"
            }
            return timed.count == 1
                ? "One event, at \(time(first.date))"
                : "\(timed.count) events, from \(time(first.date))"
        }

        if let current = timed.last(where: { $0.date <= now && ($0.end ?? $0.date) > now }) {
            // Busy until the end of the run of back-to-back or overlapping
            // events this one belongs to.
            var busyUntil = current.end ?? now
            for event in timed where event.date <= busyUntil {
                busyUntil = max(busyUntil, event.end ?? event.date)
            }
            return "In \(current.title) · busy until \(time(busyUntil))"
        }
        if let next = timed.first(where: { $0.date > now }) {
            return "Free until \(time(next.date)) · \(next.title)"
        }
        return "Free for the rest of the day"
    }

    // MARK: - Days

    /// Up to three colours for a day's dots: its items' calendar and list
    /// colours, each once, in the order they come.
    static func dotColors(_ items: [AgendaItem]) -> [AgendaItem] {
        var seen: [AgendaItem] = []
        for item in items where !seen.contains(where: { $0.color == item.color }) {
            seen.append(item)
            if seen.count == 3 { break }
        }
        return seen
    }

    /// The seven days of the week `offset` weeks from the one holding
    /// `now`, starting on the user's first weekday.
    static func week(offset: Int, from now: Date, calendar: Calendar = .current) -> [Date] {
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: 7 * offset, to: thisWeek) ?? thisWeek
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }
}
