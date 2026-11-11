//
//  IslandFloat.swift
//
//  The numbers behind an island that has been taken off its notch
//  (`IslandPlacement.floating`), kept free of AppKit and SwiftUI so they
//  compile on their own and can be checked without an app
//  (scripts/test-island-float.sh):
//
//  - The shape. Nothing has to be the hardware's any more: the flares into
//    the bezel go and the top corners round like the bottom ones, so open
//    it is a card and closed a capsule. The side walls are where they were
//    — the open panel is exactly the docked panel less its flares — so the
//    content keeps its place.
//  - The header. The camera band stays as a band of the same height, so
//    every face lays out as it does on the notch, but it is surface now,
//    and where the camera was there's a grabber: this can be moved.
//  - The closed capsule. On the notch the closed island is a sliver either
//    side of the camera. Off it, it is one capsule taller than the band and
//    as wide as what it holds: a cluster each for the music, Claude and the
//    timer, or a toast, or — with nothing live — a small bead.
//  - The edge. Black over a dark window has none of its own, so it gets a
//    hairline rim and a soft shadow. Frosted glass over a dark window is
//    nearly as lost, so it gets a fainter hairline and no shadow; Prism's
//    lens has an edge of its own.
//  - Prism's pane, closed: frost under the capsule's content, inside a rim
//    of clear lens.
//
//  The layout inside the window doesn't change with the placement (see
//  `IslandPlacement`): everything here is drawn at the top centre of a
//  window as big as `NotchMetrics.maximumFrame`, growing downward, and has
//  to fit in it. The drawing is in NotchRootView, FloatingPillView and the
//  fills (IslandMotion+SwiftUI.swift, IslandGlass+SwiftUI.swift,
//  IslandPrism+SwiftUI.swift).
//

import CoreGraphics

enum IslandFloat {
    // MARK: - The open panel's shape

    /// The open panel's corners, all four, in Black and Glass. Rounder
    /// than the docked panel's bottom corners (22): open, the island is the
    /// closed capsule grown, a soft card with nothing of the notch panel's
    /// squareness left — and as round as the header allows, whose first
    /// mark sits 10pt in from the wall and 8pt down. Tune here.
    static let cornerRadius: CGFloat = 28

    /// Prism's top corners. Its bottom ones stay the lens's
    /// (`IslandPrism.bottomCornerRadius`): rounder still, where the lip is.
    /// Its header's first mark is the side lip's 12pt further in, so the
    /// top can be rounder than the other modes'. Tune here.
    static let prismCrownRadius: CGFloat = 32

    /// The open panel's size: the docked panel's (`docked`, flares
    /// included) less the flares, `wallInset` wide, on each side. The walls
    /// don't move when the island leaves the notch; the frame comes in to
    /// meet them.
    static func openSize(docked: CGSize, wallInset: CGFloat) -> CGSize {
        CGSize(width: max(docked.width - 2 * wallInset, 0), height: docked.height)
    }

    // MARK: - The header

    /// The grabber in the middle of the header band, where the camera was:
    /// a short bar, the mark a sheet has for "this can be moved". Tune here.
    static let grabber = CGSize(width: 36, height: 5)

    /// The grabber's white, on black. On glass it is lifted like any other
    /// secondary mark (`IslandGlass.liftedOpacity`).
    static let grabberOpacity: Double = 0.3

    /// What the header keeps clear either side of the grabber: the Claude
    /// face's wings, which on the notch end short of the camera, end this
    /// short of the grabber instead and are that much wider.
    static let grabberClearance: CGFloat = 14

    /// The gap in the header's middle that the faces leave for the grabber.
    static var grabberGap: CGFloat { grabber.width + 2 * grabberClearance }

    // MARK: - The closed capsule

    /// The capsule's height: taller than the camera band (32 on this Mac),
    /// with room for a cover and two lines of text. Tune here.
    static let pillHeight: CGFloat = 38

    /// With nothing live: a bead. Small and quiet, and still a target the
    /// pointer can find, hover and take hold of. Tune here.
    static let bead = CGSize(width: 60, height: 24)

    /// The bead's own grabber: the header's bar, smaller.
    static let beadGrabber = CGSize(width: 22, height: 4)

    /// The cover's thumbnail, and its corners.
    static let cover: CGFloat = 24
    static let coverRadius: CGFloat = 6.5

    /// Claude's status marker, and the timer's ring.
    static let marker: CGFloat = 20
    static let ring: CGFloat = 18

