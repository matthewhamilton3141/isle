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
//  Prism draws the same bars as lit glass (`EqualizerStyle.glass`). Nothing
//  about the levels or the geometry changes; the bars are a little see-through
//  in the middle and whole at the edge, each has a pale rim, and each casts a
//  glow. The glow is the bars' own shadow *inside the mask*: the gradient
//  shows through the halo as it does through the bar, so a tall bar's glow
//  runs the colour ramp with it and nothing is redrawn to make it.
//

import AppKit
import Combine
import SwiftUI

/// How the waveform's bars are drawn.
enum EqualizerStyle: Equatable {
    /// Solid bars in the gradient: every mode but Prism.
    case flat
    /// Lit glass: Prism.
    case glass
}

final class EqualizerLayerView: NSView {

    // MARK: - Geometry, matching the Canvas renderer this replaced

    private let barCount: Int
    /// Thickness of a bar. Held constant across every strip the waveform is
    /// drawn into, so the collapsed island's two layouts show the same object
    /// at the same weight rather than a thick version and a thin one — the
    /// spacing is what gives when the strip is narrower. Matched to
    /// `dotHeight` so silence resolves to actual circles.
    private let barThickness: CGFloat
    /// Height of a bar at complete silence — the "dot" resting state.
    private let dotHeight: CGFloat

    // MARK: - Lit glass (tune here)

    /// How much of the gradient shows through the middle of a glass bar; its
    /// edge, `glassEdge` wide, is whole. The bars are the size and in the
    /// places they are flat: thicker, a narrow strip's bars ran together
    /// into one ribbed block.
    private static let glassBody: Float = 0.78
    private static let glassEdge: CGFloat = 0.5
    /// The pale rim over that edge.
    private static let rimWhite: Float = 0.55
    /// The glow: how far it spreads, in points, and how strong it is next to
    /// the bar.
    private static let glowRadius: CGFloat = 3
    private static let glowOpacity: Float = 1
    /// How far outside the strip the layers reach, so the glow isn't cut
    /// off at the strip's edge.
    private static let glowReach: CGFloat = 10
    private var reach: CGFloat { style == .glass ? Self.glowReach : 0 }

    /// Floor on the gap between bars. Below this the strip stops reading as
    /// separate bars, so past it the thickness gives way instead — better a
    /// thinner waveform than a solid block.
    private static let minSpacing: CGFloat = 1.2

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
    /// Glass only: the rims, white through a mask of bar outlines that
    /// move with the bars.
    private let rim = CALayer()
    private let rimMask = CALayer()
    private var rims: [CALayer] = []

    private var style: EqualizerStyle = .flat
    private var builtStyle: EqualizerStyle = .flat

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

