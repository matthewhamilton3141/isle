//
//  EqualizerLayer.swift
//
//  The waveform, drawn as layers rather than redrawn as a picture.
//
//  Six bars is trivial to draw; what cost was asking SwiftUI to draw them. Real
//  levels arrive 30 times a second, and each arrival re-ran a Canvas through the
//  view graph and the display list to move six rectangles. Here the bars are six
//  CALayers and a level update just sets their geometry — no view graph, no
//  display list, no redraw.
//
//  The colour is unchanged, and deliberately so: one vertical gradient spanning
//  the whole strip, bottom to top, which every bar samples over its own height.
//  A short bar only reaches the middle of the ramp while a tall one runs the
//  length of it, which is what makes the colour encode amplitude. That's why the
//  gradient is a single full-height layer *masked* by the bars, rather than a
//  gradient per bar — per-bar would restart the ramp in each one and lose it.
//
//  The procedural fallback (no audio tap) needs no updates at all: each bar is
//  its own sine, so each gets a keyframe loop on its own exact period and the
//  render server plays them.
//

import AppKit
import Combine
import SwiftUI

final class EqualizerLayerView: NSView {

    // MARK: - Geometry, matching the Canvas renderer this replaced

    private let barCount: Int
    private let spacing: CGFloat
    /// Height of a bar at complete silence — the "dot" resting state.
    private let dotHeight: CGFloat

    /// Per-bar frequency multipliers for the fallback pattern. Deliberately not
    /// evenly spaced, or the bars visibly march in a wave.
    private static let frequencies: [Double] = [1.00, 1.37, 0.83, 1.61, 1.13, 0.71]
    private static let phases: [Double] = [0.0, 0.9, 1.8, 0.45, 2.3, 1.35]

    /// Keyframes per second for the fallback loops. They're plain sines and Core
    /// Animation interpolates between samples, so this is a sampling rate, not a
    /// frame rate.
    private static let sampleRate: Double = 30

    // MARK: - State

    private let gradient = CAGradientLayer()
    private let barMask = CALayer()
    private var bars: [CALayer] = []

    private var palette: ArtworkPalette = .fallback
    private var isPlaying: Bool = true
    /// Real per-band magnitudes, 0...1. Fewer than `barCount` means fall back to
    /// the procedural pattern.
    private var levels: [Double] = []

    private var source: SystemAudioLevels?
    private var subscription: AnyCancellable?

    private var builtSize: CGSize = .zero
    private var builtMode: Mode = .resting
    private var builtPalette: ArtworkPalette = .fallback

    private enum Mode: Equatable { case live, procedural, resting }

    private var mode: Mode {
        if levels.count >= barCount { return .live }
        return isPlaying ? .procedural : .resting
    }

    // MARK: - Init

