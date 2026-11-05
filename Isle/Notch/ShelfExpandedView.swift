//
//  ShelfExpandedView.swift
//
//  The shelf face. The same skeleton as Music: a square where the album
//  sits — here the stack and its count — and a column beside it with the
//  items and, along the bottom, what can be done with them.
//
//  Click an item to select it (again to let it go); the actions then act on
//  the selection rather than the whole shelf. Drag an item out to drop it in
//  any app. Right-click for Show in Finder and Remove.
//
//  Every item shown is one the shelf has just checked is still where it was
//  put (see `ShelfStore`), so a name here is a file you can drag out.
//

import SwiftUI

struct ShelfExpandedView: View {
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject var shelf: ShelfStore

    /// Selected items, by path. This panel's own state: it goes when the
    /// face does.
    @State private var selection: Set<String> = []

    /// Up to five sit in one row with room for their names. Past that, two
    /// rows of smaller cells, so all ten fit with nothing scrolled away.
    private var isCompact: Bool { shelf.items.count > 5 }

    var body: some View {
        HStack(spacing: 14) {
            ShelfStack(shelf: shelf)
                // Up into the band, as the album is: there's no hardware
                // above this corner of the panel.
                .offset(y: -11)

            VStack(alignment: .leading, spacing: 0) {
                if !isCompact {
                    Text(headline)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                        // Clear of the waveform pinned at the panel's
                        // top-right, as the track title is.
                        .padding(.trailing, 36)
                    Spacer(minLength: 4)
                }
                itemGrid
                Spacer(minLength: 6)
                actions
            }
            .frame(minWidth: 340, maxWidth: 340, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(.white)
        // A selection whose item left the shelf (dragged off into the Trash,
        // removed) is no selection.
        .onChange(of: shelf.items) { _, items in
            selection.formIntersection(items.map(\.id))
        }
    }

    private var headline: String {
        if !selection.isEmpty {
            return "\(selection.count) selected · the buttons act on \(selection.count == 1 ? "it" : "them")"
        }
        return "Drag one out to use it · click to select"
    }

    // MARK: - Items

    private var itemGrid: some View {
        let columns = Array(repeating: GridItem(.fixed(64), spacing: 5), count: 5)
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 3) {
            ForEach(shelf.items) { item in
                ShelfCell(
                    item: item,
                    icon: shelf.icon(for: item),
                    compact: isCompact,
                    isSelected: selection.contains(item.id)
                )
                .onTapGesture { toggle(item) }
                .onDrag { NSItemProvider(object: item.url as NSURL) }
                .contextMenu {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([item.url])
                    }
                    Button("Remove from Shelf") {
                        shelf.remove([item.id])
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.15), value: selection)
    }

    private func toggle(_ item: ShelfItem) {
        if selection.contains(item.id) {
            selection.remove(item.id)
        } else {
            selection.insert(item.id)
        }
    }

    // MARK: - Actions

    /// What the buttons act on: the selection, or everything.
    private var subject: [ShelfItem] {
        selection.isEmpty ? shelf.items : shelf.items.filter { selection.contains($0.id) }
    }

    /// The folder Start Claude would open: the one selected folder, or with
    /// nothing selected, the shelf's one folder. Two folders and no pick is
    /// no folder.
    private var claudeFolder: ShelfItem? {
        let folder: ShelfItem?
        if selection.isEmpty {
            folder = shelf.onlyFolder
        } else {
            let folders = subject.filter(\.isFolder)
            folder = folders.count == 1 ? folders[0] : nil
        }
        guard let folder, ClaudeLauncher.canStart(in: folder.url) else { return nil }
        return folder
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if shelf.canAirDrop {
                ShelfButton(symbol: "dot.radiowaves.left.and.right",
                            title: selection.isEmpty ? "AirDrop" : "AirDrop \(selection.count)") {
                    viewModel.airDrop(subject.map(\.url))
                }
            }
            if let folder = claudeFolder {
                ShelfButton(symbol: "sparkle", title: "Start Claude here") {
                    viewModel.startClaude(in: folder.url)
                }
                .help(folder.url.path)
            }
            Spacer(minLength: 0)
            if selection.isEmpty {
                ShelfButton(symbol: "xmark", title: "Clear", outlined: true) {
                    shelf.clear()
                }
            } else {
                ShelfButton(symbol: "minus", title: "Remove", outlined: true) {
                    shelf.remove(selection)
                    selection.removeAll()
                }
            }
        }
        .padding(.bottom, 2)
    }
}

// MARK: - Pieces

/// The album's square on this face: the top few items' icons fanned out,
/// and the count under them — "10 · full" once the shelf takes no more.
private struct ShelfStack: View {
    @ObservedObject var shelf: ShelfStore

    var body: some View {
        let shown = Array(shelf.items.suffix(3))
        VStack(spacing: 4) {
            ZStack {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, item in
                    let step = CGFloat(index) - CGFloat(shown.count - 1) / 2
                    Image(nsImage: shelf.icon(for: item))
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 54, height: 54)
                        .rotationEffect(.degrees(Double(step) * 9))
                        .offset(x: step * 16, y: abs(step) * 3)
                }
            }
            .frame(height: 62)
            HStack(spacing: 4) {
                Text("\(shelf.items.count)")
                    .font(.system(size: 18, weight: .bold).monospacedDigit())
                if shelf.isFull {
                    Text("· full")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .contentTransition(.numericText())
        }
        .frame(width: 114, height: 114)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.white.opacity(0.07))
        )
        .animation(.easeInOut(duration: 0.2), value: shelf.items)
    }
}

/// One item: its Finder icon over its name. Selected, it sits on a lit
/// rounded square.
private struct ShelfCell: View {
    var item: ShelfItem
    var icon: NSImage
    var compact: Bool
    var isSelected: Bool

    var body: some View {
        VStack(spacing: compact ? 1 : 3) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: compact ? 20 : 32, height: compact ? 20 : 32)
            Text(item.name)
                .font(.system(size: compact ? 9 : 10.5, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .opacity(0.9)
        }
        .padding(.horizontal, 3)
        .padding(.vertical, compact ? 1 : 3)
        .frame(width: 64)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.white.opacity(isSelected ? 0.16 : 0))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.white.opacity(isSelected ? 0.5 : 0), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .accessibilityLabel(item.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A pill in the action row: a filled one for doing something with the
/// items, an outlined one for taking them off.
private struct ShelfButton: View {
    var symbol: String
    var title: String
    var outlined = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .bold))
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Capsule().fill(.white.opacity(outlined ? 0 : 0.12)))
            .overlay(Capsule().strokeBorder(.white.opacity(outlined ? 0.45 : 0), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
