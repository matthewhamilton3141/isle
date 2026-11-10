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

/// The closed island's light: a thin lit lower edge in the light's colours,
/// or — when Claude needs you, is done or is stopped — the whole outline,
/// held off the screen's top edge. Moves as the status asks (a pulse, a
/// flash). Drawn inside the island's outline, so half of each stroke shows.
struct ClosedIslandLight: View {
    var shape: NotchShape
    var light: FadeLight

    /// The stroke, half of which shows inside the outline.
    static let lineWidth: CGFloat = 2.4
    /// How far up from the bottom edge the lower-edge light shows, fading out.
    static let edgeReach: CGFloat = 8

    var body: some View {
        StatusLightMotionHost(status: light.status) {
            Group {
                if light.wraps {
                    shape
                        .stroke(LinearGradient(stops: light.wrap, startPoint: .leading, endPoint: .trailing),
                                lineWidth: Self.lineWidth)
                        .mask {
                            VStack(spacing: 0) {
                                Color.clear.frame(height: CGFloat(StatusLight.wrapTopClearance))
                                Color.white
                            }
                        }
                } else {
                    shape
                        .stroke(LinearGradient(stops: light.edge, startPoint: .leading, endPoint: .trailing),
                                lineWidth: Self.lineWidth)
                        .mask {
                            VStack(spacing: 0) {
                                Color.clear
                                LinearGradient(colors: [.clear, .white], startPoint: .top, endPoint: .bottom)
                                    .frame(height: Self.edgeReach)
                            }
                        }
                }
            }
            // Its own clip: a platform view's content isn't held by the
            // island's.
            .clipShape(shape)
            .id(light)
            .transition(.opacity)
            .animation(.easeInOut(duration: IslandGlass.fadeLightCrossfade), value: light)
        }
        .allowsHitTesting(false)
    }
}
