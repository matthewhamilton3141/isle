//
//  ArtworkColors.swift
//
//  Pulls a cover's colours out of album art, for the equalizer gradient,
//  the markers, the notch's ambient background and Prism's ribbon.
//
//  This file reads the pixels; which of their colours make the palette is
//  decided in CoverColors.swift, which has no AppKit in it and is tested
//  on its own. The whole thing takes a quarter of a millisecond on most
//  covers and under one on the busiest, and runs once per cover:
//  `NotchViewModel` holds the result rather than asking again.
//

import AppKit
import SwiftUI

struct ArtworkPalette: Equatable {
    var primary: Color
    var secondary: Color
    var accent: Color

    /// Neutral palette for when there's no artwork.
    static let fallback = ArtworkPalette(
        primary: Color(white: 0.45),
        secondary: Color(white: 0.30),
        accent: Color(white: 0.60)
    )
}

enum ArtworkColors {
    /// The cover is read as this many pixels a side. Fine enough that a
    /// small subject keeps its own colour instead of being averaged into
    /// the ground behind it, which is what an 8×8 grid did to it.
    private static let side = 64

    static func palette(from image: NSImage?) -> ArtworkPalette {
        guard let image, let pixels = pixels(of: image), let pick = CoverColors.pick(pixels) else {
            return .fallback
        }
        func color(_ c: CoverColors.RGB) -> Color {
            Color(.sRGB, red: c.r, green: c.g, blue: c.b)
        }
        return ArtworkPalette(
            primary: color(pick.primary),
            secondary: color(pick.secondary),
            accent: color(pick.accent)
        )
    }

    // MARK: - Sampling

    /// The cover's pixels in sRGB, leaving out any that are mostly
    /// transparent. Nil if the image can't be drawn.
    static func pixels(of image: NSImage) -> [CoverColors.RGB]? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }

        var bytes = [UInt8](repeating: 0, count: side * side * 4)

        // The draw and the read both have to happen *inside* this closure.
        //
        // CGContext does not copy the buffer it is handed — it keeps the
        // pointer and writes through it on every draw. Passing `&bytes`
        // straight to the initializer produced a pointer guaranteed valid
        // only for the duration of that one call, and `draw` then wrote
        // through it afterwards: undefined behaviour, and the kind that reads
        // back as blocks of arbitrary colour rather than as a crash.
        // `withUnsafeMutableBytes` is what actually pins the buffer for as
        // long as the context is alive.
        let drew: Bool = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let context = CGContext(
                    data: base,
                    width: side,
                    height: side,
                    bitsPerComponent: 8,
                    bytesPerRow: side * 4,
                    space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  )
            else { return false }

            // Drawing the whole image into the small context is the
            // downscale. Medium, not high: high sharpens, and the ringing
            // beside a hard edge is a colour the cover doesn't have.
            context.interpolationQuality = .medium
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drew else { return nil }

        return stride(from: 0, to: bytes.count, by: 4).compactMap { index in
            let alpha = Double(bytes[index + 3])
            guard alpha > 127 else { return nil }
            // The context's channels are premultiplied.
            return CoverColors.RGB(
                r: min(1, Double(bytes[index]) / alpha),
                g: min(1, Double(bytes[index + 1]) / alpha),
                b: min(1, Double(bytes[index + 2]) / alpha)
            )
        }
    }
}
