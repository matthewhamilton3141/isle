//
//  MarqueeText.swift
//
//  Now-playing ticker for text that's too long for the notch.
//
//  Per spec 3.1 this is a horizontal *offset* animation with a pause at
//  each end — explicitly not an opacity flash, both because a strobing
//  label is unpleasant to read and because flashing UI is an accessibility
//  problem. Text that already fits is left completely static; no animation
//  runs at all in that case.
//
//  Driven off `TimelineView(.animation)` and wall-clock time rather than a
//  repeating SwiftUI animation, so multiple marquees (title and artist)
//  stay in phase with each other and with the equalizer instead of drifting
//  apart over a long track.
//

import SwiftUI

struct MarqueeText: View {
    let text: String
    var font: Font = .system(size: 13, weight: .semibold)

    /// Points per second while moving.
    var speed: Double = 30
    /// Seconds held still at each end.
    var pause: Double = 1.2

    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0

    private var overflow: CGFloat {
        max(0, textWidth - containerWidth)
    }

    var body: some View {
        GeometryReader { geometry in
            Group {
                if overflow > 0 {
                    scrolling
                } else {
                    Text(text)
                        .font(font)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .onAppear { containerWidth = geometry.size.width }
            .onChange(of: geometry.size.width) { _, new in containerWidth = new }
        }
        .frame(height: lineHeight)
        // Measure the untruncated text off-screen. `fixedSize` stops the
        // layout system from wrapping or eliding it, so we get the true width.
        .background(
            Text(text)
                .font(font)
                .lineLimit(1)
                .fixedSize()
                .hidden()
                .background(
                    GeometryReader { proxy in
                        Color.clear.onAppear { textWidth = proxy.size.width }
                            .onChange(of: text) { _, _ in
                                textWidth = proxy.size.width
                            }
                    }
                )
                .allowsHitTesting(false),
            alignment: .leading
        )
        .clipped()
    }

    private var lineHeight: CGFloat {
        // Enough for a 13pt line without clipping descenders.
        18
    }

    private var scrolling: some View {
        TimelineView(.animation) { context in
            let offset = offset(at: context.date.timeIntervalSinceReferenceDate)
            Text(text)
                .font(font)
                .lineLimit(1)
                .fixedSize()
                .offset(x: offset)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        // The scrolling text runs past both edges; fade them so it slides out
        // of view rather than being guillotined by the clip rect.
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.04),
                    .init(color: .black, location: 0.96),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
    }

    /// Ping-pong: hold, travel left, hold, travel back. Going back rather
    /// than snapping to the start avoids a jump-cut mid-title.
    private func offset(at time: TimeInterval) -> CGFloat {
        let travel = Double(overflow) / speed
        let cycle = (pause + travel) * 2
        guard cycle > 0 else { return 0 }

        let t = time.truncatingRemainder(dividingBy: cycle)

        if t < pause {
            return 0
        }
        if t < pause + travel {
            let progress = (t - pause) / travel
            return -overflow * eased(progress)
        }
        if t < pause * 2 + travel {
            return -overflow
        }
        let progress = (t - pause * 2 - travel) / travel
        return -overflow * (1 - eased(progress))
    }

    /// Gentle ease in/out so the text doesn't start and stop abruptly.
    private func eased(_ t: Double) -> CGFloat {
        CGFloat(t * t * (3 - 2 * t))
    }
}

#Preview("Marquee") {
    VStack(alignment: .leading, spacing: 12) {
        MarqueeText(text: "Short title")
        MarqueeText(text: "A Very Long Song Title That Will Definitely Overflow The Notch")
        MarqueeText(
            text: "An Artist With An Unreasonably Long Name Indeed",
            font: .system(size: 11, weight: .regular)
        )
    }
    .frame(width: 220)
    .padding()
    .background(.black)
    .foregroundStyle(.white)
}
