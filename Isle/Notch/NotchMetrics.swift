//
//  NotchMetrics.swift
//
//  Physical geometry of the camera housing, plus the sizes Isle draws at
//  in each state. Everything the layout depends on lives here as a named
//  constant rather than sprinkled through the views — the spec calls for
//  the split-view widths and similar to stay tunable (see 3.1).
//

import AppKit

/// Measured properties of a screen's camera housing, if it has one.
struct NotchMetrics {
    /// Size of the physical notch cutout. On a screen with no notch this is
    /// the size of the fallback pill we draw in the same position instead.
    let notchSize: CGSize

    /// True when these numbers came from a real camera housing rather than
    /// the non-notched fallback. Views use this to decide whether to draw
    /// the top corners squared off (we're hugging a real cutout, so the top
    /// edge is flush with the bezel) or fully rounded (free-floating pill).
    let hasPhysicalNotch: Bool

    let screen: NSScreen

    // MARK: - Tunables

    /// Extra width Isle claims beyond the physical cutout when collapsed, so
    /// there's room for the equalizer on one side and the Claude glyph on the
    /// other without either sitting under the camera.
    ///
    /// Sized to the content rather than picked for looks: artwork thumbnail
    /// (18) or waveform (26), plus the root and row padding. Much below this
    /// and the split view's two elements start colliding.
    static let collapsedSideInset: CGFloat = 46

    /// Extra width added to the *right* of the collapsed notch when the Claude
    /// glyph shows alongside the music waveform, so the glyph gets its own room
    /// instead of the waveform shrinking and the row rebalancing. The shape is
    /// shifted right by half of this so the camera cutout stays put — see
    /// NotchRootView.collapsedShift.
    static let collapsedClaudeExtra: CGFloat = 22

    /// Size of the hover-expanded panel.
    ///
    /// Height accounts for the dead band under the camera housing: the top
    /// `notchSize.height` points of the expanded panel sit behind the physical
    /// cutout and can't show anything, so the usable content area is that much
    /// shorter than the panel. At 146 the usable content area is ~104pt; the
    /// 114pt artwork stays that size and takes up the shortfall by protruding
    /// up into the housing band, which is safe above the album (no hardware
    /// there — see the x-span note in ExpandedNotchView).
    static let expandedSize = CGSize(width: 520, height: 146)

    /// The tallest the panel ever gets, whichever face asks. Most faces keep
    /// `expandedSize`; a face with more to show reports the content height
    /// it wants (`NotchViewModel.faceContentHeight`) — the question face
    /// while an `AskUserQuestion` is live, the agenda always — and gets it up
    /// to this cap. One cap for every face that grows, so the window, which
    /// is sized to hold it from the start (see `maximumFrame`) and never
    /// resized while drawing, needs no per-face case.
    static let panelMaxHeight: CGFloat = 230

    /// How far either side of the open panel the pointer may stray before it
    /// closes — the side half of `NotchWindowController.stayOpenPad`. Here
    /// because the window has to reach it too (see `maximumFrame`).
    static let stayOpenSidePad: CGFloat = 16

    /// Panel height for a face whose content wants `contentHeight`, below a
    /// camera housing `bandHeight` tall. Never shorter than the standard
    /// panel, never taller than the cap. A face fits its content to
    /// `contentRoom` before it gets here — the question face shortens its
    /// descriptions so every option fits — so it is only ever cut by the cap
    /// past what that face can give up.
    static func panelHeight(contentHeight: CGFloat, bandHeight: CGFloat) -> CGFloat {
        min(panelMaxHeight, max(expandedSize.height, contentInsets(bandHeight: bandHeight) + ceil(contentHeight)))
    }

    /// The most a face's content can have: the cap, less the expanded
    /// content's insets.
    static func contentRoom(bandHeight: CGFloat) -> CGFloat {
        panelMaxHeight - contentInsets(bandHeight: bandHeight)
    }

    /// The expanded content's top inset (band + 2) and bottom inset (8), from
    /// NotchRootView.
    private static func contentInsets(bandHeight: CGFloat) -> CGFloat {
        bandHeight + 2 + 8
    }

