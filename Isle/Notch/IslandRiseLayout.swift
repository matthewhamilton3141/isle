//
//  IslandRiseLayout.swift
//
//  How high in its window an island off the notch is drawn. Hanging from
//  its capsule (on the notch, and off it opening down) it's at the top;
//  standing on the capsule (opening up) it's on the floor, the shadow's
//  room under it; and growing both ways from the capsule, as a hover opens
//  it (`IslandOpening.rise`), it's that share of the way down. The window
//  is placed so the capsule is at its anchor in every case
//  (`NotchMetrics.frame(for:opening:)`), so as the island grows and
//  shrinks it moves `rise` of the change up and the rest down.
//
//  A layout rather than spacers, so the island's place follows its own
//  size in whatever transaction changes it — the resize on a swipe as much
//  as the open spring — the way the spacers did for up and down alone.
//

import SwiftUI

struct IslandRiseLayout: Layout {
    /// `IslandOpening.rise`: 0 at the top, 1 on the floor.
    var rise: CGFloat
    /// The room kept under the island standing on the floor.
    var below: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for view in subviews {
            let size = view.sizeThatFits(ProposedViewSize(bounds.size))
            let drop = rise * max(bounds.height - below - size.height, 0)
            view.place(at: CGPoint(x: bounds.midX, y: bounds.minY + drop), anchor: .top, proposal: ProposedViewSize(size))
        }
    }
}
