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
import AppKit

struct NotchRootView: View {
    @ObservedObject var viewModel: NotchViewModel

    /// Reports the currently occupied rect (in this view's coordinate space)
    /// so the window can restrict hit-testing to it.
    var onActiveRectChange: ((CGRect) -> Void)?

    private var state: NotchState { viewModel.state }

    /// The notch's *live* width, sampled from the animating layout rather than
    /// the discrete target `size`. Drives both the reveal of the expanded
    /// content and the cutout hit-test, so neither jumps ahead of the frame.
    @State private var liveWidth: CGFloat = 0

    private var size: CGSize {
        viewModel.metrics?.windowSize(for: state)
            ?? NotchMetrics.expandedSize
    }

    /// 0 when fully collapsed, 1 when fully expanded, tracking the animation.
    private var expandProgress: CGFloat {
        let collapsed = viewModel.metrics?.windowSize(for: .collapsed).width ?? 0
        let expanded = NotchMetrics.expandedSize.width
        guard expanded > collapsed, liveWidth > 0 else { return state.isExpanded ? 1 : 0 }
        return min(max((liveWidth - collapsed) / (expanded - collapsed), 0), 1)
    }

    /// The expanded content stays fully hidden until the notch is ~65% open,
    /// then fades in over the rest of the travel — so the title, artwork and
    /// controls never show inside a half-grown notch.
    private var expandedContentOpacity: Double {
        Double(min(1, max(0, (expandProgress - 0.65) / 0.3)))
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
        .animation(state.isExpanded ? .notchOpen : .notchClose, value: state)
        .onChange(of: state) { previous, current in
            // Only on the open/close transition itself, not on changes between
            // the two expanded states — those aren't a gesture the user made
            // and buzzing for them would feel random.
            guard previous.isExpanded != current.isExpanded else { return }
            viewModel.playTransitionHaptic()
        }
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
                        stops: [
                            // Nothing above 0.40 — that lands roughly on the
                            // artist line, so the wash starts below the text
                            // rather than running the full height of the
                            // panel. Still strictly one direction: it only
                            // ever gets stronger toward the bottom.
                            .init(color: .clear, location: 0.40),
                            .init(color: palette.secondary.opacity(0.10), location: 0.64),
                            .init(color: palette.primary.opacity(0.24), location: 1.0),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                // Artwork palettes are pulled from album covers, which are
                // often heavily saturated — taken neat the wash read as a
                // colour cast over the panel rather than ambient light. Pulling
                // saturation down keeps the hue association without the glare.
                .saturation(0.35)
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
        // Clip everything to the notch outline. The expanded content is laid
        // out at its full width the instant the state flips, but the frame
        // only reaches that width at the end of the animation — without this
        // the content spills out of a still-growing notch.
        .clipShape(
            NotchShape(
                topCornerRadius: state.isExpanded ? 12 : 8,
                bottomCornerRadius: state.isExpanded ? 22 : 12
            )
        )
        // Hover region is the full bounding rectangle, not the notch outline.
        // The outline's top edge sits at the screen edge and its top corners
        // are carved inward by the concave flares, so hovering the top of the
        // island landed just *outside* the shape and collapsed it. The
        // rectangle keeps the whole island — top edge and corners included —
        // live, so the panel only closes once the pointer leaves it entirely.
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(hovering ? .notchOpen : .notchClose) {
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
                // Opacity gated on how far the notch has actually opened; the
                // transition still handles the fade-out on collapse.
                .opacity(expandedContentOpacity)
                .transition(.opacity)
        } else {
            CollapsedNotchView(viewModel: viewModel, palette: palette)
                .transition(.opacity)
        }
    }

    private static let space = "isle.notch"

    private func report(_ proxy: GeometryProxy) {
        liveWidth = proxy.size.width
        onActiveRectChange?(proxy.frame(in: .global))
    }
}
