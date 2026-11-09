//
//  IslandMotion.swift
//
//  The numbers and the arithmetic behind the island's two small motions,
//  kept free of AppKit and SwiftUI so they compile on their own and can be
//  checked without an app (scripts/test-island-motion.sh):
//
//  - The proximity swell. A collapsed island grows by a few points, and leans
//    a point or so toward the pointer, as the pointer comes near it. Purely a
//    visual: the hover zones, the hit rect and the open timing all ignore it.
//  - The collapse. Closing, the panel's corners and width lead and its height
//    follows, so it draws back into the notch with a shape rather than
//    shrinking evenly: while the width is ahead the side walls taper in
//    toward the bottom, a genie that is gone again once both have arrived.
//    Width settles with a little overshoot; height never does (see
//    `Animation.notchClose` for why it mustn't).
//
//  The SwiftUI side — the springs as `Animation`s, the transaction plumbing
//  and the swell's fill — is in IslandMotion+SwiftUI.swift. There each
//  channel really runs on its own spring: the outline's width and height are
//  separate animatable lengths (`IslandOutlineLength`) and its radii the
//  shape's own animatable data, each given its spring by its own transaction.
//  (Two plain `.frame`s, which it used to be, are animated by the layout as
//  one size and drew width and height in lockstep.) Measured on the drawn
//  outline, offscreen: the width reaches 90% of its travel ~75ms before the
//  height, the corners first of all, and the height is monotonic.
//

import CoreGraphics
import Foundation

enum IslandMotion {
    // MARK: - Springs

    /// A spring as SwiftUI's `.spring(response:dampingFraction:)` defines it:
    /// unit mass, stiffness (2π / response)², damping 2ζ√stiffness. Stated
    /// here once so the `Animation` the app runs and the curve the renders and
    /// tests evaluate are the same spring.
    struct Spring: Equatable {
        var response: Double
        var dampingFraction: Double

        /// Progress from 0 toward 1 at time `t` (seconds) after starting from
        /// rest: the spring's step response. Underdamped springs pass 1 and
        /// come back; a critically damped one never does.
        func value(at t: Double) -> Double {
            guard t > 0 else { return 0 }
            let w0 = 2 * Double.pi / response
            let z = dampingFraction
            if z >= 1 {
                // Critical (and, harmlessly, anything stiffer).
                return 1 - exp(-w0 * t) * (1 + w0 * t)
            }
            let wd = w0 * (1 - z * z).squareRoot()
            let decay = exp(-z * w0 * t)
            return 1 - decay * (cos(wd * t) + (z * w0 / wd) * sin(wd * t))
        }
    }

    /// Closing: the width. Faster than the height and a little underdamped,
    /// so the panel pulls in from the sides first and settles a hair past
    /// its collapsed width — about 2% of the travel — before coming back.
    static let collapseWidth = Spring(response: 0.24, dampingFraction: 0.78)

    /// Closing: the height. Exactly `Animation.notchClose`: critically damped
    /// so the pill is never shorter than the camera housing, and the curve
    /// `IslandPresentation.collapseLockDuration` was measured against — so
    /// the hover lock still covers the whole close.
    static let collapseHeight = Spring(response: 0.30, dampingFraction: 1.0)

    /// Closing: the corner radii. Fastest of the three, so the outline takes
    /// the pill's corners while the panel is still large.
    static let collapseCorners = Spring(response: 0.18, dampingFraction: 1.0)

    /// The swell, in and out. Quick and nearly critical: it should read as
    /// the island noticing, not wobbling.
    static let swell = Spring(response: 0.24, dampingFraction: 0.86)

    /// Reduce Motion's close: plain and quick, no shape, no overshoot.
    static let reducedCloseDuration: Double = 0.18

    // MARK: - Genie taper

    /// How far the side walls may draw in toward the bottom while the width
    /// leads the height — the "genie" in the collapse. Points per side at
    /// full lead. 0 turns the taper off and leaves only the per-channel
    /// timing.
    static let maxTaper: CGFloat = 14

