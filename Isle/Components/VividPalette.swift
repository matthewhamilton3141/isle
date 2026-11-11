//
//  VividPalette.swift
//
//  A second way to pull colours out of album art, for Prism, which wants a
//  cover's colourful colours rather than its commonest ones.
//
//  `ArtworkColors.palette` averages the cover down to an 8×8 grid and
//  ranks the cells. Averaging is what makes it cheap and steady, and also
//  what loses a cover's colour: a small vivid subject on a large dull
//  ground is averaged into the ground, cell by cell, and the cells that
//  win are the ground's. Here the cover is read at a finer grain and every
//  pixel votes for its hue, with a vote that grows steeply with how
//  colourful it is (saturated and bright at once) — so a little of a
//  strong colour outweighs a lot of a weak or a dark one — and the palette
//  is the hues with the most votes, each drawn as the average of the
//  pixels that voted for it, the strongest counting most.
//
//  Kept free of AppKit so the choosing compiles on its own and can be
//  checked without an image (scripts/test-island-glass.sh). Reading the
//  pixels is `ArtworkColors.vividPalette`.
//
//  The other modes keep `ArtworkColors.palette`, which Matthew settled on
//  for them; nothing here changes what they draw.
//

import Foundation

enum VividPalette {
    struct RGB: Equatable {
        var r: Double
        var g: Double
        var b: Double
    }

    /// Hue is counted in this many bins round the wheel: 15° each.
    static let binCount = 24

    /// A pixel less saturated or darker than this has no hue worth
    /// counting: greys, near-blacks and JPEG noise. Low, so a cover that
    /// is all pastels still has its pinks and mints told apart; beside a
    /// strong colour their votes are next to nothing.
    static let minSaturation: Double = 0.06
    static let minBrightness: Double = 0.12

    /// A vote is the pixel's chroma (saturation times brightness: how far
    /// its strongest channel stands above its weakest) to this power. At
    /// 2, a vivid pixel at 0.8 outvotes sixty dusty or dark ones at 0.1.
    /// Tune here.
    static let chromaPower: Double = 2

    /// A cover whose counted pixels are fewer than this fraction of it has
    /// no colour to speak of (a black-and-white photograph with a faint
    /// cast, say), and gets no vivid palette.
    static let minCoverage: Double = 0.015

    /// The second and third colours are at least this many bins from the
    /// ones already chosen (30°), so the palette is different colours
    /// rather than shades of one, and have at least this fraction of the
    /// first's votes, so a stray pixel doesn't become a colour.
    static let minSeparation = 2
    static let minShare: Double = 0.05

    /// The palette from a cover's pixels, or nil for a cover with no
    /// colour in it. A cover with one colour, or two, gets its missing
    /// colours as a deeper and a paler shade of the first: never a hue the
    /// cover doesn't have.
    static func pick(_ pixels: [RGB]) -> (primary: RGB, secondary: RGB, accent: RGB)? {
        guard !pixels.isEmpty else { return nil }
        var votes = [Double](repeating: 0, count: binCount)
        var sums = [RGB](repeating: RGB(r: 0, g: 0, b: 0), count: binCount)
        var weights = [Double](repeating: 0, count: binCount)
        var counted = 0
        for p in pixels {
            let mx = max(p.r, p.g, p.b), mn = min(p.r, p.g, p.b)
            guard mx >= minBrightness else { continue }
            let s = (mx - mn) / mx
            guard s >= minSaturation else { continue }
            let w = pow(mx - mn, chromaPower)
            let bin = min(Int(hue(p) * Double(binCount)), binCount - 1)
            votes[bin] += w
            // The hue's colour is the average of its pixels with the vote
            // squared, so it is the colour of the hue's strongest pixels,
            // not of its dim edges.
            weights[bin] += w * w
            sums[bin].r += p.r * w * w
            sums[bin].g += p.g * w * w
            sums[bin].b += p.b * w * w
            counted += 1
        }
        guard Double(counted) >= minCoverage * Double(pixels.count) else { return nil }

        // A hue's support is its bin and half of each neighbour's, so a
        // colour that straddles a bin edge isn't split into two weak ones.
        func support(_ i: Int) -> Double {
            votes[i] + 0.5 * (votes[(i + 1) % binCount] + votes[(i + binCount - 1) % binCount])
        }
        func color(_ i: Int) -> RGB {
            var w = 0.0, c = RGB(r: 0, g: 0, b: 0)
            for (j, weight) in [(i, 1.0), ((i + 1) % binCount, 0.5), ((i + binCount - 1) % binCount, 0.5)] {
                w += weights[j] * weight
                c.r += sums[j].r * weight
                c.g += sums[j].g * weight
                c.b += sums[j].b * weight
            }
            return w > 0 ? RGB(r: c.r / w, g: c.g / w, b: c.b / w) : c
        }
        func apart(_ i: Int, _ j: Int) -> Int {
            let d = abs(i - j)
            return min(d, binCount - d)
        }

        // Ties go to the lower bin, so the same pixels always give the
        // same palette.
        let order = (0..<binCount).sorted { support($0) != support($1) ? support($0) > support($1) : $0 < $1 }
        let first = order[0]
        guard support(first) > 0 else { return nil }
        let floor = support(first) * minShare
        // A further colour has votes of its own, enough of them. Judged
        // by support alone, the shoulder of the first colour — a bin two
        // along with nothing in it but half its neighbour's support — came
        // back as the second.
        func stands(_ i: Int) -> Bool { votes[i] >= floor }
        let second = order.first { apart($0, first) >= minSeparation && stands($0) }
        let third = order.first { i in
            guard let second else { return false }
            return apart(i, first) >= minSeparation && apart(i, second) >= minSeparation && stands(i)
        }

        let primary = color(first)
        return (
            primary,
            second.map(color) ?? shade(primary, brightness: 0.72, saturation: 1.1),
            third.map(color) ?? shade(second.map(color) ?? primary, brightness: 1.25, saturation: 0.6)
        )
    }

    /// 0...1 round the wheel, red at 0.
    static func hue(_ c: RGB) -> Double {
        let mx = max(c.r, c.g, c.b), mn = min(c.r, c.g, c.b), d = mx - mn
        guard d > 0 else { return 0 }
        var h: Double
        if mx == c.r { h = ((c.g - c.b) / d).truncatingRemainder(dividingBy: 6) }
        else if mx == c.g { h = (c.b - c.r) / d + 2 }
        else { h = (c.r - c.g) / d + 4 }
        h /= 6
        return h < 0 ? h + 1 : h
    }

    /// A colour's shade: its hue kept, brightness and saturation scaled
    /// (both clamped to 0...1).
    static func shade(_ c: RGB, brightness: Double, saturation: Double) -> RGB {
        let mx = max(c.r, c.g, c.b), mn = min(c.r, c.g, c.b)
        guard mx > 0 else { return c }
        let s = min(1, (mx - mn) / mx * saturation), v = min(1, mx * brightness)
        // Rebuild from hue, the new saturation and the new brightness.
        let h = hue(c) * 6
        let i = Int(h) % 6, f = h - Double(Int(h))
        let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
        switch i {
        case 0: return RGB(r: v, g: t, b: p)
        case 1: return RGB(r: q, g: v, b: p)
        case 2: return RGB(r: p, g: v, b: t)
        case 3: return RGB(r: p, g: q, b: v)
        case 4: return RGB(r: t, g: p, b: v)
        default: return RGB(r: v, g: p, b: q)
        }
    }
}
