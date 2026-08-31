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
    /// The "Pop out notch for alerts" checkbox, refreshed each time the menu
    /// opens so it always reflects the current setting.
    private var expandAlertsItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()

        // If Isle's hooks were installed by an older build, quietly bring the
        // helper and hook set up to date (e.g. to pick up the SessionEnd hook
        // that clears the island when a session closes). No-op if not installed.
        HookInstaller.refreshIfNeeded()

        notchController = NotchWindowController()
        notchController?.show()

        // First launch (no mode chosen yet): ask what Isle should be before
        // it settles into the default Both behaviour.
        if !AppSettings.shared.hasChosenMode {
            openSetup()
        }

        // Silent check-on-launch: an unreachable/unconfigured endpoint stays
        // quiet. If it finds a newer build the user hasn't dismissed, prompt.
        Task {
            await Updater.shared.check(silent: true)
            presentUpdatePromptIfNeeded()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        notchController?.shutdown()
    }

    // MARK: - Menu bar

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = StatusBarIcon.image
        item.button?.setAccessibilityLabel("Isle")

        let menu = NSMenu()
        menu.delegate = self   // keeps the alert checkbox in sync on open
        menu.addItem(
            withTitle: "Toggle Notch",
            action: #selector(toggleNotch),
            keyEquivalent: ""
        ).target = self

        // Quick access to the "expand for alerts" preference without opening
        // Settings — a checkbox that mirrors AppSettings.expandOnAlert.
        let alertsItem = NSMenuItem(
            title: "Pop out notch for alerts",
            action: #selector(toggleExpandOnAlert),
            keyEquivalent: ""
        )
        alertsItem.target = self
        alertsItem.state = AppSettings.shared.expandOnAlert ? .on : .off
        menu.addItem(alertsItem)
        expandAlertsItem = alertsItem

        menu.addItem(.separator())

        menu.addItem(
            withTitle: "Settings…",
            action: #selector(openSettings),
            keyEquivalent: ","
        ).target = self
        menu.addItem(
            withTitle: "Setup…",
            action: #selector(openSetup),
            keyEquivalent: ""
        ).target = self
        menu.addItem(
            withTitle: "Check for Updates…",
            action: #selector(checkForUpdates),
            keyEquivalent: ""
        ).target = self
        menu.addItem(.separator())

        menu.addItem(
            withTitle: "Marker Editor…",
            action: #selector(openMarkerEditor),
            keyEquivalent: ""
        ).target = self
        menu.addItem(
            withTitle: "Animation Gallery…",
            action: #selector(openAnimationGallery),
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

    @objc private func toggleExpandOnAlert() {
        AppSettings.shared.expandOnAlert.toggle()
        expandAlertsItem?.state = AppSettings.shared.expandOnAlert ? .on : .off
    }

    // MARK: - Onboarding / Setup

    private var setupWindow: NSWindow?

    @objc private func openSetup() {
        if let setupWindow {
            setupWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = OnboardingView(settings: .shared) { [weak self] in
            self?.setupWindow?.close()
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 460),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Isle Setup"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.contentView = NSHostingView(rootView: view)
        window.center()
        window.isReleasedWhenClosed = false
        setupWindow = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private var galleryWindow: NSWindow?

    @objc private func openAnimationGallery() {
        if let galleryWindow {
            galleryWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 820),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Isle — Animation Gallery"
        window.contentView = NSHostingView(rootView: AnimationGalleryView())
        window.center()
        // Keep the instance around after a close so reopening is instant and
        // doesn't hit a released window (the app is an agent with no main
        // window to fall back on).
        window.isReleasedWhenClosed = false
        galleryWindow = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Marker editor

    private var markerEditorWindow: NSWindow?

    @objc private func openMarkerEditor() {
        if let markerEditorWindow {
            markerEditorWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 640),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Isle — Marker Editor"
        window.contentView = NSHostingView(rootView: MarkerEditorView())
        window.center()
        window.isReleasedWhenClosed = false
        markerEditorWindow = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Settings

    private var settingsWindow: NSWindow?

    @objc private func openSettings() {
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 440),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Isle Settings"
        window.contentView = NSHostingView(rootView: SettingsView(settings: .shared))
        window.center()
        window.isReleasedWhenClosed = false
        settingsWindow = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Updates

    /// Manual "Check for Updates…": open Settings so the result (and any
    /// download progress) is visible, then run a *non-silent* check — errors
    /// surface here, unlike the quiet check-on-launch.
    @objc private func checkForUpdates() {
        openSettings()
        Task { await Updater.shared.check() }
    }

    /// After the silent launch check, prompt only for a newer build the user
    /// hasn't already dismissed. "Later" remembers this version so it won't
    /// nag again until a newer one ships.
    private func presentUpdatePromptIfNeeded() {
        guard Updater.shared.shouldPrompt,
              case let .available(version, notes) = Updater.shared.phase else { return }
        let alert = NSAlert()
        alert.messageText = "Update available — \(version)"
        let trimmed = notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        alert.informativeText = (trimmed?.isEmpty == false)
            ? trimmed!
            : "A newer version of Isle is ready to install."
        alert.addButton(withTitle: "Update & Restart")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            Task { await Updater.shared.install() }
        } else {
            Updater.shared.dismiss()
        }
    }
}

// MARK: - Menu delegate

extension AppDelegate: NSMenuDelegate {
    /// The setting can change from the Settings window too, so re-read it every
    /// time the menu opens rather than trusting the last toggle.
    func menuNeedsUpdate(_ menu: NSMenu) {
        expandAlertsItem?.state = AppSettings.shared.expandOnAlert ? .on : .off
    }
}
