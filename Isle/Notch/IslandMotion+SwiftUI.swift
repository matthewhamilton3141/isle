//
//  IslandMotion+SwiftUI.swift
//
//  The island's motions as SwiftUI sees them: the springs as `Animation`s,
//  the transaction flag that gives the collapse its per-channel timing, and
//  the fill that carries the proximity swell. The numbers are in
//  IslandMotion.swift.
//
//  Nothing here runs on a clock. The collapse is three springs SwiftUI runs
//  for the length of the close and no longer; the swell is a spring started
//  by a stepped reading that changes a handful of times per approach (see
//  `ProximityGate`) and is applied as a render transform, so the island's
//  layout and hit rect never see it.
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
/// that make up the outline can each swap in their own spring for it. Set
/// only by NotchRootView's state transaction; every other animated change —
/// a toast widening the pill, a face growing the panel — passes through
/// untouched.
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
/// move to the new face's (Agenda is taller than Music), and only the
/// height frame reads this flag, so it alone gets a spring.
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

extension View {
    /// During a collapse, animate this modifier (and what it wraps, unless a
    /// deeper channel says otherwise) on `channel`'s spring.
    func islandCollapseChannel(_ channel: IslandCollapseChannel) -> some View {
        transaction { t in
            guard t.isIslandCollapse, t.animation != nil else { return }
            t.animation = channel.animation
        }
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
