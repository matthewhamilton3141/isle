//
//  NotchShortcuts.swift
//
//  The global shortcuts, wired to the island: reads the moment off the view
//  model, tells `HotKeyCenter` what to hold (`ShortcutPlan.active`), and
//  turns a press into the face's own call (`ShortcutPlan.command`).
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
    /// A shortcut is holding an island open (`IslandPresentation.isHeldOpen`).
    var isIslandHeldOpen: Bool { get }
    func toggleIslandFromShortcut()
    /// Open an island, held, if none is open.
    func openIslandFromShortcut()
    func closeHeldIsland()
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
    }

    /// Re-read the moment and hold what it calls for, once per turn of the
    /// run loop however many changes ask.
    func refresh() {
        guard !refreshQueued else { return }
        refreshQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshQueued = false
            self.center.apply(ShortcutPlan.active(self.context(), bindings: self.settings.shortcuts))
        }
    }

    /// The moment, as `ShortcutPlan` reads it.
    func context(now: Date = Date()) -> ShortcutContext {
        var context = ShortcutContext()
        context.running = host?.shortcutsRunning ?? false
        context.heldOpen = host?.isIslandHeldOpen ?? false
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

    // MARK: - A press

    private func perform(_ action: ShortcutAction) {
        let context = context()
        let visible = (host?.isAnyIslandExpanded ?? false) && viewModel.showsPendingRequestFace
        let project = viewModel.claudeProject.flatMap { $0.isEmpty ? nil : $0 }

        switch ShortcutPlan.command(for: action, context: context, faceVisible: visible) {
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
        case .toggleIsland:
            host?.toggleIslandFromShortcut()
        case .closeHeld:
            host?.closeHeldIsland()
        case .none:
            break
        }
        refresh()
    }

    private func notice(_ outcome: IslandToast.ShortcutOutcome, project: String?) {
        viewModel.showShortcutNotice(.shortcut(outcome, project: project))
    }
}
