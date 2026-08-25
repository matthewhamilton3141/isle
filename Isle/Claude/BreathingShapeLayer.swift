//
//  BreathingShapeLayer.swift
//
//  AppKit / CAShapeLayer version of the "breathing" pulse animation:
//  a shape scaling + fading in a continuous loop, driven natively by
//  Core Animation rather than a display-linked draw loop. Cheaper than
//  the Canvas version for a static (non-redrawn) vector path, since
//  CA runs the animation on the render server.
//
//  Includes an NSViewRepresentable bridge so it can be dropped
//  straight into SwiftUI alongside BreathingShapeView.swift.
//

import AppKit
import QuartzCore
import SwiftUI

// MARK: - Breathing CAShapeLayer

final class BreathingShapeLayer: CAShapeLayer {

    private var period: CFTimeInterval = 1.6
    private var minScale: CGFloat = 0.85
    private var minOpacity: Float = 0.55

    // Required boilerplate for CALayer subclasses.
    override init() { super.init() }
    override init(layer: Any) {
        // Copies config across for the presentation-layer clone Core Animation makes.
        if let other = layer as? BreathingShapeLayer {
            period = other.period
            minScale = other.minScale
            minOpacity = other.minOpacity
        }
        super.init(layer: layer)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// - Parameters:
    ///   - path: shape to draw, in its own natural coordinate space.
    ///   - fillColor: fill color for the shape.
    ///   - period: full breathe cycle length (min -> max -> min), in seconds.
    ///   - minScale: smallest scale in the cycle (max is always 1.0).
    ///   - minOpacity: dimmest opacity in the cycle (max is always 1.0).
    convenience init(
        path: CGPath,
        fillColor: NSColor = .controlAccentColor,
        period: CFTimeInterval = 1.6,
        minScale: CGFloat = 0.85,
        minOpacity: Float = 0.55
    ) {
        self.init()
        self.period = period
        self.minScale = minScale
        self.minOpacity = minOpacity

        // CAShapeLayer draws `path` in the layer's own coordinate space,
        // so sizing bounds to the path's bounding box + centering the
        // anchor point makes scale/opacity animate around the shape's
        // visual center, not its top-left corner.
        let box = path.boundingBoxOfPath
        self.bounds = box
        self.position = CGPoint(x: box.midX, y: box.midY)
        self.anchorPoint = CGPoint(x: 0.5, y: 0.5)

        self.path = path
        self.fillColor = fillColor.cgColor
        self.opacity = 1.0

        startBreathing()
    }

    /// Call when the driving state changes. Cheap no-op restart if only
    /// `fillColor` changed; tears down and re-adds the loop animations
    /// only when `period`/`minScale`/`minOpacity` actually differ, so
    /// switching states doesn't reset the breathing phase every frame.
    func configure(
        period: CFTimeInterval,
        minScale: CGFloat,
        minOpacity: Float,
        fillColor: NSColor
    ) {
        guard period != self.period || minScale != self.minScale || minOpacity != self.minOpacity else {
            if fillColor.cgColor != self.fillColor {
                self.fillColor = fillColor.cgColor
            }
            return
        }
        self.period = period
        self.minScale = minScale
        self.minOpacity = minOpacity
        self.fillColor = fillColor.cgColor
        removeAnimation(forKey: "breatheScale")
        removeAnimation(forKey: "breatheOpacity")
        startBreathing()
    }

    private func startBreathing() {
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = minScale
        scale.toValue = 1.0

        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = minOpacity
        opacity.toValue = 1.0

        for anim in [scale, opacity] {
            anim.duration = period / 2
            anim.autoreverses = true
            anim.repeatCount = .infinity
            anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        }

        add(scale, forKey: "breatheScale")
        add(opacity, forKey: "breatheOpacity")
    }
}

// MARK: - SwiftUI bridge

/// Drop-in SwiftUI wrapper. Size it with `.frame(width:height:)` from
/// the call site — the underlying layer centers itself in the view.
struct BreathingShapeViewRepresentable: NSViewRepresentable {
    var path: CGPath
    var fillColor: NSColor = .controlAccentColor
    var period: CFTimeInterval = 1.6
    var minScale: CGFloat = 0.85
    var minOpacity: Float = 0.55

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        let shapeLayer = BreathingShapeLayer(
            path: path,
            fillColor: fillColor,
            period: period,
            minScale: minScale,
            minOpacity: minOpacity
        )
        container.layer = shapeLayer
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let shapeLayer = nsView.layer as? BreathingShapeLayer else { return }
        shapeLayer.path = path
        shapeLayer.configure(period: period, minScale: minScale, minOpacity: minOpacity, fillColor: fillColor)
    }
}

// MARK: - Placeholder mark (matches SparkShape from the SwiftUI version)

/// Builds the same generic 4-point spark as a raw `CGPath`, centered
/// at `.zero` with the given point-to-point radius. Swap this out for
/// your real mark's path.
func sparkCGPath(radius: CGFloat) -> CGPath {
    let longR = radius
    let shortR = radius * 0.32
    let points: [CGPoint] = [
        CGPoint(x: 0, y: -longR), CGPoint(x: shortR, y: -shortR),
        CGPoint(x: longR, y: 0), CGPoint(x: shortR, y: shortR),
        CGPoint(x: 0, y: longR), CGPoint(x: -shortR, y: shortR),
        CGPoint(x: -longR, y: 0), CGPoint(x: -shortR, y: -shortR)
    ]
    let path = CGMutablePath()
    path.addLines(between: points)
    path.closeSubpath()
    return path
}

// MARK: - Example usage

struct BreathingSparkLayerExample: View {
    var body: some View {
        BreathingShapeViewRepresentable(
            path: sparkCGPath(radius: 16),
            fillColor: .systemOrange,
            period: 1.6,
            minScale: 0.8,
            minOpacity: 0.5
        )
        .frame(width: 32, height: 32)
    }
}

#Preview {
    BreathingSparkLayerExample()
        .padding(40)
}
