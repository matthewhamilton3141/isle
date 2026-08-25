//
//  IsleApp.swift
//
//  Entry point. Isle is an agent app (LSUIElement) — no Dock icon, no
//  main window. Everything the user sees is either the notch overlay
//  (an NSWindow we manage ourselves) or the menu bar item, so the
//  SwiftUI `App` body is deliberately an empty `Settings` scene.
//

import SwiftUI
import AppKit

@main
struct IsleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Settings is the one scene type that doesn't force a window open at
        // launch. The real UI lives in AppDelegate's NotchWindowController.
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var notchController: NotchWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()

        notchController = NotchWindowController()
        notchController?.show()
    }

    func applicationWillTerminate(_ notification: Notification) {
        notchController?.hide()
    }

    // MARK: - Menu bar

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "rectangle.topthird.inset.filled",
            accessibilityDescription: "Isle"
        )

        let menu = NSMenu()
        menu.addItem(
            withTitle: "Toggle Notch",
            action: #selector(toggleNotch),
            keyEquivalent: ""
        ).target = self
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit Isle",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        item.menu = menu
        statusItem = item
    }

    @objc private func toggleNotch() {
        guard let notchController else { return }
        notchController.isVisible ? notchController.hide() : notchController.show()
    }
}
