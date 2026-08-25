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

    /// Row height. Defaults to a 13pt title; pass something smaller for the
    /// artist line so it doesn't reserve space it never uses.
    var lineHeight: CGFloat = 18

    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0

    private var overflow: CGFloat {
        max(0, textWidth - containerWidth)
    }

    var body: some View {
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: lineHeight)
        // Both widths are reported through preferences rather than read
        // inside onChange. Reading `proxy.size.width` from an onChange(of:
        // text) handler returns the width from *before* the new string was
        // laid out, so a longer title measured as the previous, shorter one —
        // overflow came out as 0 and the text was silently truncated instead
        // of scrolling. Preferences are emitted after layout, so they always
        // describe the string currently on screen.
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: MarqueeContainerWidthKey.self,
                    value: proxy.size.width
                )
            }
        )
        // The untruncated text, measured off-screen. `fixedSize` stops the
        // layout system wrapping or eliding it, so we get its true width.
        .background(
            Text(text)
                .font(font)
                .lineLimit(1)
                .fixedSize()
                .hidden()
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: MarqueeTextWidthKey.self,
                            value: proxy.size.width
                        )
                    }
                )
                .allowsHitTesting(false),
            alignment: .leading
        )
        .onPreferenceChange(MarqueeContainerWidthKey.self) { containerWidth = $0 }
        .onPreferenceChange(MarqueeTextWidthKey.self) { textWidth = $0 }
        .clipped()
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

private struct MarqueeTextWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct MarqueeContainerWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
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
