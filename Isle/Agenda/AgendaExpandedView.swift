//
//  AgendaExpandedView.swift
//
//  The agenda face of the expanded panel. Mirrors the other faces' skeleton
//  — a 114pt block on the left where the album art and the Claude marker
//  sit, here a date card, then a text column — so switching faces keeps the
//  panel's weight where it was. It is the one face that asks for a taller
//  panel every time (see `AgendaLayout.contentHeight`): a fifth line, and a
//  field to add to it.
//
//  Calm by default: the day's list, as it always was, with the quick-add
//  field along the bottom. One click away, under the date card, the same day
//  as a timeline — free time at a glance — and the week, whose days pick
//  which one the face is on. Today, every time the panel opens.
//
//  The list shows five lines at a time and scrolls for the rest — a
//  two-finger swipe while hovering, with the bottom edge fading to say there
//  is more. Sideways swipes stay the faces' own (see `FacePager`); nothing
//  here moves sideways. The date card opens Calendar: this is a glance at
//  the notch, not the Calendar app. An event in progress reads "Now"; an
//  all-day event "All day"; a reminder with a date but no time "Today"; an
//  overdue reminder keeps its time, in the warning tint. A reminder's circle
//  ticks it off; a call has its Join.
//

import SwiftUI
import EventKit

struct AgendaExpandedView: View {
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject var agenda: AgendaModel
    var palette: ArtworkPalette

    enum Mode: CaseIterable {
        case day
        case timeline
        case week

        var symbol: String {
            switch self {
            case .day: return "list.bullet"
            case .timeline: return "calendar.day.timeline.left"
            case .week: return "calendar"
            }
        }

        var title: String {
            switch self {
            case .day: return "Day"
            case .timeline: return "Timeline"
            case .week: return "Week"
            }
        }
    }

    /// Per panel: the face opens on today's list every time, and a view
    /// chosen last time doesn't follow the user into the next glance.
    @State private var mode: Mode = .day
    /// The day the face is on. Nil is today — kept as nil rather than a date
    /// so a panel left open over midnight moves on with the day.
    @State private var selectedDay: Date?
    /// The week the strip shows, in weeks from this one.
    @State private var weekOffset = 0

    private var lead: TimeInterval { viewModel.agendaJoinLead }

