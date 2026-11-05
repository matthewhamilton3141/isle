//
//  AgendaTimelineView.swift
//
//  A day as a bar of hours: events as blocks in their calendars' colours,
//  the gaps between them the free time, and on today a line at now with the
//  hours already gone dimmed behind it. All-day events ride above the bar as
//  chips, since they have no place along it; one line underneath says in
//  words what the bar shows.
//
//  The window is `AgendaLayout.timelineWindow`: today from an hour ago to the
//  last event's end, another day its working hours widened to fit. Drawn
//  from the minute the face's `TimelineView(.everyMinute)` hands down — the
//  now line steps once a minute, on the minute, and nothing redraws between.
//

import SwiftUI

struct AgendaTimelineView: View {
    let items: [AgendaItem]
    let day: Date
    let now: Date

    static let barHeight: CGFloat = 40

    private var isToday: Bool { Calendar.current.isDate(day, inSameDayAs: now) }

    var body: some View {
        let window = AgendaLayout.timelineWindow(for: items, day: day, now: now)
        let allDay = items.filter { $0.kind == .event && $0.isAllDay }
        VStack(alignment: .leading, spacing: 0) {
            if !allDay.isEmpty {
                allDayChips(allDay)
                    .padding(.bottom, 6)
            }
            GeometryReader { proxy in
                bar(window: window, width: proxy.size.width)
            }
            .frame(height: Self.barHeight)

            GeometryReader { proxy in
                hourLabels(window: window, width: proxy.size.width)
            }
            .frame(height: 12)
            .padding(.top, 3)

            Text(AgendaLayout.summary(for: items, day: day, now: now))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.top, 8)
        }
    }

    // MARK: - All day

    private func allDayChips(_ events: [AgendaItem]) -> some View {
        HStack(spacing: 5) {
            ForEach(events.prefix(3)) { event in
                HStack(spacing: 4) {
                    Circle().fill(event.color).frame(width: 6, height: 6)
                    Text(event.title)
                        .font(.system(size: 10.5, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.horizontal, 7)
                .frame(height: 17)
                .background(Capsule().fill(event.color.opacity(0.18)))
            }
            if events.count > 3 {
                Text("+\(events.count - 3)")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Bar

    private func x(_ date: Date, in window: DateInterval, width: CGFloat) -> CGFloat {
        let fraction = date.timeIntervalSince(window.start) / max(window.duration, 1)
        return CGFloat(min(max(fraction, 0), 1)) * width
    }

    private func bar(window: DateInterval, width: CGFloat) -> some View {
        let placed = AgendaLayout.lanes(items.filter { item in
            (item.end ?? item.date) > window.start && item.date < window.end
        })
        let gap: CGFloat = 2
        let nowX = x(now, in: window, width: width)

        return ZStack(alignment: .topLeading) {
            // The day's free time: the bar itself, empty.
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(.white.opacity(0.07))

            // Hour ticks, faint, so a block's length reads in hours.
            ForEach(hours(in: window), id: \.self) { hour in
                Rectangle()
                    .fill(.white.opacity(0.08))
                    .frame(width: 1, height: Self.barHeight)
                    .offset(x: x(hour, in: window, width: width))
            }

            ForEach(placed, id: \.item.id) { entry in
                let item = entry.item
                let lanes = entry.lanes
                let laneHeight = (Self.barHeight - 4 - gap * CGFloat(lanes - 1)) / CGFloat(lanes)
                let start = x(item.date, in: window, width: width)
                let end = x(item.end ?? item.date, in: window, width: width)
                let blockWidth = max(3, end - start - 1)
                let past = isToday && (item.end ?? item.date) <= now
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(item.color.opacity(past ? 0.4 : 0.9))
                    .overlay(alignment: .leading) {
                        // A title only where a word of it fits: a sliver
                        // reading "L…" says less than its colour does.
                        if blockWidth >= 34, laneHeight >= 13 {
                            Text(item.title)
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(.black.opacity(past ? 0.55 : 0.8))
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .padding(.horizontal, 4)
                        }
                    }
                    .frame(width: blockWidth, height: laneHeight)
                    .offset(x: start, y: 2 + CGFloat(entry.lane) * (laneHeight + gap))
            }

            if isToday, now > window.start, now < window.end {
                // The hours already gone, dimmed.
                Rectangle()
                    .fill(.black.opacity(0.35))
                    .frame(width: nowX, height: Self.barHeight)
                    .allowsHitTesting(false)
                nowLine
                    .offset(x: nowX - 1)
            }
        }
        .frame(width: width, height: Self.barHeight, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private var nowLine: some View {
        Capsule()
            .fill(.white)
            .frame(width: 2, height: Self.barHeight)
            .shadow(color: .black.opacity(0.5), radius: 1)
    }

    // MARK: - Hours

    private func hours(in window: DateInterval) -> [Date] {
        let calendar = Calendar.current
        var hour = calendar.dateInterval(of: .hour, for: window.start)?.start ?? window.start
        if hour < window.start { hour = hour.addingTimeInterval(3600) }
        var result: [Date] = []
        while hour <= window.end {
            result.append(hour)
            hour = hour.addingTimeInterval(3600)
        }
        return result
    }

    private func hourLabels(window: DateInterval, width: CGFloat) -> some View {
        let all = hours(in: window)
        // Every hour while there's room for its label; every other when the
        // day is long and the hours narrow.
        let perHour = width / CGFloat(max(window.duration / 3600, 1))
        let step = perHour >= 26 ? 1 : (perHour >= 13 ? 2 : 3)
        let shown = all.enumerated().filter { $0.offset % step == 0 }.map(\.element)
        return ZStack(alignment: .topLeading) {
            ForEach(shown, id: \.self) { hour in
                let position = x(hour, in: window, width: width)
                Text(hour.formatted(.dateTime.hour(.defaultDigits(amPM: .narrow))))
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.45))
                    .fixedSize()
                    // Centred on its tick, but kept inside the bar's ends.
                    .frame(width: 30)
                    .offset(x: min(max(position - 15, -6), width - 24))
            }
        }
        .frame(width: width, alignment: .topLeading)
    }
}
