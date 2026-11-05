//
//  AgendaMonitor.swift
//
//  Calendar events and reminders, read from EventKit, for two consumers:
//  the agenda face of the expanded panel, which lists what's left of today
//  and steps through the days around it, and the collapsed island, which
//  borrows a moment for an event a few minutes before it starts and a
//  reminder as it comes due.
//
//  And written, only ever on a click: a reminder ticked off (or back on, to
//  undo), and an event or reminder the user typed, read back to them and
//  confirmed. Both go through the same full access the reading already
//  holds; nothing here writes on its own account.
//
//  Scheduled, not polled. One fetch pulls everything inside the horizon, a
//  single timer is armed for the earliest thing that changes what's shown —
//  a toast to fire, an event ending and leaving the list — and the store's
//  own change notification (`EKEventStoreChanged`) re-fetches whenever
//  Calendar, Reminders or a sync touches anything. Waking from sleep and the
//  clock changing re-fetch too, since either can move "now" past things the
//  timer was waiting for.
//
//  Follows the shape of PowerMonitor: a plain @MainActor class with
//  callbacks, idempotent configuration, and no @Published state of its own —
//  NotchViewModel owns the observable side.
//
//  Says nothing it can't back up. All-day events and reminders with a date
//  but no time are *listed* but never announced: they have no moment, and
//  the time Reminders itself chooses for them is a preference Isle can't
//  read. A moment found late — the timer firing after the Mac wakes from a
//  long sleep — is dropped rather than announced, because "in 5 min" is a
//  claim about now, and macOS's own notification already covered it.
//

import AppKit
import EventKit
import SwiftUI

/// One line of the agenda: an event or a reminder, as the panel lists it.
struct AgendaItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case event
        case reminder
    }

    let id: String
    let kind: Kind
    let title: String
    /// Start of an event, or due time of a reminder. For an all-day event or
    /// a date-only reminder this is the start of that day, and `isAllDay`
    /// says so — the panel prints "All day" or "Today" rather than midnight.
    let date: Date
    /// When an event ends and leaves the list. Nil for reminders, which stay
    /// until completed.
    let end: Date?
    let isAllDay: Bool
    let color: Color
    /// The reminder's EventKit identifier, for ticking it off. Nil for events.
    var reminderID: String? = nil
    /// A repeating reminder. Ticking one moves it on to its next date, which
    /// unticking doesn't undo — so it gets no Undo.
    var recurs = false
    /// The event's call link, when `MeetingLink` found exactly one.
    var joinURL: URL? = nil
}

/// Everything in the days the agenda can be stepped through — the week
/// before this one to a few weeks ahead — filed by the start of each day.
/// Events are filed under every day they touch, ended or not; reminders under
/// the day they're due, an overdue one under today, as Reminders lists it.
struct AgendaDays: Equatable {
    var interval: DateInterval?
    var byDay: [Date: [AgendaItem]] = [:]

    static let empty = AgendaDays()

    func items(on day: Date, calendar: Calendar = .current) -> [AgendaItem] {
        byDay[calendar.startOfDay(for: day)] ?? []
    }

    /// Whether `day` falls inside what was fetched, so a day outside it can
    /// say "not loaded" rather than "nothing on".
    func covers(_ day: Date) -> Bool {
        interval?.contains(day) ?? false
    }
}

@MainActor
final class AgendaMonitor {
    /// A toast worth showing. Fired at the moment it describes, never for
    /// anything already past when the monitor started.
    var onEvent: ((IslandToast) -> Void)?

    /// What's left of today, sorted, every time it changes — a fetch, an event
    /// ending, the switches turning off (an empty list).
    var onAgendaChanged: (([AgendaItem]) -> Void)?

    /// The days around this one, every time a fetch lands — for the week
    /// strip, the timeline and another day's list. Published from the same
    /// fetch as the list above, so the two never disagree about today.
    var onDaysChanged: ((AgendaDays) -> Void)?

    /// What EventKit will let Isle read. Static because `SettingsView` and
    /// the agenda panel ask the same question to explain a switch that is on
    /// but showing nothing.
    enum Access {
        case granted
        case declined
        case undetermined

