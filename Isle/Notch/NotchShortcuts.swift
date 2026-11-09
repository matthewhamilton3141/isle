//
//  NotchShortcuts.swift
//
//  The global shortcuts, wired to the island: reads the moment off the view
//  model, tells `HotKeyCenter` what to hold (`ShortcutPlan.active`), and
//  turns a press into the face's own call (`ShortcutPlan.command`).
//
//  Whether it's in front of the user: `ShortcutFaceTracker`, fed on every
//  look at the moment — a refresh (any change to the view model, an
//  island's hover, the pointer changing displays) and every press.
//
//  Which request a press answers: `pendingRequest`, the one on the island's
//  session — the same one the face's Approve answers. With several sessions
//  waiting, selection already puts the most pressing on the island; the
//  others are "+N need you" until it moves on to them, and a press never
//  reaches past the island to one of those.
//

import AppKit
import Combine

/// What the shortcuts need from whoever owns the islands.
@MainActor
protocol ShortcutIslandHost: AnyObject {
    /// The islands are on screen.
    var shortcutsRunning: Bool { get }
    /// Some island's panel is open.
    var isAnyIslandExpanded: Bool { get }
    /// Where the open island is, as far as the user goes.
    var islandPresence: ShortcutIslandPresence { get }
    func toggleIslandFromShortcut()
    /// Open an island, held, if none is open.
    func openIslandFromShortcut()
}

@MainActor
final class NotchShortcuts {
    private let viewModel: NotchViewModel
    private let settings: AppSettings
    private let center: HotKeyCenter
    private weak var host: ShortcutIslandHost?
    private var cancellables = Set<AnyCancellable>()
    private var refreshQueued = false

    /// The request on the island and when it was first seen there — what
    /// `ShortcutPlan.armDelay` counts from.
    private var seenRequest: (id: String, at: Date)?
    private var armWork: DispatchWorkItem?

    /// Whether, and since when, the request's face is in front of the user.
    private var faceTracker = ShortcutFaceTracker()

    /// A look again the moment the face counts as seen, so the hints that
    /// wait for that (`ShortcutHints`) come up then. One-shot, like
    /// `armWork`, and only while a face is up and not yet seen.
    private var seenWork: DispatchWorkItem?
    private var seenWorkAt: Date?

    /// The hints' keys, made again only when the bindings or the request
    /// change: writing a combo asks the keyboard layout what its key types.
    private var hintKeys: (bindings: ShortcutBindings, request: String?, keys: [ShortcutAction: String])?

    init(viewModel: NotchViewModel, settings: AppSettings? = nil, center: HotKeyCenter? = nil,
         host: ShortcutIslandHost) {
        let settings = settings ?? .shared
        let center = center ?? .shared
        self.viewModel = viewModel
        self.settings = settings
        self.center = center
        self.host = host
        center.onAction = { [weak self] action in self?.perform(action) }
        // Any change to what the island shows may change what's held. Read
        // a turn later: `objectWillChange` fires before the value lands. The
        // plan is a handful of comparisons and the center acts only on a
        // difference, so a busy view model costs next to nothing here.
        viewModel.objectWillChange
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        settings.$shortcuts
            .removeDuplicates()
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        // The recorder letting every key go (or taking them back): the hints
        // must stop saying a press would act while nothing is held.
        center.$isSuspended
            .removeDuplicates()
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
    }