    var body: some View {
        // On the minute, not every frame and not a minute from whenever the
        // face appeared: "Now" arrives as a meeting starts, an overdue
        // reminder turns amber, the now line steps along the timeline, and a
        // call's Join comes forward, all on the minute they're true.
        TimelineView(.everyMinute) { context in
            let now = context.date
            let day = selectedDay ?? now
            HStack(alignment: .top, spacing: 14) {
                VStack(spacing: 0) {
                    Button(action: Self.openCalendar) {
                        dateCard(for: day, isToday: Calendar.current.isDate(day, inSameDayAs: now))
                            .frame(width: AgendaLayout.cardSide, height: AgendaLayout.cardSide)
                            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open Calendar")
                    .offset(y: -AgendaLayout.cardRaise)

                    Spacer(minLength: 0)
                    switcher
                }
                .frame(width: AgendaLayout.cardSide)

                VStack(alignment: .leading, spacing: 0) {
                    main(day: day, now: now)
                        .frame(maxHeight: .infinity, alignment: .top)
                    QuickAddBar(viewModel: viewModel, agenda: agenda)
                        .padding(.trailing, AgendaLayout.trailingInset)
                }
                .frame(width: AgendaLayout.columnWidth, alignment: .leading)
            }
            // Laid out at its own height and pinned to the top, whatever the
            // panel's height is at the moment, as the shelf is. Centred in a
            // shorter panel — the neighbour's, mid-swipe — the face rode 20pt
            // up under the camera, and jumped back down the frame the swipe
            // landed and the content area took this face's height (and up
            // again leaving). Now the panel's edge cuts the field off instead.
            // `minHeight: 0`, or the flexible frame takes the child's 144 as
            // its least height and the pager centres that instead.
            .frame(height: AgendaLayout.contentHeight, alignment: .top)
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
            .foregroundStyle(.white)
        }
    }

    // MARK: - Views

    @ViewBuilder
    private func main(day: Date, now: Date) -> some View {
        switch mode {
        case .day:
            dayList(day: day, now: now, rows: composingRows(5))
                .padding(.top, 1)
        case .timeline:
            AgendaTimelineView(items: items(on: day, now: now, includingEnded: true), day: day, now: now)
                .padding(.top, AgendaLayout.cutoutClearance)
                .padding(.trailing, AgendaLayout.trailingInset)
        case .week:
            VStack(alignment: .leading, spacing: 4) {
                AgendaWeekStrip(
                    days: AgendaLayout.week(offset: weekOffset, from: now),
                    selected: day, now: now, palette: palette,
                    items: { agenda.days.items(on: $0) },
                    canPage: (back: weekOffset > -1, forward: weekOffset < 4),
                    page: { step in withAnimation(.easeInOut(duration: 0.2)) { weekOffset += step } },
                    select: { picked in
                        selectedDay = Calendar.current.isDate(picked, inSameDayAs: now) ? nil : picked
                    }
                )
                .padding(.top, AgendaLayout.cutoutClearance - 1)
                .padding(.trailing, AgendaLayout.trailingInset)
                dayList(day: day, now: now, rows: composingRows(3))
            }
        }
    }

    /// Lines of list to show: fewer while the quick-add preview stands
    /// between the list and the field.
    private func composingRows(_ rows: Int) -> Int {
        agenda.review == nil ? rows : max(1, rows - 2)
    }

    /// The way between the three views, under the date card and level with
    /// the quick-add field.
    private var switcher: some View {
        HStack(spacing: 2) {
            ForEach(Mode.allCases, id: \.self) { option in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        mode = option
                        // Back to this week whenever the strip is opened.
                        if option == .week { weekOffset = 0 }
                    }
                } label: {
                    Image(systemName: option.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(mode == option ? 0.95 : 0.45))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(
                            Capsule().fill(.white.opacity(mode == option ? 0.16 : 0))
                        )
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.title)
            }
        }
        .padding(2)
        .frame(height: AgendaLayout.barHeight)
        .background(Capsule().fill(.white.opacity(0.07)))
    }

    // MARK: - Date card

    private func dateCard(for date: Date, isToday: Bool) -> some View {
        VStack(spacing: 0) {
            Text(date.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                .font(.system(size: 12, weight: .semibold))
                .tracking(1.5)
                .foregroundStyle(isToday ? palette.accent : .white.opacity(0.6))
            Text(date.formatted(.dateTime.day()))
                .font(.system(size: 52, weight: .bold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.vertical, -4)
            Text(date.formatted(.dateTime.month(.wide)))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.islandSecondary(0.6))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.white.opacity(0.07))
        )
        .contentTransition(.numericText())
    }

    /// Calendar opens on whatever it last showed, which is today unless the
    /// user left it elsewhere. Steering it to a date would take an Apple
    /// Event, and with it a second Automation prompt; opening the app is the
    /// honest version of "show me the rest".
    private static func openCalendar() {
        NSWorkspace.shared.open(URL(string: "ical://")!)
    }

    // MARK: - Items

    /// What the face lists for `day`. Today it's what's left — the list the
    /// island and the home tile read, so the three agree — unless the
    /// timeline wants the morning too. Another day, everything on it.
    /// Reminders ticked a moment ago stay, ticked, until their Undo goes.
    private func items(on day: Date, now: Date, includingEnded: Bool = false) -> [AgendaItem] {
        let isToday = Calendar.current.isDate(day, inSameDayAs: now)
        let base = isToday && !includingEnded ? viewModel.agendaItems : agenda.days.items(on: day)
        return agenda.withTicked(base, on: Calendar.current.startOfDay(for: day))
    }

    // MARK: - List

    private func dayList(day: Date, now: Date, rows visible: Int) -> some View {
        let items = items(on: day, now: now)
        let isToday = Calendar.current.isDate(day, inSameDayAs: now)
        return Group {
            if items.isEmpty {
                emptyState(day: day, isToday: isToday, compact: mode == .week)
            } else {
                rows(items, day: day, now: now, visible: visible)
            }
        }
    }

    private func rows(_ items: [AgendaItem], day: Date, now: Date, visible: Int) -> some View {
        let overflows = items.count > visible
        return ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(items) { item in
                    AgendaRow(
                        item: item, day: day, now: now, lead: lead,
                        tick: agenda.ticked[item.id],
                        onTick: { agenda.tick(item) },
                        onUndo: { agenda.undo(item) }
                    )
                }
            }
            .padding(.trailing, AgendaLayout.trailingInset)
        }
        .scrollIndicators(.hidden)
        .frame(height: AgendaLayout.rowHeight * CGFloat(visible))
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

    // MARK: - Empty

    /// Mirrors the music face's idle placeholder — same fonts, weights and
    /// placement — so switching faces doesn't jump the text around. Under
    /// the week strip, a single quieter line.
    @ViewBuilder
    private func emptyState(day: Date, isToday: Bool, compact: Bool) -> some View {
        if compact {
            Text(isToday ? emptyHeadline : "Nothing on \(day.formatted(.dateTime.weekday(.wide)))")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.islandSecondary(0.55))
                .padding(.top, 6)
                .padding(.leading, 2)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                Text(isToday ? emptyHeadline : "Nothing on \(day.formatted(.dateTime.weekday(.wide)))")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                Spacer().frame(height: 2)

                Text(isToday ? emptyDetail : "No events or reminders on \(day.formatted(.dateTime.day().month(.wide))).")
                    .font(.system(size: 12.5, weight: .regular))
                    .foregroundStyle(.islandSecondary(0.72))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.trailing, AgendaLayout.trailingInset)
            }
            .padding(.top, 22)
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

// MARK: - Row

