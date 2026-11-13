//
//  IslandCarry.swift
//
//  One island's way off its notch and back: takes the presses its window
//  offers (`NotchWindow.pressInterceptor`), runs them through `IslandHold`,
//  and does what that decides — starts and stops the line round the panel,
//  takes the island off the notch when the line has gone all the way
//  round, moves the window with the pointer while the button stays down,
//  and puts it down where it's let go, or back on the notch if that's near
//  the notch.
//
//  One per island, like `FacePager`: a press happens on one screen.
//  `NotchWindowController` makes it, tells it what only the controller
//  knows (whether a reply is being typed, where the island is drawn), and
//  hears back when the island has been put down, to remember where.
//
//  The window is moved, never resized: the island is drawn at the top
//  centre of its window whatever the placement (see `IslandPlacement`), so
//  following the pointer is a window move per drag event. `placement`
//  itself is published only when the island is lifted, when the notch
//  takes it or lets it go, and when it's put down — not per event — so a
//  drag doesn't re-evaluate the island's views.
//

import AppKit
import SwiftUI

@MainActor
final class IslandCarry {
    /// The pointer as it is now: where, and whether the primary button is
    /// down. Read fresh at each deadline rather than remembered from events.
    struct Pointer {
        var location: CGPoint
        var buttonDown: Bool
    }

    enum Haptic {
        /// The island came loose, or was picked up.
        case lifted
        /// The notch took it back while it was being carried.
        case snapped
    }

    private let presentation: IslandPresentation
    private unowned let window: NotchWindow

    private var hold = IslandHold()
    private var deadline: DispatchWorkItem?

    /// While carrying: the island's anchor less the pointer, as it was
    /// picked up, so the island keeps the place it was grabbed by.
    private var grabOffset: CGPoint?

    /// The notch may take the island back mid-carry. False for an island
    /// only just taken off the notch, until it has been carried clear: it
    /// starts on the notch, and would be pulled straight back.
    private var snapArmed = false

    /// The notch has taken the island back, and it's drawn there until
    /// it's carried clear again or let go.
    private var snapped = false

    private var glide: IslandGlide?

    // MARK: The controller's side

    var pointer: () -> Pointer = {
        Pointer(location: NSEvent.mouseLocation, buttonDown: NSEvent.pressedMouseButtons & 1 != 0)
    }

    /// The drawn island in screen coordinates; nil before the first layout.
    var drawnRect: () -> CGRect? = { nil }

    /// Whether a press may be taken at all, as far as the controller knows:
    /// no reply being typed, no file drag in flight.
    var canArm: () -> Bool = { true }

    var reduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    var haptic: (Haptic) -> Void = { _ in }

    /// The island was put down (or put back): `placement` is where it now
    /// lives. Called at once, before any glide, so it's remembered even if
    /// Isle quits mid-move.
    var onPlaced: (IslandPlacement) -> Void = { _ in }

    /// The window has stopped moving after being put down.
    var onArrived: () -> Void = {}

    init(presentation: IslandPresentation, window: NotchWindow) {
        self.presentation = presentation
        self.window = window
    }

    /// The island is being carried, or is still gliding to where it was
    /// put: not the moment to re-place its window.
    var isBusy: Bool { hold.phase == .carrying || glide != nil }

    // MARK: - Presses

    /// A down, dragged or up event of the primary button on the island's
    /// window, before the views see it.
    func handle(_ event: NSEvent) -> IslandHold.Verdict {
        let outcome: IslandHold.Outcome
        switch event.type {
        case .leftMouseDown:
            let point = window.convertPoint(toScreen: event.locationInWindow)
            outcome = hold.down(kind: kind(ofPressAt: point, event), at: point, time: event.timestamp)
        case .leftMouseDragged:
            outcome = hold.moved(to: location(of: event), time: event.timestamp)
        case .leftMouseUp:
            outcome = hold.up(at: location(of: event), time: event.timestamp)
        default:
            return .pass
        }
        perform(outcome.actions)
        scheduleDeadline()
        return outcome.verdict
    }

