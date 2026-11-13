//
//  IslandBleed+AppKit.swift
//
//  Where the bleed (`IslandBleed`) is drawn and what moves it.
//
//  The neck is between the camera housing and an island that's off it: in
//  the gap, which is no window's. So it has one of its own,
//  `NotchBleedWindow`, over the top centre of the screen: borderless,
//  transparent, click-through, never key or main, at the island's level
//  and ordered just under the island's windows, on screen only while there
//  is a neck to draw. The neck is one `CAShapeLayer` path, set with no
//  implicit animation, so the window server draws it where the island is.
//
//  `IslandBleedDriver` follows the island: every time its window moves
//  (each drag event of a carry, each step of a glide home, which
//  `NotchWindow.didSlide` reports), it reads where the island is drawn,
//  works out the neck and the black on the island, and hands the first to
//  the layer and the second to the island's fill (`IslandBleedModel`).
//  Nothing runs between moves. `IslandCarry` starts it when the island is
//  taken off the notch or picked up, and ends it: once home, where there's
//  nothing left to draw, or when the island is put down elsewhere, when
//  the neck drains back into the notch on Core Animation's own spring (the
//  close spring, `IslandMotion.collapseHeight`) and the black on the island
//  fades with it.
//

import AppKit
import SwiftUI

/// The neck's window: see the file's comment.
final class NotchBleedWindow: NSWindow {
    let neck = CAShapeLayer()

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isMovable = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none

        // A layer-hosting view, y down like `IslandBleed`'s space.
        let root = CALayer()
        root.isGeometryFlipped = true
        let view = NSView()
        view.layer = root
        view.wantsLayer = true
        neck.fillColor = CGColor(gray: 0, alpha: 1)
        neck.actions = ["path": NSNull(), "position": NSNull(), "bounds": NSNull(), "contentsScale": NSNull()]
        root.addSublayer(neck)
        contentView = view
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class IslandBleedDriver {
    private let presentation: IslandPresentation
    private unowned let island: NotchWindow

    /// The island as drawn, in screen coordinates; nil before a layout.
    var drawnRect: () -> CGRect? = { nil }
    var reduceMotion: () -> Bool = { false }

    /// The screen's frame and its camera housing; nil on a display with
    /// none. The island's metrics, as Isle runs.
    lazy var stage: () -> (screen: CGRect, housing: CGSize)? = { [weak self] in
        guard let metrics = self?.presentation.metrics, metrics.hasPhysicalNotch else { return nil }
        return (metrics.screen.frame, metrics.notchSize)
    }

    private var window: NotchBleedWindow?

    /// Between `engage` and `release`: following the island.
    private(set) var engaged = false

    /// The closeness the island was picked up at, when that was already
    /// within reach (put down near the notch and picked up again): the
    /// bleed starts from nothing there and comes in as the island is
    /// brought closer, rather than appearing whole in the hand. 0 for an
    /// island taken off the notch, which starts merged.
    private var floor: CGFloat = 0

    /// What's drawn now, for the drain.
    private var drawn: (outline: IslandBleed.Outline, bridge: IslandBleed.Bridge, offset: CGPoint)?

    /// Counts drains, so a finished one only clears up if it's still the
    /// latest thing that happened.
    private var drainID = 0

    init(presentation: IslandPresentation, island: NotchWindow) {
        self.presentation = presentation
        self.island = island
    }

    /// The window the neck is drawn in, once there has been a neck.
    var bleedWindow: NSWindow? { window }

    /// Told when the neck's window is made (it is made the first time
    /// there's a neck to draw), for whatever watches the island's windows.
    var onWindowMade: ((NSWindow) -> Void)?

    // MARK: - Following

    /// Starts following the island: taken off the notch (`fromNotch`), or
    /// picked up, or sent home from where it was.
    func engage(fromNotch: Bool) {
        drainID &+= 1
        engaged = true
        floor = 0
        if !fromNotch, let scene = scene() {
            floor = IslandBleed.closeness(distance: IslandBleed.distance(scene))
        }
        follow()
    }

    /// The island moved (or changed): draw the bleed for where it is now.
    func follow() {
        guard engaged else { return }
        guard let stage = stage(), let scene = scene(on: stage) else {
            clearNeck()
            publish(nil)
            return
        }
        var c = IslandBleed.closeness(distance: IslandBleed.distance(scene))
        if floor > 0 {
            if c <= 0 {
                floor = 0
            } else {
                c = floor >= 1 ? 0 : max(0, (c - floor) / (1 - floor))
            }
        }
        let d = IslandBleed.distance(closeness: c)
        let bridge = IslandBleed.bridge(scene, distance: d)
        if let bridge {
            draw(bridge, on: stage)
        } else {
            clearNeck()
        }
        publish(IslandBleed.stain(scene, distance: d, bridge: bridge))
    }

    /// Stops following. `drain`: the island was put down away from the
    /// notch, and what's drawn runs back into the notch on the close
    /// spring; otherwise it goes at once (home, where nothing is left, or
    /// the island re-placed or hidden).
    func release(drain: Bool) {
        let wasEngaged = engaged
        engaged = false
        floor = 0
        drainID &+= 1
        let id = drainID
        guard wasEngaged, drain, !reduceMotion() else {
            hide()
            return
        }
        if let drawn, let window, window.isVisible {
            let to = drawn.outline.retracted(
                housingFoot: drawn.bridge.housingFoot,
                islandTop: drawn.bridge.islandTop,
                notchCentre: drawn.bridge.notchCentre,
                islandCentre: drawn.bridge.islandCentre
            ).path(offset: drawn.offset)
            let neck = window.neck
            let spring = CASpringAnimation(keyPath: "path")
            spring.mass = 1
            spring.stiffness = IslandMotion.collapseHeight.stiffness
            spring.damping = IslandMotion.collapseHeight.damping
            spring.fromValue = neck.presentation()?.path ?? neck.path
            spring.toValue = to
            spring.duration = spring.settlingDuration
            CATransaction.begin()
            CATransaction.setCompletionBlock { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.drainID == id else { return }
                    self.hideWindow()
                }
            }
            neck.path = to
            neck.add(spring, forKey: "drain")
            CATransaction.commit()
            self.drawn = nil
        } else {
            hideWindow()
        }
        if presentation.bleed.stain != nil {
            withAnimation(.notchClose) {
                presentation.bleed.stain?.opacity = 0
            } completion: { [weak self] in
                guard let self, self.drainID == id else { return }
                self.presentation.bleed.stain = nil
            }
        }
    }

