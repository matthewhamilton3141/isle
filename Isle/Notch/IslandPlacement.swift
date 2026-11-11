//
//  IslandPlacement.swift
//
//  Where one island is: hanging from its screen's notch, as it always has,
//  or taken off it and left somewhere on the screen.
//
//  Detached, the island is no longer drawn against the camera housing, so
//  nothing about it has to be the hardware's shape or colour: no band to
//  keep clear, no flares into the bezel, and a closed form that can be more
//  than a sliver either side of a cutout.
//
//  The layout inside the window doesn't change with the placement: the
//  island is drawn at the top centre of its window either way, and growing
//  means growing downward from there. Detaching moves the window, so that
//  top centre lands on `anchor`.
//
//  Kept free of AppKit and SwiftUI so it compiles on its own for scripts.
//

import CoreGraphics

enum IslandPlacement: Equatable {
    /// On the notch (or, on a screen without one, where the notch would be).
    case docked

    /// Off the notch. `anchor` is the top centre of the drawn island, in
    /// global screen coordinates (AppKit's: origin bottom-left, y up).
    case floating(anchor: CGPoint)

    var isFloating: Bool {
        if case .floating = self { return true }
        return false
    }

    var anchor: CGPoint? {
        if case .floating(let anchor) = self { return anchor }
        return nil
    }
}
