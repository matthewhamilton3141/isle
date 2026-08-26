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

    /// Force-collapses the notch once the pointer leaves the panel entirely.
    ///
    /// SwiftUI's `.onHover` occasionally misses a mouse-exit for a high-level
    /// overlay panel — the notch then stays expanded, and because the expanded
    /// panel fills the window its hit area swallows clicks across the whole
    /// top-centre strip. This global monitor is the guarantee: once the pointer
    /// is well clear of the panel, hovering is false, full stop. Isle never
    /// becomes the active app, so a global monitor (not a local one) is what
    /// sees these moves. `.mouseMoved` monitoring needs no special permission.
    private func observePointer() {
        guard pointerMonitor == nil else { return }
        pointerMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved]
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self,
                      let window = self.window,
                      self.viewModel.isHovering
                else { return }

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
                self.viewModel.isHovering = false
            }
        }
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
