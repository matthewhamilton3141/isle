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

    /// This island's own state — hover, and the geometry of the screen it's
    /// drawn on. One per display; the view model behind it is shared.
    @ObservedObject var island: IslandPresentation

    /// Which part of the island this tree draws (`IslandGlassLayer`): all of
    /// it, or, as Isle runs, the panel without the glass material over a
    /// second tree in a non-key window that draws the material alone. The
    /// material's tree builds no content and makes no haptics; its outline
    /// follows the same state on the same springs.
    var glassLayer: IslandGlassLayer = .all

    /// Reports the currently occupied rect (in this view's coordinate space)
    /// so the window can restrict hit-testing to it. Optional so previews can
    /// build the view without the window controller's hit-test plumbing.
    var onActiveRectChange: ((CGRect) -> Void)? = nil

    private var state: NotchState { island.state }

    /// The notch's *live* frame, sampled from the animating layout rather than
    /// the discrete target `size`. Drives both the reveal of the expanded
    /// content and the hit-test, so neither jumps ahead of the frame.
    @State private var liveSize: CGSize = .zero

    /// The size the island last started collapsing from, for the collapse's
    /// taper (see `outline`). Snapshotted from the live frame at the moment
    /// of the close rather than recomputed, because the open size a face
    /// would report can change under a collapse already in flight.
    @State private var collapseOrigin: CGSize?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// What the open panel is drawn on. Reduce Transparency takes the glass
    /// modes back to black.
    private var panelBackground: PanelBackground {
        reduceTransparency ? .black : viewModel.panelBackground
    }

    /// The camera housing the notch glow grows from: with the glow on, in a
    /// mode that has one, and only on a screen with a real notch.
    private var glowHousing: CGSize? {
        guard viewModel.panelNotchGlow, panelBackground.growsNotchGlow,
              let metrics = island.metrics, metrics.hasPhysicalNotch else { return nil }
        return metrics.notchSize
    }

    /// Horizontal padding inside the collapsed shape: 10 (root) + 4 (collapsed
    /// view), each side. Used to turn content widths into a shape width.
    private static let collapsedHPadding: CGFloat = 28

    private var size: CGSize {
        guard let metrics = island.metrics else { return NotchMetrics.expandedSize }
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
        return CGSize(width: metrics.windowSize(for: state).width, height: expandedHeight)
    }

    /// The open panel's height: the standard 146, unless the face on screen
    /// asks for more — a live question seating its options, the agenda its
    /// day — when it grows to that, capped (see `NotchMetrics.panelHeight`).
    /// Only ever read for an expanded state.
    private var expandedHeight: CGFloat {
        // The drop face stands in for whatever face was open, at the
        // standard height, and goes again with the drag.
        if island.isDropTarget, viewModel.acceptsDrops { return NotchMetrics.expandedSize.height }
        let room = NotchMetrics.contentRoom(bandHeight: notchBandHeight)
        guard let content = viewModel.faceContentHeight(room: room) else { return NotchMetrics.expandedSize.height }
        return NotchMetrics.panelHeight(contentHeight: content, bandHeight: notchBandHeight)
    }

    /// The spring for a height change while open — a face growing or
    /// shrinking the panel. The open and close curves, by direction.
    private var panelResizeAnimation: Animation {
        reduceMotion ? .notchCloseReduced
            : expandedHeight > NotchMetrics.expandedSize.height ? .notchOpen : .notchClose
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
        let collapsed = island.metrics?.windowSize(for: .collapsed).width ?? 0
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

    /// Resolved on the view model — see `NotchViewModel.palette`. Extraction
    /// itself stays cached there (this only picks between the cached artwork
    /// colours and the accent): deriving it here re-ran extraction on every
    /// body evaluation, which both cost real CPU at 30fps and let a near-tied
    /// colour ranking flip frame to frame.
    private var palette: ArtworkPalette {
        viewModel.palette
    }

    /// Where Fade's light takes its colours. The cover's only while there's
    /// a track up and it has a cover — not `palette`, whose accent stand-in
    /// would light a panel with no music in it; without one the light is
    /// spectral. Claude's status whenever there is one to show
    /// (`NotchViewModel.statusLightKind`).
    private var lightSource: IslandLightSource {
        guard panelBackground == .fade else { return .none }
        let palette = viewModel.hasMusicActivity ? viewModel.artworkPalette : nil
        guard let status = viewModel.statusLightKind else { return IslandLightSource(palette: palette) }
        return IslandLightSource(palette: palette, status: status, statusHex: viewModel.statusLightHex(status))
    }

    /// Height of the physical camera housing. Content in the expanded panel
    /// has to start below this. Falls back to the common 32pt housing if
    /// metrics aren't available yet, which is safer than falling back to 0 —
    /// guessing low hides content, guessing high only wastes a few points.
    private var notchBandHeight: CGFloat {
        island.metrics?.notchSize.height ?? 32
    }

    var body: some View {
        // Read here, not in the closure: the transaction is built from the
        // state this body was evaluated for.
        let opening = state.isExpanded
        let reduced = reduceMotion
        VStack(spacing: 0) {
            notch
                .offset(x: collapsedShift)
                // The shift exists to centre an asymmetric pill, so it moves
                // with the width.
                .islandCollapseChannel(.width)
                // A swipe lands in an untimed transaction (see
                // `FacePager.settle`): `disablesAnimations`, so the faces swap
                // and the pager re-bases its offset in one frame. The
                // `.animation(value: expandedHeight)` below honours that flag,
                // which left the height snapping to the new face's. Here a
                // swipe's transaction gets the resize spring back for the
                // outline, and the guard on the content inside takes it away
                // again, so only the outline moves.
                //
                // It has to sit here, on the outermost modifier of the notch:
                // measured, a transaction changed on an inner frame (as the
                // scoped `transaction(_:body:)` on the height frame did) leaves
                // the size's animation as the outer transaction had it.
                .transaction { t in
                    guard t.isPanelResize else { return }
                    t.disablesAnimations = false
                    t.animation = panelResizeAnimation
                }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Open on the open spring. Close on the close spring, marked as a
        // collapse so the outline's width, height and corners each take their
        // own (see `notch`; the close spring is the height's, and is what the
        // content's fade-out runs on) — or, with Reduce Motion, on a plain
        // quick ease with nothing shaped about it: unmarked, the channels
        // stand aside and the outline closes as one frame.
        .transaction(value: state) { t in
            guard !t.disablesAnimations else { return }
            if opening {
                t.animation = .notchOpen
            } else if reduced {
                t.animation = .notchCloseReduced
            } else {
                t.animation = .notchClose
                t.isIslandCollapse = true
            }
        }
        // A question arriving while the panel is already open (or leaving it),
        // or a move to or from a taller face, changes the height without
        // changing the state; give that its own spring rather than a jump.
        // The same curves, by direction.
        .animation(panelResizeAnimation, value: expandedHeight)
        .onChange(of: state) { previous, current in
            if previous.isExpanded, !current.isExpanded, liveSize.width > 0, liveSize.height > 0 {
                collapseOrigin = liveSize
            }
            // Only on the open/close transition itself, not on changes between
            // the two expanded states — those aren't a gesture the user made
            // and buzzing for them would feel random. Once, from the panel.
            guard previous.isExpanded != current.isExpanded, glassLayer != .materialOnly else { return }
            viewModel.playTransitionHaptic()
        }
        .environment(\.islandGlassLayer, glassLayer)
    }

    /// The island's outline, shared by the clip and the fill so the two can
    /// never disagree. While collapsing it carries the sizes it's collapsing
    /// between, which is what lets it taper (see `NotchShape.genie`).
    private var outline: NotchShape {
        let corners = state.isExpanded ? IslandMotion.openCorners : IslandMotion.collapsedCorners
        var genie: NotchShape.Genie?
        if state == .collapsed, !reduceMotion, let collapseOrigin {
            genie = NotchShape.Genie(
                expanded: collapseOrigin,
                collapsed: size,
                band: island.metrics?.notchSize ?? NotchMetrics.fallbackNotchSize,
                bandShift: collapsedShift
            )
        }
        return NotchShape(topCornerRadius: corners.top, bottomCornerRadius: corners.bottom, genie: genie)
    }

    private var notch: some View {
        ZStack {
            // Holds the ZStack at the full frame the way the fill used to.
            // The fill itself is now `IslandFill`, behind and outside the
            // clip, so it can carry the proximity swell.
            Color.clear

            content
                .padding(.horizontal, state.isExpanded ? 22 : 10)
                // Reserve the camera housing's band. Nothing may be drawn in
                // the top `notchHeight` points of the expanded panel — that's
                // physical hardware, and anything placed there is simply
                // invisible rather than merely obscured.
                .padding(.top, state.isExpanded ? notchBandHeight + NotchMetrics.contentTopGap : 0)
                .padding(.bottom, state.isExpanded ? 8 : 0)

            // The way home, inside a face (only when there is more than one
            // face, so there's a home to go back to). In the housing band to
            // the right of the physical cutout: that band is ordinary screen,
            // not hardware, and nothing else uses it — the waveform sits
            // below it. Inside the ZStack so it clips to the notch outline;
            // opacity-gated so it fades in with the rest of the expanded
            // content instead of popping mid-animation.
            //
            // It comes and goes with the tile moves under it, on their spring
            // (see `TileMorph`), rather than popping as the face starts.
            ZStack {
                if glassLayer == .materialOnly {
                    EmptyView()
                } else if state.isExpanded, viewModel.showsHome, !island.isDropTarget, let face = viewModel.expandedPlace.face {
                    NotchCrumb(face: face, attention: viewModel.needsYouElsewhere) {
                        viewModel.selectHome()
                    }
                    .frame(height: notchBandHeight)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.trailing, Self.crumbTrailing)
                    .opacity(expandedContentOpacity)
                    .transition(.opacity)
                } else if state.isExpanded, viewModel.expandedPlace == .home || !viewModel.showsHome, !island.isDropTarget {
                    // On Home the same spot holds Settings — and on the one
                    // face of an island with no Home, which has no way home
                    // to sit there and would otherwise have no gear at all. Its right edge
                    // sits where the crumb's does (the crumb's label carries
                    // its own 4pt inset; the gear's 22pt target is centred).
                    NotchSettingsButton()
                        .frame(height: notchBandHeight)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(.trailing, Self.crumbTrailing - 5)
                        .opacity(expandedContentOpacity)
                        .transition(.opacity)
                }
            }
            .animation(reduceMotion ? .easeInOut(duration: 0.28) : .tileMorph, value: viewModel.expandedPlace == .home)
        }
        // A swipe's face swap stays instant for everything inside the
        // outline, though the notch's outermost modifier (in `body`) gives
        // the swipe's transaction an animation for the outline's sake.
        .transaction { t in
            guard t.isPanelResize else { return }
            t.disablesAnimations = true
            t.animation = nil
        }
        // Width and height as separate animatable lengths, each under its
        // own channel, so a collapse runs them on separate springs: the
        // width leads, the height follows. Not plain `.frame`s — see
        // `IslandOutlineLength` for why those moved in lockstep. Outside a
        // collapse both lengths snap and the layout animates the size
        // change as one frame, as it always did.
        .modifier(IslandOutlineLength(axis: .horizontal, length: size.width))
        .islandCollapseChannel(.width, snaps: true)
        .modifier(IslandOutlineLength(axis: .vertical, length: size.height))
        .islandCollapseChannel(.height, snaps: true)
        // Clip everything to the notch outline. The expanded content is laid
        // out at its full width the instant the state flips, but the frame
        // only reaches that width at the end of the animation — without this
        // the content spills out of a still-growing notch.
        .clipShape(outline)
        // Flat black on both tabs — the ambient artwork/Claude wash was
        // removed, so nothing tints the panel behind the content — or, in a
        // glass mode, black that blends to glass while open. Drawn
        // outside the clip so the collapsed island can swell a few points as
        // the pointer nears; never part of the hit rect below.
        .background(alignment: .top) {
            IslandFill(
                proximity: island.proximity,
                shape: outline,
                size: size,
                active: state == .collapsed,
                background: panelBackground,
                opened: state.isExpanded,
                housing: glowHousing,
                housingShift: collapsedShift,
                bandHeight: notchBandHeight,
                light: lightSource
            )
        }
        // The corners lead the collapse: the clip's and the fill's radii.
        .islandCollapseChannel(.corners)
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
        let hostWidth = island.metrics?.maximumFrame.width ?? NotchMetrics.expandedSize.width
        return CGRect(
            x: (hostWidth - s.width) / 2 + collapsedShift,
            y: 0,
            width: s.width,
            height: s.height
        )
    }

    @ViewBuilder
    private var content: some View {
        if glassLayer == .materialOnly {
            // The material's window draws no content.
            EmptyView()
        } else if state.isExpanded {
            let glass = panelBackground.isGlass
            ExpandedNotchView(viewModel: viewModel, island: island, palette: glass ? palette.flooredForGlass : palette)
                .environment(\.islandOnGlass, glass)
                // Opacity gated on how far the notch has actually opened; the
                // transition still handles the fade-out on collapse.
                .opacity(expandedContentOpacity)
                .transition(.opacity)
        } else {
            CollapsedNotchView(viewModel: viewModel, island: island, palette: palette)
                .transition(.opacity)
        }
    }

    // MARK: - Crumb

    /// Inset of the crumb from the panel's right edge: the panel's 22 plus
    /// the waveform's own 4, so the crumb ends on the waveform's right edge
    /// in the band just above it.
    private static let crumbTrailing: CGFloat = 26
}