    /// How many points of taper a unit of lead buys, before `maxTaper` caps
    /// it. The lead (width's progress minus height's) peaks near 0.25 with
    /// the springs above, so this puts the peak taper around 9pt.
    static let taperGain: CGFloat = 36

    /// The taper of a shape `rect` big, collapsing from an `expanded` panel
    /// to a `collapsed` pill. Read off how much further the width has come
    /// than the height, so it is a transient by construction: zero when the
    /// panel is open (neither has moved), zero when the pill has settled
    /// (both have arrived), and zero for anything that moves both together.
    static func taper(rect: CGSize, expanded: CGSize, collapsed: CGSize) -> CGFloat {
        let spanW = expanded.width - collapsed.width
        let spanH = expanded.height - collapsed.height
        guard spanW > 1, spanH > 1 else { return 0 }
        let wp = min(max((expanded.width - rect.width) / spanW, 0), 1)
        let hp = min(max((expanded.height - rect.height) / spanH, 0), 1)
        let lead = max(0, wp - hp)
        // NotchShape also caps it so the bottom corners can't cross.
        return min(lead * taperGain, maxTaper)
    }

    // MARK: - Collapse model

    /// One frame of the collapse: the outline's size, its corners, and the
    /// taper that size implies.
    struct CollapseFrame: Equatable {
        var size: CGSize
        var topCornerRadius: CGFloat
        var bottomCornerRadius: CGFloat
        var taper: CGFloat
    }

    /// Settled corner radii, open and collapsed — the values NotchRootView
    /// draws with.
    static let openCorners = (top: CGFloat(12), bottom: CGFloat(22))
    static let collapsedCorners = (top: CGFloat(8), bottom: CGFloat(12))

    /// How long the collapse takes to come within 1% of its travel: the
    /// height spring's, which is the slowest channel. Matches
    /// `IslandPresentation.collapseLockDuration`.
    static let collapseDuration: Double = 0.32

    /// The collapse at `t` seconds, from an open panel `expanded` big to a
    /// pill `collapsed` big: what NotchRootView draws, frame for frame, for a
    /// collapse from a settled panel, since each channel runs its own spring
    /// from rest there. The tests evaluate it directly. (A collapse that
    /// interrupts an open still in flight starts from the open's motion
    /// rather than from rest, so it only approaches this.)
    static func collapse(at t: Double, from expanded: CGSize, to collapsed: CGSize) -> CollapseFrame {
        let w = CGFloat(collapseWidth.value(at: t))
        let h = CGFloat(collapseHeight.value(at: t))
        let c = CGFloat(collapseCorners.value(at: t))
        let size = CGSize(
            width: expanded.width + (collapsed.width - expanded.width) * w,
            height: expanded.height + (collapsed.height - expanded.height) * h
        )
        return CollapseFrame(
            size: size,
            topCornerRadius: openCorners.top + (collapsedCorners.top - openCorners.top) * c,
            bottomCornerRadius: openCorners.bottom + (collapsedCorners.bottom - openCorners.bottom) * c,
            taper: taper(rect: size, expanded: expanded, collapsed: collapsed)
        )
    }
}

// MARK: - Proximity

/// How near the pointer is to a collapsed island, in coarse steps.
///
/// Stepped on purpose: the pointer reports up to 120 moves a second, and the
/// island only needs to change when the answer does. Eight steps of swell
/// over the whole approach and three of lean either way is a handful of
/// updates per reach, each one smoothed by the swell spring, so the view
/// sees a few changes rather than a stream.
struct IslandProximity: Equatable {
    /// 0 (out of reach) through `IslandMotion.proximitySteps` (touching).
    var level: Int
    /// −`leanSteps` (pointer well to the left) through +`leanSteps`.
    var lean: Int

    static let rest = IslandProximity(level: 0, lean: 0)