    init(barCount: Int = 6, spacing: CGFloat = 2.0, dotHeight: CGFloat = 2.5) {
        self.barCount = barCount
        self.spacing = spacing
        self.dotHeight = dotHeight
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        gradient.mask = barMask
        layer?.addSublayer(gradient)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Input

    /// The live path. The view subscribes to the levels itself rather than being
    /// handed them through SwiftUI, so a level change never reaches the view
    /// graph — it only moves six layers.
    func attach(to source: SystemAudioLevels) {
        guard self.source !== source else { return }
        self.source = source
        subscription = source.$levels
            .sink { [weak self] levels in
                MainActor.assumeIsolated { self?.setLevels(levels) }
            }
    }

    func configure(palette: ArtworkPalette, isPlaying: Bool) {
        let modeWas = mode
        self.palette = palette
        self.isPlaying = isPlaying
        if palette != builtPalette { applyGradient() }
        if mode != modeWas { rebuild() }
    }

    /// Static levels, for the previews and the gallery.
    func setStaticLevels(_ levels: [Double]) { setLevels(levels) }

    private func setLevels(_ next: [Double]) {
        let modeWas = mode
        levels = next
        if mode != modeWas { rebuild(); return }
        if mode == .live { applyLiveLevels() }
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        guard bounds.size != builtSize else { return }
        rebuild()
    }

    // MARK: - Build

    private func rebuild() {
        let size = bounds.size
        builtSize = size
        builtMode = mode
        guard size.width > 0, size.height > 0 else { return }

        makeBars()
        applyGradient()

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        gradient.frame = CGRect(origin: .zero, size: size)
        barMask.frame = CGRect(origin: .zero, size: size)

        let barWidth = self.barWidth(for: size)
        for index in 0..<barCount {
            let bar = bars[index]
            bar.removeAllAnimations()
            bar.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            bar.position = CGPoint(
                x: CGFloat(index) * (barWidth + spacing) + barWidth / 2,
                y: size.height / 2
            )
        }

        switch mode {
        case .live:
            applyLiveLevels()
        case .resting:
            for index in 0..<barCount { setBar(index, level: 0, size: size, barWidth: barWidth) }
        case .procedural:
            installProceduralLoops(size: size, barWidth: barWidth)
        }

        CATransaction.commit()
    }

    private func makeBars() {
        guard bars.count != barCount else { return }
        bars.forEach { $0.removeFromSuperlayer() }
        bars = (0..<barCount).map { _ in
            let bar = CALayer()
            // Opaque: this layer is a mask, so its alpha is what shows the
            // gradient through. The colour itself is never seen.
            bar.backgroundColor = NSColor.black.cgColor
            barMask.addSublayer(bar)
            return bar
        }
    }

    private func applyGradient() {
        builtPalette = palette
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Bottom to top, primary to accent. The view is unflipped, so the
        // layer's unit space puts (0.5, 0) at the bottom — matching the Canvas
        // version, which ran its gradient from y = height up to y = 0.
        gradient.startPoint = CGPoint(x: 0.5, y: 0)
        gradient.endPoint = CGPoint(x: 0.5, y: 1)
        gradient.colors = [
            NSColor(palette.primary).cgColor,
            NSColor(palette.accent).cgColor
        ]
        CATransaction.commit()
    }

    // MARK: - Bar geometry

    private func barWidth(for size: CGSize) -> CGFloat {
        max(1, (size.width - spacing * CGFloat(barCount - 1)) / CGFloat(barCount))
    }

    /// The height a bar takes at a given level, and the radius that rounds it.
    /// Grows from the dot outward, half above centre and half below.
    private func barHeight(level: Double, size: CGSize) -> CGFloat {
        max(dotHeight, size.height * CGFloat(min(max(level, 0), 1)))
    }

    private func setBar(_ index: Int, level: Double, size: CGSize, barWidth: CGFloat) {
        let full = barHeight(level: level, size: size)
        let bar = bars[index]
        bar.bounds = CGRect(x: 0, y: 0, width: barWidth, height: full)
        // CoreGraphics clamps a rounded rect's corner to half the smaller side,
        // so a bar shorter than it is wide reads as a pill. Match that, or a
        // resting dot would render as a square.
        bar.cornerRadius = min(barWidth, full) / 2
    }

    private func applyLiveLevels() {
        let size = builtSize
        guard size.width > 0, bars.count == barCount else { return }
        let barWidth = self.barWidth(for: size)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for index in 0..<barCount {
            setBar(index, level: levels[index], size: size, barWidth: barWidth)
        }
        CATransaction.commit()
    }

    // MARK: - Procedural fallback

    /// Each bar is its own sine at its own frequency, so each loops on its own
    /// exact period — no common multiple to find, and nothing approximated.
    private func installProceduralLoops(size: CGSize, barWidth: CGFloat) {
        let now = CACurrentMediaTime()
        let clockNow = Date.timeIntervalSinceReferenceDate

        for index in 0..<barCount {
            let frequency = Self.frequencies[index % Self.frequencies.count]
            let phase = Self.phases[index % Self.phases.count]
            let period = 2 * .pi / (frequency * 3.1)
            let count = max(2, Int((period * Self.sampleRate).rounded()))

            var heights: [Any] = []
            var radii: [Any] = []
            heights.reserveCapacity(count + 1)
            radii.reserveCapacity(count + 1)
            for step in 0...count {
                let clock = clockNow + period * Double(step % count) / Double(count)
                let wave = sin(clock * frequency * 3.1 + phase)
                let level = 0.18 + (wave + 1) / 2 * 0.72
                let full = barHeight(level: level, size: size)
                heights.append(full)
                radii.append(min(barWidth, full) / 2)
            }

            let bar = bars[index]
            bar.bounds = CGRect(x: 0, y: 0, width: barWidth, height: heights[0] as! CGFloat)
            bar.cornerRadius = radii[0] as! CGFloat
            bar.add(loop(heights, keyPath: "bounds.size.height", duration: period, beginTime: now),
                    forKey: "height")
            bar.add(loop(radii, keyPath: "cornerRadius", duration: period, beginTime: now),
                    forKey: "radius")
        }
    }

    private func loop(
        _ values: [Any], keyPath: String, duration: Double, beginTime: CFTimeInterval
    ) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = values
        animation.duration = max(duration, 0.001)
        animation.calculationMode = .linear
        animation.beginTime = beginTime
        animation.repeatCount = .greatestFiniteMagnitude
        animation.fillMode = .forwards
        animation.isRemovedOnCompletion = false
        return animation
    }
}