// MARK: - Previews

#if DEBUG
/// Full-app canvas preview of the notch overlay. Live and interactive — the
/// home grid and the crumb work, so the alert override can be exercised
/// right in the canvas. No subsystems start (the view model is only
/// constructed, never `start()`ed), so nothing touches audio or the adapter.
private enum NotchPreview {
    /// A view model and the one island in front of it, wired the way
    /// `NotchWindowController` wires them for a real screen.
    @MainActor
    static func island(
        _ configure: (NotchViewModel) -> Void = { _ in }
    ) -> (NotchViewModel, IslandPresentation) {
        // Isolated defaults so a preview never reads or writes the real prefs.
        let settings = AppSettings(defaults: UserDefaults(suiteName: "isle.preview")!)
        settings.mode = .both            // show both sources + the home grid
        let vm = NotchViewModel(settings: settings)
        let island = IslandPresentation(content: vm)
        if let screen = NSScreen.main {
            island.metrics = NotchMetrics(screen: screen)
        }
        configure(vm)
        return (vm, island)
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

#Preview("Notch — live alert (face switch)") {
    // A live approval auto-jumps to the Claude face; go Home and pick Music
    // in the canvas to confirm the manual override sticks.
    let (vm, island) = NotchPreview.island { $0.claudeState = .needsApproval }
    return NotchPreviewStage {
        NotchRootView(viewModel: vm, island: island)
    }
}

/// Runs the toast cycle live in the canvas. A view of its own so the loop is
/// owned by something with a lifetime — started in `.task`, cancelled when the
/// canvas tears the preview down, rather than left spinning behind it.
private struct ToastPreviewLoop: View {
    @ObservedObject var viewModel: NotchViewModel
    let island: IslandPresentation

