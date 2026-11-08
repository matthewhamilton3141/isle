//
//  IslandMotion+SwiftUI.swift
//
//  The island's motions as SwiftUI sees them: the springs as `Animation`s,
//  the transaction flag that gives the collapse its per-channel timing, and
//  the fill that carries the proximity swell. The numbers are in
//  IslandMotion.swift.
//
//  Nothing here runs on a clock. The collapse is three springs SwiftUI runs
//  for the length of the close and no longer — the outline's width and
//  height as `IslandOutlineLength`s, so for those ~0.35s the outline is laid
//  out at each in-between size; every other size change stays a plain frame
//  change, laid out once and animated by SwiftUI. The swell is a spring
//  started by a stepped reading that changes a handful of times per approach
//  (see `ProximityGate`) and is applied as a render transform, so the
//  island's layout and hit rect never see it.
//

import SwiftUI

extension Animation {
    init(_ spring: IslandMotion.Spring) {
        self = .spring(response: spring.response, dampingFraction: spring.dampingFraction, blendDuration: 0)
    }

    /// Reduce Motion's close: a plain quick ease, nothing shaped, nothing
    /// past the target.
    static var notchCloseReduced: Animation {
        .easeOut(duration: IslandMotion.reducedCloseDuration)
    }

    static var islandSwell: Animation { Animation(IslandMotion.swell) }
}

// MARK: - The collapse's channels

/// Marks the transaction of an open-to-collapsed change, so the modifiers
/// that make up the outline can each swap in their own spring for it (see
/// `islandCollapseChannel`). Set only by NotchRootView's state transaction,
/// and never with Reduce Motion; every other animated change — a toast
/// widening the pill, a face growing the panel — animates as it did before
/// the channels existed.
private struct IslandCollapseKey: TransactionKey {
    static let defaultValue = false
}

extension Transaction {
    var isIslandCollapse: Bool {
        get { self[IslandCollapseKey.self] }
        set { self[IslandCollapseKey.self] = newValue }
    }
}

/// Marks a face change made inside an otherwise untimed transaction — a
/// swipe landing, which swaps the face and re-bases the pager's offset in
/// one frame so nothing on screen jumps. The panel's height still has to
/// move to the new face's (Agenda is taller than Music): NotchRootView gives
/// the flagged transaction the resize spring on the notch's outermost
/// modifier, and takes it away again on the content inside, so only the
/// outline moves.
private struct PanelResizeKey: TransactionKey {
    static let defaultValue = false
}

extension Transaction {
    var isPanelResize: Bool {
        get { self[PanelResizeKey.self] }
        set { self[PanelResizeKey.self] = newValue }
    }
}

enum IslandCollapseChannel {
    case width, height, corners

    var animation: Animation {
        switch self {
        case .width: Animation(IslandMotion.collapseWidth)
        case .height: Animation(IslandMotion.collapseHeight)
        case .corners: Animation(IslandMotion.collapseCorners)
        }
    }
}

/// The animation a transaction carried before the first collapse channel
/// replaced it, so whatever a channel wraps can be given it back (see
/// `IslandOutlineLength`). Stashed once, by the outermost channel.
private struct CollapseStashKey: TransactionKey {
    static let defaultValue: Animation?? = nil
}

extension Transaction {
    fileprivate var collapseStash: Animation?? {
        get { self[CollapseStashKey.self] }
        set { self[CollapseStashKey.self] = newValue }
    }

    /// The animation from before any collapse channel touched this
    /// transaction.
    fileprivate var animationBeforeChannels: Animation? {
        collapseStash ?? animation
    }
}

extension View {
    /// During a collapse, animate what this wraps on `channel`'s spring.
    ///
    /// Outside a collapse: a channel over a render value (the corners, the
    /// shift) passes the transaction through. A channel over an
    /// `IslandOutlineLength` (`snaps: true`) takes the animation away
    /// instead, so that length goes to its new value at once and the size
    /// change animates the way any frame change does — by the layout's own
    /// geometry animation, on the transaction outside the notch. That keeps
    /// the open, a face growing the panel and a toast widening the pill
    /// exactly as they were.
    func islandCollapseChannel(_ channel: IslandCollapseChannel, snaps: Bool = false) -> some View {
        transaction { t in
            let original = t.animationBeforeChannels
            if t.collapseStash == nil { t.collapseStash = .some(original) }
            if t.isIslandCollapse, original != nil {
                t.animation = channel.animation
            } else if snaps {
                t.animation = nil
            } else {
                t.animation = original
            }
        }
    }
}

/// One axis of the island's outline frame, as an animatable value.
///
/// Why this and not `.frame(width:)`: a frame's size change is animated by
/// SwiftUI's layout as one geometry — width and height together, on
/// whichever transaction reaches the layout first — so per-axis
/// transactions around two `.frame`s still drew them in lockstep (measured:
/// width and height reached 90% of the collapse in the same frame). An
/// `Animatable` modifier is interpolated on its own, with the animation of
/// the transaction its input changed in, and lays out the in-between
/// lengths itself; two of them, each under its own channel, really do run
/// on two springs.
///
/// What it wraps gets the transaction's original animation back (see
/// `islandCollapseChannel`), so the content's own transitions run as they
/// would without the channels.
struct IslandOutlineLength: ViewModifier, Animatable {
    var axis: Axis
    var length: CGFloat

    var animatableData: CGFloat {
        get { length }
        set { length = newValue }
    }

    func body(content: Content) -> some View {
        content
            .transaction { t in
                if let original = t.collapseStash { t.animation = original }
            }
            .frame(
                width: axis == .horizontal ? length : nil,
                height: axis == .vertical ? length : nil
            )
    }
}

// MARK: - The swell

/// One island's proximity reading, published on its own so a change
/// re-evaluates only the fill below — not the root view and the faces, which
/// observe `IslandPresentation` itself.
@MainActor
final class IslandProximityModel: ObservableObject {
    @Published var reading: IslandProximity = .rest
}

/// The island's black fill, swollen and leaning by the proximity reading.
///
/// It's the only fill: drawn behind the clipped content, outside the clip,
/// so it can reach a few points past the outline the content and the hit
/// rect use. The growth is a `scaleEffect` anchored on the top edge — a
/// render transform over the same path the clip uses, so the top stays
/// flush with the screen, the taper and corners match the clip exactly, and
/// a change costs no layout.
struct IslandFill: View {
    @ObservedObject var proximity: IslandProximityModel
    var shape: NotchShape
    /// The outline's settled size, which the swell is measured against.
    var size: CGSize
    /// Collapsed and allowed to swell. False takes the swell back to rest.
    var active: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let reading = active && !reduceMotion ? proximity.reading : .rest
        let swell = reading.swell
        shape
            .fill(.black)
            .animation(.islandSwell) { fill in
                fill
                    .scaleEffect(
                        x: size.width > 0 ? 1 + 2 * swell.width / size.width : 1,
                        y: size.height > 0 ? 1 + swell.height / size.height : 1,
                        anchor: .top
                    )
                    .offset(x: reading.leanOffset)
            }
    }
}
