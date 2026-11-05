//
//  NotchWindow.swift
//
//  The borderless, transparent, always-on-top window the notch lives in.
//
//  This is an NSPanel rather than a plain NSWindow specifically for
//  `.nonactivatingPanel`, which is only honoured on panels. Isle is an
//  agent app with no Dock icon, so if the overlay took focus when clicked
//  there'd be no obvious way to give it back — the user would click
//  play/pause and silently lose their text cursor. A non-activating panel
//  receives clicks without deactivating the frontmost app.
//

import AppKit

final class NotchWindow: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false

        // Sit above the menu bar. `.statusBar` alone still lands under the
        // menu bar on some configurations, so key off the main-menu level
        // explicitly and add one.
        level = NSWindow.Level(
            rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 1
        )

        // Follow the user across Spaces and stay put during Mission Control —
        // the notch is hardware, so it shouldn't look like it belongs to one
        // desktop. `.fullScreenAuxiliary` keeps it up over full-screen apps.
        collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .fullScreenAuxiliary,
            .ignoresCycle,
        ]

        isMovable = false
        isMovableByWindowBackground = false
        ignoresMouseEvents = false

        // Panels hide themselves when the owning app deactivates; Isle's
        // whole point is being visible while you work in other apps.
        hidesOnDeactivate = false

        // Keep it out of screenshots' window lists and Exposé clutter.
        isExcludedFromWindowsMenu = true
    }

    // Isle's controls are hover/click driven and it should never pull focus
    // out of the frontmost app, so key and main status are both refused.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Offered every scroll event before the views under the pointer see it.
    /// Returns true to keep it from them.
    ///
    /// Scroll events need no key status: the window server sends them to the
    /// window under the pointer, key or not, which is how the Agenda list
    /// already scrolls in a panel that never takes focus. They arrive here
    /// first, on their way to that list, so this is where a horizontal swipe
    /// between faces is told from a vertical scroll and taken out before the
    /// list sees it.
    var scrollInterceptor: (@MainActor (NSEvent) -> Bool)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .scrollWheel, let scrollInterceptor, scrollInterceptor(event) {
            return
        }
        super.sendEvent(event)
    }

    /// Where a drag over this window goes. The window, not a view, is the
    /// destination: nothing in the notch registers a SwiftUI drop, so AppKit
    /// hands every file drag over the window's frame to the window itself,
    /// and the handler decides what part of that frame counts — the island
    /// and its lip, or the open panel and its pad.
    weak var dropHandler: NotchDropHandler?
}

/// The drag callbacks of one notch window, passed on with the window they
/// arrived at.
@MainActor
protocol NotchDropHandler: AnyObject {
    func dragUpdated(_ info: any NSDraggingInfo, in window: NotchWindow) -> NSDragOperation
    func dragExited(_ window: NotchWindow)
    func performDrop(_ info: any NSDraggingInfo, in window: NotchWindow) -> Bool
    func dragEnded(_ window: NotchWindow)
}

extension NotchWindow: NSDraggingDestination {
    func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dropHandler?.dragUpdated(sender, in: self) ?? []
    }

    func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dropHandler?.dragUpdated(sender, in: self) ?? []
    }

    func draggingExited(_ sender: (any NSDraggingInfo)?) {
        dropHandler?.dragExited(self)
    }

    func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        dropHandler?.performDrop(sender, in: self) ?? false
    }

    func draggingEnded(_ sender: any NSDraggingInfo) {
        dropHandler?.dragEnded(self)
    }
}
