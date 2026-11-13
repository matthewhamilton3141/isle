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

    /// Where the controller put this window — `NotchMetrics.maximumFrame`,
    /// or that size wherever an island off its notch has been left
    /// (`NotchMetrics.frame(for:)`) — set by `place(_:)` and `slide(to:)`
    /// and nothing else. The window is never sized by its content or moved
    /// by AppKit: every frame change lands here, and a resize or move that
    /// went around `setFrame` is put back.
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
        didSlide?()
    }

    /// Told after every `place` and `slide`: the island's window moved.
    /// The notch's bleed follows it (`IslandBleedDriver`).
    var didSlide: (() -> Void)?

    /// Moves the window to `frame` while the island is carried or glides
    /// home: `place`, without the window server round trips of bringing the
    /// glass back into step in every other respect, which a move changes
    /// nothing about. It runs on every drag event.
    ///
    /// The glass window is this one's child, so AppKit moves it along in
    /// the same call; it's only set here if that left it somewhere else.
    func slide(to frame: NSRect) {
        placedFrame = frame
        super.setFrame(frame, display: false)
        if hasGlass, glassWindow.frame != frame {
            glassWindow.setFrame(frame, display: false)
        }
        didSlide?()
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
            glassWindow.assertLens()
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

    /// Offered the primary button's down, dragged and up events before the
    /// views see them, the same way: this is where a press held on the
    /// island is told from a click (see `IslandHold`, `IslandCarry`), and
    /// where the drags of an island being carried stop short of the views.
    var pressInterceptor: (@MainActor (NSEvent) -> IslandHold.Verdict)?

    /// Where the views last saw the pointer during the press under way, in
    /// window coordinates: the press itself, or the last drag passed on.
    private var lastPressLocation: NSPoint?

    /// Told of each press the views are about to get, with where it went
    /// down in window coordinates. What it returns runs once the views have
    /// had that press's release — only if they had all of it, so a press
    /// the island took for a hold or a carry runs nothing. This is how a
    /// click outside a field that has the keys lets the field go
    /// (`watchClicksOutsideComposeFields`), after whatever the click was
    /// on has done its job.
    var pressObserver: (@MainActor (NSPoint) -> (@MainActor () -> Void)?)?

    /// What `pressObserver` asked to run when the press under way is let go.
    private var afterRelease: (@MainActor () -> Void)?

    override func sendEvent(_ event: NSEvent) {
        var released: (@MainActor () -> Void)?
        switch event.type {
        case .scrollWheel:
            if let scrollInterceptor, scrollInterceptor(event) { return }
        case .leftMouseDown, .leftMouseDragged, .leftMouseUp:
            switch pressInterceptor?(event) ?? .pass {
            case .pass:
                lastPressLocation = event.type == .leftMouseUp ? nil : event.locationInWindow
                if event.type == .leftMouseDown {
                    afterRelease = pressObserver?(event.locationInWindow)
                } else if event.type == .leftMouseUp {
                    released = afterRelease
                    afterRelease = nil
                }
            case .swallow:
                afterRelease = nil
                return
            case .cancelPress:
                let release = cancellingRelease(for: event)
                lastPressLocation = nil
                afterRelease = nil
                if let release { super.sendEvent(release) }
                return
            }
        default:
            break
        }
        super.sendEvent(event)
        released?()
    }

    /// The views a click may land in without letting a field go: each
    /// `ComposeFieldRegion` on the island adds itself while it's in this
    /// window. Weak, so a field that's gone is gone from here too.
    let composeFields = NSHashTable<NSView>.weakObjects()

    /// Whether `point`, in window coordinates, is in a field drawn in this
    /// window — its text, its Send, or the capsule round them.
    func composeFieldContains(_ point: NSPoint) -> Bool {
        composeFields.allObjects.contains { view in
            view.window === self && !view.isHiddenOrHasHiddenAncestor
                && view.convert(view.bounds, to: nil).contains(point)
        }
    }

    /// The button-up the views get in place of `event` when the press under
    /// it wasn't a click: one that lands far outside the window, so the
    /// control that took the press sees the pointer let go somewhere else
    /// and doesn't fire. The views must still get *a* release — they saw
    /// the press, and would otherwise go on thinking the button is down.
    ///
    /// Far away straight down, at the x the views last saw: the island's
    /// sliders read the pointer's x, and a release that moved sideways could
    /// be read as one last drag.
    private func cancellingRelease(for event: NSEvent) -> NSEvent? {
        NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: NSPoint(x: (lastPressLocation ?? event.locationInWindow).x, y: -Self.farAway),
            modifierFlags: event.modifierFlags,
            timestamp: event.timestamp,
            windowNumber: windowNumber,
            context: nil,
            eventNumber: event.eventNumber,
            clickCount: 0,
            pressure: 0
        )
    }

    private static let farAway: CGFloat = 100_000

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
///
/// That look is the frosted one, except in Prism, which wants the lens
/// Liquid Glass keeps for key windows (`lensed`).
///
/// A plain window, and it must stay one. For a window whose style mask has
/// `.nonactivatingPanel`, `NSWindow.becomeKey()` itself asks the window
/// server for the key focus (AppKit's `_stealKeyFocusWithOptions:`), which
/// is how such a panel is typed into while another app stays frontmost.
/// The lens is got by calling `becomeKey()` directly, so with that style
/// this window took the keyboard from whatever the user was typing in —
/// nothing in Isle got the keys either, so every press was an alert beep —
/// though it can't become key, takes no events and is never ordered key.
/// That was 1.2.0. Without the style, `becomeKey()` changes the window's
/// own state and appearance and asks the window server for nothing.
final class IslandGlassWindow: NSWindow {
    /// Whether this window's glass is drawn as a lens: what's behind it
    /// nearly sharp, bent at the edges. Liquid Glass does that for a
    /// window with the key appearance, which a window takes on in
    /// `becomeKey()`, so this tells the window it is key without it ever
    /// being so: it still can't become key, takes no events, and the
    /// keyboard stays where it was (see above for what that depends on).
    ///
    /// Three things take the appearance away again, and each is answered:
    /// - AppKit's own `resignKey()`, sent when the app deactivates or
    ///   another of Isle's windows takes the keys: ignored while lensed.
    /// - The window server, which notices a window dressed as key in an
    ///   app that hasn't the keyboard and asks for the appearance back —
    ///   a few tens of milliseconds after it's taken, and again whenever
    ///   the keyboard moves between apps. AppKit gives it up without a
    ///   word to the window (`_handleResignKeyAppearanceEvent`), so that
    ///   is refused while lensed (`handleResignKeyAppearanceEvent`).
    /// - Ordering the window out. It's asked for again once it is back
    ///   (`assertLens`, from `NotchWindow.syncGlass`).
    var lensed = false {
        didSet {
            guard lensed != oldValue else { return }
            if lensed {
                assertLens()
            } else {
                lensAsk &+= 1
                super.resignKey()
            }
        }
    }

