//
//  GlyphInk.swift
//
//  Optical centring for SF Symbols.
//
//  A symbol's layout box is not a tight box around its marks — it carries
//  bearing, and that bearing is not symmetric. Centring the *box* therefore
//  leaves the visible glyph slightly off centre, by a different amount for
//  every symbol: measured at 12pt semibold, `headphones` sits 0.5pt left of
//  where it looks like it should, `bolt.fill` half a point high, `keyboard`
//  only 0.17 left. Individually invisible; side by side in a fixed slot, the
//  set reads as unaligned, because each glyph is off by its own amount.
//
//  So this measures the actual ink — render once, scan the alpha channel for
//  the tight bounds, and report how far that sits from the box centre. The
//  caller subtracts it and the marks land on one axis.
//
//  Measured rather than tabulated on purpose: bearings are a property of the
//  installed symbol set, and Apple redraws symbols between releases. A hard
//  coded table would be right on the OS it was written against and quietly
//  wrong on the next one.
//

import AppKit

enum GlyphInk {
    /// Rendering scale for the measurement. Sub-point offsets are what's being
    /// measured, so the scan needs finer resolution than the glyph's own size.
    private static let sampleScale: CGFloat = 8

    /// Anything at least this opaque counts as ink, which keeps antialiased
    /// edges from widening the bounds.
    private static let inkAlpha: CGFloat = 0.08

    private static var cache: [String: CGSize] = [:]

    /// How far the glyph's ink sits from the centre of its layout box, in
    /// points, in SwiftUI's coordinates (x right, y down). Apply the negation
    /// to centre it optically.
    ///
    /// Cached per symbol and size: this renders a bitmap and walks it, which is
    /// far too expensive for a view body, and there are only a handful of
    /// symbols in the toast set.
    static func centeringOffset(for symbolName: String, pointSize: CGFloat) -> CGSize {
        let key = "\(symbolName)@\(pointSize)"
        if let cached = cache[key] { return cached }
        let offset = measure(symbolName, pointSize: pointSize) ?? .zero
        cache[key] = offset
        return offset
    }

    private static func measure(_ name: String, pointSize: CGFloat) -> CGSize? {
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return nil }

        let size = symbol.size
        let pixelsWide = Int(size.width * sampleScale)
        let pixelsHigh = Int(size.height * sampleScale)
        guard pixelsWide > 0, pixelsHigh > 0,
              let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }

        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        symbol.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()

        var minX = pixelsWide, maxX = -1, minY = pixelsHigh, maxY = -1
        for y in 0..<pixelsHigh {
            for x in 0..<pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > inkAlpha {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= 0 else { return nil }

        let inkCentreX = (CGFloat(minX) + CGFloat(maxX) + 1) / 2 / sampleScale
        let inkCentreY = (CGFloat(minY) + CGFloat(maxY) + 1) / 2 / sampleScale

        // `colorAt` indexes from the top down, which is already SwiftUI's
        // direction — so neither axis needs flipping here.
        return CGSize(width: inkCentreX - size.width / 2,
                      height: inkCentreY - size.height / 2)
    }
}
