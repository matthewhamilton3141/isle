//
//  StatusLight+SwiftUI.swift
//
//  The status light's motion (the numbers and rules are in StatusLight.swift):
//  `StatusLightMotionHost` runs the light — whatever SwiftUI draws it — in a
//  layer of its own, so the pulse and the flash are Core Animation's: a
//  pulse is one endless opacity animation in the render server, a flash one
//  keyframe animation, and the app does nothing per frame for either. Still
//  states have no animation at all.
//

import SwiftUI
import AppKit

/// Draws `content` — the light — and moves it as `status` asks
/// (`StatusLightKind.motion`): a gentle endless pulse for approval and a
/// question, one flash when done arrives, nothing for the rest.
///
/// The flash is a second copy of the light, brightened up and away again
/// over the steady one. It plays when the status *turns* to done while the
/// light is on screen; arriving on an island that's already done (opened
/// after the fact) doesn't flash it again.
struct StatusLightMotionHost<Content: View>: NSViewRepresentable {
    var status: StatusLightKind?
    @ViewBuilder var content: Content

    func makeNSView(context: Context) -> MotionView {
        let view = MotionView()
        view.update(content: AnyView(content), status: status, reduceMotion: context.environment.accessibilityReduceMotion)
        return view
    }

    func updateNSView(_ view: MotionView, context: Context) {
        view.update(content: AnyView(content), status: status, reduceMotion: context.environment.accessibilityReduceMotion)
    }

    /// Two click-through hosting views of the light — the steady one and the
    /// flash — each animated by Core Animation on its own layer.
    final class MotionView: NSView {
        private let steady = PassThroughHostingView(rootView: AnyView(EmptyView()))
        private let flash = PassThroughHostingView(rootView: AnyView(EmptyView()))
        private var status: StatusLightKind?
        private var seen = false

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            for host in [steady, flash] {
                host.sizingOptions = []
                host.autoresizingMask = [.width, .height]
                host.frame = bounds
                host.wantsLayer = true
                addSubview(host)
            }
            flash.layer?.opacity = 0
            flash.isHidden = true
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func update(content: AnyView, status: StatusLightKind?, reduceMotion: Bool) {
            steady.rootView = content
            flash.rootView = content
            let previous = status == self.status ? status : self.status
            let arrived = seen && previous != status
            self.status = status
            seen = true
            let motion = reduceMotion ? .still : (status?.motion ?? .still)
            setPulsing(motion == .pulse)
            if motion == .flash, arrived { playFlash() }
        }

        private func setPulsing(_ on: Bool) {
            guard let layer = steady.layer else { return }
            let running = layer.animation(forKey: "statusLight.pulse") != nil
            guard on != running else { return }
            if on {
                let pulse = CABasicAnimation(keyPath: "opacity")
                pulse.fromValue = 1
                pulse.toValue = StatusLight.pulseLow
                pulse.duration = StatusLight.pulsePeriod / 2
                pulse.autoreverses = true
                pulse.repeatCount = .infinity
                pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                // A two-second breath needs no more than this: the window
                // server redraws the light this often, not at the display's
                // full rate.
                pulse.preferredFrameRateRange = CAFrameRateRange(
                    minimum: Float(StatusLight.pulseFrameRate / 2),
                    maximum: Float(StatusLight.pulseFrameRate),
                    preferred: Float(StatusLight.pulseFrameRate)
                )
                layer.add(pulse, forKey: "statusLight.pulse")
            } else {
                layer.removeAnimation(forKey: "statusLight.pulse")
            }
        }

        private func playFlash() {
            guard let layer = flash.layer else { return }
            flash.isHidden = false
            CATransaction.begin()
            CATransaction.setCompletionBlock { [weak self] in self?.flash.isHidden = true }
            let up = CAKeyframeAnimation(keyPath: "opacity")
            up.values = [0, StatusLight.flashPeak, 0]
            up.keyTimes = [0, NSNumber(value: StatusLight.flashRise), 1]
            up.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut)]
            up.duration = StatusLight.flashDuration
            layer.add(up, forKey: "statusLight.flash")
            CATransaction.commit()
        }
    }
}

/// Never the target of a click: the light lies over the panel's buttons.
final class PassThroughHostingView: NSHostingView<AnyView> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
