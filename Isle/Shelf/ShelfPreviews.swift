//
//  ShelfPreviews.swift
//
//  What the shelf shows each item as: Finder's icon, and then — for a file
//  QuickLook can draw — the file itself, as a thumbnail: a PDF's first page,
//  the image, a frame of the video.
//
//  The store does the bookkeeping (see `ShelfStore`'s previews); this is the
//  pieces it's built from. A thumbnail is of a file as it was when it was
//  made, so each one is kept under a stamp of the file then — its modified
//  date and size — and a file whose stamp has moved on gets a new one. The
//  stamp is read on the shelf's queue like every other look at the disk, and
//  QuickLook does its drawing out of process, so a file on a slow volume
//  holds up nothing but its own preview.
//

import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// A file as it is now, as far as a preview is concerned: any save changes
/// the modified date, the size, or both.
struct ShelfStamp: Hashable, Sendable {
    var modified: Date
    var size: Int
    /// On a disk this Mac holds rather than a server. Only these get a
    /// thumbnail: QuickLook would read a video or a long PDF over the network
    /// to draw one, every time the file changed. A server's files keep their
    /// icons.
    var isLocal: Bool
}

/// What a thumbnail is a thumbnail of. The cache is keyed by it, so a file
/// put back on the shelf unchanged gets the one it had.
struct ShelfPreviewKey: Hashable, Sendable {
    var path: String
    var stamp: ShelfStamp
}

/// How one item looks on the shelf. Either part can still be on its way:
/// with neither, the item shows the icon for its kind (see
/// `ShelfStore.icon(for:)`).
struct ShelfPreview {
    /// Finder's icon for this file, custom icons and all, from the queue.
    var icon: NSImage?
    /// QuickLook's drawing of the file. Nil for a folder, for anything
    /// QuickLook can't draw, and until it lands.
    var thumbnail: NSImage?
    /// The stamp the item was last looked at with. Nil for a folder.
    var stamp: ShelfStamp?
}

/// Makes thumbnails. Kept apart, like `ShelfFileSystem`, so a harness can
/// stand in a slow one.
struct ShelfThumbnailer: Sendable {
    /// Starts a thumbnail of the file at `url`, fitted to `size` points at
    /// `scale` pixels a point, and returns a way to call it off. `done` is
    /// called once, on any thread, with the image, or nil when there's
    /// nothing to draw. Called on the shelf's queue; must return at once.
    var generate: @Sendable (
        _ url: URL, _ size: CGSize, _ scale: CGFloat,
        _ done: @escaping @Sendable (CGImage?) -> Void
    ) -> @Sendable () -> Void

    static let quickLook = ShelfThumbnailer { url, size, scale, done in
        // `.thumbnail` alone: what the file looks like, or nothing. Asked for
        // an icon as well, QuickLook would answer a folder or a zip with the
        // icon the shelf already has.
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: size, scale: scale, representationTypes: .thumbnail
        )
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
            done(representation?.cgImage)
        }
        return { QLThumbnailGenerator.shared.cancel(request) }
    }
}

/// One thumbnail on its way. Its `cancel` is set and called on the shelf's
/// queue only; the store holds it on the main thread by identity, so a
/// thumbnail that lands for a job that has since been replaced is dropped.
final class ShelfPreviewJob: @unchecked Sendable {
    let key: ShelfPreviewKey
    var cancel: (@Sendable () -> Void)?
    var isCancelled = false

    init(key: ShelfPreviewKey) {
        self.key = key
    }
}

/// An item to look at on the queue, and what the main thread already knows
/// about it.
struct ShelfLookRequest: Sendable {
    var url: URL
    var isFolder: Bool
    var known: ShelfStamp?
    var hasIcon: Bool
}

/// What the queue found.
struct ShelfLook: @unchecked Sendable {
    var path: String
    var stamp: ShelfStamp?
    /// Only when it was asked for: there was none yet, or the file changed.
    var icon: NSImage?
}

extension ShelfFileSystem {
    /// The icon for a kind of thing, from its extension alone — no look at
    /// the disk, so it's what an item shows before the queue has answered.
    static func kindIcon(isFolder: Bool, pathExtension: String) -> NSImage {
        let type = isFolder ? .folder : (UTType(filenameExtension: pathExtension) ?? .data)
        return NSWorkspace.shared.icon(for: type)
    }
}