    /// Fraction of the collapsed width given to music when both music and a
    /// Claude Code activity are live. See the split-view rule in spec 3.1 —
    /// kept here as a constant so a future "cycle instead of split" setting
    /// is a small change.
    static let splitMusicFraction: CGFloat = 0.5

    /// Fallback pill size for displays with no camera housing.
    static let fallbackNotchSize = CGSize(width: 180, height: 32)

    // MARK: - Derivation

    /// Reads the camera housing geometry from a screen.
    ///
    /// `safeAreaInsets.top` gives the housing height. The width isn't exposed
    /// directly, but `auxiliaryTopLeftArea` / `auxiliaryTopRightArea` describe
    /// the usable menu bar strips either side of it, so the gap between them
    /// is the cutout.
    init(screen: NSScreen) {
        self.screen = screen

        let topInset = screen.safeAreaInsets.top

        guard topInset > 0,
              let leftArea = screen.auxiliaryTopLeftArea,
              let rightArea = screen.auxiliaryTopRightArea
        else {
            self.notchSize = Self.fallbackNotchSize
            self.hasPhysicalNotch = false
            return
        }

        let width = screen.frame.width - leftArea.width - rightArea.width
        // A zero/negative gap means the auxiliary areas met in the middle,
        // i.e. no cutout after all — fall back rather than draw a 0pt window.
        guard width > 0 else {
            self.notchSize = Self.fallbackNotchSize
            self.hasPhysicalNotch = false
            return
        }

        self.notchSize = CGSize(width: width, height: topInset)
        self.hasPhysicalNotch = true
    }

    /// The screen Isle should live on. The spec scopes v1 to the built-in
    /// display only (non-goal: multi-display sync), so prefer the screen with
    /// a real notch and fall back to the main one.
    static func preferredScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
    }

    // MARK: - Frames

    /// Window frame for a given state, in global (bottom-left origin) coords.
    func windowFrame(for state: NotchState) -> NSRect {
        let size = windowSize(for: state)
        let screenFrame = screen.frame

        return NSRect(
            x: screenFrame.midX - size.width / 2,
            // Pin to the very top of the screen; the notch cutout is flush
            // with the physical top edge, and the panel hangs down from it.
            y: screenFrame.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }

    func windowSize(for state: NotchState) -> CGSize {
        switch state {
        case .collapsed:
            return collapsedSize(claudeAlongsideMusic: false)
        case .hoverExpanded, .liveActivityExpanded:
            return Self.expandedSize
        }
    }

    /// Collapsed size, optionally widened on the right to seat the Claude glyph
    /// next to the waveform without reflowing the music content.
    func collapsedSize(claudeAlongsideMusic: Bool) -> CGSize {
        let extra = claudeAlongsideMusic ? Self.collapsedClaudeExtra : 0
        return CGSize(
            width: notchSize.width + Self.collapsedSideInset * 2 + extra,
            height: notchSize.height
        )
    }

    /// The largest frame Isle ever occupies. The window is sized to this once
    /// and the *content* animates inside it — resizing an NSWindow every frame
    /// fights the compositor and produces visible tearing on the notch edge.
    var maximumFrame: NSRect {
        let expanded = windowFrame(for: .hoverExpanded)
        let collapsed = windowFrame(for: .collapsed)
        // Room for the tallest a face can grow the panel — every face that
        // grows shares the one cap. Transparent and click-through like the
        // rest of the window outside the drawn notch.
        let grown = NSRect(
            x: expanded.minX,
            y: screen.frame.maxY - Self.panelMaxHeight,
            width: expanded.width,
            height: Self.panelMaxHeight
        )
        // And the stay-open pad either side of the open panel. A hover reads
        // the pad off the global pointer monitor and doesn't need the window
        // there, but a file drag over the drop face does: AppKit hands a drag
        // to the window only inside its frame, so a pad outside it is a drag
        // leaving, and the drop face shut the moment a drag overshot the
        // panel's edge. Transparent and click-through like the rest.
        let pad = expanded.insetBy(dx: -Self.stayOpenSidePad, dy: 0)
        return expanded.union(collapsed).union(grown).union(pad)
    }
}