    var body: some View {
        NotchRootView(viewModel: viewModel, island: island)
            .task { await viewModel.runPreviewToastLoop() }
    }
}

/// The one to watch: every toast on a loop, through the real queue and the
/// real timers, with Claude working underneath so each toast is seen taking the
/// island and handing it back.
#Preview("Notch — toasts (live)") {
    // Something for the toast to displace and return to. `working` is ambient,
    // so it doesn't suppress the toast the way an approval would — see
    // `NotchViewModel.showsToast`.
    let (vm, island) = NotchPreview.island { $0.claudeState = .working }
    return NotchPreviewStage {
        ToastPreviewLoop(viewModel: vm, island: island)
    }
}

/// Stills, for checking copy, colour and width without waiting for the cycle.
#Preview("Notch — toasts (stills)") {
    let pinned = NotchViewModel.previewToasts().map { toast in
        NotchPreview.island { $0.pinPreviewToast(toast) }
    }
    return VStack(spacing: 10) {
        ForEach(Array(pinned.enumerated()), id: \.offset) { _, pair in
            NotchRootView(viewModel: pair.0, island: pair.1)
                .frame(height: 40)
        }
    }
    .frame(width: NotchMetrics.expandedSize.width + 120)
    .padding(.vertical, 16)
    .background(
        LinearGradient(
            colors: [Color(white: 0.32), Color(white: 0.06)],
            startPoint: .top, endPoint: .bottom
        )
    )
}

#Preview("Notch — resting") {
    let (vm, island) = NotchPreview.island()
    return NotchPreviewStage {
        NotchRootView(viewModel: vm, island: island)
    }
}
#endif
