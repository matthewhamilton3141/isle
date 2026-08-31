//
//  MarqueeText.swift
//
//  Now-playing ticker for text that's too long for the notch.
//
//  Per spec 3.1 this is a horizontal *offset* animation — explicitly not an
//  opacity flash, both because a strobing label is unpleasant to read and
//  because flashing UI is an accessibility problem. Text that already fits is
//  left completely static; no animation runs at all in that case.
//
//  The travel is a continuous cycle, not a there-and-back. The string is laid
//  down twice with a gap and slid steadily left; by the time the first copy has
//  fully left the frame the second sits exactly where the first began, so the
//  animation restarts with nothing to see. That reads as one unbroken pass
//  through the title, where a ping-pong made you sit through a return trip over
//  words you had already read.
//
//  Core Animation drives it, like the marker and the waveform: a constant
//  velocity slide is a single translation, so the whole thing goes to the render
//  server once and this process does nothing while it plays. It exists only
//  while the panel is open — ExpandedNotchView isn't built when the notch is
//  collapsed — so a closed island costs nothing at all.
//

import AppKit
import SwiftUI

struct MarqueeText: View {
    let text: String
    var fontSize: CGFloat = 13
    var weight: NSFont.Weight = .semibold
    var color: Color = .white

    /// Points per second while moving.
    var speed: Double = 30
    /// Held still after the panel opens, before the first pass begins. The
    /// island is still growing at that point, and text that starts travelling
    /// immediately reads as jitter rather than as a deliberate move.
    var startDelay: Double = 0.3
    /// Clear space between the end of one pass and the start of the next.
    var gap: CGFloat = 44

    /// Row height. Defaults to a 13pt title; pass something smaller for the
    /// artist line so it doesn't reserve space it never uses.
    var lineHeight: CGFloat = 18

    var body: some View {
        MarqueeRepresentable(
            text: text, fontSize: fontSize, weight: weight, color: color,
            speed: speed, startDelay: startDelay, gap: gap
        )
        .frame(height: lineHeight)
        .accessibilityLabel(text)
    }
}

// MARK: - SwiftUI bridge

private struct MarqueeRepresentable: NSViewRepresentable {
    var text: String
    var fontSize: CGFloat
    var weight: NSFont.Weight
    var color: Color
    var speed: Double
    var startDelay: Double
    var gap: CGFloat

    func makeNSView(context: Context) -> MarqueeLayerView {
        let view = MarqueeLayerView()
        view.configure(text: text, font: font, color: NSColor(color),
                       speed: speed, startDelay: startDelay, gap: gap)
        return view
    }

    func updateNSView(_ view: MarqueeLayerView, context: Context) {
        view.configure(text: text, font: font, color: NSColor(color),
                       speed: speed, startDelay: startDelay, gap: gap)
    }

    private var font: NSFont { .systemFont(ofSize: fontSize, weight: weight) }
}

// MARK: - Layer view

final class MarqueeLayerView: NSView {

    private let track = CALayer()
    private var copies: [CATextLayer] = []
    private let fade = CAGradientLayer()

    private var text: String = ""
    private var font: NSFont = .systemFont(ofSize: 13, weight: .semibold)
    private var color: NSColor = .white
    private var speed: Double = 30
    private var startDelay: Double = 0.3
    private var gap: CGFloat = 44

    private var builtKey: String = ""
    private var builtWidth: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.addSublayer(track)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    func configure(
        text: String, font: NSFont, color: NSColor,
        speed: Double, startDelay: Double, gap: CGFloat
    ) {
        self.text = text
        self.font = font
        self.color = color
        self.speed = speed
        self.startDelay = startDelay
        self.gap = gap
        rebuildIfNeeded()
    }

    override func layout() {
        super.layout()
        rebuildIfNeeded()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        builtKey = ""            // contentsScale changed; the text needs redrawing
        rebuildIfNeeded()
    }

    // MARK: - Build

    private func rebuildIfNeeded() {
        let scale = window?.backingScaleFactor ?? 2
        let key = "\(text)|\(font.pointSize)|\(font.fontName)|\(color.description)|\(speed)|\(gap)|\(scale)"
        guard key != builtKey || bounds.width != builtWidth else { return }
        builtKey = key
        builtWidth = bounds.width
        rebuild(scale: scale)
    }

    private func rebuild(scale: CGFloat) {
        guard bounds.width > 0, bounds.height > 0 else { return }

        let textWidth = ceil((text as NSString).size(withAttributes: [.font: font]).width)
        // Fits: one static copy, no animation, no mask. Nothing moves and
        // nothing is scheduled.
        let scrolls = textWidth > bounds.width

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        makeCopies(scrolls ? 2 : 1, scale: scale)
        for (index, copy) in copies.enumerated() {
            copy.frame = CGRect(
                x: CGFloat(index) * (textWidth + gap), y: 0,
                width: textWidth, height: bounds.height
            )
        }

        track.frame = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height)
        track.removeAllAnimations()

        if scrolls {
            // One pass is the string plus the gap after it: by the time that
            // much has gone by, the second copy sits exactly where the first
            // started, so restarting is invisible.
            let distance = textWidth + gap
            let slide = CABasicAnimation(keyPath: "transform.translation.x")
            slide.fromValue = 0
            slide.toValue = -distance
            slide.duration = distance / speed
            slide.repeatCount = .greatestFiniteMagnitude
            // The settle the panel needs to finish opening before anything moves.
            // `.backwards` fill holds the start position through it, rather than
            // leaving the first frames undefined.
            slide.beginTime = CACurrentMediaTime() + startDelay
            slide.fillMode = .backwards
            slide.isRemovedOnCompletion = false
            track.add(slide, forKey: "slide")

            // The text runs past both edges; fade them so it slides out of view
            // rather than being guillotined by the clip rect.
            fade.frame = CGRect(origin: .zero, size: bounds.size)
            fade.startPoint = CGPoint(x: 0, y: 0.5)
            fade.endPoint = CGPoint(x: 1, y: 0.5)
            fade.colors = [
                NSColor.clear.cgColor, NSColor.black.cgColor,
                NSColor.black.cgColor, NSColor.clear.cgColor,
            ]
            fade.locations = [0, 0.04, 0.96, 1]
            layer?.mask = fade
        } else {
            layer?.mask = nil
        }

        CATransaction.commit()
    }

    private func makeCopies(_ count: Int, scale: CGFloat) {
        if copies.count != count {
            copies.forEach { $0.removeFromSuperlayer() }
            copies = (0..<count).map { _ in
                let layer = CATextLayer()
                layer.truncationMode = .none
                layer.isWrapped = false
                layer.alignmentMode = .left
                track.addSublayer(layer)
                return layer
            }
        }
        // Handed an attributed string rather than a plain one, so the weight and
        // colour are the ones asked for rather than CATextLayer's defaults.
        let attributed = NSAttributedString(
            string: text,
            attributes: [.font: font, .foregroundColor: color]
        )
        for copy in copies {
            copy.contentsScale = scale
            copy.string = attributed
        }
    }
}

#Preview("Marquee") {
    VStack(alignment: .leading, spacing: 12) {
        MarqueeText(text: "Short title", fontSize: 14)
        MarqueeText(text: "It’s The End Of The World As We Know It (And I Feel Fine)", fontSize: 14)
        MarqueeText(
            text: "An Artist With An Unreasonably Long Name Indeed",
            fontSize: 11, weight: .regular, color: .white.opacity(0.7)
        )
    }
    .frame(width: 220)
    .padding()
    .background(.black)
}