/// One line: a time, a mark, a title, and on the right whatever the line
/// can do — Join a call, Undo a tick.
struct AgendaRow: View {
    let item: AgendaItem
    /// The day the line is listed under.
    let day: Date
    let now: Date
    let lead: TimeInterval
    let tick: AgendaModel.Tick?
    let onTick: () -> Void
    let onUndo: () -> Void

    /// Width of the time column, so titles line up whatever the time reads.
    static let timeWidth: CGFloat = 58

    /// The warm tint Isle already uses for "worth noticing, not urgent".
    static let overdue = Color(hex: "#E8842B")

    private var isTicked: Bool { tick != nil && tick?.restoring == false }

    private var isToday: Bool { Calendar.current.isDate(day, inSameDayAs: now) }

    /// An event already over, on a day looked back at.
    private var isPast: Bool {
        item.kind == .event && (item.end ?? item.date) <= now
    }

    var body: some View {
        let label = timeLabel
        HStack(spacing: 10) {
            Text(label.text)
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(label.emphasised ? Self.overdue : .white.opacity(0.55))
                .lineLimit(1)
                .frame(width: Self.timeWidth, alignment: .trailing)

            mark

            Text(item.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(isTicked ? 0.45 : 1))
                .strikethrough(isTicked, color: .white.opacity(0.45))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)

            trailing
        }
        .opacity(isPast ? 0.5 : 1)
        .frame(height: AgendaLayout.rowHeight)
    }

    // MARK: Mark

    /// A filled dot for an event; for a reminder, Reminders' own circle,
    /// which ticks it off — both in the calendar's or list's colour.
    @ViewBuilder
    private var mark: some View {
        switch item.kind {
        case .event:
            Circle()
                .fill(item.color)
                .frame(width: 8, height: 8)
        case .reminder:
            if item.reminderID == nil {
                // Nothing to tick it off by (a fixture without one).
                ring
            } else {
                Button(action: onTick) {
                    ZStack {
                        if isTicked {
                            Circle().fill(item.color)
                            Image(systemName: "checkmark")
                                .font(.system(size: 6.5, weight: .heavy))
                                .foregroundStyle(.black.opacity(0.8))
                        } else {
                            ring
                        }
                    }
                    .frame(width: 11, height: 11)
                    // A target bigger than the circle.
                    .frame(width: 17, height: AgendaLayout.rowHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isTicked ? "Completed" : "Mark as completed")
                .padding(.horizontal, -4)
            }
        }
    }

    private var ring: some View {
        Circle()
            .strokeBorder(item.color, lineWidth: 1.5)
            .frame(width: 9, height: 9)
    }

    // MARK: Trailing

    @ViewBuilder
    private var trailing: some View {
        if isTicked {
            if !item.recurs {
                RowPill(title: "Undo", fill: .white.opacity(0.16), foreground: .white, action: onUndo)
                    .transition(.opacity)
            }
        } else {
            switch AgendaLayout.join(for: item, at: now, lead: lead) {
            case .now(let url):
                JoinPill(tint: item.color, url: url)
            case .later(let url):
                Button { NSWorkspace.shared.open(url) } label: {
                    Image(systemName: "video.fill")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.islandSecondary(0.45))
                        .frame(width: 22, height: AgendaLayout.rowHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Join call")
            case .none:
                EmptyView()
            }
        }
    }

    // MARK: Time

    private var timeLabel: (text: String, emphasised: Bool) {
        switch item.kind {
        case .event:
            if item.isAllDay { return ("All day", false) }
            if isToday, item.date <= now { return ("Now", false) }
            // Began on an earlier day, still going on this one.
            if item.date < Calendar.current.startOfDay(for: day) { return ("Ongoing", false) }
            return (Self.time(item.date), false)
        case .reminder:
            if item.isAllDay { return (isToday ? "Today" : "Due", false) }
            return (Self.time(item.date), isToday && item.date < now)
        }
    }

    private static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}

// MARK: - Pills

/// "Join", in the call's own calendar colour. Opens the link the event
/// carries, in whatever app claims it — Zoom, Teams, FaceTime, a browser.
struct JoinPill: View {
    var tint: Color
    var url: URL
    var compact = false

    var body: some View {
        Button { NSWorkspace.shared.open(url) } label: {
            HStack(spacing: 3) {
                Image(systemName: "video.fill")
                    .font(.system(size: compact ? 8 : 8.5, weight: .bold))
                Text("Join")
                    .font(.system(size: compact ? 10 : 10.5, weight: .bold))
            }
            .foregroundStyle(.black.opacity(0.85))
            .padding(.horizontal, compact ? 7 : 8)
            .frame(height: compact ? 18 : 17)
            .background(Capsule().fill(tint))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Join call")
    }
}

/// A small capsule button at the end of a line.
struct RowPill: View {
    var title: String
    var fill: Color
    var foreground: Color
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(foreground)
                .padding(.horizontal, 8)
                .frame(height: 17)
                .background(Capsule().fill(fill))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
