//
//  NotchWindowController.swift
//
//  Owns the overlay panels and keeps them glued to the right screens.
//
//  There is one *island* — one panel, one hosting view, one IslandPresentation
//  — per screen Isle is drawing on, and exactly one NotchViewModel behind all
//  of them. Every island shows the same track, the same Claude status, the same
//  power toast; what differs per screen is the cutout geometry and which island
//  the pointer is currently on. See IslandPresentation for that split.
//
//  Sizing note: each panel is created once at its maximum extent and never
//  resized while animating. The SwiftUI content inside grows and shrinks
//  against a fixed frame. Resizing an NSWindow per frame fights the window
//  server and shows up as tearing along the notch edge, which is the one
//  place it's most visible.
//

import AppKit
import SwiftUI
import Combine

@MainActor
final class NotchWindowController {
    /// One screen's worth of overlay. A class rather than a struct because the
    /// SwiftUI layout callback mutates `activeRectInView` from outside the
    /// dictionary that holds it.
    private final class Island {
        let presentation: IslandPresentation
        let window: NotchWindow
        let hosting: NotchHostingView<NotchRootView>

        /// The screen this island is drawn on. Re-resolved on every sync: a
        /// hotplug can hand back a different `NSScreen` object for the same
        /// display, with a different frame.
        var screen: NSScreen

        /// The notch's live clickable region, in the hosting view's coordinate
        /// space (top-left origin). Drives `ignoresMouseEvents` so the window
        /// server passes clicks outside the drawn notch straight through — see
        /// `updateClickThrough`.
        var activeRectInView: CGRect?

        init(
            presentation: IslandPresentation,
            window: NotchWindow,
            hosting: NotchHostingView<NotchRootView>,
            screen: NSScreen
        ) {
            self.presentation = presentation
            self.window = window
            self.hosting = hosting
            self.screen = screen
        }
    }

    /// Live islands, keyed by the display's runtime ID.
    ///
    /// `CGDirectDisplayID` is reassigned across reconnects and reboots, so it
    /// would be no use for *persisting* a choice of display — but that is
    /// exactly what this doesn't do. The key only has to be stable for as long
    /// as a display stays plugged in, which is what lets a re-sync reuse the
    /// existing panel (and so keep its marquee and equalizer phases) rather
    /// than rebuild it.
    private var islands: [CGDirectDisplayID: Island] = [:]

    private var screenObserver: (any NSObjectProtocol)?
    private var pointerMonitor: Any?
    private var cancellables = Set<AnyCancellable>()

    /// A sync arrived while an island was open and was deferred — see
    /// `syncIslands`. Run as soon as everything has collapsed.
    private var syncDeferred = false

    private let viewModel = NotchViewModel()
    private let settings = AppSettings.shared

    /// Between `show()` and `hide()`. Screen and settings changes only re-place
    /// panels while this is true.
    private var isRunning = false

    var isVisible: Bool { islands.values.contains { $0.window.isVisible } }

    init() {
        observeScreenChanges()
        observeDisplayScope()
    }

    deinit {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        if let pointerMonitor {
            NSEvent.removeMonitor(pointerMonitor)
        }
    }

    // MARK: - Lifecycle

    func show() {
        isRunning = true
        syncIslands()
        guard !islands.isEmpty else { return }
        observePointer()
        viewModel.start()
    }

    /// Quit path. Hides as usual, then waits briefly for the audio tap to come
    /// down rather than leaving it to the OS to reclaim on process death.
    func shutdown() {
        hide()
        viewModel.shutdown()
    }

    func hide() {
        isRunning = false
        for island in islands.values {
            island.presentation.setHovering(false)
            island.window.orderOut(nil)
        }
        // The panels are kept, not destroyed: `hide()` is a toggle from the
        // menu bar, and rebuilding the hosting views on the way back would
        // restart the marquee and equalizer phases.
        if let pointerMonitor {
            NSEvent.removeMonitor(pointerMonitor)
            self.pointerMonitor = nil
        }
        cancelSweepRecheck()
        viewModel.stop()
    }

    // MARK: - Placement