    /// Re-read the moment and hold what it calls for, once per turn of the
    /// run loop however many changes ask.
    func refresh() {
        guard !refreshQueued else { return }
        refreshQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshQueued = false
            let context = self.context()
            self.center.apply(ShortcutPlan.active(context, bindings: self.settings.shortcuts))
            self.showHints(context: context, face: self.face())
        }
    }

    /// Tells the face which keys its buttons carry, and which a press would
    /// act on now (`ShortcutHints`).
    private func showHints(context: ShortcutContext, face: ShortcutFace) {
        let bindings = settings.shortcuts
        let request = viewModel.pendingRequest?.id
        let keys: [ShortcutAction: String]
        if let cached = hintKeys, cached.bindings == bindings, cached.request == request {
            keys = cached.keys
        } else {
            keys = ShortcutHints.keys(bindings)
            hintKeys = (bindings, request, keys)
        }
        viewModel.setShortcutHints(ShortcutHints(
            keys: keys.filter { action, _ in
                if case .refused = center.status[action] { return false }
                return true
            },
            live: ShortcutPlan.live(context, face: face, held: center.held)))

        // Shown but not yet seen: look again when it will be.
        guard face == .shown, let since = faceTracker.since else {
            seenWork?.cancel()
            seenWork = nil
            seenWorkAt = nil
            return
        }
        let due = since.addingTimeInterval(ShortcutPlan.seenDelay)
        guard seenWorkAt != due else { return }
        seenWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.seenWork = nil
            self?.seenWorkAt = nil
            self?.refresh()
        }
        seenWork = work
        seenWorkAt = due
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, due.timeIntervalSinceNow) + 0.01, execute: work)
    }

    /// The moment, as `ShortcutPlan` reads it.
    func context(now: Date = Date()) -> ShortcutContext {
        var context = ShortcutContext()
        context.running = host?.shortcutsRunning ?? false
        context.composing = viewModel.composing != nil
        context.answering = viewModel.isAnsweringRequest

        guard let request = viewModel.pendingRequest else {
            seenRequest = nil
            armWork?.cancel()
            armWork = nil
            return context
        }
        switch request.kind {
        case .approval:
            context.request = .approval(guarded: request.guardedBy != nil,
                                        reviewing: viewModel.isReviewingRemember && request.remember != nil)
        case .question:
            if let question = viewModel.currentQuestion {
                context.request = .question(options: question.options.count, multiSelect: question.multiSelect)
            }
        }
        if seenRequest?.id != request.id {
            seenRequest = (request.id, now)
        }
        let age = now.timeIntervalSince(seenRequest!.at)
        context.armed = age >= ShortcutPlan.armDelay
        if !context.armed, armWork == nil {
            // Look again the moment it arms. One-shot, and only while a
            // request is too new — the keys are never polled for.
            let work = DispatchWorkItem { [weak self] in
                self?.armWork = nil
                self?.refresh()
            }
            armWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + (ShortcutPlan.armDelay - age) + 0.01, execute: work)
        }
        return context
    }

    /// The request's face, as a press sees it — and the tracker brought up
    /// to date.
    func face(now: Date = Date()) -> ShortcutFace {
        faceTracker.update(request: viewModel.pendingRequest?.id,
                           showsFace: viewModel.showsPendingRequestFace,
                           presence: host?.islandPresence ?? .closed,
                           now: now)
    }

    // MARK: - A press

    private func perform(_ action: ShortcutAction) {
        let context = context()
        let face = face()
        let project = viewModel.claudeProject.flatMap { $0.isEmpty ? nil : $0 }

        switch ShortcutPlan.command(for: action, context: context, face: face) {
        case .approve:
            notice(viewModel.decide(allow: true) ? .approved : .notSent, project: project)
        case .deny:
            notice(viewModel.decide(allow: false) ? .denied : .notSent, project: project)
        case .confirmRemember:
            notice(viewModel.allowRemembering() ? .alwaysAllowed : .notSent, project: project)
        case .cancelRemember:
            viewModel.cancelRemember()
        case .pick(let index):
            guard let question = viewModel.currentQuestion, question.options.indices.contains(index) else { break }
            viewModel.pickOption(question.options[index].label)
            if viewModel.isAnsweringRequest { notice(.answered, project: project) }
        case .submit:
            viewModel.advanceQuestion()
            if viewModel.isAnsweringRequest { notice(.answered, project: project) }
        case .reveal:
            viewModel.revealPendingRequest()
            host?.openIslandFromShortcut()
            // Revealed where the user is: the look starts now.
            faceTracker.restart(now: Date())
        case .toggleIsland:
            host?.toggleIslandFromShortcut()
        case .none:
            break
        }
        refresh()
    }

    private func notice(_ outcome: IslandToast.ShortcutOutcome, project: String?) {
        viewModel.showShortcutNotice(.shortcut(outcome, project: project))
    }
}