    var isRest: Bool { level == 0 && lean == 0 }

    /// Extra width per side and extra height, in points. The top never moves.
    var swell: CGSize {
        let f = CGFloat(level) / CGFloat(IslandMotion.proximitySteps)
        return CGSize(width: IslandMotion.maxSwell.width * f, height: IslandMotion.maxSwell.height * f)
    }

    /// Horizontal shift toward the pointer, in points. Never more than the
    /// swell's side growth, so the swollen outline always covers the island's
    /// own on both sides and no edge of the resting shape shows past it.
    var leanOffset: CGFloat {
        let raw = IslandMotion.maxLean * CGFloat(lean) / CGFloat(IslandMotion.leanSteps)
        let cap = swell.width
        return min(max(raw, -cap), cap)
    }

    /// The reading for a pointer at `pointer` near an island drawn at
    /// `island`, both in the same coordinates (Isle uses screen space).
    /// Only meaningful once the pointer is within reach; `ProximityGate`
    /// makes sure it isn't asked otherwise.
    init(pointer: CGPoint, island: CGRect) {
        let dx = max(island.minX - pointer.x, 0, pointer.x - island.maxX)
        let dy = max(island.minY - pointer.y, 0, pointer.y - island.maxY)
        let distance = (dx * dx + dy * dy).squareRoot()
        let closeness = min(max(1 - distance / IslandMotion.proximityReach, 0), 1)
        // Smoothstep: nothing much until the pointer is properly close, then
        // the rest of the swell over the last stretch.
        let eased = closeness * closeness * (3 - 2 * closeness)
        level = Int((eased * CGFloat(IslandMotion.proximitySteps)).rounded())

        let halfSpan = island.width / 2 + IslandMotion.proximityReach
        let side = min(max((pointer.x - island.midX) / halfSpan, -1), 1)
        lean = Int((side * eased * CGFloat(IslandMotion.leanSteps)).rounded())
    }

    init(level: Int, lean: Int) {
        self.level = level
        self.lean = lean
    }
}

extension IslandMotion {
    /// How far from the island the pointer starts to register, in points.
    /// Measured from the drawn island's edge, so the open lip (14pt below
    /// it) sits inside the last quarter of the approach.
    static let proximityReach: CGFloat = 56

    /// The most the island grows: per side, and downward.
    static let maxSwell = CGSize(width: 3, height: 2)

    /// The most it leans toward the pointer.
    static let maxLean: CGFloat = 1.5

    static let proximitySteps = 8
    static let leanSteps = 3
}

/// Decides, per pointer move, whether the island's proximity reading changed.
///
/// The pointer monitor already runs on every move (it owns hover and
/// click-through), so this adds no wake-ups of its own; what it has to do is
/// cost nothing when the pointer is nowhere near. Out of reach it's one rect
/// test and, once at rest, an early return: no reading computed, nothing
/// published, and the `allowed` check — which asks the island for its state —
/// never evaluated.
struct ProximityGate {
    private(set) var current: IslandProximity = .rest

    /// How many readings were computed. Only the tests look at this.
    private(set) var evaluations = 0

    /// The new reading if it changed, else nil. `island` nil (no layout yet,
    /// or proximity switched off) relaxes to rest.
    mutating func update(
        pointer: CGPoint,
        island: CGRect?,
        allowed: @autoclosure () -> Bool
    ) -> IslandProximity? {
        let reach = IslandMotion.proximityReach
        let next: IslandProximity
        if let island,
           island.insetBy(dx: -reach, dy: -reach).contains(pointer),
           allowed() {
            evaluations += 1
            next = IslandProximity(pointer: pointer, island: island)
        } else {
            next = .rest
        }
        guard next != current else { return nil }
        current = next
        return next
    }

    /// Back to rest. The reading if that's a change, else nil.
    mutating func relax() -> IslandProximity? {
        guard !current.isRest else { return nil }
        current = .rest
        return .rest
    }
}
