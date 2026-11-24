//
//  CoverArt.swift
//
//  The album art slot, cross-fading from one cover to the next.
//
//  Each cover is keyed on its NSImage's identity, which the sources only
//  replace when they actually fetched or decoded a new one, so the fade runs
//  once per cover and never for a re-sent copy of the same one.
//
//  While a new track's cover is still on its way (`awaiting`), the slot shows
//  an empty tile rather than the no-cover placeholder. The placeholder is a
//  claim that the track has no art; the tile claims nothing, and it keeps a
//  skip to one fade instead of two. See `NotchViewModel.awaitingCover`.
//

import AppKit
import SwiftUI

struct CoverArt<Placeholder: View>: View {
    var image: NSImage?
    var awaiting: Bool
    @ViewBuilder var placeholder: () -> Placeholder

    static var fade: Animation { .easeInOut(duration: 0.35) }

    var body: some View {
        ZStack {
            if let image {
                // High interpolation is load-bearing: these are ~640px bitmaps
                // drawn into 22–114pt, and the default filter aliases badly at
                // that reduction.
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .aspectRatio(contentMode: .fill)
                    .id(ObjectIdentifier(image))
                    .transition(.opacity)
            } else if awaiting {
                Color.white.opacity(0.08)
                    .transition(.opacity)
            } else {
                placeholder()
                    .transition(.opacity)
            }
        }
        .animation(Self.fade, value: image.map(ObjectIdentifier.init))
        .animation(Self.fade, value: awaiting)
    }
}