    /// The waveform, the size it is on the notch.
    static let wave = CGSize(width: 26, height: 20)

    /// A toast's glyph slot, the width of the cover it stands in for.
    static let toastGlyph: CGFloat = 24

    /// Between a cluster's mark and its text, and its text and the
    /// waveform.
    static let markGap: CGFloat = 8
    static let waveGap: CGFloat = 9

    /// Between two clusters: this much air either side of a hairline.
    static let clusterGap: CGFloat = 11
    static let divider = CGSize(width: 1, height: 14)
    static let dividerOpacity: Double = 0.16

    /// From the capsule's trailing end to the last cluster's text or
    /// waveform. The leading end is measured off the mark there
    /// (`leadingInset`).
    static let trailingInset: CGFloat = 15

    /// From the capsule's leading end to a mark `size` tall: its inset from
    /// the top and bottom, and a little more, so a square mark sits inside
    /// the capsule's round end rather than in its corner.
    static func leadingInset(mark size: CGFloat) -> CGFloat {
        (pillHeight - size) / 2 + 2
    }

    /// The text beside a mark: one line, or two. Title over artist, status
    /// over project. Sizes and line heights; two lines are 27pt of the
    /// capsule's 38.
    static let titleSize: CGFloat = 12
    static let titleLine: CGFloat = 15
    static let detailSize: CGFloat = 10
    static let detailLine: CGFloat = 12

    /// How wide a cluster's text may be before it scrolls (the title, the
    /// artist) or is cut (the project): alone in the capsule, and sharing
    /// it. And the least a music label is given, so a one-word title
    /// doesn't make a capsule that looks cut short.
    static let labelMaxAlone: CGFloat = 156
    static let labelMaxShared: CGFloat = 112
    static let labelMin: CGFloat = 36

    /// The text a cluster is given for text `natural` wide.
    static func labelWidth(natural: CGFloat, alone: Bool) -> CGFloat {
        min(max(natural.rounded(.up), labelMin), alone ? labelMaxAlone : labelMaxShared)
    }

    /// What the closed capsule holds, as the widths that size it. Built
    /// from the view model by `FloatingPillLayout`, which measures the
    /// text; laid out by `FloatingPillView`.
    struct Pill: Equatable {
        /// The music: its label's width, and whether the waveform is on.
        struct Music: Equatable {
            var label: CGFloat
            var wave: Bool
        }

        /// A toast borrows the whole capsule: its text's width.
        var toast: CGFloat?
        var music: Music?
        /// Claude: the status text's width.
        var claude: CGFloat?
        /// The timer: its clock's width.
        var timer: CGFloat?

        /// Nothing live: the bead.
        var isBead: Bool { toast == nil && clusters == 0 }

        /// How many clusters share the capsule (a toast is on its own).
        var clusters: Int {
            toast != nil ? 0 : (music == nil ? 0 : 1) + (claude == nil ? 0 : 1) + (timer == nil ? 0 : 1)
        }

        /// The mark at the capsule's leading end, which sets the inset
        /// there: the toast's glyph, else the first cluster's.
        var leadingMark: CGFloat {
            if toast != nil { return IslandFloat.toastGlyph }
            if music != nil { return IslandFloat.cover }
            if claude != nil { return IslandFloat.marker }
            return IslandFloat.ring
        }

        /// Each cluster's width, in the order they're drawn: music, Claude,
        /// the timer.
        var clusterWidths: [CGFloat] {
            let f = IslandFloat.self
            if let toast { return [f.toastGlyph + f.markGap + toast] }
            var widths: [CGFloat] = []
            if let music { widths.append(f.cover + f.markGap + music.label + (music.wave ? f.waveGap + f.wave.width : 0)) }
            if let claude { widths.append(f.marker + f.markGap + claude) }
            if let timer { widths.append(f.ring + f.markGap + timer) }
            return widths
        }

        /// The capsule's size: the bead, or the clusters with their gaps
        /// between the two end insets.
        var size: CGSize {
            guard !isBead else { return IslandFloat.bead }
            let f = IslandFloat.self
            let widths = clusterWidths
            let between = CGFloat(widths.count - 1) * (2 * f.clusterGap + f.divider.width)
            let width = f.leadingInset(mark: leadingMark) + widths.reduce(0, +) + between + f.trailingInset
            return CGSize(width: width.rounded(.up), height: f.pillHeight)
        }
    }

