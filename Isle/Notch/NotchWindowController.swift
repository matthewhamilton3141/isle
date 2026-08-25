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

    private let viewModel = NotchViewModel()

    var isVisible: Bool { window?.isVisible ?? false }

    init() {
        observeScreenChanges()
    }

    deinit {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
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
        viewModel.start()
    }

    func hide() {
        window?.orderOut(nil)
        viewModel.stop()
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
