//
//  DetachTrace.swift
//
//  The line that runs round the island while it's being held: from the
//  bottom centre of its outline, both ways at once, up the two sides to
//  meet at the top where the island joins the notch. When the ends meet
//  the island comes loose (see `IslandHold`, `IslandCarry`). Let go early
//  and it runs back.
//
//  Core Animation, start to finish. The run is a pure function of time, so
//  it's handed to the render server once — a `strokeEnd` animation on two
//  shape layers — and nothing here is evaluated per frame: no TimelineView,
//  no state stepped on a clock. SwiftUI only says which phase it's in.
//
//  With Reduce Motion nothing travels: the whole outline fades up over the
//  same time instead.
//
//  The line is drawn just inside the outline (a stroke twice the width,
//  clipped to the outline's interior), so it sits on the island rather than
//  half on the desktop, and the top edge — flush with the top of the screen
//  on the notch — shows its full width.
//

import AppKit
import QuartzCore
import SwiftUI

/// What the line is doing.
enum DetachTracePhase: Equatable {
    /// Nothing drawn.
    case idle
    /// Running from the bottom centre to the top, over `duration` seconds.
    /// `topGap` is the width at the top centre it stops short of (the
    /// camera housing; see `DetachTraceGeometry.halves`).
    case running(duration: TimeInterval, topGap: CGFloat)
    /// Let go early: running back to where it started.
    case retracting
    /// The ends met: the whole outline, fading away.
    case completed
}

/// One island's line. A model of its own, like the proximity swell's, so a
/// change of phase re-evaluates the trace's view and nothing else — not the
/// root view and the faces, which observe `IslandPresentation` itself.
@MainActor
final class DetachTraceModel: ObservableObject {
    @Published private(set) var phase: DetachTracePhase = .idle

    /// How long the line takes to run back, and to fade once it has met.
    static let retractDuration: TimeInterval = 0.18
    static let fadeDuration: TimeInterval = 0.28

    /// Bumped by every change, so a tidy-up scheduled by an earlier phase
    /// leaves a newer one alone.
    private var generation = 0

    func run(for duration: TimeInterval, topGap: CGFloat) {
        generation += 1
        phase = .running(duration: duration, topGap: topGap)
    }

    /// The hold ended early. Back to idle once the line has run back.
    func retract() {
        guard case .running = phase else { return }
        generation += 1
        phase = .retracting
        clear(after: Self.retractDuration)
    }

    /// The ends met. Back to idle once the outline has faded.
    func complete() {
        guard case .running = phase else { return }
        generation += 1
        phase = .completed
        clear(after: Self.fadeDuration)
    }

    /// Gone, now.
    func clear() {
        generation += 1
        if phase != .idle { phase = .idle }
    }

    /// Takes the view out of the tree once there's nothing left to draw —
    /// a tidy-up after the animation, not part of it.
    private func clear(after delay: TimeInterval) {
        let scheduled = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.05) { [weak self] in
            guard let self, self.generation == scheduled else { return }
            self.phase = .idle
        }
    }
}