    /// The widest the capsule gets: all three clusters, their labels at
    /// their caps, a clock that counts hours (`clock` wide), the waveform
    /// on. What the window has to hold (see the tests).
    static func widestPill(status: CGFloat, clock: CGFloat) -> CGSize {
        Pill(music: .init(label: labelMaxShared, wave: true), claude: min(status, labelMaxShared), timer: clock).size
    }

    // MARK: - Corners

    /// The outline's corners off the notch: no flare (`top`), and the same
    /// roundness above (`crown`) as below. Closed, a capsule's: half the
    /// height, whichever of the capsule and the bead it is.
    static func corners(open: Bool, prism: Bool, closedHeight: CGFloat) -> (top: CGFloat, bottom: CGFloat, crown: CGFloat) {
        guard open else { return (0, closedHeight / 2, closedHeight / 2) }
        return prism
            ? (0, IslandPrism.bottomCornerRadius, prismCrownRadius)
            : (0, cornerRadius, cornerRadius)
    }

    // MARK: - The edge

    /// The rim: a hairline of white just inside the outline, so black over
    /// a dark window still has an edge. Drawn as a stroke `rimWidth` wide
    /// centred on the outline and clipped to it: half shows. Tune here.
    static let rimOpacity: Double = 0.2
    static let rimWidth: CGFloat = 1

    /// The same hairline on Glass, fainter: dark frosted glass over a dark
    /// window is a shade apart from it and no more, and the system draws
    /// its glass no edge there. Tune here.
    static let glassRimOpacity: Double = 0.12

    /// The shadow: soft, and cast downward. Tune here.
    static let shadowOpacity: Double = 0.42
    static let shadowRadius: CGFloat = 12
    static let shadowDrop: CGFloat = 5

    /// The island's top edge is the window's, so there is no room above it
    /// for a shadow. Rather than have the window cut one off, the shadow
    /// grows from nothing at the top edge to its full strength this far
    /// down: light from above.
    static let shadowRise: CGFloat = 26

    /// How far past the outline the shadow is given room to fall, to the
    /// sides and below: past this it is cut. Twice the blur radius is
    /// where a Gaussian has all but gone.
    static var shadowReach: (side: CGFloat, below: CGFloat) {
        (2 * shadowRadius, 2 * shadowRadius + shadowDrop)
    }

    // MARK: - Prism's pane

    /// Prism's top rim, open: how far below the top edge the frost behind
    /// the content begins (its edge is as soft as the walls',
    /// `IslandPrism.rimFeather`, so the frost is whole about twice this far
    /// down). Slim — the header's marks start some 10pt under the top edge
    /// — but a rim: off the notch the lens runs all the way round, where
    /// on it the band over the camera is black. Tune here.
    static let prismTopRim: CGFloat = 6

    /// Closed, the capsule is lens with frost under its content: the frost
    /// stops this short of the edge all round, and its edge is this soft.
    /// Tune here.
    static let prismPillRim: CGFloat = 3.5
    static let prismPillFeather: CGFloat = 1.5

    /// The pane's insets, corner radius and feather at `progress` of the
    /// open (0 the capsule, 1 the panel): from the capsule's slim even rim
    /// to the panel's — `side` inside each wall, `IslandPrism.lip` above
    /// the bottom edge, the slim top rim. `height` is the closed capsule's.
    struct PrismPane: Equatable {
        var top: CGFloat
        var side: CGFloat
        var bottom: CGFloat
        var topRadius: CGFloat
        var bottomRadius: CGFloat
        var feather: CGFloat
    }

    /// The radius of the open pane's bottom corners (as on the notch).
    static let prismPaneRadius: CGFloat = 18

    static func prismPane(progress: Double, closedHeight: CGFloat) -> PrismPane {
        let p = CGFloat(min(max(progress, 0), 1))
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * p }
        let closedRadius = max(closedHeight / 2 - prismPillRim, 0)
        return PrismPane(
            top: mix(prismPillRim, prismTopRim),
            side: mix(prismPillRim, IslandPrism.rim),
            bottom: mix(prismPillRim, IslandPrism.lip),
            topRadius: mix(closedRadius, max(prismCrownRadius - IslandPrism.rim, 0)),
            bottomRadius: mix(closedRadius, prismPaneRadius),
            feather: mix(prismPillFeather, IslandPrism.rimFeather)
        )
    }
}