    /// A move with no button held reached the pointer monitor: whatever
    /// press there was is over, even if its release never came this way.
    func pointerMovedFreely() {
        guard hold.phase != .idle else { return }
        check()
    }

    /// Where a drag or a release is. An event's own location is relative to
    /// the window, which while carrying has moved since the event was made,
    /// so then it's the pointer itself that's read.
    private func location(of event: NSEvent) -> CGPoint {
        hold.phase == .carrying ? pointer().location : window.convertPoint(toScreen: event.locationInWindow)
    }

    /// What a press at `point` could become, or nil when it's not the
    /// island's to take: outside the drawn island, a control-click, a
    /// reply being typed (the panel is key), a file drag or the drop face,
    /// a swipe between faces still moving, a press on one of AppKit's own
    /// controls, or a closed island on its notch.
    private func kind(ofPressAt point: CGPoint, _ event: NSEvent) -> IslandHold.Kind? {
        guard !event.modifierFlags.contains(.control),
              glide == nil,
              presentation.metrics != nil,
              drawnRect()?.insetBy(dx: -1, dy: -1).contains(point) == true,
              holdable,
              !landsOnControl(event)
        else { return nil }
        switch (presentation.placement.isFloating, presentation.state.isExpanded) {
        case (false, true): return .detach
        case (true, true): return .pickUp
        case (true, false): return .drag
        case (false, false): return nil
        }
    }

    /// The press is on an AppKit control inside the SwiftUI content — the
    /// reply field. Those track the mouse in a loop of their own from the
    /// button going down to it coming up, so the drags and the release of a
    /// press on one never come through the window's `sendEvent`: a hold
    /// started there could lift the island and then never hear it move.
    private func landsOnControl(_ event: NSEvent) -> Bool {
        guard let content = window.contentView else { return false }
        let point = content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
        var view = content.hitTest(point)
        while let current = view, current !== content {
            if current is NSControl || current is NSText { return true }
            view = current.superview
        }
        return false
    }

    /// Nothing else has a claim on the island right now.
    private var holdable: Bool {
        canArm() && !window.isKeyWindow && !presentation.isDropTarget && presentation.pager.current == nil
    }

    /// Whether a hold under way may go on: as `holdable`, and the panel it
    /// was pressed on is still open (an alert can close it mid-hold).
    private var stillHoldable: Bool {
        holdable && presentation.state.isExpanded
    }

    // MARK: - The clock