        static func to(_ type: EKEntityType) -> Access {
            switch EKEventStore.authorizationStatus(for: type) {
            case .fullAccess: return .granted
            case .notDetermined: return .undetermined
            default: return .declined
            }
        }
    }

    private let store = EKEventStore()
    private var watchesEvents = false
    private var watchesReminders = false
    private var leadMinutes = 0

    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var timer: Timer?

    /// A reload the store asked for, waiting out the burst it arrived in.
    private var reloadTask: Task<Void, Never>?

    /// How long a store change waits before the re-fetch runs. EventKit posts
    /// `EKEventStoreChanged` once per touched object during a sync — a
    /// calendar refreshing over iCloud can post dozens in a second — and each
    /// reload is a synchronous events query on the main thread plus a
    /// reminders fetch. Half a second collapses a burst into one reload and
    /// is still well inside a toast's own tolerance.
    private static let reloadCoalesce: Duration = .milliseconds(500)

    /// Bumped on every reload so a reminder fetch that lands after a newer
    /// reload started is discarded rather than overwriting its result.
    private var generation = 0

    private var pendingEvents: [Pending] = []
    private var pendingReminders: [Pending] = []
    private var listedEvents: [AgendaItem] = []
    private var listedReminders: [AgendaItem] = []
    private var dayEvents: [AgendaItem] = []
    private var dayReminders: [AgendaItem] = []
    private var dayInterval: DateInterval?

    /// Keys already announced, so a reload — every store change is one —
    /// can't re-arm something that has fired. Kept across stop/start too:
    /// flipping the switch off and on shouldn't repeat this morning's toast.
    private var fired: Set<String> = []

    /// When the next full re-fetch is due regardless of store changes, so an
    /// event that was beyond the horizon at the last fetch gets picked up.
    private var reloadDeadline: Date = .distantFuture

    /// A moment waiting for its timer.
    private struct Pending {
        let key: String
        let fireDate: Date
        let toast: IslandToast
    }

    /// What one fetch pulls from a reminder, computed off the main actor so
    /// the EKReminder objects never have to cross to it.
    private struct Candidate {
        let key: String
        let identifier: String
        let due: Date
        let hasTime: Bool
        let recurs: Bool
        let title: String
        let color: Color
    }

    /// How far ahead the toast fetch looks.
    private static let horizon: TimeInterval = 12 * 3600

    /// How often to re-fetch even when the store has been quiet — half the
    /// horizon, so nothing is ever closer than six hours without being seen.
    private static let refetchInterval: TimeInterval = 6 * 3600

    /// How late a moment may be found and still be announced. Covers timer
    /// tolerance and a brief sleep; anything later is stale and dropped.
    private static let grace: TimeInterval = 90

    private var isRunning: Bool { !observers.isEmpty }

    // MARK: - Lifecycle

    /// Brings the monitor in line with the three settings. Idempotent: the
    /// same values twice is a no-op, so the view model can call this from
    /// its general "apply settings" path without re-fetching each time.
    ///
    /// Access is requested only for a source that has just been switched
    /// on. That is what ties the macOS prompt to the switch: Setup and
    /// Settings both say "asks as soon as you continue", and this is the
    /// moment they mean. A source switched on while access is already
    /// declined doesn't prompt — macOS wouldn't — it just reads nothing, and
    /// Settings says so.
    func configure(events: Bool, reminders: Bool, leadMinutes: Int) {
        let eventsChanged = events != watchesEvents
        let remindersChanged = reminders != watchesReminders
        let leadChanged = leadMinutes != self.leadMinutes
        guard eventsChanged || remindersChanged || leadChanged else { return }

        watchesEvents = events
        watchesReminders = reminders
        self.leadMinutes = leadMinutes

        guard events || reminders else {
            stop()
            return
        }
        if !isRunning { startObserving() }

        Task { [weak self] in
            guard let self else { return }
            if events, eventsChanged { await self.requestAccess(to: .event) }
            if reminders, remindersChanged { await self.requestAccess(to: .reminder) }
            self.reload()
        }
    }

    private func stop() {
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        reloadTask?.cancel()
        reloadTask = nil
        timer?.invalidate()
        timer = nil
        pendingEvents.removeAll()
        pendingReminders.removeAll()
        listedEvents.removeAll()
        listedReminders.removeAll()
        dayEvents.removeAll()
        dayReminders.removeAll()
        dayInterval = nil
        generation += 1
        onAgendaChanged?([])
        onDaysChanged?(.empty)
    }

