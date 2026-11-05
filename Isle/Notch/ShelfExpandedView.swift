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
//  Each item is its thumbnail — the PDF's first page, the picture, a frame
//  of the film — once QuickLook has drawn it, and its icon until then; a
//  folder, or anything QuickLook can't draw, stays its icon. The panel is
//  as tall as the rows need (see `ShelfLayout`).
//

import SwiftUI

struct ShelfExpandedView: View {
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject var shelf: ShelfStore

    /// Selected items, by path. This panel's own state: it goes when the
    /// face does.
    @State private var selection: Set<String> = []

    /// Up to five sit in one row of large cells. Past that, two rows of
    /// smaller ones, so all ten fit with nothing scrolled away. The view
    /// model's count, not this face's: it holds a row while the panel is
    /// open (see `NotchViewModel.shelfRows`), and sets the panel's height.
    private var rows: Int { viewModel.shelfRows }
    private var cell: ShelfLayout.Cell { ShelfLayout.cell(rows: rows) }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 0) {
                ShelfStack(shelf: shelf)
                    // Up into the band, as the album is: there's no hardware
                    // above this corner of the panel.
                    .offset(y: -ShelfLayout.stackRaise)
                Spacer(minLength: 0)
                ShelfCount(shelf: shelf)
                    .frame(height: ShelfLayout.barHeight)
                    .padding(.bottom, ShelfLayout.barBottom)
            }
            .frame(width: ShelfLayout.stackSide)
            .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 0) {
                if rows == 1 {
                    Text(headline)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                        .frame(height: ShelfLayout.headlineHeight, alignment: .top)
                        .padding(.bottom, ShelfLayout.headlineGap)
                }
                itemGrid
                // The least gap is under `ShelfLayout.barGap`: on a Mac with
                // a deeper housing than this one the cap leaves a few points
                // less room, and the gap gives them up first.
                Spacer(minLength: 2)
                actions
            }
            // The column runs under the camera cutout, whose hardware edge
            // sits a point below the band the safe area reports, so the top
            // row keeps a few points clear of it. Text alone has that room in
            // its own leading; the thumbnails don't.
            .padding(.top, ShelfLayout.cutoutClearance)
            .frame(width: ShelfLayout.columnWidth, alignment: .topLeading)
            .frame(maxHeight: .infinity, alignment: .top)
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
        let columns = Array(
            repeating: GridItem(.fixed(ShelfLayout.cellWidth), spacing: ShelfLayout.cellGap),
            count: ShelfLayout.columns
        )
        return LazyVGrid(columns: columns, alignment: .leading, spacing: ShelfLayout.rowGap) {
            ForEach(shelf.items) { item in
                ShelfCell(
                    item: item,
                    icon: shelf.icon(for: item),
                    thumbnail: shelf.thumbnail(for: item),
                    cell: cell,
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
        .frame(height: ShelfLayout.barHeight)
        .padding(.bottom, ShelfLayout.barBottom)
    }
}

// MARK: - Pieces

/// The album's square on this face: the top few items fanned out, each its
/// thumbnail once it has one, the latest kept on top.
private struct ShelfStack: View {
    @ObservedObject var shelf: ShelfStore

    var body: some View {
        let shown = Array(shelf.items.suffix(3))
        ZStack {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, item in
                let step = CGFloat(index) - CGFloat(shown.count - 1) / 2
                ShelfPreviewImage(icon: shelf.icon(for: item), thumbnail: shelf.thumbnail(for: item),
                                  side: ShelfLayout.fanSide, corner: 5)
                    // A shadow so each card reads over the one under it.
                    .shadow(color: .black.opacity(0.45), radius: 3, y: 1)
                    .rotationEffect(.degrees(Double(step) * 9))
                    .offset(x: step * 17, y: abs(step) * 3)
            }
        }
        .frame(width: ShelfLayout.stackSide, height: ShelfLayout.stackSide)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.white.opacity(0.07))
        )
        .animation(.easeInOut(duration: 0.2), value: shelf.items)
    }
}

/// Under the square, level with the buttons: how many, and "full" once the
/// shelf takes no more.
private struct ShelfCount: View {
    @ObservedObject var shelf: ShelfStore

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text("\(shelf.items.count)")
                .font(.system(size: 18, weight: .bold).monospacedDigit())
                .contentTransition(.numericText())
            Text(shelf.isFull ? "full" : shelf.items.count == 1 ? "item" : "items")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
        }
        .animation(.easeInOut(duration: 0.2), value: shelf.items.count)
    }
}

/// One item: its thumbnail, or its icon, over its name. Selected, it sits
/// on a lit rounded square.
private struct ShelfCell: View {
    var item: ShelfItem
    var icon: NSImage
    var thumbnail: NSImage?
    var cell: ShelfLayout.Cell
    var isSelected: Bool

    var body: some View {
        VStack(spacing: cell.spacing) {
            ShelfPreviewImage(icon: icon, thumbnail: thumbnail, side: cell.side, corner: 4)
            // Two lines, cut in the middle, so a long name still shows how it
            // ends: the extension, the number after "copy". The frame holds
            // two lines whether the name needs them or not, so every cell is
            // one height and the panel's is the rows' (see `ShelfLayout`).
            Text(item.name)
                .font(.system(size: cell.nameSize, weight: .medium))
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
                .opacity(0.9)
                .frame(width: ShelfLayout.cellWidth - 2 * cell.padding, height: cell.nameHeight, alignment: .top)
        }
        .padding(cell.padding)
        .frame(width: ShelfLayout.cellWidth)
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

/// An item's picture in a `side` square: its icon, filling the square as
/// Finder draws one, until a thumbnail lands; then the thumbnail at its own
/// shape, rounded and edged so a white page reads against the black. The two
/// cross-fade. Shared by the cells, the stack and the home tile.
struct ShelfPreviewImage: View {
    var icon: NSImage
    var thumbnail: NSImage?
    var side: CGFloat
    var corner: CGFloat

    var body: some View {
        ZStack {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: corner, style: .continuous)
                            .strokeBorder(.white.opacity(0.16), lineWidth: 0.5)
                    )
                    .transition(.opacity)
            } else {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .transition(.opacity)
            }
        }
        .frame(width: side, height: side)
        .animation(.easeInOut(duration: 0.25), value: thumbnail != nil)
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
