//
//  DotMatrixLayer.swift
//
//  The Core Animation half of the marker renderer. Builds one circle layer per
//  dot and gives each the whole of its animation up front, as keyframes, so the
//  render server plays it and this process stays asleep.
//
//  Three curves per dot, on three separate looping animations:
//
//    opacity          the intensity curve, on the animation's period
//    transform.scale  the radius curve, on the same period
//    backgroundColor  the hue drift, on its own (usually much longer) period
//
//  They're separate because they genuinely loop on different clocks — a marker
//  might pulse every 4 seconds while its palette drifts over 20 — and folding
//  them into one animation would force the loop out to the common multiple of
//  both and multiply the keyframe count for nothing. Layer opacity multiplies
//  into the background colour's alpha, which is exactly how `Color.opacity`
//  behaved in the Canvas version, so splitting them is not an approximation.
//
//  See DotMatrixView.swift for the curves themselves.
//

import AppKit
import SwiftUI

final class DotMatrixLayerView: NSView {

    /// Keyframes per second of loop. The curves are smooth and Core Animation
    /// interpolates between keyframes, so this is a sampling rate rather than a
    /// frame rate — it doesn't cap how smoothly the result plays.
    private static let sampleRate: Double = 30

    /// Hue drifts far more slowly than intensity does, so it's sampled coarser.
    private static let colorSampleRate: Double = 10

    /// Ceiling on keyframes for one loop, so the long `motion` window can't turn
    /// into an unreasonable amount of data. Past this the sampling rate drops
    /// instead of the loop shortening.
    private static let maxKeyframes = 600

    private struct Config: Equatable {
        var design: MarkerDesign
        var colors: DotColors
    }

    private var config: Config?
    private var levels: [Double] = []

    /// The last inputs handed to `apply`, compared before anything is derived
    /// from them. `DotColors` costs four `Color`→`NSColor` bridges and a hex
    /// parse to build, and `apply` runs on every body evaluation of the view
    /// above it — so without this the colours were resolved every time just
    /// to find out nothing had changed.
    private var appliedDesign: MarkerDesign?
    private var appliedPalette: ArtworkPalette?
    private var appliedTint: Color?
    private var dotLayers: [CALayer] = []
    private var builtSize: CGSize = .zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Layers are positioned from the top down, matching the Canvas renderer
    /// this replaced (row 0 is the top row).
    override var isFlipped: Bool { true }

    // MARK: - Input

    func apply(design: MarkerDesign, palette: ArtworkPalette, tint: Color?, animateMorph: Bool) {
        guard design != appliedDesign || palette != appliedPalette || tint != appliedTint else { return }
        appliedDesign = design
        appliedPalette = palette
        appliedTint = tint

        let next = Config(design: design, colors: DotColors(design: design, palette: palette, tint: tint))
        guard next != config else { return }

        let previousLevels = levels
        let previousDots = config?.design.dots
        config = next
        levels = DotMatrixCurves.levels(for: design)

        // Only a changed lit-dot layout morphs. A colour, speed or animation
        // change rebuilds the loop in place, which is what the Canvas version
        // did by reading those straight from `design` each frame.
        let layoutChanged = previousDots != design.dots
        rebuild(morphingFrom: animateMorph && layoutChanged ? previousLevels : nil)
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        guard bounds.size != builtSize else { return }
        rebuild(morphingFrom: nil)
    }

    // MARK: - Build

    private func rebuild(morphingFrom previousLevels: [Double]?) {
        guard let config, let host = layer else { return }
        let size = bounds.size
        builtSize = size
        guard size.width > 0, size.height > 0 else { return }

        let n = MarkerDesign.dimension
        let cell = min(size.width, size.height) / CGFloat(n)
        let ox = (size.width - cell * CGFloat(n)) / 2
        let oy = (size.height - cell * CGFloat(n)) / 2

        let curves = DotMatrixCurves(
            design: config.design, levels: levels, colors: config.colors, cell: Double(cell)
        )
        let maxRadius = curves.maxRadius
        let diameter = maxRadius * 2

        makeLayers(count: MarkerDesign.dotCount, in: host)

        // One clock for the whole grid. The curves are functions of absolute
        // time, so anchoring every loop to the same instant keeps dots in the
        // phase relationship the design describes, and keeps a rebuild
        // (a new palette, say) from visibly restarting the animation.
        let now = CACurrentMediaTime()
        let clockNow = Date.timeIntervalSinceReferenceDate
        let morphDuration = previousLevels == nil ? 0 : DotMatrixCurves.morphDuration

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        for row in 0..<n {
            for col in 0..<n {
                let index = row * n + col
                let dot = dotLayers[index]

                dot.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
                dot.cornerRadius = maxRadius
                dot.position = CGPoint(
                    x: ox + (CGFloat(col) + 0.5) * cell,
                    y: oy + (CGFloat(row) + 0.5) * cell
                )
                dot.removeAllAnimations()

                install(
                    on: dot, row: row, col: col, index: index,
                    curves: curves, previousLevels: previousLevels,
                    now: now, clockNow: clockNow, morphDuration: morphDuration
                )
            }
        }

        CATransaction.commit()
    }

