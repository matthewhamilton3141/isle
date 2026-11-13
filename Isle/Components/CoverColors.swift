//
//  CoverColors.swift
//
//  Chooses the colours of a record sleeve: the ones a person would name
//  for it.
//
//  The cover's pixels are grouped into the colours it actually has, in
//  OKLab, where distance and colourfulness are what the eye sees rather
//  than what the RGB numbers say. Each of those colours is then scored by
//  how colourful it is and how much of the cover it holds, so neither the
//  near-black that merely covers the most area nor a stray speck wins, and
//  the palette is the best of them plus the best that are a different
//  colour from it. A cover with one colour gets that colour and its own
//  lighter and darker shades; one with two gets two; one with none gets
//  its greys. Nothing is ever made up: every colour returned is one of
//  the cover's, at most lifted off black with its hue kept so it can be
//  seen on the island.
//
//  Kept free of AppKit so the choosing compiles on its own and can be
//  checked without an image (scripts/test-artwork-palette.sh). Reading the
//  pixels is `ArtworkColors.palette`.
//

import Foundation

enum CoverColors {
    /// sRGB, channels 0...1.
    struct RGB: Equatable {
        var r: Double
        var g: Double
        var b: Double
    }

    struct Pick: Equatable {
        var primary: RGB
        var secondary: RGB
        var accent: RGB
    }

    /// A colour in OKLab: `l` is lightness 0...1, `a` and `b` the two
    /// colour axes, whose length is how colourful it is (chroma) and whose
    /// angle is its hue.
    struct Lab: Equatable {
        var l: Double
        var a: Double
        var b: Double

        var chroma: Double { (a * a + b * b).squareRoot() }
        /// Radians, -π...π.
        var hue: Double { atan2(b, a) }
    }

    /// One of the cover's colours and the fraction of the cover it holds.
    struct Swatch: Equatable {
        var lab: Lab
        var share: Double
    }

    // MARK: - Parameters

    /// The cover's pixels are grouped into at most this many colours.
    static let clusterCount = 16
    /// Refinement passes over the grouping; it settles well before this.
    static let maxIterations = 12
    /// Two of those closer than this (OKLab distance) are one colour.
    static let mergeDistance: Double = 0.05

    /// Below this chroma (see `isColour`) a colour is a neutral: a grey, a
    /// white, a black, or one of those with a cast too faint to name.
    static let neutralChroma: Double = 0.025

    /// Two colours whose hues are closer than this are one colour in two
    /// shades; further apart, they are two colours (radians: 30°). Two
    /// colours count fully as different once they are `hueSpread` apart
    /// (60°); between the two a candidate is marked down (see `choose`).
    static let hueStep: Double = 30 * .pi / 180
    static let hueSpread: Double = 60 * .pi / 180

    /// A colour's score (see `score`) is its presence times its chroma to
    /// `chromaPower`. Presence is `share / (share + presencePivot)`: it
    /// climbs steeply over the first few percent of the cover and is
    /// nearly flat after, so holding 60% of the cover is worth little more
    /// than holding 15%, and a tenth of a percent is worth very little.
    static let presencePivot: Double = 0.03
    static let chromaPower: Double = 1.5

    /// A cover whose colourful pixels are fewer than this fraction of it
    /// has no colour to speak of, and gets its neutrals.
    static let minColourShare: Double = 0.01

    /// A further colour is named only if it scores at least this fraction
    /// of the first's: a cover's second colour has to be one you'd notice
    /// beside its first.
    static let minRelativeScore: Double = 0.2

    /// A shade of a colour differs from it by at least this much
    /// lightness, and holds at least this much of the cover.
    static let shadeStep: Double = 0.08
    static let shadeShare: Double = 0.005

    /// The lightness each slot is held above, so it shows on black: where
    /// the brightness floors this replaces (0.35, 0.28, 0.45) put a grey.
    static let primaryFloor: Double = 0.46
    static let secondaryFloor: Double = 0.40
    static let accentFloor: Double = 0.55

