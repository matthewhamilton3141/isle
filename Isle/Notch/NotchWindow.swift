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
        // On and off screen at once, never with the system's fade: handing
        // the keys back after a reply can take the panel off screen and
        // straight back (`NotchWindowController.giveKeysBack`), and with the
        // fade that played out over the island — the panel fading away over
        // its glass, which stayed behind at the open size as a grey block
        // while the island closed, then nothing at all until the pill came
        // back. The island's own motion is all in its content.
        animationBehavior = .none

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

        glassWindow.level = level
        glassWindow.collectionBehavior = collectionBehavior
        observeWindowChanges()
    }

    // MARK: - Placement

    /// Where the controller put this window — `NotchMetrics.maximumFrame` —
    /// set by `place(_:)` and nothing else. The window is never sized by its
    /// content or moved by AppKit: every frame change lands here, and a
    /// resize or move that went around `setFrame` is put back.
    ///
    /// The hosting views' `sizingOptions` are empty so the SwiftUI content
    /// doesn't size the window; this holds it even if something else does.
    /// Left to that, the window had been clamped to the open panel's 520pt
    /// keeping its origin, which takes the 16pt stay-open pad off the right
    /// and draws the island 16pt left of the camera — the collapsed pill's
    /// right cluster half under the housing.
    private(set) var placedFrame: NSRect?

    /// Puts the window, and its glass window, at `frame`, and keeps them there.
    func place(_ frame: NSRect) {
        placedFrame = frame
        setFrame(frame, display: false)
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(placedFrame ?? frameRect, display: flag)
        syncGlass()
    }

    /// Back to the placed frame after a change that didn't come through
    /// `setFrame` (the resize and move notifications).
    private func holdPlacement() {
        guard let placedFrame, frame != placedFrame, !holdingPlacement else { return }
        holdingPlacement = true
        super.setFrame(placedFrame, display: true)
        holdingPlacement = false
        syncGlass()
    }

    private var holdingPlacement = false

    // The size is the controller's alone: nothing may constrain it.
    override var contentMinSize: NSSize { get { super.contentMinSize } set {} }
    override var contentMaxSize: NSSize { get { super.contentMaxSize } set {} }
    override var minSize: NSSize { get { super.minSize } set {} }
    override var maxSize: NSSize { get { super.maxSize } set {} }

    // MARK: - The glass window

    /// Where the glass panel backgrounds' material is drawn: a window of its
    /// own, a child of this one just below it, that never becomes key.
    /// Liquid Glass turns on its full lens in a key window — what's behind
    /// comes through nearly sharp — and this panel becomes key while a reply
    /// is typed, so glass drawn here would change its look mid-reply. See
    /// `IslandGlassLayer`.
    ///
    /// It shows exactly when this window does, always directly below it, at
    /// its frame, level and alpha: after every ordering, visibility, alpha,
    /// level, key, screen or Space change the two are brought back into step
    /// (`syncGlass`). It's taken off screen before this window is, and put
    /// back after, so it is never on screen alone — bare glass with the
    /// panel's content missing — nor, for a frame, over the panel.
    let glassWindow = IslandGlassWindow()

    /// Gives the glass window its content: the island's tree drawing the
    /// material alone.
    func attachGlass(_ view: NSView) {
        glassWindow.contentView = view
        hasGlass = true
        syncGlass()
    }

    /// Whether `attachGlass` has given the glass window anything to draw.
    private(set) var hasGlass = false

    /// Brings the glass window into step with this one: the same frame,
    /// level and alpha, on screen just below it when this window is on
    /// screen, and off screen when it isn't.
    func syncGlass() {
        guard hasGlass else { return }
        if glassWindow.frame != frame { glassWindow.setFrame(frame, display: false) }
        if glassWindow.level != level { glassWindow.level = level }
        if glassWindow.alphaValue != alphaValue { glassWindow.alphaValue = alphaValue }
        if isVisible {
            if glassWindow.parent !== self {
                glassWindow.parent?.removeChildWindow(glassWindow)
                // Ordered in just below this window, and kept there.
                addChildWindow(glassWindow, ordered: .below)
            } else {
                // Already attached: assert the order anyway, in case anything
                // on the way (a Space switch, the window server) moved it.
                glassWindow.order(.below, relativeTo: windowNumber)
            }
        } else {
            hideGlass()
        }
    }

    /// Takes the glass window off screen — before this one goes, so the glass
    /// is never left showing on its own.
    private func hideGlass() {
        if glassWindow.parent != nil { glassWindow.parent?.removeChildWindow(glassWindow) }
        if glassWindow.isVisible { glassWindow.orderOut(nil) }
    }

    override func orderFrontRegardless() {
        super.orderFrontRegardless()
        syncGlass()
    }

    override func orderFront(_ sender: Any?) {
        super.orderFront(sender)
        syncGlass()
    }

    override func orderBack(_ sender: Any?) {
        super.orderBack(sender)
        syncGlass()
    }

    override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
        if place == .out { hideGlass() }
        super.order(place, relativeTo: otherWin)
        syncGlass()
    }

    override func orderOut(_ sender: Any?) {
        hideGlass()
        super.orderOut(sender)
        syncGlass()
    }

    override func setIsVisible(_ flag: Bool) {
        if !flag { hideGlass() }
        super.setIsVisible(flag)
        syncGlass()
    }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        super.makeKeyAndOrderFront(sender)
        syncGlass()
    }

    override func becomeKey() {
        super.becomeKey()
        syncGlass()
    }

    override func resignKey() {
        super.resignKey()
        syncGlass()
    }

    override var alphaValue: CGFloat {
        // Fading out, the glass goes first; fading in, it follows.
        willSet { if hasGlass, newValue < alphaValue { glassWindow.alphaValue = newValue } }
        didSet { syncGlass() }
    }

    override var level: NSWindow.Level {
        didSet { syncGlass() }
    }

    /// The window server's and AppKit's own changes: a Space switch, a
    /// screen change, the window covered or uncovered, a resize or move
    /// that didn't come through `setFrame`.
    private func observeWindowChanges() {
        let center = NotificationCenter.default
        for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
            windowObservers.append(center.addObserver(forName: name, object: self, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.holdPlacement() }
            })
        }
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didChangeScreenNotification] {
            windowObservers.append(center.addObserver(forName: name, object: self, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.syncGlass() }
            })
        }
        windowObservers.append(center.addObserver(forName: NSWindow.didResizeNotification, object: glassWindow, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncGlass() }
        })
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncGlass() }
        }
    }

    private var windowObservers: [NSObjectProtocol] = []
    private var spaceObserver: NSObjectProtocol?

    deinit {
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        if let spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver)
        }
    }

    // Isle's controls are hover/click driven and it should never pull focus
    // out of the frontmost app, so key status is refused — except while a
    // field on the Claude face is taking a reply. Then, and only then, the
    // panel can become key; `.nonactivatingPanel` means it does so without
    // activating Isle, so the frontmost app stays frontmost and gets its keys
    // back the moment composing ends (see NotchWindowController). Main status
    // is never wanted.
    var allowsKey = false
    override var canBecomeKey: Bool { allowsKey }
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

/// The window the island's glass is drawn in (see `NotchWindow.glassWindow`):
/// borderless, transparent, click-through, and never key or main, so its
/// glass keeps the look it has at rest whatever the panel over it does.
final class IslandGlassWindow: NSPanel {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isMovable = false
        hidesOnDeactivate = false
        isExcludedFromWindowsMenu = true
        // Ordered with the panel, instantly, as the panel is (see there).
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
