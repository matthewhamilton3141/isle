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
            // Artwork colour washing up from the bottom edge. Rising rather
            // than falling so it reads as light pooling under the album art
            // instead of a header bar, and so the top stays pure black where
            // it meets the physical bezel.
            .overlay {
                NotchShape(
                    topCornerRadius: state.isExpanded ? 12 : 8,
                    bottomCornerRadius: state.isExpanded ? 22 : 12
                )
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: palette.primary.opacity(0.10), location: 0.55),
                            .init(color: palette.primary.opacity(0.30), location: 1),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .opacity(state.isExpanded ? 1 : 0)
            }

            content
                .padding(.horizontal, state.isExpanded ? 18 : 10)
                .padding(.vertical, state.isExpanded ? 14 : 0)
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