    /// How a colour under its floor is lifted to it (see `lifted`).
    static let maxChromaGrowth: Double = 2
    static let blackLightness: Double = 0.10
    static let blackFade: Double = 0.10

    // MARK: - Choosing

    /// The palette from a cover's pixels, or nil when there are none.
    static func pick(_ pixels: [RGB]) -> Pick? {
        choose(swatches(pixels))
    }

    /// The palette from a cover's colours.
    static func choose(_ swatches: [Swatch]) -> Pick? {
        guard !swatches.isEmpty else { return nil }
        let named = self.named(swatches)
        guard let first = named.first else { return neutrals(swatches) }
        let score = swatches.map(score)
        let ranked = swatches.indices.filter { score[$0] > 0 }
            .sorted { score[$0] != score[$1] ? score[$0] > score[$1] : $0 < $1 }

        // Slots the cover has no further colour for take the first's own
        // shades: a lighter one for the accent, a darker for the secondary.
        let base = swatches[first].lab
        let shades = ranked.filter {
            !named.contains($0)
                && sameHue(swatches[$0].lab, base)
                && abs(swatches[$0].lab.l - base.l) >= shadeStep
                && swatches[$0].share >= shadeShare
        }
        let lighter = shades.first { swatches[$0].lab.l > base.l }
        let darker = shades.first { swatches[$0].lab.l < base.l }

        let accent: Int, secondary: Int
        switch named.count {
        case 3:
            accent = named[1]
            secondary = named[2]
        case 2:
            accent = named[1]
            secondary = darker ?? lighter ?? first
        default:
            // Never a darker shade for the accent: on most covers that is
            // the colour's edge against black lettering, and it dulls
            // whatever is drawn in it.
            accent = lighter ?? first
            secondary = darker ?? first
        }
        return Pick(
            primary: rgb(lifted(base, to: primaryFloor)),
            secondary: rgb(lifted(swatches[secondary].lab, to: secondaryFloor)),
            accent: rgb(lifted(swatches[accent].lab, to: accentFloor))
        )
    }

    /// The colours a person would name for the cover, best first: up to
    /// three, as indices into `swatches`. None for a cover with no colour.
    static func named(_ swatches: [Swatch]) -> [Int] {
        let score = swatches.map(score)
        let colourful = swatches.indices.filter { score[$0] > 0 }
        let colourShare = colourful.reduce(0) { $0 + swatches[$1].share }
        guard colourShare >= minColourShare else { return [] }

        // Best first; equal scores keep the order they were found in.
        let ranked = colourful.sorted { score[$0] != score[$1] ? score[$0] > score[$1] : $0 < $1 }
        // Then the best that is a different colour from those already
        // named, twice: its score, marked down while its hue is still
        // close to one of theirs, so that of two colours about as strong
        // the one further round the wheel is taken.
        let floor = score[ranked[0]] * minRelativeScore
        var named = [ranked[0]]
        while named.count < 3 {
            var best: Int?, bestValue = floor
            for i in ranked where !named.contains(i) {
                let apart = named.map { hueGap(swatches[$0].lab, swatches[i].lab) }.min() ?? .pi
                guard apart >= hueStep else { continue }
                let value = score[i] * min(1, apart / hueSpread).squareRoot()
                if value > bestValue {
                    best = i
                    bestValue = value
                }
            }
            guard let best else { break }
            named.append(best)
        }
        return named
    }

    /// Whether one of the cover's colours is a colour at all, judged as
    /// the island would show it: a deep navy is one, though the numbers
    /// for something that dark are small, and a black with a cast isn't.
    static func isColour(_ c: Lab) -> Bool {
        lifted(c, to: primaryFloor).chroma >= neutralChroma
    }