    /// Asks to be looked at again when the hold's next deadline comes. One
    /// pending at a time; on the main queue, which runs through event
    /// tracking too.
    private func scheduleDeadline() {
        deadline?.cancel()
        deadline = nil
        guard let due = hold.deadline else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.deadline = nil
                self?.check()
            }
        }
        deadline = work
        let wait = max(0, due - ProcessInfo.processInfo.systemUptime)
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
    }

    private func check() {
        let now = pointer()
        let outcome = hold.tick(
            time: ProcessInfo.processInfo.systemUptime,
            pointer: now.location,
            buttonDown: now.buttonDown,
            holdable: stillHoldable
        )
        perform(outcome.actions)
        scheduleDeadline()
    }

    // MARK: - Doing it

    private func perform(_ actions: [IslandHold.Action]) {
        for action in actions {
            switch action {
            case .traceBegan(let run):
                presentation.detachTrace.run(for: run, topGap: traceGap)
            case .traceCancelled:
                presentation.detachTrace.retract()
            case .lifted(let point):
                lift(grabbedAt: point)
            case .carried(let point):
                carry(to: point)
            case .dropped(let point):
                drop(at: point)
            }
        }
    }

    /// The width at the top centre the line stops short of: the camera
    /// housing, while the island hangs from a real one.
    private var traceGap: CGFloat {
        guard !presentation.placement.isFloating,
              let metrics = presentation.metrics, metrics.hasPhysicalNotch
        else { return 0 }
        return metrics.notchSize.width
    }

    /// The island comes loose where it is — its anchor is exactly where
    /// its top centre already was, so nothing jumps — and from here follows
    /// the pointer by the place it was grabbed.
    private func lift(grabbedAt point: CGPoint) {
        guard let bounds = presentation.metrics?.placementBounds else { return }
        cancelGlide()
        let anchor = NotchMetrics.anchor(of: window.frame)
        grabOffset = CGPoint(x: anchor.x - point.x, y: anchor.y - point.y)
        snapped = false
        snapArmed = !bounds.captures(anchor)
        presentation.detachTrace.complete()
        haptic(.lifted)
        if !presentation.placement.isFloating {
            setPlacement(.floating(anchor: anchor))
        }
    }

    private func carry(to point: CGPoint) {
        guard let grabOffset, let metrics = presentation.metrics else { return }
        let bounds = metrics.placementBounds
        let wanted = Self.anchor(for: point, grabbedBy: grabOffset)

        if snapped {
            // On the notch until it's carried clear of it.
            guard !bounds.holds(wanted) else { return }
            snapped = false
            cancelGlide()
            let anchor = bounds.carrying(wanted)
            setPlacement(.floating(anchor: anchor))
            window.slide(to: metrics.frame(for: .floating(anchor: anchor)))
            return
        }

        if !snapArmed {
            if !bounds.holds(wanted) { snapArmed = true }
        } else if bounds.captures(wanted) {
            // Near enough: the notch takes it, and that's where it's drawn,
            // as it will be if it's let go here.
            snapped = true
            haptic(.snapped)
            setPlacement(.docked)
            move(to: metrics.frame(for: .docked))
            return
        }
        window.slide(to: metrics.frame(for: .floating(anchor: bounds.carrying(wanted))))
    }

    private func drop(at point: CGPoint) {
        defer {
            grabOffset = nil
            snapped = false
        }
        guard let grabOffset, let bounds = presentation.metrics?.placementBounds else { return }
        let wanted = Self.anchor(for: point, grabbedBy: grabOffset)
        // Back on the notch if the notch has it, if it's let go within
        // reach of it, or if it was never carried clear in the first place.
        if snapped || !snapArmed || bounds.captures(wanted) {
            settle(.docked)
        } else {
            settle(.floating(anchor: bounds.resting(wanted)))
        }
    }

    /// Where the island's anchor goes for a pointer at `point`: the pointer
    /// plus the grab, on whole points — the pointer reports halves, and a
    /// window on a half point is drawn soft on a display that has none.
    private static func anchor(for point: CGPoint, grabbedBy offset: CGPoint) -> CGPoint {
        CGPoint(x: (point.x + offset.x).rounded(), y: (point.y + offset.y).rounded())
    }

    /// Puts the island at `placement` for good: published, remembered, and
    /// the window brought the rest of the way there.
    private func settle(_ placement: IslandPlacement) {
        guard let metrics = presentation.metrics else { return }
        setPlacement(placement)
        onPlaced(placement)
        move(to: metrics.frame(for: placement)) { [weak self] in
            self?.onArrived()
        }
    }

    /// Publishes the placement. On or off the notch is a change of look,
    /// which moves on the island's own springs: the open one coming loose,
    /// the close one — which can't overshoot the hardware — going home.
    private func setPlacement(_ placement: IslandPlacement) {
        guard presentation.placement != placement else { return }
        guard presentation.placement.isFloating != placement.isFloating else {
            presentation.placement = placement
            return
        }
        let animation: Animation = reduceMotion() ? .notchCloseReduced
            : placement.isFloating ? .notchOpen : .notchClose
        withAnimation(animation) {
            presentation.placement = placement
        }
    }

    // MARK: - Moving the window

    /// Brings the window to `frame` on the close spring — or at once, with
    /// Reduce Motion or nowhere to go.
    private func move(to frame: NSRect, then completion: (() -> Void)? = nil) {
        cancelGlide()
        guard window.frame != frame, !reduceMotion() else {
            if window.frame != frame { window.slide(to: frame) }
            completion?()
            return
        }
        glide = IslandGlide(window: window, to: frame) { [weak self] in
            self?.glide = nil
            completion?()
        }
    }

    private func cancelGlide() {
        glide?.cancel()
        glide = nil
    }

    // MARK: - From the controller

    /// Puts the island at `placement` now, no motion, ending whatever was
    /// under way: the controller re-placing its islands (a screen change),
    /// and the first placement of a new one.
    func place(_ placement: IslandPlacement) {
        guard let metrics = presentation.metrics else { return }
        deadline?.cancel()
        deadline = nil
        // A carry ends where the controller says, not where it was.
        _ = hold.abandon()
        grabOffset = nil
        snapped = false
        presentation.detachTrace.clear()
        cancelGlide()
        if presentation.placement != placement { presentation.placement = placement }
        window.place(metrics.frame(for: placement))
    }

    /// Ends a press under way, the island put down where it is (the
    /// islands are being hidden).
    func cancel() {
        deadline?.cancel()
        deadline = nil
        perform(hold.abandon().actions)
    }

    /// Back onto the notch, from wherever it is. Nothing to do on the
    /// notch, or while it's in the user's hand.
    func returnToNotch() {
        guard presentation.placement.isFloating, hold.phase != .carrying else { return }
        settle(.docked)
    }
}