    private func startObserving() {
        // Coalesced, not immediate — see `reloadCoalesce`. Every one of these
        // can arrive in a burst (a sync, or a wake that also moves the clock).
        let reload: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleReload() }
        }
        let center = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter
        // Every notification here is posted from an arbitrary thread; `queue:
        // .main` is what makes `assumeIsolated` above true.
        observers = [
            (center, center.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main, using: reload)),
            (center, center.addObserver(forName: .NSSystemClockDidChange, object: nil, queue: .main, using: reload)),
            (center, center.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main, using: reload)),
            (workspace, workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: reload)),
        ]
    }

    // MARK: - Access

    private func requestAccess(to type: EKEntityType) async {
        guard Access.to(type) == .undetermined else { return }
        do {
            switch type {
            case .event:    _ = try await store.requestFullAccessToEvents()
            case .reminder: _ = try await store.requestFullAccessToReminders()
            @unknown default: break
            }
        } catch {
            NSLog("Isle: EventKit access request failed — \(error.localizedDescription)")
        }
    }

    // MARK: - Writing

    /// Where a quick-add of one kind would go: the default calendar or list,
    /// by name and colour, for the preview to say before anything is saved.
    struct Destination: Equatable {
        let title: String
        let color: Color
    }

    enum WriteError: Error, Equatable {
        case noAccess(EKEntityType)
        case noCalendar
        case failed

        var message: String {
            switch self {
            case .noAccess(.event): return "Calendar access is off — allow Isle in System Settings"
            case .noAccess: return "Reminders access is off — allow Isle in System Settings"
            case .noCalendar: return "There's no calendar to add it to"
            case .failed: return "Couldn't save it — try again in Calendar"
            }
        }
    }

    /// The default calendar for a new event, or list for a new reminder, as
    /// macOS has it set. Nil without access to that kind — EventKit can't
    /// say — or without a default that can be written to.
    func destination(for kind: QuickAddDraft.Kind) -> Destination? {
        let type: EKEntityType = kind == .event ? .event : .reminder
        guard Access.to(type) == .granted else { return nil }
        let calendar = kind == .event ? store.defaultCalendarForNewEvents : store.defaultCalendarForNewReminders()
        guard let calendar, calendar.allowsContentModifications else { return nil }
        return Destination(title: calendar.title, color: IslandToast.legible(calendar.cgColor))
    }

    /// Saves a draft the user has confirmed. The only place a quick-add is
    /// written. Asks for access to that kind first if it has never been asked
    /// — the one moment a write feature prompts, since it's the first time
    /// the user has asked Isle to write — and goes no further if the answer
    /// is no.
    func add(_ draft: QuickAddDraft) async throws {
        let type: EKEntityType = draft.kind == .event ? .event : .reminder
        await requestAccess(to: type)
        guard Access.to(type) == .granted else { throw WriteError.noAccess(type) }

        do {
            switch draft.kind {
            case .event:
                guard let calendar = store.defaultCalendarForNewEvents, calendar.allowsContentModifications,
                      let start = draft.date else { throw WriteError.noCalendar }
                let event = EKEvent(eventStore: store)
                event.calendar = calendar
                event.title = draft.title
                event.startDate = start
                event.endDate = start.addingTimeInterval(max(draft.duration, 60))
                try store.save(event, span: .thisEvent, commit: true)
            case .reminder:
                guard let calendar = store.defaultCalendarForNewReminders(),
                      calendar.allowsContentModifications else { throw WriteError.noCalendar }
                let reminder = EKReminder(eventStore: store)
                reminder.calendar = calendar
                reminder.title = draft.title
                if let date = draft.date {
                    let units: Set<Calendar.Component> = draft.hasTime
                        ? [.year, .month, .day, .hour, .minute]
                        : [.year, .month, .day]
                    reminder.dueDateComponents = Calendar.current.dateComponents(units, from: date)
                    // A reminder with a time alerts at it, as one made in
                    // Reminders does; without an alarm EventKit saves it
                    // silent.
                    if draft.hasTime { reminder.addAlarm(EKAlarm(absoluteDate: date)) }
                }
                try store.save(reminder, commit: true)
            }
        } catch let error as WriteError {
            throw error
        } catch {
            NSLog("Isle: couldn't save a quick-add — \(error.localizedDescription)")
            throw WriteError.failed
        }
    }

    /// Ticks a reminder off, or back on for an undo. True when EventKit
    /// saved it; the store's own change notification then re-fetches, which
    /// is what takes it off the list (or puts it back).
    func setReminder(_ identifier: String, completed: Bool) -> Bool {
        guard Access.to(.reminder) == .granted,
              let reminder = store.calendarItem(withIdentifier: identifier) as? EKReminder,
              reminder.calendar?.allowsContentModifications ?? false
        else { return false }
        reminder.isCompleted = completed
        do {
            try store.save(reminder, commit: true)
            return true
        } catch {
            NSLog("Isle: couldn't \(completed ? "complete" : "reopen") a reminder — \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Fetching

    /// Runs `reload` once the current burst of store changes has gone quiet.
    /// A newer request restarts the wait, so a sync that keeps posting delays
    /// the fetch until it has finished rather than fetching mid-way through.
    private func scheduleReload() {
        guard isRunning else { return }
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(for: Self.reloadCoalesce)
            guard !Task.isCancelled, let self else { return }
            self.reloadTask = nil
            self.reload()
        }
    }

    /// Re-reads everything inside the horizon and the days around this one,
    /// and re-arms the timer. Events are synchronous; reminders come back on
    /// a completion, so the two are kept apart and the reminders side is only
    /// replaced when its fetch lands — a tick in between still sees the
    /// previous set.
    private func reload() {
        guard isRunning else { return }
        generation += 1
        let gen = generation

        let now = Date()
        let end = now.addingTimeInterval(Self.horizon)
        let days = Self.dayInterval(around: now)
        dayInterval = days
        reloadDeadline = now.addingTimeInterval(Self.refetchInterval)
        pruneFired(before: now.addingTimeInterval(-Self.horizon))

        if watchesEvents, Access.to(.event) == .granted {
            (pendingEvents, listedEvents, dayEvents) = events(from: now, to: end, days: days)
        } else {
            pendingEvents = []
            listedEvents = []
            dayEvents = []
        }

        guard watchesReminders, Access.to(.reminder) == .granted else {
            pendingReminders = []
            listedReminders = []
            dayReminders = []
            publish()
            return
        }
        publish()

        // No lower bound: an overdue reminder is still due, and the Reminders
        // app lists it under Today for the same reason. The upper bound is
        // the later of the toast horizon and the last day the agenda can be
        // stepped to.
        let predicate = store.predicateForIncompleteReminders(
            withDueDateStarting: nil, ending: max(end, days.end), calendars: nil
        )
        store.fetchReminders(matching: predicate) { [weak self] reminders in
            let candidates = Self.candidates(from: reminders ?? [])
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, gen == self.generation else { return }
                    self.install(candidates, now: Date(), days: days)
                    self.publish()
                }
            }
        }
    }

    /// The days the agenda can be stepped through: from the start of last
    /// week to five weeks on from the start of this one, in the user's own
    /// weeks (`Calendar.current.firstWeekday`). Enough for the week strip to
    /// look back one week and ahead four without another fetch.
    nonisolated static func dayInterval(around now: Date, calendar: Calendar = .current) -> DateInterval {
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -7, to: thisWeek) ?? thisWeek
        let end = calendar.date(byAdding: .day, value: 35, to: thisWeek) ?? thisWeek
        return DateInterval(start: start, end: end)
    }

    /// Splits a reminder fetch three ways: those with a due time and a moment
    /// still ahead become toasts; everything due by the end of today is
    /// listed; and every one is filed under its day — an overdue one under
    /// today.
    private func install(_ candidates: [Candidate], now: Date, days: DateInterval) {
        let earliest = now.addingTimeInterval(-Self.grace)
        let horizon = now.addingTimeInterval(Self.horizon)
        let endOfToday = Self.endOfToday(now)
        let startOfToday = Calendar.current.startOfDay(for: now)

        pendingReminders = candidates.compactMap { candidate -> Pending? in
            guard candidate.hasTime, candidate.due >= earliest, candidate.due <= horizon,
                  !fired.contains(candidate.key) else { return nil }
            return Pending(
                key: candidate.key,
                fireDate: candidate.due,
                toast: .reminder(key: candidate.key, title: candidate.title, tint: candidate.color)
            )
        }

        let items = candidates.map { candidate in
            AgendaItem(
                id: candidate.key,
                kind: .reminder,
                title: IslandToast.untitled(candidate.title, fallback: "Reminder"),
                date: candidate.due,
                end: nil,
                isAllDay: !candidate.hasTime,
                color: candidate.color,
                reminderID: candidate.identifier,
                recurs: candidate.recurs
            )
        }
        listedReminders = items.filter { $0.date < endOfToday }
        dayReminders = items.filter { $0.date < days.end && ($0.date >= days.start || $0.date < startOfToday) }
    }

    /// One read of the calendar for all three uses: the toasts inside the
    /// horizon, what's left of today, and every event in the agenda's days.
    private func events(from now: Date, to end: Date, days: DateInterval)
        -> (pending: [Pending], listed: [AgendaItem], days: [AgendaItem]) {
        let lead = TimeInterval(leadMinutes * 60)
        let earliest = now.addingTimeInterval(-Self.grace)
        let endOfToday = Self.endOfToday(now)
        // The predicate matches events *overlapping* the range, so a meeting
        // that started an hour ago is returned too — it's still on for the
        // list, and the fire-date check drops it from the toasts. The range
        // is stretched by the lead time so an event just past the horizon
        // whose toast falls inside it is seen, and covers the agenda's days.
        let toastEnd = end.addingTimeInterval(lead)
        let predicate = store.predicateForEvents(
            withStart: min(earliest, days.start), end: max(toastEnd, days.end), calendars: nil
        )

        var pending: [Pending] = []
        var listed: [AgendaItem] = []
        var filed: [AgendaItem] = []
        for event in store.events(matching: predicate) {
            guard event.status != .canceled,
                  !Self.isDeclined(event),
                  let start = event.startDate,
                  let finish = event.endDate
            else { continue }

            // Keyed by occurrence: `calendarItemIdentifier` is shared by every
            // instance of a recurring event, so the start time is what tells
            // today's standup from tomorrow's.
            let key = "event:\(event.calendarItemIdentifier)@\(Int(start.timeIntervalSince1970))"
            let color = IslandToast.legible(event.calendar?.cgColor)
            let title = event.title ?? ""
            let join = event.isAllDay ? nil : MeetingLink.find(url: event.url, location: event.location, notes: event.notes)
            let item = AgendaItem(
                id: key,
                kind: .event,
                title: IslandToast.untitled(title, fallback: "Event"),
                date: start,
                end: finish,
                isAllDay: event.isAllDay,
                color: color,
                joinURL: join
            )

            if finish > now, start < endOfToday { listed.append(item) }
            if start < days.end, finish > days.start { filed.append(item) }

            let fire = start.addingTimeInterval(-lead)
            guard !event.isAllDay, fire >= earliest, fire <= toastEnd, !fired.contains(key) else { continue }
            pending.append(Pending(
                key: key,
                fireDate: fire,
                toast: .event(key: key, title: title, minutesBefore: leadMinutes, tint: color, isCall: join != nil)
            ))
        }
        return (pending, listed, filed)
    }

    /// An invitation the user has declined is still on the calendar, greyed
    /// out; announcing it would be reminding them of a meeting they said no to.
    private static func isDeclined(_ event: EKEvent) -> Bool {
        event.attendees?.contains { $0.isCurrentUser && $0.participantStatus == .declined } ?? false
    }

    /// Reduces the fetched reminders to plain values on whatever queue
    /// EventKit called back on. A reminder with a date but no time is due
    /// at the start of that day for sorting, and flagged as such.
    nonisolated private static func candidates(from reminders: [EKReminder]) -> [Candidate] {
        reminders.compactMap { reminder in
            guard !reminder.isCompleted,
                  let components = reminder.dueDateComponents,
                  let due = Calendar.current.date(from: components)
            else { return nil }
            let key = "reminder:\(reminder.calendarItemIdentifier)@\(Int(due.timeIntervalSince1970))"
            return Candidate(
                key: key,
                identifier: reminder.calendarItemIdentifier,
                due: due,
                hasTime: components.hour != nil,
                recurs: reminder.hasRecurrenceRules,
                title: reminder.title ?? "",
                color: IslandToast.legible(reminder.calendar?.cgColor)
            )
        }
    }

    private static func endOfToday(_ now: Date) -> Date {
        let calendar = Calendar.current
        return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
    }

    // MARK: - Publishing

    /// Hands the merged list to the view model and re-arms the timer. Sorted
    /// by when — an all-day event and a date-only reminder sort at the top,
    /// since their moment is "today" — with reminders before events at the
    /// same instant, as the shorter line.
    private func publish() {
        let now = Date()
        listedEvents.removeAll { ($0.end ?? .distantFuture) <= now }
        let items = (listedEvents + listedReminders).sorted(by: Self.inOrder)
        onAgendaChanged?(items)
        onDaysChanged?(fileDays(now: now))
        schedule()
    }

    private static func inOrder(_ a: AgendaItem, _ b: AgendaItem) -> Bool {
        if a.date != b.date { return a.date < b.date }
        if a.kind != b.kind { return a.kind == .reminder }
        return a.title < b.title
    }

    /// Files every event under each day it touches and every reminder under
    /// the day it's due, overdue ones under today.
    private func fileDays(now: Date) -> AgendaDays {
        guard let interval = dayInterval else { return .empty }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        var byDay: [Date: [AgendaItem]] = [:]

        for event in dayEvents {
            var day = max(calendar.startOfDay(for: event.date), interval.start)
            let finish = event.end ?? event.date
            repeat {
                byDay[day, default: []].append(event)
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            } while day < finish && day < interval.end
        }
        for reminder in dayReminders {
            let day = max(calendar.startOfDay(for: reminder.date), today)
            byDay[day, default: []].append(reminder)
        }
        for day in byDay.keys { byDay[day]?.sort(by: Self.inOrder) }
        return AgendaDays(interval: interval, byDay: byDay)
    }

    // MARK: - Timing

    /// One timer, for whichever comes first: the next moment to announce, an
    /// event ending and leaving the list, or the periodic re-fetch. Added in
    /// `.common` so a menu being tracked doesn't hold a meeting's toast until
    /// it closes.
    private func schedule() {
        timer?.invalidate()
        timer = nil

        let nextToast = (pendingEvents + pendingReminders).map(\.fireDate).min() ?? .distantFuture
        let nextEnd = listedEvents.compactMap(\.end).min() ?? .distantFuture
        let fireDate = min(nextToast, nextEnd, reloadDeadline)
        guard fireDate != .distantFuture else { return }

        let timer = Timer(fire: fireDate, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        timer = nil
        let now = Date()
        guard now < reloadDeadline else {
            reload()
            return
        }
        fire(&pendingEvents, at: now)
        fire(&pendingReminders, at: now)
        // Also prunes any event that has just ended, and re-arms.
        publish()
    }

    /// Announces everything whose moment has come. A moment found late —
    /// past `grace` — is marked fired but not announced: after a sleep the
    /// timer delivers the whole backlog at once, and none of it is still
    /// true.
    private func fire(_ pending: inout [Pending], at now: Date) {
        // A second's slack for timer tolerance, so a toast armed for 09:55:00
        // and delivered at 09:54:59.6 isn't put back for another pass.
        let cutoff = now.addingTimeInterval(1)
        let due = pending.filter { $0.fireDate <= cutoff }
        pending.removeAll { $0.fireDate <= cutoff }

        for item in due.sorted(by: { $0.fireDate < $1.fireDate }) {
            fired.insert(item.key)
            guard now.timeIntervalSince(item.fireDate) <= Self.grace else { continue }
            onEvent?(item.toast)
        }
    }

    /// Keys embed the moment they were for, so anything older than the
    /// horizon can't come back from a fetch and needn't be remembered.
    private func pruneFired(before date: Date) {
        let cutoff = Int(date.timeIntervalSince1970)
        fired = fired.filter { key in
            guard let at = key.split(separator: "@").last, let stamp = Int(at) else { return false }
            return stamp >= cutoff
        }
    }
}
