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
        return expanded.union(collapsed)
    }
}
