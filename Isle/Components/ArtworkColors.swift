//
//  ArtworkColors.swift
//
//  Pulls a couple of representative colours out of album art, used for the
//  equalizer gradient and the notch's ambient background (spec 3.1, 3.2).
//
//  Deliberately the cheap approach the spec asks for — downscale hard, then
//  average by region — rather than k-means clustering. At the size this is
//  displayed the difference isn't visible, and this runs in well under a
//  millisecond on a thumbnail, which matters because it re-runs on every
//  track change.
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
    /// Sampling grid. 8x8 is enough to separate a record sleeve's background
    /// from its subject without picking up JPEG noise.
    private static let gridSize = 8

    static func palette(from image: NSImage?) -> ArtworkPalette {
        guard let image, let samples = sample(image), !samples.isEmpty else {
            return .fallback
        }

        // Rank by how saturated *and* bright each region is. Straight
        // frequency ranking tends to return the near-black background that
        // dominates most album art, which makes for a dead-looking gradient.
        let ranked = samples.sorted { lhs, rhs in
            lhs.vibrancy > rhs.vibrancy
        }

        let primary = ranked[0]
        // Step away from the primary so the gradient actually reads as a
        // gradient; adjacent grid cells are usually near-identical.
        let secondary = ranked.first { $0.distance(to: primary) > 0.25 }
            ?? ranked[min(1, ranked.count - 1)]
        let accent = ranked.first {
            $0.distance(to: primary) > 0.35 && $0.distance(to: secondary) > 0.25
        } ?? primary

        return ArtworkPalette(
            primary: primary.color(minBrightness: 0.35),
            secondary: secondary.color(minBrightness: 0.28),
            accent: accent.color(minBrightness: 0.45)
        )
    }

    // MARK: - Sampling

    private struct Sample {
        var r: Double
        var g: Double
        var b: Double

        var brightness: Double { (r + g + b) / 3 }

        var saturation: Double {
            let maxC = max(r, g, b)
            let minC = min(r, g, b)
            guard maxC > 0 else { return 0 }
            return (maxC - minC) / maxC
        }

        /// Favour colours that are both colourful and not nearly black/white.
        var vibrancy: Double {
            saturation * (1 - abs(brightness - 0.55) * 1.4)
        }

        func distance(to other: Sample) -> Double {
            let dr = r - other.r, dg = g - other.g, db = b - other.b
            return (dr * dr + dg * dg + db * db).squareRoot()
        }

        /// Lift very dark samples so the gradient stays visible against the
        /// notch's black background.
        func color(minBrightness: Double) -> Color {
            let current = brightness
            guard current > 0, current < minBrightness else {
                return Color(red: r, green: g, blue: b)
            }
            let scale = minBrightness / current
            return Color(
                red: min(1, r * scale),
                green: min(1, g * scale),
                blue: min(1, b * scale)
            )
        }
    }

    private static func sample(_ image: NSImage) -> [Sample]? {
        guard let cgImage = image.cgImage(
            forProposedRect: nil, context: nil, hints: nil
        ) else { return nil }

        let side = gridSize
        var pixels = [UInt8](repeating: 0, count: side * side * 4)

        // The draw and the read both have to happen *inside* this closure.
        //
        // CGContext does not copy the buffer it is handed — it keeps the
        // pointer and writes through it on every draw. Passing `&pixels`
        // straight to the initializer produced a pointer guaranteed valid
        // only for the duration of that one call, and `draw` then wrote
        // through it afterwards: undefined behaviour, and the kind that reads
        // back as blocks of arbitrary colour rather than as a crash.
        // `withUnsafeMutableBytes` is what actually pins the buffer for as
        // long as the context is alive.
        let drew: Bool = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let context = CGContext(
                    data: base,
                    width: side,
                    height: side,
                    bitsPerComponent: 8,
                    bytesPerRow: side * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  )
            else { return false }

            // Drawing the whole image into an 8x8 context is the downscale —
            // the interpolation does the averaging for us.
            context.interpolationQuality = .medium
            context.draw(
                cgImage,
                in: CGRect(x: 0, y: 0, width: side, height: side)
            )
            return true
        }
        guard drew else { return nil }

        return stride(from: 0, to: pixels.count, by: 4).compactMap { index in
            let alpha = Double(pixels[index + 3]) / 255
            guard alpha > 0.5 else { return nil }
            return Sample(
                r: Double(pixels[index]) / 255,
                g: Double(pixels[index + 1]) / 255,
                b: Double(pixels[index + 2]) / 255
            )
        }
    }
}
