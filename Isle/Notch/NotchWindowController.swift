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
    private var localPointerMonitor: Any?
    private var cancellables = Set<AnyCancellable>()

    /// A sync arrived while an island was open and was deferred — see
    /// `syncIslands`. Run as soon as everything has collapsed.
    private var syncDeferred = false

    private let viewModel = NotchViewModel()
    private let settings = AppSettings.shared

    /// Whether a file drag is under way, read off the same global monitor
    /// as the hover — see `FileDrop.swift`.
    private let fileDrag = FileDragWatch()

    /// Between `show()` and `hide()`. Screen and settings changes only re-place
    /// panels while this is true.
    private var isRunning = false

    var isVisible: Bool { islands.values.contains { $0.window.isVisible } }

    /// The capture behind the waveform, for Settings to report on. The view
    /// model owns it; this is the only way out.
    var audioLevels: SystemAudioLevels { viewModel.audioLevelSource }

    init() {
        observeScreenChanges()
        observeDisplayScope()
        fileDrag.onChange = { [weak self] inFlight in
            self?.fileDragChanged(inFlight)
        }
    }

    deinit {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        if let pointerMonitor {
            NSEvent.removeMonitor(pointerMonitor)
        }
        if let localPointerMonitor {
            NSEvent.removeMonitor(localPointerMonitor)
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
            island.presentation.endDrop(collapse: false)
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
        if let localPointerMonitor {
            NSEvent.removeMonitor(localPointerMonitor)
            self.localPointerMonitor = nil
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
            island.presentation.endDrop(collapse: false)
            island.presentation.setHovering(false)
            island.window.orderOut(nil)
            islands.removeValue(forKey: id)
        }
    }

    private func makeIsland(id: CGDirectDisplayID, screen: NSScreen, metrics: NotchMetrics) {
        let presentation = IslandPresentation(content: viewModel)
        presentation.metrics = metrics

        let window = NotchWindow(contentRect: metrics.maximumFrame)
        // A two-finger swipe across an open face moves between faces.
        window.scrollInterceptor = { [weak presentation] event in
            presentation?.handleScroll(event) ?? false
        }
        // Files dragged onto the island open the drop face.
        window.registerForDraggedTypes([.fileURL])
        window.dropHandler = self
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
    /// The side is `NotchMetrics.stayOpenSidePad`, which the window frame is
    /// widened by so a file drag in the pad still reaches the window.
    private static let stayOpenPad = (top: CGFloat(10), side: NotchMetrics.stayOpenSidePad, bottom: CGFloat(26))

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
    /// sees these moves.
    ///
    /// The left button's down, dragged and up events come through the same
    /// monitor, for one thing only: telling a file drag under way, which
    /// sends no `mouseMoved` at all (see `FileDragWatch`). None of these
    /// needs a permission — a global monitor is gated behind Accessibility
    /// for key events only, and mouse events are delivered as they are for
    /// `.mouseMoved`.
    ///
    /// One monitor covers every island: the pointer is only ever in one place,
    /// so each move is routed to the island whose screen it is on and every
    /// other island is told to collapse.
    ///
    /// A global monitor sees only events sent to *other* apps, so it goes
    /// blind exactly when Isle is where the moves are sent: while the AirDrop
    /// sheet has Isle active, or while a panel is key for a reply. A local
    /// monitor on `mouseMoved` sees those, and they take the same path. An
    /// event goes to one app or the other, never both, so the two don't
    /// overlap; `handlePointerMove` drops a repeat all the same.
    private func observePointer() {
        guard pointerMonitor == nil else { return }
        pointerMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.fileDrag.handle(event)
                switch event.type {
                case .mouseMoved:
                    self.handlePointerMove(event)
                case .leftMouseDragged:
                    self.handleDragMove()
                default:
                    break
                }
            }
        }
        // Moves only. Isle's own presses and drags — an item dragged off the
        // shelf — are no file drag *to* the island, and stay unseen as before.
        localPointerMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.fileDrag.handle(event)
                self.handlePointerMove(event)
            }
            return event
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
        // A move already handled, or one older than it: no news. Matters
        // only for the sweep reading below, which would take a repeat for a
        // pause — and a pause for an arrival.
        guard event.timestamp > lastPointerTimestamp else { return }

        // A move with no button held: whatever drag there was is over. The
        // window's own drag callbacks end the drop face on the way out; this
        // is the backstop for one that never got them.
        endDropTargets()

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

    // MARK: - File drags

    /// A file drag moved. The pointer is held down, so `mouseMoved` is silent
    /// and click-through would stay as the drag found it — leaving every
    /// island transparent to the drag it's meant to receive. Reconciled here
    /// instead, only while the drag carries files.
    private func handleDragMove() {
        guard fileDrag.isDraggingFiles else { return }
        for island in islands.values {
            updateClickThrough(island)
        }
    }

    private func fileDragChanged(_ inFlight: Bool) {
        viewModel.fileDragChanged(inFlight)
        // Back to the plain hot rect once it's over; the drag's own grown
        // one from its first event.
        for island in islands.values {
            updateClickThrough(island)
        }
    }

    /// Ends every drop face without collapsing, and forgets the payload.
    private func endDropTargets() {
        guard viewModel.dropPayload != nil || islands.values.contains(where: { $0.presentation.isDropTarget }) else {
            return
        }
        for island in islands.values {
            island.presentation.endDrop(collapse: false)
        }
        viewModel.setDropPayload(nil)
    }

    private func island(for window: NotchWindow) -> Island? {
        islands.values.first { $0.window === window }
    }

    /// Where a file drag counts as over an island. Collapsed, the island and
    /// the same lip below it a hover opens from; open on the drop face, the
    /// panel and the same pad a hover stays open in. Nothing here looks at
    /// speed: a drag is slow and deliberate, and nothing sweeps past with
    /// files in hand on the way to the menu bar.
    private func dropZone(for island: Island) -> CGRect? {
        guard let zones = hoverZones(for: island) else { return nil }
        return island.presentation.isDropTarget ? zones.stayOpen : zones.open
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
        var hot = screenRect.insetBy(dx: -6, dy: -6)
        // A file drag reaches the window over the whole of the drop zone,
        // or it never sees the lip below the island.
        if fileDrag.isDraggingFiles, viewModel.acceptsDrops, let zone = dropZone(for: island) {
            hot = hot.union(zone)
        }
        let ignores = !hot.contains(NSEvent.mouseLocation)
        // Only on a change. This runs on every pointer move on every island,
        // and the setter is a window-server round trip whether or not the
        // value moved.
        if island.window.ignoresMouseEvents != ignores {
            island.window.ignoresMouseEvents = ignores
        }
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

// MARK: - Drop destination

extension NotchWindowController: NotchDropHandler {
    /// Every `draggingEntered` and `draggingUpdated`. Opens the drop face as
    /// the drag reaches the island, lights the target under the pointer, and
    /// lets the face go if the drag strays past the panel's pad. Says a drop
    /// is possible only over a target that would do something, so letting
    /// go anywhere else hands the files straight back.
    func dragUpdated(_ info: any NSDraggingInfo, in window: NotchWindow) -> NSDragOperation {
        guard let island = island(for: window) else { return [] }
        let presentation = island.presentation

        // A drag that started in Isle — an item leaving the shelf — isn't a
        // drop onto it. And nothing drops over a live alert.
        guard info.draggingSource == nil, viewModel.acceptsDrops else {
            presentation.endDrop(collapse: false)
            return []
        }
        guard let zone = dropZone(for: island) else { return [] }
        let pointer = window.convertPoint(toScreen: info.draggingLocation)

        if !presentation.isDropTarget {
            guard zone.contains(pointer),
                  let urls = DropPayload.fileURLs(on: info.draggingPasteboard)
            else { return [] }
            viewModel.setDropPayload(DropPayload(urls: urls))
            for other in islands.values where other !== island {
                other.presentation.endDrop(collapse: true)
            }
            cancelSweepRecheck()
            presentation.beginDrop()
            updateClickThrough(island)
        } else if !zone.contains(pointer) {
            presentation.endDrop(collapse: true)
            updateClickThrough(island)
            return []
        }

        guard let payload = viewModel.dropPayload else { return [] }
        presentation.lightDropTarget(at: island.hosting.topLeftPoint(fromWindow: info.draggingLocation)) {
            self.viewModel.canPerform($0, with: payload)
        }
        guard presentation.litDropTarget != nil else { return [] }
        return Self.dropOperation(allowedBy: info.draggingSourceOperationMask)
    }

    /// What every target tells the source it did: a copy, or failing that
    /// a link — never a move. The shelf keeps only a path, Start Claude
    /// only opens one, and AirDrop sends a copy of its own, so the source's
    /// file has to stay exactly where it was. `.generic` doesn't promise
    /// that: plenty of sources — another shelf, a file manager, a list in an
    /// app — read it as a move and take their copy away once the drop lands.
    ///
    /// Copy before link because every file source offers it, so the cursor
    /// shows the same badge whatever the drag came from. A source offering
    /// neither — Command held over a Finder drag asks for a move and nothing
    /// else — gets no drop, rather than one it would take for a move.
    static func dropOperation(allowedBy mask: NSDragOperation) -> NSDragOperation {
        if mask.contains(.copy) { return .copy }
        if mask.contains(.link) { return .link }
        return []
    }

    func dragExited(_ window: NotchWindow) {
        guard let island = island(for: window), island.presentation.isDropTarget else { return }
        island.presentation.endDrop(collapse: true)
        if !islands.values.contains(where: { $0.presentation.isDropTarget }) {
            viewModel.setDropPayload(nil)
        }
    }

    func performDrop(_ info: any NSDraggingInfo, in window: NotchWindow) -> Bool {
        guard let island = island(for: window) else { return false }
        let target = island.presentation.litDropTarget
        let payload = viewModel.dropPayload
        island.presentation.endDrop(collapse: false)
        viewModel.setDropPayload(nil)
        fileDrag.dragConcluded()
        guard island.presentation.state.isExpanded, let target, let payload,
              viewModel.canPerform(target, with: payload)
        else { return false }
        // After AppKit is done with the drop: Terminal and the share sheet
        // shouldn't come up from inside its callback.
        DispatchQueue.main.async { [viewModel] in
            viewModel.performDrop(target, with: payload)
        }
        return true
    }

    func dragEnded(_ window: NotchWindow) {
        guard let island = island(for: window) else { return }
        island.presentation.endDrop(collapse: false)
        if !islands.values.contains(where: { $0.presentation.isDropTarget }) {
            viewModel.setDropPayload(nil)
        }
    }
}