    private func makeLayers(count: Int, in host: CALayer) {
        guard dotLayers.count != count else { return }
        dotLayers.forEach { $0.removeFromSuperlayer() }
        dotLayers = (0..<count).map { _ in
            let dot = CALayer()
            dot.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            dot.allowsEdgeAntialiasing = true
            host.addSublayer(dot)
            return dot
        }
    }

    // MARK: - Animations

    private func install(
        on dot: CALayer, row: Int, col: Int, index: Int,
        curves: DotMatrixCurves, previousLevels: [Double]?,
        now: CFTimeInterval, clockNow: Double, morphDuration: Double
    ) {
        let level = levels[index]

        // The steady loop, phase-aligned to wall-clock so it picks up exactly
        // where the curve is now rather than restarting at zero.
        let period = curves.animationPeriod
        let start = clockNow + morphDuration

        // `looped` cross-fades the tail into the head for a baked loop, so the
        // wrap is continuous — see DotMatrixCurves.loopBlend. Colour is left
        // alone: it always loops on its own exact period and has no seam.
        let opacity = keyframes(period: period, rate: Self.sampleRate) { clock in
            curves.looped(clock) { c in
                curves.opacity(row: row, col: col, clock: start + c, level: level)
            }
        }
        let scale = keyframes(period: period, rate: Self.sampleRate) { clock in
            curves.looped(clock) { c in
                curves.scale(row: row, col: col, clock: start + c, level: level)
            }
        }
        let colorPeriod = curves.colorPeriod
        let colors = keyframes(period: colorPeriod, rate: Self.colorSampleRate) { clock in
            curves.colors.rgba(row: row, col: col, clock: start + clock).opaqueCGColor
        }

        // Settle the model values on the loop's first frame, so a layer that is
        // never animated (or whose animation is stripped) still looks right.
        dot.opacity = Float(opacity.first as? Double ?? 0)
        dot.setValue(scale.first as? Double ?? 0, forKeyPath: "transform.scale")
        dot.backgroundColor = (colors.first as! CGColor)

        // The morph: a one-shot run from where the dot was to where the loop
        // begins, so dots slide on and off when the design's layout changes.
        // `.forwards` fill holds its end value until the loop takes over, and
        // the loop's later `beginTime` keeps the two from fighting.
        if let previousLevels, index < previousLevels.count, morphDuration > 0 {
            let from = previousLevels[index]
            if from != level {
                let steps = max(2, Int(morphDuration * Self.sampleRate))
                var morphOpacity: [Double] = []
                var morphScale: [Double] = []
                morphOpacity.reserveCapacity(steps)
                morphScale.reserveCapacity(steps)
                for step in 0..<steps {
                    let raw = Double(step) / Double(steps - 1)
                    let t = raw * raw * (3 - 2 * raw)          // smoothstep
                    let blended = from + (level - from) * t
                    let clock = clockNow + raw * morphDuration
                    morphOpacity.append(
                        curves.opacity(row: row, col: col, clock: clock, level: blended))
                    morphScale.append(
                        curves.scale(row: row, col: col, clock: clock, level: blended))
                }
                dot.add(
                    loop(morphOpacity as [Any], keyPath: "opacity",
                         duration: morphDuration, beginTime: now, repeats: false),
                    forKey: "morphOpacity")
                dot.add(
                    loop(morphScale as [Any], keyPath: "transform.scale",
                         duration: morphDuration, beginTime: now, repeats: false),
                    forKey: "morphScale")
            }
        }

        let loopStart = now + morphDuration
        dot.add(loop(opacity, keyPath: "opacity", duration: period, beginTime: loopStart),
                forKey: "opacity")
        dot.add(loop(scale, keyPath: "transform.scale", duration: period, beginTime: loopStart),
                forKey: "scale")
        dot.add(loop(colors, keyPath: "backgroundColor", duration: colorPeriod, beginTime: loopStart),
                forKey: "color")
    }

    /// Samples one full period, repeating the first value as the last so the
    /// loop closes on itself instead of stepping at the seam.
    private func keyframes(
        period: Double, rate: Double, _ value: (Double) -> Any
    ) -> [Any] {
        let count = min(Self.maxKeyframes, max(2, Int((period * rate).rounded())))
        var values: [Any] = []
        values.reserveCapacity(count + 1)
        for step in 0..<count {
            values.append(value(period * Double(step) / Double(count)))
        }
        values.append(values[0])
        return values
    }

    private func loop(
        _ values: [Any], keyPath: String, duration: Double,
        beginTime: CFTimeInterval, repeats: Bool = true
    ) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = values
        animation.duration = max(duration, 0.001)
        animation.calculationMode = .linear
        animation.beginTime = beginTime
        animation.repeatCount = repeats ? .greatestFiniteMagnitude : 1
        // Never `.backwards`. The loop's `beginTime` sits after the morph, and a
        // backwards fill would apply its first value during that window —
        // clobbering the morph it is supposed to be waiting for. With no
        // backwards fill it contributes nothing until it starts, so the morph's
        // forwards fill holds the dot until the loop takes over.
        animation.fillMode = .forwards
        animation.isRemovedOnCompletion = false
        return animation
    }
}
