//
//  NotchRootView.swift
//
//  Root of the overlay. Draws the notch shape at whatever size the current
//  state calls for and swaps the content inside it.
//
//  The hosting window stays at its maximum size the whole time and only the
//  content resizes — see NotchWindowController for why. That means this view
//  is responsible for reporting its live hit area back up, so clicks outside
//  the visible notch pass through to whatever is underneath.
//

import SwiftUI

struct NotchRootView: View {
    @ObservedObject var viewModel: NotchViewModel

    /// Reports the currently occupied rect (in this view's coordinate space)
    /// so the window can restrict hit-testing to it.
    var onActiveRectChange: ((CGRect) -> Void)?

    private var state: NotchState { viewModel.state }

    private var size: CGSize {
        viewModel.metrics?.windowSize(for: state)
            ?? NotchMetrics.expandedSize
    }

    private var palette: ArtworkPalette {
        ArtworkColors.palette(from: viewModel.media.artwork)
    }

    /// Height of the physical camera housing. Content in the expanded panel
    /// has to start below this. Falls back to the common 32pt housing if
    /// metrics aren't available yet, which is safer than falling back to 0 —
    /// guessing low hides content, guessing high only wastes a few points.
    private var notchBandHeight: CGFloat {
        viewModel.metrics?.notchSize.height ?? 32
    }

    var body: some View {
        VStack(spacing: 0) {
            notch
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.notch, value: state)
    }

    private var notch: some View {
        ZStack {
            NotchShape(
                topCornerRadius: state.isExpanded ? 12 : 8,
                bottomCornerRadius: state.isExpanded ? 22 : 12
            )
            .fill(.black)
            // A single directional wash from one artwork colour to the other,
            // travelling upward: secondary at the top, primary pooling at the
            // bottom. Both ends are real colours rather than fading to clear,
            // so the ramp reads as one continuous direction instead of
            // brightening toward the middle and falling away again.
            .overlay {
                NotchShape(
                    topCornerRadius: state.isExpanded ? 12 : 8,
                    bottomCornerRadius: state.isExpanded ? 22 : 12
                )
                .fill(
                    LinearGradient(
                        colors: [
                            palette.secondary.opacity(0.20),
                            palette.primary.opacity(0.42),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .opacity(state.isExpanded ? 1 : 0)
            }

            content
                .padding(.horizontal, state.isExpanded ? 22 : 10)
                // Reserve the camera housing's band. Nothing may be drawn in
                // the top `notchHeight` points of the expanded panel — that's
                // physical hardware, and anything placed there is simply
                // invisible rather than merely obscured.
                .padding(.top, state.isExpanded ? notchBandHeight + 2 : 0)
                .padding(.bottom, state.isExpanded ? 8 : 0)
        }
        .frame(width: size.width, height: size.height)
        // Restrict both hover and clicks to the drawn shape, so the corners
        // of the bounding box aren't secretly interactive.
        .contentShape(
            NotchShape(
                topCornerRadius: state.isExpanded ? 12 : 8,
                bottomCornerRadius: state.isExpanded ? 22 : 12
            )
        )
        .onHover { hovering in
            withAnimation(.notch) {
                viewModel.isHovering = hovering
            }
        }
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { report(proxy) }
                    .onChange(of: proxy.frame(in: .named(Self.space))) { _, _ in
                        report(proxy)
                    }
            }
        )
        .coordinateSpace(name: Self.space)
    }

    @ViewBuilder
    private var content: some View {
        if state.isExpanded {
            ExpandedNotchView(viewModel: viewModel, palette: palette)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
        } else {
            CollapsedNotchView(viewModel: viewModel, palette: palette)
                .transition(.opacity)
        }
    }

    private static let space = "isle.notch"

    private func report(_ proxy: GeometryProxy) {
        onActiveRectChange?(proxy.frame(in: .global))
    }
}