    /// Reconcile the live islands against the screens Isle should be drawing on.
    ///
    /// Idempotent and cheap: an existing island is reframed in place, a newly
    /// attached screen gets a panel, and a screen that has gone away — or
    /// dropped out of scope — loses one. Called on launch, on display changes,
    /// and when the user changes the display scope.
    private func syncIslands() {
        guard isRunning else { return }

        // Never re-place a panel the pointer is inside. The hover rule below
        // assumes a target that stays put, and a display change while the user
        // is reaching for the island — plugging in a monitor renumbers screens
        // and can move the built-in display's origin — would move it mid-reach.
        // Defer instead, and pick it up on collapse.
        if islands.values.contains(where: { $0.presentation.isHovering }) {
            syncDeferred = true
            return
        }
        syncDeferred = false

        let screens = targetScreens()
        guard !screens.isEmpty else {
            NSLog("Isle: no screen available to place the island on")
            return
        }

        var wanted = Set<CGDirectDisplayID>()

        for screen in screens {
            guard let id = Self.displayID(of: screen) else { continue }
            wanted.insert(id)

            let metrics = NotchMetrics(screen: screen)
            if let island = islands[id] {
                island.screen = screen
                island.presentation.metrics = metrics
                island.window.setFrame(metrics.maximumFrame, display: false)
                island.window.orderFrontRegardless()
            } else {
                makeIsland(id: id, screen: screen, metrics: metrics)
            }
        }

        for (id, island) in islands where !wanted.contains(id) {
            island.presentation.setHovering(false)
            island.window.orderOut(nil)
            islands.removeValue(forKey: id)
        }
    }

    private func makeIsland(id: CGDirectDisplayID, screen: NSScreen, metrics: NotchMetrics) {
        let presentation = IslandPresentation(content: viewModel)
        presentation.metrics = metrics

        let window = NotchWindow(contentRect: metrics.maximumFrame)
        let hosting = NotchHostingView(
            rootView: NotchRootView(viewModel: viewModel, island: presentation) { [weak self] rect in
                self?.updateActiveRect(rect, on: id)
            }
        )

        // In the dictionary before the content view is set: SwiftUI can report
        // its first layout during the `contentView` assignment, and the
        // callback above looks the island up by id.
        islands[id] = Island(
            presentation: presentation,
            window: window,
            hosting: hosting,
            screen: screen
        )

        window.contentView = hosting
        window.setFrame(metrics.maximumFrame, display: false)
        window.orderFrontRegardless()
    }

    /// The screens to draw on, in the user's chosen scope.
    ///
    /// Mirrored secondaries are dropped in both scopes: a mirror already shows
    /// the primary's island, and drawing a second one would put two panels on
    /// the same pixels with two independent hover states.
    private func targetScreens() -> [NSScreen] {
        switch settings.displayScope {
        case .builtIn:
            // `preferredScreen` is the notched screen, else main — so on a
            // clamshelled MacBook or a Mac mini this still means *somewhere*
            // rather than nowhere.
            return [NotchMetrics.preferredScreen()].compactMap { $0 }
        case .all:
            let screens = NSScreen.screens.filter { !Self.isMirrorSecondary($0) }
            return screens.isEmpty ? [NotchMetrics.preferredScreen()].compactMap { $0 } : screens
        }
    }