    init(barCount: Int = 6, barThickness: CGFloat = 2.5, dotHeight: CGFloat = 2.5) {
        self.barCount = barCount
        self.barThickness = barThickness
        self.dotHeight = dotHeight
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        gradient.mask = barMask
        layer?.addSublayer(gradient)
        rim.backgroundColor = NSColor.white.cgColor
        rim.opacity = Self.rimWhite
        rim.mask = rimMask
        rim.isHidden = true
        layer?.addSublayer(rim)
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

    /// Stop following the capture and rest on the procedural pattern. A no-op
    /// when nothing is attached, so the representable can call it every update.
    func detach() {
        guard source != nil else { return }
        subscription = nil
        source = nil
        setLevels([])
    }

    func configure(palette: ArtworkPalette, isPlaying: Bool, style: EqualizerStyle = .flat) {
        let modeWas = mode
        self.palette = palette
        self.isPlaying = isPlaying
        self.style = style
        if palette != builtPalette { applyGradient() }
        if mode != modeWas || style != builtStyle { rebuild() }
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
        builtStyle = style
        guard size.width > 0, size.height > 0 else { return }

        makeBars()
        applyGradient()

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // The layers reach past the strip by the glow's reach (nothing, flat);
        // the bars stand where they always did.
        let reach = reach
        let frame = CGRect(origin: .zero, size: size).insetBy(dx: -reach, dy: -reach)
        gradient.frame = frame
        barMask.frame = CGRect(origin: .zero, size: frame.size)
        rim.frame = frame
        rimMask.frame = barMask.frame
        rim.isHidden = style != .glass

        let (barWidth, spacing) = geometry(for: size)
        for index in 0..<barCount {
            for piece in pieces(index) {
                piece.removeAllAnimations()
                piece.anchorPoint = CGPoint(x: 0.5, y: 0.5)
                piece.position = CGPoint(
                    x: reach + CGFloat(index) * (barWidth + spacing) + barWidth / 2,
                    y: reach + size.height / 2
                )
            }
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
        if bars.count != barCount {
            bars.forEach { $0.removeFromSuperlayer() }
            bars = (0..<barCount).map { _ in
                let bar = CALayer()
                barMask.addSublayer(bar)
                return bar
            }
        }
        let glass = style == .glass
        if glass, rims.count != barCount {
            rims.forEach { $0.removeFromSuperlayer() }
            rims = (0..<barCount).map { _ in
                let outline = CALayer()
                outline.borderColor = NSColor.black.cgColor
                outline.borderWidth = Self.glassEdge
                rimMask.addSublayer(outline)
                return outline
            }
        }
        for bar in bars {
            // These layers are a mask, so their alpha is what shows the
            // gradient through. The colour itself is never seen. Flat, a
            // bar is opaque. Glass, its middle lets a little less through
            // than its edge, and its shadow lets the gradient through
            // round it: the glow.
            bar.backgroundColor = NSColor.black.withAlphaComponent(glass ? CGFloat(Self.glassBody) : 1).cgColor
            bar.borderColor = NSColor.black.cgColor
            bar.borderWidth = glass ? Self.glassEdge : 0
            bar.shadowColor = NSColor.black.cgColor
            bar.shadowOffset = .zero
            bar.shadowRadius = glass ? Self.glowRadius : 0
            bar.shadowOpacity = glass ? Self.glowOpacity : 0
        }
    }

    /// The layers that are bar `index`: the bar, and in glass its rim.
    private func pieces(_ index: Int) -> [CALayer] {
        style == .glass && rims.count == barCount ? [bars[index], rims[index]] : [bars[index]]
    }

    private func applyGradient() {
        builtPalette = palette
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Bottom to top, primary to accent. The view is unflipped, so the
        // layer's unit space puts (0.5, 0) at the bottom — matching the Canvas
        // version, which ran its gradient from y = height up to y = 0.
        // The ramp spans the strip, not the glow's reach round it.
        let tall = builtSize.height + 2 * reach
        let inset = tall > 0 ? reach / tall : 0
        gradient.startPoint = CGPoint(x: 0.5, y: inset)
        gradient.endPoint = CGPoint(x: 0.5, y: 1 - inset)
        gradient.colors = [
            NSColor(palette.primary).cgColor,
            NSColor(palette.accent).cgColor
        ]
        CATransaction.commit()
    }

    // MARK: - Bar geometry

    /// Bar thickness and the gap between bars for a given strip.
    ///
    /// The thickness is the fixed quantity and the spacing is derived, which is
    /// the inverse of how this used to work — deriving the thickness from a
    /// fixed spacing meant a narrower strip silently drew thinner bars, and the
    /// island's two layouts ended up showing the same waveform at two different
    /// weights.
    private func geometry(for size: CGSize) -> (barWidth: CGFloat, spacing: CGFloat) {
        let gaps = CGFloat(barCount - 1)
        let spacing = (size.width - barThickness * CGFloat(barCount)) / gaps
        guard spacing < Self.minSpacing else { return (barThickness, spacing) }
        // Too narrow to seat full-weight bars: hold the gaps at the floor and
        // let the bars take the shortfall.
        return (max(1, (size.width - Self.minSpacing * gaps) / CGFloat(barCount)), Self.minSpacing)
    }

    /// The height a bar takes at a given level, and the radius that rounds it.
    /// Grows from the dot outward, half above centre and half below.
    private func barHeight(level: Double, size: CGSize) -> CGFloat {
        max(dotHeight, size.height * CGFloat(min(max(level, 0), 1)))
    }

    private func setBar(_ index: Int, level: Double, size: CGSize, barWidth: CGFloat) {
        let full = barHeight(level: level, size: size)
        for bar in pieces(index) {
            bar.bounds = CGRect(x: 0, y: 0, width: barWidth, height: full)
            // CoreGraphics clamps a rounded rect's corner to half the smaller side,
            // so a bar shorter than it is wide reads as a pill. Match that, or a
            // resting dot would render as a square.
            bar.cornerRadius = min(barWidth, full) / 2
        }
    }

    private func applyLiveLevels() {
        let size = builtSize
        guard size.width > 0, bars.count == barCount else { return }
        let barWidth = geometry(for: size).barWidth
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

            for bar in pieces(index) {
                bar.bounds = CGRect(x: 0, y: 0, width: barWidth, height: heights[0] as! CGFloat)
                bar.cornerRadius = radii[0] as! CGFloat
                bar.add(loop(heights, keyPath: "bounds.size.height", duration: period, beginTime: now),
                        forKey: "height")
                bar.add(loop(radii, keyPath: "cornerRadius", duration: period, beginTime: now),
                        forKey: "radius")
            }
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
