//
//  StatusBarIcon.swift
//
//  Isle's menu-bar glyph: the Claude 3×3 dot mark, drawn as a template image so
//  it adopts the menu bar's tint (light/dark, vibrancy) like a system icon.
//

import AppKit

enum StatusBarIcon {
    /// The status item image. A centred 3×3 grid of dots, each 26% of the grid
    /// box, in a ~15pt square with clean margins.
    static var image: NSImage {
        let side: CGFloat = 15
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            NSColor.black.setFill()
            let r = NSRect(x: 0, y: 0, width: side, height: side).insetBy(dx: 1.5, dy: 1.5)
            let box = min(r.width, r.height)
            let d = box * 0.26
            let step = (box - d) / 2          // outer dots hug the box edges
            let originX = r.midX - box / 2
            let originY = r.midY - box / 2
            for row in 0..<3 {
                for col in 0..<3 {
                    let dot = NSRect(
                        x: originX + CGFloat(col) * step,
                        y: originY + CGFloat(row) * step,
                        width: d, height: d
                    )
                    NSBezierPath(ovalIn: dot).fill()
                }
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