    /// How much a colour is the cover's (zero for a neutral): how much of
    /// the cover it holds, how colourful it is as the island would show
    /// it, and how little it has to be lifted to be shown — a lifted
    /// colour is drawn as something the cover doesn't quite have, so one
    /// that needs no lift is preferred to a darker one of the same
    /// strength.
    static func score(_ s: Swatch) -> Double {
        guard isColour(s.lab) else { return 0 }
        return s.share / (s.share + presencePivot)
            * pow(lifted(s.lab, to: primaryFloor).chroma, chromaPower)
            * min(1, s.lab.l / primaryFloor)
    }

    /// Whether two of the cover's colours are one colour in two shades:
    /// the same hue, whatever their lightness.
    static func sameHue(_ x: Lab, _ y: Lab) -> Bool {
        hueGap(x, y) < hueStep
    }

    /// The angle between two hues, the short way round: 0...π.
    static func hueGap(_ x: Lab, _ y: Lab) -> Double {
        let d = abs(x.hue - y.hue)
        return d > .pi ? 2 * .pi - d : d
    }

    /// A cover with no colour: its lightest neutral that holds a real part
    /// of it on top, and its own darker greys under that.
    private static func neutrals(_ swatches: [Swatch]) -> Pick {
        let order = swatches.indices.sorted {
            let a = light(swatches[$0]), b = light(swatches[$1])
            return a != b ? a > b : $0 < $1
        }
        let top = swatches[order[0]].lab
        func below(_ lab: Lab) -> Lab? {
            order.lazy.map { swatches[$0] }
                .first { $0.lab.l <= lab.l - shadeStep && $0.share >= shadeShare }?.lab
        }
        let mid = below(top) ?? top
        let low = below(mid) ?? mid
        return Pick(
            primary: rgb(lifted(mid, to: primaryFloor)),
            secondary: rgb(lifted(low, to: secondaryFloor)),
            accent: rgb(lifted(top, to: accentFloor))
        )
    }

    private static func light(_ s: Swatch) -> Double {
        s.share / (s.share + presencePivot) * s.lab.l * s.lab.l
    }

    // MARK: - The cover's colours

    /// The cover's colours, from its pixels in any order.
    ///
    /// The pixels are first counted into a coarse RGB histogram in whole
    /// numbers, so the same pixels in a different order give exactly the
    /// same counts, and everything after works from the histogram's cells
    /// in a fixed order: the result depends on the pixels alone.
    static func swatches(_ pixels: [RGB]) -> [Swatch] {
        guard !pixels.isEmpty else { return [] }
        // 5 bits a channel: 32,768 cells, each keeping the sum of the
        // pixels in it, so a cell's colour is their mean, not its corner.
        var cells = [Int](repeating: 0, count: 32_768 * 4)
        for p in pixels {
            let r = byte(p.r), g = byte(p.g), b = byte(p.b)
            let i = ((r >> 3) << 10 | (g >> 3) << 5 | (b >> 3)) * 4
            cells[i] += 1
            cells[i + 1] += r
            cells[i + 2] += g
            cells[i + 3] += b
        }
        var points: [Lab] = [], weights: [Double] = []
        for i in stride(from: 0, to: cells.count, by: 4) where cells[i] > 0 {
            let n = Double(cells[i]) * 255
            points.append(lab(RGB(r: Double(cells[i + 1]) / n, g: Double(cells[i + 2]) / n, b: Double(cells[i + 3]) / n)))
            weights.append(Double(cells[i]))
        }
        return cluster(points, weights, total: Double(pixels.count))
    }

    private static func byte(_ x: Double) -> Int {
        Int((min(1, max(0, x)) * 255).rounded())
    }

