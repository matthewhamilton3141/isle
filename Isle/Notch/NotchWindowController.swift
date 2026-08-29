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

    func hide() {
        window?.orderOut(nil)
        if let pointerMonitor {
            NSEvent.removeMonitor(pointerMonitor)
            self.pointerMonitor = nil
        }
        viewModel.stop()
    }

    // MARK: - Pointer backstop

    /// Tracks the pointer to do two things: keep clicks passing through the
    /// dead area around the notch, and force-collapse the panel when the
    /// pointer leaves it. Isle never becomes the active app, so a global
    /// monitor (not a local one) is what sees these moves. `.mouseMoved`
    /// monitoring needs no special permission.
    private func observePointer() {
        guard pointerMonitor == nil else { return }
        pointerMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved]
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }

                // Every move: reconcile click-through, so the window server
                // only routes clicks to Isle when the pointer is over the
                // drawn notch and passes everything else to what's underneath.
                self.updateClickThrough()

                // Backstop for collapse: SwiftUI's `.onHover` occasionally
                // misses a mouse-exit for a high-level overlay panel, leaving
                // the panel stuck open. Once the pointer is well clear of the
                // panel, hovering is false, full stop.
                guard let window = self.window, self.viewModel.isHovering else { return }

                // The window hugs the screen's top edge, so the pointer on the
                // island's top row reports y == frame.maxY — which `contains`
                // counts as *outside*, wrongly collapsing the panel the moment
                // you touch the top. Pad the region (generously up top) so only
                // a real departure from the island trips the backstop.
                //
                // NSEvent.mouseLocation and the frame are both screen coords,
                // bottom-left origin, so they compare directly.
                let region = window.frame.insetBy(dx: -6, dy: -12)
                guard !region.contains(NSEvent.mouseLocation) else { return }
                self.viewModel.setHovering(false)
            }
        }
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

        guard let rect = activeRectInView else {
            // No layout yet — err toward interactive so the notch is never dead.
            window.ignoresMouseEvents = false
            return
        }

        let frame = window.frame
        // `rect` is measured from the top of the window; the window's top edge
        // sits at `frame.maxY`.
        let screenRect = CGRect(
            x: frame.minX + rect.minX,
            y: frame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
        // Keep clicks routed to Isle a hair before the pointer reaches the
        // visible notch (the pad), so the first hover-in is never missed.
        let hot = screenRect.insetBy(dx: -6, dy: -6)
        window.ignoresMouseEvents = !hot.contains(NSEvent.mouseLocation)

        // Expansion, though, only arms when the pointer is genuinely *over* the
        // drawn notch — no outward pad — so merely passing near it (the earlier
        // behaviour, which popped the panel before you'd reached it) doesn't
        // count. Driven straight off the pointer for immediacy; the collapse side
        // stays with the generous frame backstop in `observePointer`, giving
        // open-small / stay-open-large hysteresis.
        if screenRect.contains(NSEvent.mouseLocation) { viewModel.setHovering(true) }
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
