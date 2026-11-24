//
//  HoverGrow+SwiftUI.swift
//
//  The hover grow on screen: `.hoverGrow()` on a control makes it grow a
//  little while the pointer is on it, `HoverTargetsLayer` tells the tracker
//  where every such control is, and `HoverTracker` says which one the
//  pointer is on, from the moves the window controller hands it.
//
//  The moves come from the controller, not from SwiftUI's hover: its
//  monitors see the pointer whatever app is active and whether or not the
//  panel is key, which is exactly when SwiftUI's own tracking can't be
//  counted on here.
//

import SwiftUI

/// The control under the pointer, one tracker per island like its pager: a
/// pointer is on one display at a time, and each island's controls are laid
/// out in its own window's space.
@MainActor
final class HoverTracker: ObservableObject {
    /// The control under the pointer.
    @Published private(set) var hovered: UUID?
    /// Its laid-out size, for how much it grows (`HoverGrow.scale`).
    private(set) var hoveredSize: CGSize = .zero

    private var rule = HoverTargets()

    /// A pointer move, in the hosting view's top-left space.
    func pointerMoved(_ point: CGPoint) {
        rule.move(to: point)
        publish()
    }

    /// The pointer is on another display.
    func pointerLeft() {
        rule.leave()
        publish()
    }

    /// The controls on show (`HoverTargetsLayer`).
    func setTargets(_ targets: [HoverTarget]) {
        guard targets != rule.targets else { return }
        rule.setTargets(targets)
        publish()
    }

    private func publish() {
        let id = rule.hovered
        hoveredSize = rule.targets.first { $0.id == id }?.rect.size ?? .zero
        if hovered != id { hovered = id }
    }
}

private struct HoverTrackerKey: EnvironmentKey {
    static let defaultValue: HoverTracker? = nil
}

extension EnvironmentValues {
    /// The open island's tracker. Nil outside the island, and in the glass
    /// material's window, which lays out no controls.
    var hoverTracker: HoverTracker? {
        get { self[HoverTrackerKey.self] }
        set { self[HoverTrackerKey.self] = newValue }
    }
}

// MARK: - Controls

/// A control that grows, as it lays out: which and where.
struct HoverGrowItem {
    var id: UUID
    var bounds: Anchor<CGRect>
}

struct HoverGrowKey: PreferenceKey {
    static let defaultValue: [HoverGrowItem] = []
    static func reduce(value: inout [HoverGrowItem], nextValue: () -> [HoverGrowItem]) {
        value.append(contentsOf: nextValue())
    }
}

private struct HoverGrowModifier: ViewModifier {
    @Environment(\.hoverTracker) private var tracker
    @State private var id = UUID()

    func body(content: Content) -> some View {
        if let tracker {
            HoverGrowBody(content: content, tracker: tracker, id: id)
        } else {
            content
        }
    }
}

private struct HoverGrowBody<Content: View>: View {
    var content: Content
    @ObservedObject var tracker: HoverTracker
    var id: UUID
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let scale = isEnabled && tracker.hovered == id ? HoverGrow.scale(for: tracker.hoveredSize) : 1
        content
            .scaleEffect(scale)
            .animation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.7), value: scale)
            // Taken outside the scale, so the bounds are the control's laid-
            // out ones and don't grow under the pointer as it does.
            .transformAnchorPreference(key: HoverGrowKey.self, value: .bounds) { items, bounds in
                // A control that can't be pressed doesn't offer itself.
                guard isEnabled else { return }
                items.append(HoverGrowItem(id: id, bounds: bounds))
            }
    }
}

extension View {
    /// Grows this control a little while the pointer is on it, on the open
    /// island. For things a click presses, not for words to read.
    func hoverGrow() -> some View {
        modifier(HoverGrowModifier())
    }
}

// MARK: - Where they are

/// Tells the tracker where every growing control is, in the island's
/// top-left space. Draws nothing.
struct HoverTargetsLayer: View {
    var items: [HoverGrowItem]
    var tracker: HoverTracker

    var body: some View {
        GeometryReader { proxy in
            let origin = proxy.frame(in: .global).origin
            let targets = items.map {
                HoverTarget(id: $0.id, rect: proxy[$0.bounds].offsetBy(dx: origin.x, dy: origin.y))
            }
            Color.clear
                .onChange(of: targets, initial: true) { _, targets in tracker.setTargets(targets) }
                .onDisappear { tracker.setTargets([]) }
        }
        .allowsHitTesting(false)
    }
}