    private static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
            .uint32Value
    }

    private static func isMirrorSecondary(_ screen: NSScreen) -> Bool {
        guard let id = displayID(of: screen) else { return false }
        return CGDisplayMirrorsDisplay(id) != kCGNullDirectDisplay
    }

    private func updateActiveRect(_ rect: CGRect, on id: CGDirectDisplayID) {
        guard let island = islands[id] else { return }
        island.activeRectInView = rect
        island.hosting.activeRect = rect
        updateClickThrough(island)
    }

    // MARK: - Hover zones

    /// How far *below* the island the open zone reaches.
    ///
    /// Idle, the island collapses to the bare camera cutout: a target flush
    /// against the top edge of the screen, which the pointer can only approach
    /// from underneath. The lip meets the pointer on the way up, so a
    /// deliberate reach opens the panel a moment before landing on the notch
    /// rather than demanding you hit hardware exactly.
    private static let openLip: CGFloat = 14

    /// How far outside the panel the pointer may stray before it collapses.
    /// Deliberately lopsided: generous below and to the sides, where the
    /// pointer overshoots on its way to a control, and tight up top, where
    /// there is nothing to overshoot into.
    private static let stayOpenPad = (top: CGFloat(10), side: CGFloat(16), bottom: CGFloat(26))

    /// A move faster than this, and mostly sideways, is the pointer crossing
    /// the island on its way to the menu bar rather than arriving at it.
    private static let sweepSpeed: CGFloat = 900        // points per second
    private static let sweepAspect: CGFloat = 2.5       // |dx| vs |dy|

    /// How long after a suppressed sweep to look again. A sweep carries the
    /// pointer clear in far less than this (900pt/s covers 72pt), so what's
    /// left is a fast *approach* that stopped on the island — which stops
    /// producing events, and so needs asking rather than waiting for.
    private static let sweepRecheck: TimeInterval = 0.08

    private var lastPointerTimestamp: TimeInterval = 0
    private var sweepRecheckWork: DispatchWorkItem?

    /// Tracks the pointer to do three things: keep clicks passing through the
    /// dead area around each notch, open a panel when the pointer arrives on
    /// its island, and collapse it once the pointer leaves for good. Isle never
    /// becomes the active app, so a global monitor (not a local one) is what
    /// sees these moves. `.mouseMoved` monitoring needs no special permission.
    ///
    /// One monitor covers every island: the pointer is only ever in one place,
    /// so each move is routed to the island whose screen it is on and every
    /// other island is told to collapse.
    private func observePointer() {
        guard pointerMonitor == nil else { return }
        pointerMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved]
        ) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handlePointerMove(event)
            }
        }
    }

    /// The whole hover rule, in one place.
    ///
    /// Open and close use different zones on purpose. Opening asks for the
    /// island itself plus a lip below it — small, so the panel doesn't leap out
    /// at a pointer merely passing near. Closing asks for a much larger region
    /// around the open panel, so a pointer that overshoots a control by a few
    /// points doesn't shut it. The gap between the two is the hysteresis: easy
    /// to commit to, hard to lose by accident.
    private func handlePointerMove(_ event: NSEvent) {
        // Every move: reconcile click-through on every island, so the window
        // server only routes clicks to Isle when the pointer is over a drawn
        // notch and passes everything else to what's underneath.
        for island in islands.values {
            updateClickThrough(island)
        }

        // Measured on every move, in zone or out: the reading is an interval
        // between consecutive events, so sampling it only once the pointer is
        // already over the island would date it from whenever the pointer was
        // last there — and a sweep would clear the gate on its first frame.
        let sweeping = isSweep(event)

        let pointer = NSEvent.mouseLocation
        guard let active = island(containing: pointer) else {
            collapseAll()
            return
        }

        // The pointer is on one screen, so nothing on any other screen can
        // still be hovered. This is what closes the island you just left.
        for other in islands.values where other !== active {
            other.presentation.setHovering(false)
        }

        guard let zones = hoverZones(for: active) else { return }

        guard !active.presentation.isHovering else {
            // Open: only a real departure closes it. SwiftUI's `.onHover` sees
            // the drawn rect and nothing more, which is why closing is owned
            // here — it's the only place that knows about the pad.
            if !zones.stayOpen.contains(pointer) {
                cancelSweepRecheck()
                active.presentation.setHovering(false)
                runDeferredSync()
            }
            return
        }

        guard zones.open.contains(pointer) else {
            cancelSweepRecheck()
            runDeferredSync()
            return
        }

        // Arriving is instant; crossing is not. A fast sideways move through
        // the island is the pointer on its way somewhere else — the single
        // most common way this panel used to open when nobody asked it to.
        if sweeping {
            scheduleSweepRecheck(on: active)
        } else {
            cancelSweepRecheck()
            active.presentation.setHovering(true)
        }
    }

    /// Which island the pointer is on, by screen.
    ///
    /// The strict test comes first; the 1pt-grown fallback covers the top edge,
    /// where `NSEvent.mouseLocation` can report exactly `frame.maxY` and
    /// `CGRect.contains` excludes its own upper bound — which is precisely
    /// where the island lives.
    private func island(containing pointer: CGPoint) -> Island? {
        if let hit = islands.values.first(where: { $0.screen.frame.contains(pointer) }) {
            return hit
        }
        return islands.values.first { $0.screen.frame.insetBy(dx: -1, dy: -1).contains(pointer) }
    }

    private func collapseAll() {
        for island in islands.values {
            island.presentation.setHovering(false)
        }
        cancelSweepRecheck()
        runDeferredSync()
    }

    /// Run a sync that was held off because an island was open.
    private func runDeferredSync() {
        guard syncDeferred, !islands.values.contains(where: { $0.presentation.isHovering }) else {
            return
        }
        syncIslands()
    }

    /// The open and stay-open regions in screen coordinates, or nil before the
    /// first layout.
    private func hoverZones(for island: Island) -> (open: CGRect, stayOpen: CGRect)? {
        guard let drawn = drawnRectInScreen(island) else { return nil }
        let pad = Self.stayOpenPad
        return (
            // Screen coords are bottom-left origin, so "below the island" is
            // *lower* y — the lip hangs off `minY`.
            open: CGRect(
                x: drawn.minX,
                y: drawn.minY - Self.openLip,
                width: drawn.width,
                height: drawn.height + Self.openLip
            ),
            stayOpen: CGRect(
                x: drawn.minX - pad.side,
                y: drawn.minY - pad.bottom,
                width: drawn.width + pad.side * 2,
                height: drawn.height + pad.bottom + pad.top
            )
        )
    }

    /// Speed and direction of this move. The first event after a pause has no
    /// meaningful interval behind it, so it never counts as a sweep — which is
    /// the safe way round: it opens.
    private func isSweep(_ event: NSEvent) -> Bool {
        let interval = event.timestamp - lastPointerTimestamp
        lastPointerTimestamp = event.timestamp
        guard interval > 0, interval < 0.2 else { return false }
        let dx = abs(event.deltaX), dy = abs(event.deltaY)
        return hypot(dx, dy) / interval > Self.sweepSpeed && dx > dy * Self.sweepAspect
    }

    private func scheduleSweepRecheck(on island: Island) {
        guard sweepRecheckWork == nil else { return }
        let work = DispatchWorkItem { [weak self, weak island] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.sweepRecheckWork = nil
                guard let island,
                      let zones = self.hoverZones(for: island),
                      zones.open.contains(NSEvent.mouseLocation)
                else { return }
                island.presentation.setHovering(true)
            }
        }
        sweepRecheckWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.sweepRecheck, execute: work)
    }

    private func cancelSweepRecheck() {
        sweepRecheckWork?.cancel()
        sweepRecheckWork = nil
    }

    /// Makes a panel transparent to the mouse everywhere except its drawn
    /// notch. Returning `nil` from the hosting view's `hitTest` is not enough:
    /// the window server has already chosen this panel as the click target
    /// before `hitTest` runs, so a `nil` result drops the click rather than
    /// forwarding it to the menu bar or window underneath. Toggling
    /// `ignoresMouseEvents` makes the window server skip the panel outright, so
    /// the click lands on whatever is really there.
    ///
    /// This is also what keeps a non-notched display usable. The fallback pill
    /// sits over a *real* menu bar there, not over hardware — and everything
    /// either side of the drawn pill, which is where the app menus and status
    /// items are, stays clickable because the panel is transparent to the mouse
    /// outside it.
    ///
    /// Driven by the same `activeRect` the content reports, converted from the
    /// hosting view's top-left space to the screen's bottom-left space. Padded
    /// so the panel goes live a hair before the pointer reaches the visible
    /// notch — otherwise the flip could land one event too late and the first
    /// hover-in would be missed.
    private func updateClickThrough(_ island: Island) {
        guard let screenRect = drawnRectInScreen(island) else {
            // No layout yet — err toward interactive so the notch is never dead.
            island.window.ignoresMouseEvents = false
            return
        }

        // Keep clicks routed to Isle a hair before the pointer reaches the
        // visible notch (the pad), so the first hover-in is never missed.
        let hot = screenRect.insetBy(dx: -6, dy: -6)
        island.window.ignoresMouseEvents = !hot.contains(NSEvent.mouseLocation)
    }

    /// A drawn notch in screen coordinates (bottom-left origin), which is what
    /// `NSEvent.mouseLocation` speaks. Nil until SwiftUI reports a layout.
    private func drawnRectInScreen(_ island: Island) -> CGRect? {
        guard let rect = island.activeRectInView else { return nil }
        let frame = island.window.frame
        // `rect` is measured from the top of the window; the window's top edge
        // sits at `frame.maxY`.
        return CGRect(
            x: frame.minX + rect.minX,
            y: frame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    // MARK: - Screen and settings changes

    /// Re-place the panels when displays change — plugging in a monitor can
    /// renumber screens and move the built-in display's coordinate origin,
    /// which would otherwise leave a notch floating in the wrong place. In
    /// `.all` scope it's also how a newly attached display gets its island.
    private func observeScreenChanges() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.syncIslands()
            }
        }
    }

    /// Switching between built-in and all displays takes effect immediately —
    /// no relaunch. Delivered on the main queue rather than read inline because
    /// `@Published` fires *before* the new value is stored.
    private func observeDisplayScope() {
        settings.$displayScope
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.syncIslands()
            }
            .store(in: &cancellables)
    }
}