/// The line, over the island: NotchRootView lays it on the island's outline
/// at the outline's size. Draws nothing, and has no view in the tree, while
/// idle — and never in the glass window's tree, which draws the material
/// alone.
struct DetachTrace<Outline: Shape>: View {
    @ObservedObject var model: DetachTraceModel
    var outline: Outline
    var size: CGSize

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.islandGlassLayer) private var glassLayer

    var body: some View {
        if glassLayer != .materialOnly, model.phase != .idle, size.width > 0, size.height > 0 {
            DetachTraceRepresentable(
                outline: outline.path(in: CGRect(origin: .zero, size: size)).cgPath,
                phase: model.phase,
                reduceMotion: reduceMotion
            )
            .frame(width: size.width, height: size.height)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

private struct DetachTraceRepresentable: NSViewRepresentable {
    var outline: CGPath
    var phase: DetachTracePhase
    var reduceMotion: Bool

    func makeNSView(context: Context) -> DetachTraceView {
        DetachTraceView()
    }

    func updateNSView(_ view: DetachTraceView, context: Context) {
        view.update(outline: outline, phase: phase, reduceMotion: reduceMotion)
    }
}

/// The layers: two stroked halves of the outline, glowing as one, under one
/// clip.
final class DetachTraceView: NSView {
    /// The visible width of the line, in points, and its glow.
    static let lineWidth: CGFloat = 1.75
    static let glowRadius: CGFloat = 3.5

    /// Everything, clipped to the inside of the outline. Fades as one.
    private let clip = CALayer()
    private let clipMask = CAShapeLayer()
    /// The two halves together, which is what glows: a glow on each would
    /// double up where they start, as a bright spot at the bottom centre.
    private let lines = CALayer()
    private let left = CAShapeLayer()
    private let right = CAShapeLayer()

    /// The outline the layers were last given, and the gap at its top.
    private var drawn: (outline: CGPath, topGap: CGFloat)?
    private var applied: (phase: DetachTracePhase, reduceMotion: Bool)?
    /// A phase asked for before the view was in a window, started when it is.
    private var pending: (phase: DetachTracePhase, reduceMotion: Bool)?

    // The outline arrives in SwiftUI's coordinates, y down.
    override var isFlipped: Bool { true }

    // Never in the way of a click.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        clipMask.fillColor = NSColor.white.cgColor
        clip.mask = clipMask
        clip.opacity = 0
        for line in [left, right] {
            line.fillColor = nil
            line.strokeColor = NSColor.white.cgColor
            // Twice the visible width: the outer half is clipped away.
            line.lineWidth = Self.lineWidth * 2
            line.lineCap = .round
            line.lineJoin = .round
            line.strokeEnd = 0
            lines.addSublayer(line)
        }
        // The glow: a shadow of whatever the lines have drawn so far, so it
        // follows them as they grow.
        lines.shadowColor = NSColor.white.cgColor
        lines.shadowOffset = .zero
        lines.shadowRadius = Self.glowRadius
        lines.shadowOpacity = 0.85
        clip.addSublayer(lines)
        layer?.addSublayer(clip)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clip.frame = bounds
        clipMask.frame = clip.bounds
        lines.frame = clip.bounds
        left.frame = lines.bounds
        right.frame = lines.bounds
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, let pending else { return }
        self.pending = nil
        start(pending.phase, after: nil, reduceMotion: pending.reduceMotion)
    }

    func update(outline: CGPath, phase: DetachTracePhase, reduceMotion: Bool) {
        var gap = drawn?.topGap ?? 0
        if case .running(_, let topGap) = phase { gap = topGap }
        // Once the ends have met the line stays on the outline it ran
        // round, and fades there, whatever the island is turning into.
        if phase != .completed || drawn == nil {
            draw(outline, topGap: gap)
        }
        guard applied?.phase != phase || applied?.reduceMotion != reduceMotion else { return }
        let previous = applied?.phase
        applied = (phase, reduceMotion)
        if window == nil {
            // Not on screen yet: an animation added now would be measured
            // from before the layers were committed.
            pending = (phase, reduceMotion)
        } else {
            pending = nil
            start(phase, after: previous, reduceMotion: reduceMotion)
        }
    }

    /// Gives the layers their paths: the outline as the clip, its two
    /// halves as the lines.
    private func draw(_ outline: CGPath, topGap: CGFloat) {
        if let drawn, drawn.outline == outline, drawn.topGap == topGap { return }
        drawn = (outline, topGap)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clipMask.path = outline
        let halves = DetachTraceGeometry.halves(of: outline, topGap: topGap)
        left.path = halves?.left
        right.path = halves?.right
        CATransaction.commit()
    }

    // MARK: - Phases

    private func start(_ phase: DetachTracePhase, after previous: DetachTracePhase?, reduceMotion: Bool) {
        switch phase {
        case .idle:
            set(progress: 0, opacity: 0)
        case .running(let duration, _):
            // From nothing — or, pressed again while the last line was
            // still running back, from wherever that has got to.
            let resumes = previous == .retracting
            if reduceMotion {
                // Nothing travels: the whole outline, fading up.
                let from = resumes ? CGFloat(shown.opacity) : 0
                set(progress: 1, opacity: 0)
                animate(clip, "opacity", from: from, to: 1, over: duration, timing: CAMediaTimingFunction(name: .linear))
            } else {
                let from = resumes ? shown : (left: 0, right: 0, opacity: 1)
                set(progress: 0, opacity: 1)
                // Gently eased at both ends: it gathers from the bottom
                // centre and slows into the meeting at the top.
                let timing = CAMediaTimingFunction(controlPoints: 0.35, 0, 0.65, 1)
                animate(left, "strokeEnd", from: from.left, to: 1, over: duration, timing: timing)
                animate(right, "strokeEnd", from: from.right, to: 1, over: duration, timing: timing)
            }
        case .retracting:
            let timing = CAMediaTimingFunction(name: .easeOut)
            let from = shown
            if reduceMotion {
                animate(clip, "opacity", from: CGFloat(from.opacity), to: 0,
                        over: DetachTraceModel.retractDuration, timing: timing)
            } else {
                animate(left, "strokeEnd", from: from.left, to: 0, over: DetachTraceModel.retractDuration, timing: timing)
                animate(right, "strokeEnd", from: from.right, to: 0, over: DetachTraceModel.retractDuration, timing: timing)
            }
        case .completed:
            set(progress: 1, opacity: 1)
            animate(clip, "opacity", from: 1, to: 0, over: DetachTraceModel.fadeDuration,
                    timing: CAMediaTimingFunction(name: .easeOut))
        }
    }

    /// Where the line is right now, with nothing in flight.
    private func set(progress: CGFloat, opacity: Float) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for line in [left, right] {
            line.removeAnimation(forKey: Self.animationKey)
            line.strokeEnd = progress
        }
        clip.removeAnimation(forKey: Self.animationKey)
        clip.opacity = opacity
        CATransaction.commit()
    }

    /// One animation, handed to the render server once: from `from` to
    /// `value`, which is also where the layer is left.
    private func animate(_ layer: CALayer, _ keyPath: String, from: CGFloat, to value: CGFloat,
                         over duration: TimeInterval, timing: CAMediaTimingFunction) {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = value
        animation.duration = duration
        animation.timingFunction = timing
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setValue(value, forKeyPath: keyPath)
        layer.add(animation, forKey: Self.animationKey)
        CATransaction.commit()
    }

    private static let animationKey = "detachTrace"

    // MARK: - For the tests and renders

    /// The line as it is `progress` of the way round, at rest: what the run
    /// passes through at that point, for drawing it offscreen.
    func show(progress: CGFloat, outline: CGPath, topGap: CGFloat) {
        draw(outline, topGap: topGap)
        set(progress: progress, opacity: 1)
    }

    /// How far round the line is on screen, the animation in flight
    /// included, and how opaque.
    var shown: (left: CGFloat, right: CGFloat, opacity: Float) {
        ((left.presentation() ?? left).strokeEnd, (right.presentation() ?? right).strokeEnd,
         (clip.presentation() ?? clip).opacity)
    }

    /// The animation each line was last handed, if it's still running.
    var runningAnimations: [CABasicAnimation] {
        [left, right].compactMap { $0.animation(forKey: Self.animationKey) as? CABasicAnimation }
    }
}
