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
    /// Pointer is over this island's hit area. Set only through `setHovering`
    /// and `dismissAlert`, never from outside, so the collapse-commit gate
    /// can't be bypassed. Every transition is reported to the content, which
    /// uses it to decide how hard the media poll works.
    @Published private(set) var isHovering: Bool = false {
        didSet {
            guard isHovering != oldValue else { return }
            // However it closed, a shortcut's hold went with it.
            if !isHovering, isHeldOpen { isHeldOpen = false }
            content.islandHoverChanged(isHovering)
        }
    }

    /// A keyboard shortcut opened this island and the pointer hasn't been to
    /// it since. The panel stays up wherever the pointer is — it was asked
    /// for from the keyboard, so a pointer that was never near it can't be
    /// "leaving" — until the shortcut again or a click in another app (no
    /// Esc: that's vim's and Claude Code's, and a hold has no timeout).
    /// The first time the pointer comes into the panel's stay-open zone the
    /// hold ends and it's an ordinary hover: leaving closes it, as always.
    /// Nothing here is timed.
    @Published private(set) var isHeldOpen = false

    /// Geometry of the camera housing (or the fallback pill) on the screen this
    /// island is drawn on. Published because the views size themselves from it:
    /// moving between a notched and a non-notched display changes the shape,
    /// not just the window frame.
    @Published var metrics: NotchMetrics?

    /// Whether this island hangs from its notch or has been taken off it
    /// (see `IslandPlacement`). The views read it for what to draw; the
    /// window controller moves the window to match.
    @Published var placement: IslandPlacement = .docked

    /// While true, pointer-driven expansion is refused. Set the instant the
    /// notch starts collapsing and cleared once the close animation has
    /// settled — see `setHovering`.
    private var collapseLocked = false

    /// How long re-expansion stays locked out after a collapse begins. Covers
    /// the close spring (`Animation.notchClose`, response 0.30) so the hover
    /// region has fully shrunk before hover can fire again. The shaped
    /// collapse keeps that spring for its height, the slowest of its channels
    /// (see `IslandMotion`), so this still covers it.
    private static let collapseLockDuration: TimeInterval = 0.32

    /// The shared content. Unowned because the view model outlives every
    /// island: islands come and go with displays, it does not.
    private unowned let content: NotchViewModel

    /// This island's swipe between faces. Per island because a gesture
    /// happens on one screen; the face it lands on is the shared choice.
    let pager = FacePager()

    /// A file drag is over this island, so it's open on the drop face. Set
    /// only through `beginDrop` / `endDrop`, from the window's own dragging
    /// callbacks (see `NotchWindowController`'s drop handling).
    @Published private(set) var isDropTarget = false

    /// The drop face's target under the pointer, lit. Nil between targets.
    @Published private(set) var litDropTarget: DropTarget?

    /// How near the pointer is, for the collapsed island's swell. A model of
    /// its own so a change redraws the fill and nothing else; fed only
    /// through `trackProximity` / `relaxProximity`.
    let proximity = IslandProximityModel()
    private var proximityGate = ProximityGate()

    /// Where the drop face drew each target, in the hosting view's top-left
    /// space, as the face reports it. Not published: only the drag reads it.
    var dropTargetFrames: [DropTarget: CGRect] = [:]

    init(content: NotchViewModel) {
        self.content = content
    }

    /// A file drag reached this island: open it on the drop face. Opens past
    /// the collapse lock, unlike a hover — a drag arriving is deliberate, and
    /// it can't wait for the close spring to settle the way a pointer can
    /// simply move again.
    func beginDrop() {
        guard !isDropTarget else { return }
        relaxProximity()
        isDropTarget = true
        if !isHovering { isHovering = true }
    }

    /// Lights the target under `point` (hosting view, top-left space), if
    /// releasing there would do something.
    func lightDropTarget(at point: CGPoint, where performable: (DropTarget) -> Bool) {
        let hit = dropTargetFrames.first { $0.value.contains(point) && performable($0.key) }?.key
        if litDropTarget != hit { litDropTarget = hit }
    }

    /// The drag left, dropped, or ended. `collapse` when it left: the panel
    /// goes with it, as a pointer leaving would take it. After a drop the
    /// pointer is still on the panel, so it stays open as a hover and the
    /// next real move decides.
    func endDrop(collapse: Bool) {
        guard isDropTarget else { return }
        isDropTarget = false
        litDropTarget = nil
        if collapse { setHovering(false) }
    }

    /// A keyboard shortcut opened the island: up now, and held (see
    /// `isHeldOpen`). Past the collapse lock, like a drop — the lock is
    /// there for a pointer still on its way out, and this isn't one.
    func openFromShortcut() {
        relaxProximity()
        if !isHovering { isHovering = true }
        isHeldOpen = true
    }

    /// The pointer is in the open panel's stay-open zone. Ends a shortcut's
    /// hold — from here it's a hover like any other — and counts as a visit
    /// to the alert on it, as a hover-in does.
    func notePointerInside() {
        guard isHeldOpen else { return }
        isHeldOpen = false
        content.noteAlertVisited()
    }

    /// A scroll event reached this island's window — which happens only with
    /// the pointer over the drawn notch, since everywhere else the window is
    /// transparent to the mouse. Returns whether it was a face swipe, which
    /// the views underneath shouldn't also see. A collapsed island pages
    /// nothing.
    func handleScroll(_ event: NSEvent) -> Bool {
        guard state.isExpanded, !isDropTarget else { return false }
        return pager.handle(event, content: content)
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
            relaxProximity()
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

    /// A pointer move on this island's screen: update the swell. `drawn` is
    /// the island's drawn rect in the same (screen) coordinates as `pointer`.
    ///
    /// Out of reach this is a rect test and an early return — see
    /// `ProximityGate`. The rest of the rule is asked only once the pointer is
    /// near: the island must be collapsed, settled (the collapse lock is the
    /// close spring's length, so a swell never lands on a collapse still in
    /// flight) and not taking a drag.
    func trackProximity(pointer: CGPoint, drawn: CGRect?) {
        let allowed = { [unowned self] in
            !self.collapseLocked && !self.isDropTarget && self.state == .collapsed
        }
        if let next = proximityGate.update(pointer: pointer, island: drawn, allowed: allowed()) {
            proximity.reading = next
        }
    }

    /// Take the swell back to rest: the pointer left this screen, crossed
    /// fast, or the island is about to open.
    func relaxProximity() {
        if let next = proximityGate.relax() {
            proximity.reading = next
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
