//
//  AgendaModel.swift
//
//  The agenda face's own state, beside the view model the way the shelf and
//  the Pomodoro clock are: the days around today as `AgendaMonitor` last
//  read them, reminders ticked off and still undoable, and the quick-add
//  line from typed text to a saved event.
//
//  Two things here write to the user's calendars, and both only on a click.
//  A tick saves at once — what the row shows as done *is* done, in Reminders
//  too — and an Undo for a few seconds after puts it back. A quick-add never
//  saves from the parse: Return shows what would be added, where, and when,
//  and only Add (or a second Return on that same preview) writes it.
//

import SwiftUI
import EventKit

@MainActor
final class AgendaModel: ObservableObject {
    /// Everything in the days the face can step through.
    @Published private(set) var days: AgendaDays = .empty

    /// Reminders ticked off in the last few seconds, by item id, drawn in
    /// place — ticked, struck through, with Undo — after the store's own
    /// re-fetch has dropped them from the list.
    @Published private(set) var ticked: [String: Tick] = [:]

    // MARK: Quick add

    /// What's typed in the quick-add field. Kept while the field closes for
    /// any reason other than Add or Cancel, like the Claude face's drafts.
    @Published var draft = "" {
        didSet {
            // Anything typed after a preview makes that preview stale.
            guard draft != oldValue, review != nil else { return }
            review = nil
        }
    }

    /// The preview or the reason there isn't one, after Return.
    @Published private(set) var review: Review?

    /// A save under way, so Add can't be pressed twice.
    @Published private(set) var isSaving = false

    /// "Added", for a few seconds after a save, in the idle field — the
    /// one confirmation for something added to a day the face isn't showing.
    @Published private(set) var added: String?

    struct Tick: Equatable {
        let item: AgendaItem
        /// Unticked again, waiting for the re-fetch to bring the reminder
        /// back; drawn unticked, without Undo, until it does.
        var restoring = false
    }

    enum Review: Equatable {
        case preview(QuickAddDraft, AgendaMonitor.Destination?)
        case problem(String)
    }

    /// How long a ticked reminder keeps its Undo.
    static let undoSeconds: TimeInterval = 5

    /// A quick-add was saved: the field's work is done, and the view model
    /// hands the keys back.
    var onAdded: (() -> Void)?

    private let monitor: AgendaMonitor
    private var tickTasks: [String: Task<Void, Never>] = [:]
    private var addedTask: Task<Void, Never>?

    init(monitor: AgendaMonitor) {
        self.monitor = monitor
    }

    // MARK: - From the monitor

    func update(days: AgendaDays) {
        guard days != self.days else { return }
        self.days = days
    }

    /// The list moved on. A reminder being restored that is back in it no
    /// longer needs its stand-in.
    func listChanged(_ items: [AgendaItem]) {
        let ids = Set(items.map(\.id))
        for (id, tick) in ticked where tick.restoring && ids.contains(id) {
            ticked[id] = nil
        }
    }

    // MARK: - Ticking

