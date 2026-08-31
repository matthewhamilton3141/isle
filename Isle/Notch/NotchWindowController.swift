//
//  NotchWindowController.swift
//
//  Owns the overlay panel and keeps it glued to the right screen.
//
//  Sizing note: the panel is created once at its maximum extent and never
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
    private var window: NotchWindow?
    private var hostingView: NotchHostingView<NotchRootView>?
    private var metrics: NotchMetrics?
    private var screenObserver: (any NSObjectProtocol)?
    private var pointerMonitor: Any?

    /// The notch's live clickable region, in the hosting view's coordinate
    /// space (top-left origin). Drives `ignoresMouseEvents` so the window
    /// server passes clicks outside the drawn notch straight through — see
    /// `updateClickThrough`.
    private var activeRectInView: CGRect?

    private let viewModel = NotchViewModel()

    var isVisible: Bool { window?.isVisible ?? false }

    init() {
        observeScreenChanges()
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
        guard let screen = NotchMetrics.preferredScreen() else {
            NSLog("Isle: no screen available to place the notch on")
            return
        }

        let metrics = NotchMetrics(screen: screen)
        self.metrics = metrics
        viewModel.metrics = metrics

        let frame = metrics.maximumFrame
        let window = self.window ?? NotchWindow(contentRect: frame)

        window.setFrame(frame, display: false)

        if hostingView == nil {
            // Built once and reused. Recreating the hosting view on every
            // show() would restart the marquee and equalizer phases and drop
            // the adapter's accumulated state.
            let hosting = NotchHostingView(
                rootView: NotchRootView(viewModel: viewModel) { [weak self] rect in
                    self?.hostingView?.activeRect = rect
                    self?.activeRectInView = rect
                    self?.updateClickThrough()
                }
            )
            hostingView = hosting
        }

        window.contentView = hostingView
        window.orderFrontRegardless()

        self.window = window
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
        window?.orderOut(nil)
        if let pointerMonitor {
            NSEvent.removeMonitor(pointerMonitor)
            self.pointerMonitor = nil
        }
        viewModel.stop()
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
    /// dead area around the notch, open the panel when the pointer arrives on
    /// the island, and collapse it once the pointer leaves for good. Isle never
    /// becomes the active app, so a global monitor (not a local one) is what
    /// sees these moves. `.mouseMoved` monitoring needs no special permission.
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
        // Every move: reconcile click-through, so the window server only routes
        // clicks to Isle when the pointer is over the drawn notch and passes
        // everything else to what's underneath.
        updateClickThrough()

        // Measured on every move, in zone or out: the reading is an interval
        // between consecutive events, so sampling it only once the pointer is
        // already over the island would date it from whenever the pointer was
        // last there — and a sweep would clear the gate on its first frame.
        let sweeping = isSweep(event)

        guard let zones = hoverZones() else { return }
        let pointer = NSEvent.mouseLocation

        guard !viewModel.isHovering else {
            // Open: only a real departure closes it. SwiftUI's `.onHover` sees
            // the drawn rect and nothing more, which is why closing is owned
            // here — it's the only place that knows about the pad.
            if !zones.stayOpen.contains(pointer) {
                cancelSweepRecheck()
                viewModel.setHovering(false)
            }
            return
        }

        guard zones.open.contains(pointer) else {
            cancelSweepRecheck()
            return
        }

        // Arriving is instant; crossing is not. A fast sideways move through
        // the island is the pointer on its way somewhere else — the single
        // most common way this panel used to open when nobody asked it to.
        if sweeping {
            scheduleSweepRecheck()
        } else {
            cancelSweepRecheck()
            viewModel.setHovering(true)
        }
    }

    /// The open and stay-open regions in screen coordinates, or nil before the
    /// first layout.
    private func hoverZones() -> (open: CGRect, stayOpen: CGRect)? {
        guard let drawn = drawnRectInScreen() else { return nil }
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

    private func scheduleSweepRecheck() {
        guard sweepRecheckWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.sweepRecheckWork = nil
                guard let zones = self.hoverZones(),
                      zones.open.contains(NSEvent.mouseLocation)
                else { return }
                self.viewModel.setHovering(true)
            }
        }
        sweepRecheckWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.sweepRecheck, execute: work)
    }

    private func cancelSweepRecheck() {
        sweepRecheckWork?.cancel()
        sweepRecheckWork = nil
    }

    /// Makes the panel transparent to the mouse everywhere except the drawn
    /// notch. Returning `nil` from the hosting view's `hitTest` is not enough:
    /// the window server has already chosen this panel as the click target
    /// before `hitTest` runs, so a `nil` result drops the click rather than
    /// forwarding it to the menu bar or window underneath. Toggling
    /// `ignoresMouseEvents` makes the window server skip the panel outright, so
    /// the click lands on whatever is really there.
    ///
    /// Driven by the same `activeRect` the content reports, converted from the
    /// hosting view's top-left space to the screen's bottom-left space. Padded
    /// so the panel goes live a hair before the pointer reaches the visible
    /// notch — otherwise the flip could land one event too late and the first
    /// hover-in would be missed.
    private func updateClickThrough() {
        guard let window else { return }

        guard let screenRect = drawnRectInScreen() else {
            // No layout yet — err toward interactive so the notch is never dead.
            window.ignoresMouseEvents = false
            return
        }

        // Keep clicks routed to Isle a hair before the pointer reaches the
        // visible notch (the pad), so the first hover-in is never missed.
        let hot = screenRect.insetBy(dx: -6, dy: -6)
        window.ignoresMouseEvents = !hot.contains(NSEvent.mouseLocation)
    }

    /// The drawn notch in screen coordinates (bottom-left origin), which is
    /// what `NSEvent.mouseLocation` speaks. Nil until SwiftUI reports a layout.
    private func drawnRectInScreen() -> CGRect? {
        guard let window, let rect = activeRectInView else { return nil }
        let frame = window.frame
        // `rect` is measured from the top of the window; the window's top edge
        // sits at `frame.maxY`.
        return CGRect(
            x: frame.minX + rect.minX,
            y: frame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    // MARK: - Screen changes

    /// Re-place the panel when displays change — plugging in a monitor can
    /// renumber screens and move the built-in display's coordinate origin,
    /// which would otherwise leave the notch floating in the wrong place.
    private func observeScreenChanges() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isVisible else { return }
                self.show()
            }
        }
    }
}