    /// Puts the lens up, or back after something that may have dropped it:
    /// called whenever the two windows are brought into step.
    ///
    /// Never at once. The key appearance doesn't hold in a window that is
    /// off screen, nor when taken in the turn of the run loop that orders
    /// the window in. So it's taken on the next turn, with the window on
    /// screen — a window still off screen then is left for the `syncGlass`
    /// that follows its ordering in — and taken again a little later, in
    /// case the first was too soon after all. However often this is called
    /// in a turn, that happens once.
    func assertLens() {
        guard lensed else { return }
        lensAsk &+= 1
        let ask = lensAsk
        DispatchQueue.main.async { [weak self] in self?.raiseLens(ask) }
        for delay in Self.lensRetries {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.raiseLens(ask) }
        }
    }

    /// When the lens is asked for again after `assertLens`, in seconds.
    private static let lensRetries: [TimeInterval] = [0.1, 0.5]

    /// Counts the calls to `assertLens`, so only the latest one's work runs.
    private var lensAsk = 0

    /// Given up and taken, not just taken: a window that believes it has
    /// the key appearance doesn't ask the window server for it, and what
    /// it believes can be out of date (the window server drops it without
    /// a word when the window goes off screen). The two in one turn change
    /// nothing on screen when the lens is already up.
    private func raiseLens(_ ask: Int) {
        guard ask == lensAsk, lensed, isVisible else { return }
        super.resignKey()
        super.becomeKey()
    }

    override func orderOut(_ sender: Any?) {
        // Off screen there is no lens, and AppKit is told so.
        if lensed { super.resignKey() }
        super.orderOut(sender)
    }

    override func resignKey() {
        guard !lensed else {
            // Nothing was given up; asked for again all the same, in case
            // AppKit took the appearance on its way here.
            assertLens()
            return
        }
        super.resignKey()
    }

    /// The window server asking for the key appearance back (see `lensed`).
    /// This is AppKit's own handler for that, under its own name: private,
    /// so if a later macOS calls it something else this is never reached,
    /// and Prism's glass goes back to frosted the first time the keyboard
    /// changes hands. Nothing else depends on it.
    @objc(_handleResignKeyAppearanceEvent)
    func handleResignKeyAppearanceEvent() {
        guard !lensed else { return }
        // Not lensed: AppKit's own handling, whatever it is.
        let selector = #selector(handleResignKeyAppearanceEvent)
        guard NSWindow.instancesRespond(to: selector),
              let original = class_getMethodImplementation(NSWindow.self, selector) else { return }
        typealias Handler = @convention(c) (AnyObject, Selector) -> Void
        unsafeBitCast(original, to: Handler.self)(self, selector)
    }

    init() {
        super.init(
            contentRect: .zero,
            // Never `.nonactivatingPanel`: see the type's comment.
            styleMask: Self.style,
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isMovable = false
        // Never closed, only ordered out; and never let go of if it were.
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isExcludedFromWindowsMenu = true
        // Ordered with the panel, instantly, as the panel is (see there).
        animationBehavior = .none
    }

    /// Borderless and nothing else.
    static let style: NSWindow.StyleMask = [.borderless]

    override var styleMask: NSWindow.StyleMask {
        get { super.styleMask }
        // Whatever else is asked for, never the style that takes the keys.
        set { super.styleMask = newValue.subtracting(.nonactivatingPanel) }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