    /// Ticks a reminder off. Saved at once; the row stays, ticked, with Undo
    /// for `undoSeconds` — except a repeating one, which EventKit moves on
    /// to its next date and an untick wouldn't move back.
    func tick(_ item: AgendaItem) {
        guard item.kind == .reminder, let identifier = item.reminderID, ticked[item.id] == nil else { return }
        guard monitor.setReminder(identifier, completed: true) else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            ticked[item.id] = Tick(item: item)
        }
        tickTasks[item.id]?.cancel()
        tickTasks[item.id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.undoSeconds))
            guard !Task.isCancelled, let self else { return }
            self.tickTasks[item.id] = nil
            guard self.ticked[item.id]?.restoring == false else { return }
            withAnimation(.easeInOut(duration: 0.25)) {
                self.ticked[item.id] = nil
            }
        }
    }

    /// Puts a ticked reminder back.
    func undo(_ item: AgendaItem) {
        guard let identifier = item.reminderID, let tick = ticked[item.id], !tick.restoring, !item.recurs else { return }
        tickTasks[item.id]?.cancel()
        tickTasks[item.id] = nil
        guard monitor.setReminder(identifier, completed: false) else {
            ticked[item.id] = nil
            return
        }
        ticked[item.id]?.restoring = true
        // In case the re-fetch never lists it again — it was due on a day
        // that has since gone by — the stand-in doesn't stay forever.
        tickTasks[item.id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self else { return }
            self.tickTasks[item.id] = nil
            self.ticked[item.id] = nil
        }
    }

    /// The list as the face draws it: `items` with any ticked reminder put
    /// back in its place, ticked.
    func withTicked(_ items: [AgendaItem], on day: Date, calendar: Calendar = .current) -> [AgendaItem] {
        let ids = Set(items.map(\.id))
        let today = calendar.startOfDay(for: Date())
        let extra = ticked.values.map(\.item).filter { item in
            guard !ids.contains(item.id) else { return false }
            // Overdue reminders are listed under today.
            let filed = max(calendar.startOfDay(for: item.date), today)
            return calendar.isDate(filed, inSameDayAs: day)
        }
        guard !extra.isEmpty else { return items }
        return (items + extra).sorted { a, b in
            if a.date != b.date { return a.date < b.date }
            if a.kind != b.kind { return a.kind == .reminder }
            return a.title < b.title
        }
    }

    // MARK: - Quick add

    /// Return in the field: the first one reads the text and shows what it
    /// would add; a second, on the same text, adds it.
    func submit(now: Date = Date()) {
        if case .preview = review {
            confirm()
            return
        }
        switch QuickAddParser.parse(draft, now: now) {
        case .success(let parsed):
            // Where it would go, said before anything is saved. Access not
            // yet asked for is a preview that says it will be; declined, or
            // no writable default, is said instead of a preview.
            let type: EKEntityType = parsed.kind == .event ? .event : .reminder
            switch AgendaMonitor.Access.to(type) {
            case .undetermined:
                review = .preview(parsed, nil)
            case .declined:
                review = .problem(AgendaMonitor.WriteError.noAccess(type).message)
            case .granted:
                if let destination = monitor.destination(for: parsed.kind) {
                    review = .preview(parsed, destination)
                } else {
                    review = .problem(AgendaMonitor.WriteError.noCalendar.message)
                }
            }
        case .failure(let error):
            review = .problem(error.message)
        }
    }

    /// Add, on the preview. The one path to a save.
    func confirm() {
        guard case .preview(let parsed, _) = review, !isSaving else { return }
        isSaving = true
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.monitor.add(parsed)
                self.isSaving = false
                self.review = nil
                self.draft = ""
                self.showAdded(parsed.title)
                self.onAdded?()
            } catch {
                self.isSaving = false
                self.review = .problem((error as? AgendaMonitor.WriteError ?? .failed).message)
            }
        }
    }

    /// Cancel: the preview and the text both go.
    func cancel() {
        review = nil
        draft = ""
    }

    /// The field closed without Add or Cancel — Esc, a click elsewhere, the
    /// face going. The text stays for next time; a preview of it doesn't.
    func closed() {
        review = nil
    }

    private func showAdded(_ title: String) {
        addedTask?.cancel()
        withAnimation(.easeInOut(duration: 0.2)) { added = title }
        addedTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, let self else { return }
            withAnimation(.easeInOut(duration: 0.25)) { self.added = nil }
        }
    }

    // MARK: - Fixtures

    #if DEBUG
    /// Sets state directly, for renders and previews — never from the app.
    func applyFixture(days: AgendaDays? = nil, ticked: [String: Tick]? = nil,
                      draft: String? = nil, review: Review?? = nil, added: String?? = nil) {
        if let days { self.days = days }
        if let ticked { self.ticked = ticked }
        if let draft { self.draft = draft }
        if let review { self.review = review }
        if let added { self.added = added }
    }
    #endif
}