    /// k-means over the histogram's cells, started without chance: the
    /// first centre is the heaviest cell, and each further one the cell
    /// that is furthest from every centre so far, counted by the square
    /// root of its weight — so a small subject far from everything else
    /// gets a centre of its own before a large ground gets its fifth.
    ///
    /// Written out over plain buffers rather than with `map` and
    /// `enumerated`: this is the one loop in the picker that runs a few
    /// hundred thousand times, and in a Debug build the tidy version of
    /// it took a tenth of a second on a busy cover.
    private static func cluster(_ points: [Lab], _ weights: [Double], total: Double) -> [Swatch] {
        let n = points.count
        let k = min(clusterCount, n)
        var centres = [Lab](repeating: Lab(l: 0, a: 0, b: 0), count: k)
        var mass = [Double](repeating: 0, count: k)
        var count = 0
        points.withUnsafeBufferPointer { p in
            weights.withUnsafeBufferPointer { w in
                centres.withUnsafeMutableBufferPointer { c in
                    mass.withUnsafeMutableBufferPointer { m in
                        var heaviest = 0
                        var i = 1
                        while i < n {
                            if w[i] > w[heaviest] { heaviest = i }
                            i += 1
                        }
                        c[0] = p[heaviest]
                        count = 1
                        var nearest = [Double](repeating: .infinity, count: n)
                        var owner = [Int](repeating: -1, count: n)
                        var sums = [Double](repeating: 0, count: k * 3)
                        nearest.withUnsafeMutableBufferPointer { near in
                            owner.withUnsafeMutableBufferPointer { own in
                                sums.withUnsafeMutableBufferPointer { sum in
                                    // Seeding.
                                    while true {
                                        let last = c[count - 1]
                                        var best = -1, bestValue = 0.0
                                        i = 0
                                        while i < n {
                                            let dl = p[i].l - last.l, da = p[i].a - last.a, db = p[i].b - last.b
                                            let d = dl * dl + da * da + db * db
                                            if d < near[i] { near[i] = d }
                                            let value = w[i].squareRoot() * near[i]
                                            if value > bestValue { best = i; bestValue = value }
                                            i += 1
                                        }
                                        guard count < k, best >= 0 else { break }
                                        c[count] = p[best]
                                        count += 1
                                    }
                                    // Refinement.
                                    var pass = 0
                                    while pass < maxIterations {
                                        var moved = false
                                        i = 0
                                        while i < n {
                                            var best = 0, bestDistance = Double.infinity
                                            var j = 0
                                            while j < count {
                                                let dl = p[i].l - c[j].l, da = p[i].a - c[j].a, db = p[i].b - c[j].b
                                                let d = dl * dl + da * da + db * db
                                                if d < bestDistance { best = j; bestDistance = d }
                                                j += 1
                                            }
                                            if own[i] != best { own[i] = best; moved = true }
                                            i += 1
                                        }
                                        guard moved else { break }
                                        var j = 0
                                        while j < count {
                                            m[j] = 0
                                            sum[j * 3] = 0; sum[j * 3 + 1] = 0; sum[j * 3 + 2] = 0
                                            j += 1
                                        }
                                        i = 0
                                        while i < n {
                                            let o = own[i]
                                            sum[o * 3] += p[i].l * w[i]
                                            sum[o * 3 + 1] += p[i].a * w[i]
                                            sum[o * 3 + 2] += p[i].b * w[i]
                                            m[o] += w[i]
                                            i += 1
                                        }
                                        j = 0
                                        while j < count {
                                            if m[j] > 0 {
                                                c[j] = Lab(l: sum[j * 3] / m[j], a: sum[j * 3 + 1] / m[j], b: sum[j * 3 + 2] / m[j])
                                            }
                                            j += 1
                                        }
                                        pass += 1
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        return merged((0..<count).compactMap { c in
            mass[c] > 0 ? Swatch(lab: centres[c], share: mass[c] / total) : nil
        })
    }

    /// The grouping always makes `clusterCount` colours, so a plain cover
    /// comes back with one colour cut into several that the eye can't
    /// tell apart. Put those back together: the closest two, while any
    /// two are closer than `mergeDistance`.
    private static func merged(_ swatches: [Swatch]) -> [Swatch] {
        var out = swatches
        while out.count > 1 {
            var pair = (0, 1), closest = Double.infinity
            for i in out.indices {
                for j in out.indices where j > i {
                    let d = distance2(out[i].lab, out[j].lab)
                    if d < closest { closest = d; pair = (i, j) }
                }
            }
            guard closest < mergeDistance * mergeDistance else { break }
            let x = out[pair.0], y = out[pair.1], w = x.share + y.share
            out[pair.0] = Swatch(
                lab: Lab(l: (x.lab.l * x.share + y.lab.l * y.share) / w,
                         a: (x.lab.a * x.share + y.lab.a * y.share) / w,
                         b: (x.lab.b * x.share + y.lab.b * y.share) / w),
                share: w
            )
            out.remove(at: pair.1)
        }
        return out
    }

    private static func distance2(_ x: Lab, _ y: Lab) -> Double {
        let dl = x.l - y.l, da = x.a - y.a, db = x.b - y.b
        return dl * dl + da * da + db * db
    }

    // MARK: - Lifting

    /// The colour raised to at least `floor` lightness with its hue kept.
    ///
    /// Its chroma grows with its lightness (as far as sRGB can show, and
    /// no more than `maxChromaGrowth`), so a deep navy comes up as a blue
    /// rather than a grey. Near black it doesn't: there the eye sees
    /// black whatever cast the numbers have, so what is kept of the chroma
    /// falls away over `blackFade` to nothing at `blackLightness`, and a
    /// black comes up as a grey.
    static func lifted(_ c: Lab, to floor: Double) -> Lab {
        guard c.l < floor else { return c }
        let colour = min(1, max(0, (c.l - blackLightness) / blackFade))
        let k = min(floor / max(c.l, 1e-6), maxChromaGrowth) * colour
        return inGamut(Lab(l: floor, a: c.a * k, b: c.b * k))
    }

    /// The colour with its chroma pulled in, hue and lightness kept, until
    /// sRGB can show it.
    static func inGamut(_ c: Lab) -> Lab {
        func fits(_ k: Double) -> Bool {
            let v = linear(Lab(l: c.l, a: c.a * k, b: c.b * k))
            return min(v.r, v.g, v.b) >= -1e-4 && max(v.r, v.g, v.b) <= 1 + 1e-4
        }
        guard !fits(1) else { return c }
        var lo = 0.0, hi = 1.0
        for _ in 0..<20 {
            let mid = (lo + hi) / 2
            if fits(mid) { lo = mid } else { hi = mid }
        }
        return Lab(l: c.l, a: c.a * lo, b: c.b * lo)
    }

    // MARK: - OKLab

    static func lab(_ c: RGB) -> Lab {
        func lin(_ x: Double) -> Double { x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
        let r = lin(c.r), g = lin(c.g), b = lin(c.b)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return Lab(
            l: 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
            a: 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
            b: 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        )
    }

    static func rgb(_ c: Lab) -> RGB {
        func enc(_ x: Double) -> Double {
            let v = min(1, max(0, x))
            return v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055
        }
        let v = linear(c)
        return RGB(r: enc(v.r), g: enc(v.g), b: enc(v.b))
    }

    /// Linear-light sRGB, unclamped: outside 0...1 is outside the gamut.
    private static func linear(_ c: Lab) -> (r: Double, g: Double, b: Double) {
        let l = c.l + 0.3963377774 * c.a + 0.2158037573 * c.b
        let m = c.l - 0.1055613458 * c.a - 0.0638541728 * c.b
        let s = c.l - 0.0894841775 * c.a - 1.2914855480 * c.b
        let l3 = l * l * l, m3 = m * m * m, s3 = s * s * s
        return (
            4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3,
            -1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3,
            -0.0041960863 * l3 - 0.7034186147 * m3 + 1.7076147010 * s3
        )
    }
}
