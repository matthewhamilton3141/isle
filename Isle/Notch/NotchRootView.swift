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

    /// Horizontal padding inside the collapsed shape: 10 (root) + 4 (collapsed
    /// view), each side. Used to turn content widths into a shape width.
    private static let collapsedHPadding: CGFloat = 28

    private var size: CGSize {
        guard let metrics = viewModel.metrics else { return NotchMetrics.expandedSize }
        if state == .collapsed {
            // Sized to the per-side content: music on the left, Claude on the
            // right, so the shape grows exactly as much as it needs.
            let sides = viewModel.collapsedSideWidths
            return CGSize(
                width: metrics.notchSize.width + sides.leading + sides.trailing + Self.collapsedHPadding,
                height: metrics.notchSize.height
            )
        }
        return metrics.windowSize(for: state)
    }

    /// The collapsed sides are asymmetric (Claude's side is usually wider), so
    /// shift the shape to keep the camera cutout centred under the housing.
    private var collapsedShift: CGFloat {
        guard state == .collapsed else { return 0 }
        let sides = viewModel.collapsedSideWidths
        return (sides.trailing - sides.leading) / 2
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

    /// The expanded panel is currently showing the Claude tab.
    private var showingClaude: Bool {
        viewModel.expandedTab == .claude
    }

    /// The current Claude marker's colour — its fixed hue, or the artwork accent
    /// for palette-tinted markers — so the wash matches the dots.
    private var claudeMarkerColor: Color {
        let design = MarkerStore.shared.design(for: MarkerKind(state: viewModel.claudeState))
        return design.colorMode == .fixed ? Color(hex: design.fixedColorHex) : palette.accent
    }

    // The ambient wash colours: the Claude marker on its tab, else the artwork.
    private var washPrimary: Color { showingClaude ? claudeMarkerColor : palette.primary }
    private var washSecondary: Color { showingClaude ? claudeMarkerColor : palette.secondary }

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
                .offset(x: collapsedShift)
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
                            .init(color: washSecondary.opacity(0.10), location: 0.64),
                            .init(color: washPrimary.opacity(0.24), location: 1.0),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .saturation(0.3)
                // Only the Claude tab carries the wash now — the music tab has
                // it removed, so its panel stays flat black under the artwork.
                .opacity(state.isExpanded && showingClaude ? 1 : 0)
            }

            content
                .padding(.horizontal, state.isExpanded ? 22 : 10)
                // Reserve the camera housing's band. Nothing may be drawn in
                // the top `notchHeight` points of the expanded panel — that's
                // physical hardware, and anything placed there is simply
                // invisible rather than merely obscured.
                .padding(.top, state.isExpanded ? notchBandHeight + 2 : 0)
                .padding(.bottom, state.isExpanded ? 8 : 0)

            // The Music/Claude switcher, parked in the housing band to the
            // right of the physical cutout (only in `.both` mode). It sits in
            // the band rather than below it — the band right of the camera is
            // ordinary screen, not hardware. Inside the ZStack so it clips to
            // the notch outline; opacity-gated so it fades in with the rest of
            // the expanded content instead of popping mid-animation.
            if state.isExpanded && viewModel.showsTabBar {
                tabBar
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.trailing, 44)
                    // Centred within the housing band, so it sits at the same
                    // level as the physical camera cutout.
                    .padding(.top, max(2, (notchBandHeight - Self.tabBarHeight) / 2))
                    .opacity(expandedContentOpacity)
            }
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

    // MARK: - Tab switcher

    /// Height of the segmented pill: 22pt buttons + 4pt padding each side.
    private static let tabBarHeight: CGFloat = 30

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(IsleTab.allCases) { tab in
                let selected = viewModel.expandedTab == tab
                Button {
                    // No withAnimation here: the content cross-fade is handled
                    // by ExpandedNotchView's own `.animation(value: expandedTab)`.
                    // Wrapping the change in a transaction here was rippling into
                    // the tab bar's layout and nudging the buttons on select.
                    viewModel.activeTab = tab
                } label: {
                    // Both icons share one fixed footprint so the pill can never
                    // reflow between tabs.
                    tabIcon(for: tab, selected: selected)
                        .frame(width: 28, height: 22)
                        .background(Capsule().fill(selected ? .white.opacity(0.22) : .clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
            }
        }
        .padding(4)
        .background(Capsule().fill(.black.opacity(0.35)))
        .animation(.easeInOut(duration: 0.15), value: viewModel.expandedTab)
    }

    /// Music keeps its SF Symbol; Claude uses the 5x5 dot mark.
    @ViewBuilder
    private func tabIcon(for tab: IsleTab, selected: Bool) -> some View {
        let color: Color = selected ? .white : .white.opacity(0.45)
        switch tab {
        case .music:
            Image(systemName: tab.symbolName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(color)
        case .claude:
            // A simpler 3x3 grid reads better than 5x5 at tab-icon size.
            DotGridIcon(color: color, dimension: 3)
                .frame(width: 16, height: 16)
        }
    }

    private static let space = "isle.notch"

    private func report(_ proxy: GeometryProxy) {
        liveWidth = proxy.size.width
        onActiveRectChange?(proxy.frame(in: .global))
    }
}
