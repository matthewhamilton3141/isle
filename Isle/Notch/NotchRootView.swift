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
    /// so the window can restrict hit-testing to it. Optional so previews can
    /// build the view without the window controller's hit-test plumbing.
    var onActiveRectChange: ((CGRect) -> Void)? = nil

    private var state: NotchState { viewModel.state }

    /// The notch's *live* frame, sampled from the animating layout rather than
    /// the discrete target `size`. Drives both the reveal of the expanded
    /// content and the hit-test, so neither jumps ahead of the frame.
    @State private var liveSize: CGSize = .zero

    /// Horizontal padding inside the collapsed shape: 10 (root) + 4 (collapsed
    /// view), each side. Used to turn content widths into a shape width.
    private static let collapsedHPadding: CGFloat = 28

    private var size: CGSize {
        guard let metrics = viewModel.metrics else { return NotchMetrics.expandedSize }
        if state == .collapsed {
            // Nothing active: collapse to exactly the physical cutout so the
            // island vanishes into the hardware notch. Hover still expands it
            // (the window keeps a hot margin around the notch), so it remains
            // discoverable rather than truly gone.
            if viewModel.isCollapsedIdle {
                return metrics.notchSize
            }
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
        guard expanded > collapsed, liveSize.width > 0 else { return state.isExpanded ? 1 : 0 }
        return min(max((liveSize.width - collapsed) / (expanded - collapsed), 0), 1)
    }

    /// The expanded content stays fully hidden until the notch is ~65% open,
    /// then fades in over the rest of the travel — so the title, artwork and
    /// controls never show inside a half-grown notch.
    private var expandedContentOpacity: Double {
        Double(min(1, max(0, (expandProgress - 0.65) / 0.3)))
    }

    /// Cached on the view model — see `NotchViewModel.palette`. Deriving it
    /// here re-ran extraction on every body evaluation, which both cost real
    /// CPU at 30fps and let a near-tied colour ranking flip frame to frame.
    private var palette: ArtworkPalette {
        viewModel.palette
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
            // Flat black on both tabs — the ambient artwork/Claude wash was
            // removed, so nothing tints the panel behind the content.
            .fill(.black)

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
                    // Parked in the bottom-right corner of the panel rather than
                    // up in the housing band — inset enough to clear the rounded
                    // bottom corner and the transport keys, which stay centred.
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, 22)
                    .padding(.bottom, 16)
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
        // Hit region is the full bounding rectangle, not the notch outline. The
        // outline's top edge sits at the screen edge and its top corners are
        // carved inward by the concave flares, so the corners of the island
        // would otherwise be dead to the mouse.
        //
        // Hover itself is not read here. `.onHover` knows only this rect, and
        // both halves of the hover rule now live outside it: opening wants a
        // lip below the island (and a sideways sweep across it *not* to count),
        // closing wants a pad around the panel. NotchWindowController owns
        // both — see `handlePointerMove`.
        .contentShape(Rectangle())
        .background(
            GeometryReader { proxy in
                // Tracks the *animating* frame, for the content reveal and the
                // hit box (see `activeRect`). Unioned with the discrete target
                // there, so a dropped final sample can never leave the region
                // stuck smaller than the settled notch.
                Color.clear
                    .onAppear { liveSize = proxy.size }
                    .onChange(of: proxy.size) { _, s in liveSize = s }
            }
        )
        .onAppear { onActiveRectChange?(activeRect) }
        .onChange(of: activeRect) { _, rect in onActiveRectChange?(rect) }
    }

    /// The notch's clickable region in the hosting view's coordinate space
    /// (top-left origin). The union of the discrete target frame and the live
    /// animating frame, so the hit box *follows the animation* instead of
    /// snapping: on open the target leads, so it's interactive at full size at
    /// once; on close the live frame lags the target down, so the shrinking
    /// panel stays hittable (and clicks pass through the area it has vacated)
    /// right until it settles — rather than the region collapsing out from under
    /// a panel that's still visibly on screen. The union also self-heals if a
    /// final animation sample is dropped: the target keeps the settled size live.
    private var activeRect: CGRect {
        let target = frameRect(for: size)
        guard liveSize.width > 0, liveSize.height > 0 else { return target }
        return target.union(frameRect(for: liveSize))
    }

    /// A centred notch frame of the given size, in the hosting view's top-left
    /// space, carrying the collapsed shift that keeps the cutout under the camera.
    private func frameRect(for s: CGSize) -> CGRect {
        let hostWidth = viewModel.metrics?.maximumFrame.width ?? NotchMetrics.expandedSize.width
        return CGRect(
            x: (hostWidth - s.width) / 2 + collapsedShift,
            y: 0,
            width: s.width,
            height: s.height
        )
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

    /// Diameter of the single toggle button.
    private static let tabBarHeight: CGFloat = 34

    /// A single toggle rather than a two-segment pill: it shows the *other*
    /// tab's icon (the one you'd switch to), so on Music it's the 3x3 Claude
    /// mark and on Claude it's the music note. Tapping flips to that tab.
    private var tabBar: some View {
        let target = viewModel.expandedTab.other
        return Button {
            // No withAnimation here: the content cross-fade is handled by
            // ExpandedNotchView's own `.animation(value: expandedTab)`.
            viewModel.selectTab(target)
        } label: {
            tabIcon(for: target)
                .frame(width: Self.tabBarHeight, height: Self.tabBarHeight)
                .background(Circle().fill(.black.opacity(0.35)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Switch to \(target.title)")
        .animation(.easeInOut(duration: 0.15), value: viewModel.expandedTab)
    }

    /// Music keeps its SF Symbol; Claude uses the dot mark.
    @ViewBuilder
    private func tabIcon(for tab: IsleTab) -> some View {
        switch tab {
        case .music:
            // A 4-bar waveform, sized to the same 16x16 box as the Claude dot
            // grid so neither icon outweighs the other in the toggle.
            WaveformIcon(color: .white)
                .frame(width: 18, height: 18)
        case .claude:
            // A simpler 3x3 grid reads better than 5x5 at tab-icon size.
            DotGridIcon(color: .white, dimension: 3)
                .frame(width: 18, height: 18)
        }
    }

}

// MARK: - Previews

#if DEBUG
/// Full-app canvas preview of the notch overlay. Live and interactive — the
/// Music/Claude switcher works, so the alert tab-override fix can be exercised
/// right in the canvas. No subsystems start (the view model is only
/// constructed, never `start()`ed), so nothing touches audio or the adapter.
private enum NotchPreview {
    @MainActor
    static func viewModel(_ configure: (NotchViewModel) -> Void = { _ in }) -> NotchViewModel {
        // Isolated defaults so a preview never reads or writes the real prefs.
        let settings = AppSettings(defaults: UserDefaults(suiteName: "isle.preview")!)
        settings.mode = .both            // show both sources + the tab switcher
        let vm = NotchViewModel(settings: settings)
        if let screen = NSScreen.main {
            vm.metrics = NotchMetrics(screen: screen)
        }
        configure(vm)
        return vm
    }
}

/// Backdrop so the black notch reads against something, sized to the panel's
/// full width with room below for the expanded panel to hang into.
private struct NotchPreviewStage<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        content()
            .frame(width: NotchMetrics.expandedSize.width + 120, height: 300)
            .background(
                LinearGradient(
                    colors: [Color(white: 0.32), Color(white: 0.06)],
                    startPoint: .top, endPoint: .bottom
                )
            )
    }
}

#Preview("Notch — live alert (tab switch)") {
    NotchPreviewStage {
        NotchRootView(viewModel: NotchPreview.viewModel { vm in
            // A live approval auto-jumps to the Claude tab; click Music in the
            // canvas to confirm the manual override now sticks.
            vm.claudeState = .needsApproval
        })
    }
}

#Preview("Notch — resting") {
    NotchPreviewStage {
        NotchRootView(viewModel: NotchPreview.viewModel())
    }
}
#endif