/// Moves an island's window from where it is to a frame, on the island's
/// close spring: a move per display frame for the third of a second it
/// takes, and nothing after. A window's position can't be handed to the
/// render server the way a layer's can, so this is the one place the
/// island's motion is stepped — the same cost as the drag that led to it.
@MainActor
final class IslandGlide: NSObject {
    private weak var window: NotchWindow?
    private let from: NSRect
    private let to: NSRect
    private let completion: () -> Void
    private let started = CACurrentMediaTime()
    private var link: CADisplayLink?
    private var backstop: DispatchWorkItem?
    private var finished = false

    /// Critically damped (`Animation.notchClose`'s spring): it arrives
    /// without passing its target, so an island going home never rides up
    /// past the top of the screen.
    static let spring = IslandMotion.collapseHeight

    /// When the spring is as good as there.
    static let duration: TimeInterval = spring.reach(0.998)

    init(window: NotchWindow, to frame: NSRect, completion: @escaping () -> Void) {
        self.window = window
        from = window.frame
        to = frame
        self.completion = completion
        super.init()
        let link = window.displayLink(target: self, selector: #selector(step))
        link.add(to: .main, forMode: .common)
        self.link = link
        // A window that's on no display gets no display link callbacks; it
        // still has to arrive.
        let backstop = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.finish() }
        }
        self.backstop = backstop
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.duration + 0.1, execute: backstop)
    }

    /// Stops where it is. The completion isn't called.
    func cancel() {
        finished = true
        stop()
    }

    @objc private func step() {
        guard !finished, let window else { return }
        let elapsed = CACurrentMediaTime() - started
        guard elapsed < Self.duration else {
            finish()
            return
        }
        window.slide(to: Self.frame(at: elapsed, from: from, to: to))
    }

    /// Where the window is `elapsed` seconds into a glide.
    static func frame(at elapsed: TimeInterval, from: NSRect, to: NSRect) -> NSRect {
        let progress = CGFloat(spring.value(at: elapsed))
        // Whole points: a window on a half point is drawn soft.
        return NSRect(
            x: (from.minX + (to.minX - from.minX) * progress).rounded(),
            y: (from.minY + (to.minY - from.minY) * progress).rounded(),
            width: to.width,
            height: to.height
        )
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        stop()
        window?.slide(to: to)
        completion()
    }

    private func stop() {
        link?.invalidate()
        link = nil
        backstop?.cancel()
        backstop = nil
    }
}