    // MARK: - Reading the island

    private func scene() -> IslandBleed.Scene? {
        guard let stage = stage() else { return nil }
        return scene(on: stage)
    }

    /// The island in `IslandBleed`'s space: y down from the screen's top
    /// edge, x from its centre line (the housing's).
    private func scene(on stage: (screen: CGRect, housing: CGSize)) -> IslandBleed.Scene? {
        guard let drawn = drawnRect(), drawn.width > 0, drawn.height > 0 else { return nil }
        let rect = CGRect(
            x: drawn.minX - stage.screen.midX,
            y: stage.screen.maxY - drawn.maxY,
            width: drawn.width,
            height: drawn.height
        )
        // The straight part of the top edge: none of a capsule's ends, and
        // on an open card the roundest of the modes' corners (Prism's), so
        // the neck never lands on a curve. On the notch the top is flat.
        let crown: CGFloat
        if !presentation.placement.isFloating {
            crown = 0
        } else if presentation.state.isExpanded {
            crown = max(IslandFloat.prismCrownRadius, IslandFloat.cornerRadius)
        } else {
            crown = drawn.height / 2
        }
        return IslandBleed.Scene(housing: stage.housing, island: rect, crown: crown)
    }

    // MARK: - Drawing

    /// The window's size for a housing: room for the neck's feet as far
    /// out to the side, and as far down, as it can reach.
    private static func frame(for stage: (screen: CGRect, housing: CGSize)) -> NSRect {
        let half = stage.housing.width / 2 + IslandBleed.reach + stage.housing.width / 2 + 8
        let height = stage.housing.height + IslandBleed.reach + 2 * IslandBleed.tuck + 4
        return NSRect(x: (stage.screen.midX - half).rounded(), y: stage.screen.maxY - height, width: 2 * half, height: height)
    }

    private func draw(_ bridge: IslandBleed.Bridge, on stage: (screen: CGRect, housing: CGSize)) {
        let window: NotchBleedWindow
        if let made = self.window {
            window = made
        } else {
            window = NotchBleedWindow()
            self.window = window
            onWindowMade?(window)
        }
        let frame = Self.frame(for: stage)
        if window.frame != frame { window.setFrame(frame, display: false) }
        if window.level != island.level { window.level = island.level }
        if window.collectionBehavior != island.collectionBehavior { window.collectionBehavior = island.collectionBehavior }
        // The layer's space: the window's, y down; the scene's x is from
        // the screen's centre line.
        let offset = CGPoint(x: stage.screen.midX - frame.minX, y: 0)
        let outline = IslandBleed.outline(bridge)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let neck = window.neck
        neck.removeAnimation(forKey: "drain")
        neck.frame = CGRect(origin: .zero, size: frame.size)
        neck.contentsScale = window.backingScaleFactor
        neck.path = outline.path(offset: offset)
        CATransaction.commit()
        drawn = (outline, bridge, offset)
        if !window.isVisible {
            // Under the island's windows: the neck's foot runs on under its
            // top edge, never over what's on it.
            let glass = island.glassWindow
            window.order(.below, relativeTo: glass.isVisible ? glass.windowNumber : island.windowNumber)
        }
    }

    private func clearNeck() {
        drawn = nil
        guard let window, window.neck.path != nil else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        window.neck.removeAnimation(forKey: "drain")
        window.neck.path = nil
        CATransaction.commit()
    }

    private func publish(_ stain: IslandBleed.Stain?) {
        // Each drag event's own value, unanimated: where the island is.
        guard presentation.bleed.stain != stain else { return }
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { presentation.bleed.stain = stain }
    }

    private func hideWindow() {
        clearNeck()
        if let window, window.isVisible { window.orderOut(nil) }
    }

    private func hide() {
        hideWindow()
        if presentation.bleed.stain != nil { presentation.bleed.stain = nil }
    }
}
