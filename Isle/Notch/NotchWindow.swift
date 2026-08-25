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
}
