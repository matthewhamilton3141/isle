//
//  DropFaceView.swift
//
//  What the panel shows while files are dragged over it: one line saying
//  what's being dropped, and a target for each thing this drop can do —
//  Start Claude here for exactly one folder, Keep on shelf, AirDrop when
//  AirDrop can take the items. Nothing else is offered.
//
//  The target under the pointer is lit, and letting go there does it.
//  Letting go anywhere else, or leaving, does nothing. The pointer isn't
//  read here: a drag sends the window its own location, and the window
//  controller lights the target whose frame (reported from here) holds it.
//

import SwiftUI

struct DropFaceView: View {
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject var island: IslandPresentation
    var payload: DropPayload

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(payload.headline)
                .font(IsleType.meta)
                .foregroundStyle(.islandSecondary(IsleType.Tone.meta))
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.leading, 2)
            HStack(spacing: 10) {
                ForEach(viewModel.dropTargets(for: payload), id: \.self) { target in
                    DropTargetTile(
                        symbol: Self.symbol(target),
                        title: Self.title(target),
                        detail: detail(target),
                        isLit: island.litDropTarget == target,
                        isAvailable: viewModel.canPerform(target, with: payload)
                    )
                    .onGeometryChange(for: CGRect.self) { proxy in
                        proxy.frame(in: .global)
                    } action: { frame in
                        island.dropTargetFrames[target] = frame
                    }
                    .onDisappear { island.dropTargetFrames[target] = nil }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.bottom, 2)
        .foregroundStyle(.white)
        .animation(.easeInOut(duration: 0.12), value: island.litDropTarget)
    }

    private static func symbol(_ target: DropTarget) -> String {
        switch target {
        case .startClaude: return "sparkle"
        case .keep: return "tray.and.arrow.down"
        case .airDrop: return "dot.radiowaves.left.and.right"
        }
    }

    private static func title(_ target: DropTarget) -> String {
        switch target {
        case .startClaude: return "Start Claude here"
        case .keep: return "Keep on shelf"
        case .airDrop: return "AirDrop"
        }
    }

    /// The line under each target: where Claude will start, what keeping
    /// will actually keep, where AirDrop goes.
    private func detail(_ target: DropTarget) -> String {
        switch target {
        case .startClaude:
            // The folder, as the window's prompt will show it.
            let path = payload.claudeFolder?.path ?? ""
            return (path as NSString).abbreviatingWithTildeInPath
        case .keep:
            let count = payload.items.count
            let keeps = viewModel.shelf.wouldKeep(payload.urls)
            if keeps == count { return "until you clear it" }
            if keeps > 0 { return "keeps \(keeps) of \(count) · holds \(ShelfStore.capacity)" }
            return viewModel.shelf.isFull
                ? "shelf is full · holds \(ShelfStore.capacity)"
                : "already on the shelf"
        case .airDrop:
            return "to a nearby device"
        }
    }
}

/// One thing a drop can do. Dashed while the pointer is elsewhere, solid and
/// brighter under it; dimmed when releasing on it would do nothing (a full
/// shelf), and never lit then.
private struct DropTargetTile: View {
    var symbol: String
    var title: String
    var detail: String
    var isLit: Bool
    var isAvailable: Bool

    private static let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .semibold))
                .frame(height: 24)
            Text(title)
                .font(IsleType.headline)
                .lineLimit(1)
            Text(detail)
                .font(IsleType.note)
                .foregroundStyle(.islandSecondary(IsleType.Tone.secondary))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Self.shape.fill(.white.opacity(isLit ? 0.16 : 0.05)))
        .overlay {
            if isLit {
                Self.shape.strokeBorder(.white, lineWidth: 2)
            } else {
                Self.shape.strokeBorder(.white.opacity(0.3), style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
            }
        }
        .opacity(isAvailable ? 1 : 0.4)
        .accessibilityElement(children: .combine)
    }
}
