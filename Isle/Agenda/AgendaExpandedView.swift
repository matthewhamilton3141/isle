//
//  AgendaExpandedView.swift
//
//  The agenda face of the expanded panel: what's left of today. Mirrors the
//  other two faces' skeleton — a 114pt block on the left where the album art
//  and the Claude marker sit, here a date card, then a text column — so
//  switching faces keeps the panel's weight where it was.
//
//  The column shows three lines at a time, each a time, a coloured mark and
//  a title, and scrolls for the rest — a two-finger swipe while hovering,
//  with the bottom edge fading to say there is more. The date card opens
//  Calendar: this is a glance at the notch, not the Calendar app. An event in
//  progress reads "Now"; an all-day event "All day"; a reminder with a date
//  but no time "Today"; an overdue reminder keeps its time, in the warning
//  tint.
//

import SwiftUI
import EventKit

struct AgendaExpandedView: View {
    @ObservedObject var viewModel: NotchViewModel
    var palette: ArtworkPalette

    /// Lines visible at once; the rest scroll.
    private static let visibleRows = 3

    /// Height of one line, and so of the scrolling window.
    private static let rowHeight: CGFloat = 22

    /// The warm tint Isle already uses for "worth noticing, not urgent".
    private static let overdue = Color(hex: "#E8842B")

    var body: some View {
        // Once a minute: enough for "Now" to appear as a meeting starts and
        // for an overdue reminder to turn amber, without a per-frame clock.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            HStack(spacing: 14) {
                Button(action: Self.openCalendar) {
                    dateCard(for: context.date)
                        // The album cover's exact footprint (size + raise).
                        // Safe to raise into the housing band: it sits left
                        // of the camera cutout, on ordinary screen, just like
                        // the album.
                        .frame(width: 114, height: 114)
                        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open Calendar")
                .offset(y: -10)

                VStack(alignment: .leading, spacing: 0) {
                    Spacer(minLength: 0)
                    if viewModel.agendaItems.isEmpty {
                        emptyState
                    } else {
                        rows(at: context.date)
                    }
                    Spacer(minLength: 0)
                }
                .frame(minWidth: 340, maxWidth: 340, maxHeight: .infinity, alignment: .leading)
                .offset(y: -1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(.white)
        }
    }

    // MARK: - Date card

    private func dateCard(for date: Date) -> some View {
        VStack(spacing: 0) {
            Text(date.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                .font(.system(size: 12, weight: .semibold))
                .tracking(1.5)
                .foregroundStyle(palette.accent)
            Text(date.formatted(.dateTime.day()))
                .font(.system(size: 52, weight: .bold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.vertical, -4)
            Text(date.formatted(.dateTime.month(.wide)))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.white.opacity(0.07))
        )
    }

    /// Calendar opens on whatever it last showed, which is today unless the
    /// user left it elsewhere. Steering it to a date would take an Apple
    /// Event, and with it a second Automation prompt; opening the app is the
    /// honest version of "show me the rest".
    private static func openCalendar() {
        NSWorkspace.shared.open(URL(string: "ical://")!)
    }

    // MARK: - Rows

    private func rows(at now: Date) -> some View {
        let items = viewModel.agendaItems
        let overflows = items.count > Self.visibleRows
        return ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(items) { item in
                    row(item, at: now)
                }
            }
            // Clear the face switcher parked in the panel's bottom-right corner.
            .padding(.trailing, 44)
        }
        .scrollIndicators(.hidden)
        .frame(height: Self.rowHeight * CGFloat(Self.visibleRows))
        // The last visible line fades out when there is more below it — the
        // only cue this list scrolls, since the indicators are hidden and the
        // pointer is only ever passing through.
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: overflows ? 0.8 : 1),
                    .init(color: overflows ? .black.opacity(0.15) : .black, location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            )
        )
    }

    /// Width of the time column, so titles line up whatever the time reads.
    private static let timeWidth: CGFloat = 58

    private func row(_ item: AgendaItem, at now: Date) -> some View {
        let label = timeLabel(for: item, at: now)
        return HStack(spacing: 10) {
            Text(label.text)
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(label.emphasised ? Self.overdue : .white.opacity(0.55))
                .lineLimit(1)
                .frame(width: Self.timeWidth, alignment: .trailing)

            mark(for: item)

            Text(item.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(height: Self.rowHeight)
    }

    /// A filled dot for an event, a hollow ring for a reminder — Reminders'
    /// own unchecked circle — both in the calendar's or list's colour.
    @ViewBuilder
    private func mark(for item: AgendaItem) -> some View {
        switch item.kind {
        case .event:
            Circle()
                .fill(item.color)
                .frame(width: 8, height: 8)
        case .reminder:
            Circle()
                .strokeBorder(item.color, lineWidth: 1.5)
                .frame(width: 9, height: 9)
        }
    }

    private func timeLabel(for item: AgendaItem, at now: Date) -> (text: String, emphasised: Bool) {
        switch item.kind {
        case .event:
            if item.isAllDay { return ("All day", false) }
            if item.date <= now { return ("Now", false) }
            return (Self.time(item.date), false)
        case .reminder:
            if item.isAllDay { return ("Today", false) }
            return (Self.time(item.date), item.date < now)
        }
    }

    private static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    // MARK: - Empty

    /// Mirrors the music face's idle placeholder — same fonts, weights and
    /// placement — so switching faces doesn't jump the text around.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(emptyHeadline)
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Spacer().frame(height: 2)

            Text(emptyDetail)
                .font(.system(size: 12.5, weight: .regular))
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.trailing, 44)
        }
    }

    /// Whether every source that is switched on has had its access declined
    /// — the one empty state that isn't "nothing on today".
    private var accessDeclined: Bool {
        let events = viewModel.agendaShowsEvents
        let reminders = viewModel.agendaShowsReminders
        let eventsBlocked = !events || AgendaMonitor.Access.to(.event) == .declined
        let remindersBlocked = !reminders || AgendaMonitor.Access.to(.reminder) == .declined
        return eventsBlocked && remindersBlocked
    }

    private var emptyHeadline: String {
        accessDeclined ? "Access declined" : "Nothing more today"
    }

    private var emptyDetail: String {
        if accessDeclined {
            return "Allow Isle under Calendars or Reminders in System Settings → Privacy & Security."
        }
        switch (viewModel.agendaShowsEvents, viewModel.agendaShowsReminders) {
        case (true, true): return "No events or reminders left for today."
        case (true, false): return "No more events today."
        default: return "No reminders due today."
        }
    }
}
