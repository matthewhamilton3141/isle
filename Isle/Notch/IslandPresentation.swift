//
//  IslandPresentation.swift
//
//  The half of the notch's state that belongs to *one screen*.
//
//  `NotchViewModel` stays a singleton and owns everything the island shows —
//  the track, the Claude status, the power toast — because every island shows
//  exactly the same thing, and the subsystems behind that content (the audio
//  tap, the MediaRemote adapter, the Claude watcher) are single instances that
//  must not be duplicated per display.
//
//  What genuinely differs between screens is the presentation: which island
//  the pointer is on, and the geometry of the cutout it's drawn against. That,
//  and only that, lives here — one instance per island.
//
//  Note what is deliberately *not* here. `alertDismissed` and `alertWasHovered`
//  stay on the view model: they describe the alert, not the window. Dismissing
//  an approval prompt on the external display has dismissed it, full stop —
//  it should not still be sitting open on the laptop panel behind you.
//

import AppKit
import Combine

@MainActor
final class IslandPresentation: ObservableObject {
    /// Pointer is over this island's hit area. Set only through `setHovering`,
    /// never directly, so the collapse-commit gate can't be bypassed.
    @Published private(set) var isHovering: Bool = false

    /// Geometry of the camera housing (or the fallback pill) on the screen this
    /// island is drawn on. Published because the views size themselves from it:
    /// moving between a notched and a non-notched display changes the shape,
    /// not just the window frame.
    @Published var metrics: NotchMetrics?

    /// While true, pointer-driven expansion is refused. Set the instant the
    /// notch starts collapsing and cleared once the close animation has
    /// settled — see `setHovering`.
    private var collapseLocked = false

    /// How long re-expansion stays locked out after a collapse begins. Covers
    /// the close spring (`Animation.notchClose`, response 0.30) so the hover
    /// region has fully shrunk before hover can fire again.
    private static let collapseLockDuration: TimeInterval = 0.32

    /// The shared content. Unowned because the view model outlives every
    /// island: islands come and go with displays, it does not.
    private unowned let content: NotchViewModel

    init(content: NotchViewModel) {
        self.content = content
    }

    /// This island's visual state: its own hover crossed with the shared
    /// live-activity rule. A Claude alert opens every island at once; a hover
    /// opens only the one under the pointer.
    var state: NotchState {
        NotchStateResolver.resolve(
            isHovering: isHovering,
            hasLiveActivity: content.autoExpandsForActivity
        )
    }

    /// The only way `isHovering` changes. Opening is immediate; closing commits
    /// to the collapse and locks re-expansion out for the length of the close
    /// animation. That's what stops the panel flapping back open under a
    /// pointer that's on its way off the island — a stray hover-in during the
    /// shrink is ignored until the notch has fully settled. A live-activity
    /// interrupt is unaffected: it opens through `hasLiveActivity`, not hover.
    func setHovering(_ hovering: Bool) {
        if hovering {
            // Remember that this alert's panel was actually visited, so hovering
            // back off it can count as a dismiss.
            content.noteAlertVisited()
            guard !collapseLocked, !isHovering else { return }
            isHovering = true
        } else {
            guard isHovering else { return }
            isHovering = false
            content.noteHoveredAway()
            collapseLocked = true
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.collapseLockDuration) { [weak self] in
                self?.collapseLocked = false
            }
        }
    }

    /// Retract the current alert's panel now (a click on it). No-op unless an
    /// alert is live and the user allows dismissing; the glyph stays until the
    /// alert resolves.
    func dismissAlert() {
        guard content.dismissAlert() else { return }
        // The pointer is still over the (large) panel at click time, so drop the
        // hover explicitly or it'd stay open as a hover-expand. The hover region
        // shrinks to the collapsed island, which the pointer is now outside of.
        isHovering = false
    }
}
