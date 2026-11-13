//
//  IslandCarry.swift
//
//  One island's way off its notch and back: takes the presses its window
//  offers (`NotchWindow.pressInterceptor`), runs them through `IslandHold`,
//  and does what that decides — starts and stops the line round the panel,
//  takes the island off the notch when the line has gone all the way
//  round, moves the window with the pointer while the button stays down,
//  and puts it down where it's let go, or back on the notch if that's near
//  the notch. A click that a plain drag could have been is handed back
//  too (`onClick`): on the open panel's grabber, or on the closed capsule.
//
//  One per island, like `FacePager`: a press happens on one screen.
//  `NotchWindowController` makes it, tells it what only the controller
//  knows (whether a reply is being typed, where the island is drawn), and
//  hears back when the island has been put down, to remember where.
//
//  The window is moved, never resized: where the island is drawn inside it
//  depends only on which way it opens (`IslandOpening`), which is decided
//  when the island is put down closed and doesn't change while it's
//  carried, so following the pointer is a window move per drag event. `placement`
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

    /// A click on an island off its notch that means something here.
    enum Click {
        /// The open panel's grabber (`IslandFloat.PanelSpot.grabber`):
        /// close it to its capsule.
        case grabber
        /// The closed capsule: open it.
        case capsule
    }

    private let presentation: IslandPresentation
    private unowned let window: NotchWindow

    private var hold = IslandHold()
    private var deadline: DispatchWorkItem?

    /// What a click would be for the press under way, if it comes to one.
    private var pressClick: Click?

    /// While carrying: the island's anchor less the pointer, as it was
    /// picked up, so the island keeps the place it was grabbed by.
    private var grabOffset: CGPoint?

    /// While carrying closed: the capsule's width as it was picked up, so
    /// it's the capsule itself — not the widest it could grow to — that's
    /// kept on the screen and put down against its edges.
    private var pillWidth: CGFloat?

    /// While carrying: the drawn island's top centre less its anchor. The
    /// notch takes back the island whose *top centre* reaches it — the
    /// anchor is that only for an island centred and opening down; opening
    /// up it's the capsule under the panel, pinned it's one end.
    private var topOffset: CGPoint = .zero

    /// The notch may take the island back mid-carry. False for an island
    /// only just taken off the notch, until it has been carried clear: it
    /// starts on the notch, and would be pulled straight back.
    private var snapArmed = false

    /// The notch has taken the island back, and it's drawn there until
    /// it's carried clear again or let go.
    private var snapped = false

    private var glide: IslandGlide?

    /// The notch's black reaching for the island near it (`IslandBleed`),
    /// which follows the window wherever this moves it.
    let bleed: IslandBleedDriver

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

    /// A press that could have been a drag was let go where it went down,
    /// on the grabber or the capsule. Passed on to the views as well.
    var onClick: (Click) -> Void = { _ in }

    init(presentation: IslandPresentation, window: NotchWindow) {
        self.presentation = presentation
        self.window = window
        bleed = IslandBleedDriver(presentation: presentation)
        bleed.drawnRect = { [weak self] in self?.drawnRect() }
        presentation.willOpen = { [weak self] in self?.openForPlace() }
        bleed.reduceMotion = { [weak self] in self?.reduceMotion() ?? false }
        window.didSlide = { [weak self] in self?.bleed.follow() }
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
            let press = press(at: point, event)
            pressClick = press?.click
            outcome = hold.down(kind: press?.kind, at: point, time: event.timestamp)
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

    /// What a press at `point` could become, and what it would be if it
    /// turned out a click; or nil when it's not the island's to take:
    /// outside the drawn island, a control-click, a reply being typed (the
    /// panel is key), a file drag or the drop face, a swipe between faces
    /// still moving, a press on one of AppKit's own controls, or a closed
    /// island on its notch.
    ///
    /// Open off the notch, it's where on the panel that decides: its header
    /// and its bare edge hold nothing a drag could mean instead, so a drag
    /// there moves it at once; on its content a drag can be a slider's, a
    /// scrub or an item off the shelf, so there it takes the short hold.
    private func press(at point: CGPoint, _ event: NSEvent) -> (kind: IslandHold.Kind, click: Click?)? {
        guard !event.modifierFlags.contains(.control),
              glide == nil,
              presentation.metrics != nil,
              drawnRect()?.insetBy(dx: -1, dy: -1).contains(point) == true,
              holdable,
              !landsOnControl(event)
        else { return nil }
        switch (presentation.placement.isFloating, presentation.state.isExpanded) {
        case (false, true): return (.detach, nil)
        case (true, true):
            switch spot(at: point) {
            case .grabber: return (.drag, .grabber)
            case .edge: return (.drag, nil)
            case .content: return (.pickUp, nil)
            }
        case (true, false): return (.drag, .capsule)
        case (false, false): return nil
        }
    }

    /// Where on the open panel `point` is (`IslandFloat.spot`): the drawn
    /// island is the panel, and its header band is the camera band's
    /// height, as it's drawn (NotchRootView).
    private func spot(at point: CGPoint) -> IslandFloat.PanelSpot {
        guard let drawn = drawnRect(), let band = presentation.metrics?.notchSize.height else { return .content }
        let local = CGPoint(x: point.x - drawn.minX, y: drawn.maxY - point.y)
        return IslandFloat.spot(at: local, panel: drawn.size, band: band)
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
            case .clicked:
                if let click = pressClick { onClick(click) }
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
        let anchor = NotchMetrics.anchor(of: window.frame, opening: presentation.placement.isFloating ? presentation.opening : .down)
        grabOffset = CGPoint(x: anchor.x - point.x, y: anchor.y - point.y)
        pillWidth = drawnRect()?.width
        topOffset = .zero
        if presentation.placement.isFloating, let drawn = drawnRect() {
            topOffset = presentation.opening.topCentre(of: drawn.size, open: isOpen, pillHeight: IslandFloat.pillHeight)
        }
        snapped = false
        snapArmed = !bounds.captures(top(of: anchor))
        presentation.detachTrace.complete()
        haptic(.lifted)
        // Before the placement changes, so the black on the island comes in
        // with the floating look, on its spring.
        bleed.engage(fromNotch: !presentation.placement.isFloating)
        if !presentation.placement.isFloating {
            // Off the notch open, hanging from where it was.
            presentation.opening = .down
            setPlacement(.floating(anchor: anchor))
        }
    }

    /// The drawn island's top centre for an anchor carried to `anchor`.
    private func top(of anchor: CGPoint) -> CGPoint {
        CGPoint(x: anchor.x + topOffset.x, y: anchor.y + topOffset.y)
    }

    /// Whether the island is open: an open panel carried is kept on the
    /// screen whole, opening the way it does; a closed capsule only has to
    /// be on it itself.
    private var isOpen: Bool { presentation.state.isExpanded }

    /// Where the island is carried to for `wanted`, kept on the screen.
    private func carried(_ wanted: CGPoint, in bounds: IslandPlacementBounds) -> CGPoint {
        if isOpen { return bounds.carrying(wanted, open: presentation.opening) }
        guard presentation.placement.isFloating, let pillWidth else { return bounds.carrying(wanted) }
        return bounds.carrying(wanted, pillWidth: pillWidth, carried: presentation.opening)
    }

    private func carry(to point: CGPoint) {
        guard let grabOffset, let metrics = presentation.metrics else { return }
        let bounds = metrics.placementBounds
        let wanted = Self.anchor(for: point, grabbedBy: grabOffset)

        if snapped {
            // On the notch until it's carried clear of it.
            guard !bounds.holds(top(of: wanted)) else { return }
            snapped = false
            cancelGlide()
            let anchor = carried(wanted, in: bounds)
            setPlacement(.floating(anchor: anchor))
            window.slide(to: metrics.frame(for: .floating(anchor: anchor), opening: presentation.opening))
            return
        }

        if !snapArmed {
            if !bounds.holds(top(of: wanted)) { snapArmed = true }
        } else if bounds.captures(top(of: wanted)) {
            // Near enough: the notch takes it, and that's where it's drawn,
            // as it will be if it's let go here.
            snapped = true
            haptic(.snapped)
            // From here it opens down, centred: its anchor is its top
            // centre, and the grab is kept by that.
            self.grabOffset = CGPoint(x: grabOffset.x + topOffset.x, y: grabOffset.y + topOffset.y)
            topOffset = .zero
            turn(to: .down)
            setPlacement(.docked)
            move(to: metrics.frame(for: .docked))
            return
        }
        window.slide(to: metrics.frame(for: .floating(anchor: carried(wanted, in: bounds)), opening: presentation.opening))
    }

    private func drop(at point: CGPoint) {
        defer {
            grabOffset = nil
            pillWidth = nil
            topOffset = .zero
            snapped = false
        }
        guard let grabOffset, let bounds = presentation.metrics?.placementBounds else { return }
        let wanted = Self.anchor(for: point, grabbedBy: grabOffset)
        // Back on the notch if the notch has it, if it's let go within
        // reach of it, or if it was never carried clear in the first place.
        if snapped || !snapArmed || bounds.captures(top(of: wanted)) {
            settle(.docked)
        } else {
            // Put down away from the notch: the black lets go.
            bleed.release(drain: true)
            let down = bounds.putDown(wanted, open: keptOpening, pillWidth: pillWidth ?? bounds.pill.width, carried: presentation.opening)
            settle(.floating(anchor: down.anchor))
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
        let opening = opening(for: placement, in: metrics.placementBounds)
        turn(to: opening)
        setPlacement(placement)
        onPlaced(placement)
        move(to: metrics.frame(for: placement, opening: opening)) { [weak self] in
            // Home: the bleed has merged into the notch, and is done.
            if !placement.isFloating { self?.bleed.release(drain: false) }
            self?.onArrived()
        }
    }

    /// Which way the island will open at `placement`: down on the notch;
    /// off it, kept while it's open, else the way its place calls for.
    private func opening(for placement: IslandPlacement, in bounds: IslandPlacementBounds) -> IslandOpening {
        guard let anchor = placement.anchor else { return .down }
        return keptOpening ?? bounds.opening(at: anchor)
    }

    /// The way an open island opens, which it keeps wherever it's put;
    /// nil while it's closed — a capsule closed by its grabber too — whose
    /// place decides when it's put down.
    private var keptOpening: IslandOpening? {
        isOpen ? presentation.opening : nil
    }

    /// Changes which way the island opens without anything on the screen
    /// moving: the window is put where the new opening wants it for the
    /// island's anchor as it is now, and the island drawn inside it where
    /// that opening puts it, in the same screen update. Only ever called
    /// with the island closed (or on its way to the notch, where it opens
    /// down), so it's the capsule that is redrawn in place.
    ///
    /// Pinned differently (`IslandOpening.pin`), the anchor is another
    /// point of the capsule — its middle or an end — so it's taken afresh,
    /// for the capsule as it's drawn now.
    private func turn(to opening: IslandOpening) {
        guard presentation.opening != opening, let metrics = presentation.metrics else { return }
        let old = presentation.opening
        var anchor = NotchMetrics.anchor(of: window.frame, opening: old)
        if presentation.placement.isFloating, let drawn = drawnRect() {
            let mid = window.frame.midX + old.offset(width: drawn.width, open: isOpen)
            anchor.x = mid - opening.offset(width: drawn.width, open: isOpen) - opening.shift
            // An open panel turned (going home to the notch) keeps its top
            // edge, or its bottom edge, where it is: it's the capsule's
            // anchor that differs between opening up and down, not the
            // panel's top.
            if isOpen {
                anchor.y = opening.upward ? drawn.minY + IslandFloat.pillHeight : drawn.maxY
            }
        }
        window.disableScreenUpdatesUntilFlush()
        window.glassWindow.disableScreenUpdatesUntilFlush()
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) {
            presentation.opening = opening
        }
        // The views in step now, not on the next pass, so the window and
        // what's in it change together.
        window.contentView?.layoutSubtreeIfNeeded()
        window.glassWindow.contentView?.layoutSubtreeIfNeeded()
        window.slide(to: metrics.frame(for: .floating(anchor: anchor), opening: opening))
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

    // MARK: - Before it opens

    /// The island is about to open (`IslandPresentation.willOpen`): closed
    /// off its notch, it opens the way its place calls for *now*. The way
    /// it opened is kept only while it's open — so an open panel carried
    /// and put down stays whole on the screen — and once it's closed again
    /// it's the capsule's place that decides, wherever it got there.
    /// Anchored again for that in place, so nothing on the screen moves
    /// (`turn`) before the open spring starts.
    private func openForPlace() {
        guard presentation.placement.isFloating, !isOpen, hold.phase != .carrying, glide == nil,
              let metrics = presentation.metrics, let anchor = presentation.placement.anchor,
              let width = drawnRect()?.width
        else { return }
        let (rest, opening) = metrics.placementBounds.forPlace(anchor, pillWidth: width, was: presentation.opening)
        guard opening != presentation.opening || rest != anchor else { return }
        turn(to: opening)
        setPlacement(.floating(anchor: rest))
        onPlaced(.floating(anchor: rest))
        window.slide(to: metrics.frame(for: .floating(anchor: rest), opening: opening))
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
        bleed.release(drain: false)
        let opening = opening(for: placement, in: metrics.placementBounds)
        if presentation.opening != opening { presentation.opening = opening }
        if presentation.placement != placement { presentation.placement = placement }
        window.place(metrics.frame(for: placement, opening: opening))
    }

    /// Ends a press under way, the island put down where it is (the
    /// islands are being hidden).
    func cancel() {
        deadline?.cancel()
        deadline = nil
        perform(hold.abandon().actions)
        bleed.release(drain: false)
    }

    /// Back onto the notch, from wherever it is. Nothing to do on the
    /// notch, or while it's in the user's hand.
    func returnToNotch() {
        guard presentation.placement.isFloating, hold.phase != .carrying else { return }
        // Home along the glide, the notch reaching for it on the way.
        bleed.engage(fromNotch: false)
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
