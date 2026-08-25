//
//  NotchHostingView.swift
//
//  Hosting view that only accepts mouse events inside the drawn notch.
//
//  The panel is deliberately kept at its fully-expanded size at all times so
//  the compositor never has to resize a window mid-animation. The side
//  effect is that the collapsed notch — maybe 300pt wide — sits inside a
//  520pt window. Without this, that whole invisible rectangle would swallow
//  clicks along the top of the screen, and the user would find the menu bar
//  and the top of their frontmost window mysteriously dead.
//
//  So: hit-test against the live content rect and return nil everywhere else,
//  which lets AppKit deliver the click to whatever is underneath.
//

import AppKit
import SwiftUI

final class NotchHostingView<Content: View>: NSHostingView<Content> {
    /// Live bounds of the drawn notch, in this view's coordinate space.
    /// Nil until SwiftUI reports a layout, during which nothing is clickable.
    var activeRect: CGRect?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let activeRect else { return nil }

        // `point` arrives in the superview's coordinate space.
        var local = convert(point, from: superview)

        // `activeRect` comes from SwiftUI, which always measures top-left
        // origin with y increasing downward. AppKit only agrees when the view
        // is flipped, so mirror y when it isn't rather than assuming either
        // way — NSHostingView's flippedness is not ours to rely on.
        if !isFlipped {
            local.y = bounds.height - local.y
        }

        guard activeRect.contains(local) else { return nil }

        return super.hitTest(point)
    }
}
