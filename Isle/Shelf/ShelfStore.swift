//
//  ShelfStore.swift
//
//  The shelf: a few files and folders kept within reach of the notch, for
//  dragging out again, AirDropping, or starting Claude in.
//
//  It holds references, never copies. Isle isn't sandboxed, so a reference
//  is the path itself — no security-scoped bookmark is needed to reach it
//  again. A path, rather than a plain bookmark, on purpose: a bookmark
//  follows a file into the Trash and would keep showing it there. A file
//  that's moved, renamed, trashed or on a volume that's gone is no longer
//  where the user put it, and the shelf drops it rather than show something
//  it can't hand back.
//
//  That check is event-driven: each item has a vnode watch on it (an
//  `O_EVTONLY` descriptor, so it never holds a volume from unmounting), and
//  a delete, rename or revoke re-checks the shelf at once. Every open of the
//  panel checks again, which covers anything a watch can't see.
//

import AppKit
import Combine

/// One thing on the shelf.
struct ShelfItem: Identifiable, Equatable {
    let url: URL
    /// A folder you can `cd` into: a directory that isn't a package. An app
    /// or a document bundle is a file as far as the user is concerned.
    let isFolder: Bool

    var id: String { url.path }
    var name: String { url.lastPathComponent }

    init(url: URL) {
        self.url = url
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        isFolder = (values?.isDirectory ?? false) && !(values?.isPackage ?? false)
    }
}

/// "1 folder, 3 files": what a set of items is, by kind. Shared by the drop
/// face, the shelf face and the home tile so they all count the same way.
struct ItemTally: Equatable {
    var folders = 0
    var files = 0

    init(_ items: [ShelfItem]) {
        folders = items.filter(\.isFolder).count
        files = items.count - folders
    }

    var total: Int { folders + files }

    /// "4 items", or "1 item".
    var itemsLine: String { Self.count(total, "item") }

    /// "1 folder, 3 files", "2 files", "1 folder".
    var kindsLine: String {
        [folders > 0 ? Self.count(folders, "folder") : nil,
         files > 0 ? Self.count(files, "file") : nil]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    static func count(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
    }
}

@MainActor
final class ShelfStore: ObservableObject {
    /// The most the shelf holds. Quick storage, not a second Finder: ten is
    /// two rows of five in the face's column, every one of them in view with
    /// no scrolling, and the face and the drop face say so once it's full.
    static let capacity = 10

    /// Oldest first, as dropped.
    @Published private(set) var items: [ShelfItem] = [] {
        didSet {
            guard items != oldValue else { return }
            canAirDrop = AirDropSender.canSend(items.map(\.url))
        }
    }

    /// AirDrop can take what's on the shelf. Asked once per change to the
    /// items rather than on every draw of the face.
    @Published private(set) var canAirDrop = false

    private let settings: AppSettings

    /// One vnode watch per item, keyed by path.
    private var watches: [String: DispatchSourceFileSystemObject] = [:]

    /// File icons, keyed by path. `NSWorkspace.icon(forFile:)` is a Launch
    /// Services lookup; the face redraws on a selection, and asking again
    /// each time bought nothing.
    private var icons: [String: NSImage] = [:]

    init(settings: AppSettings) {
        self.settings = settings
        items = settings.shelfPaths
            .map { URL(fileURLWithPath: $0) }
            .filter { Self.exists($0) }
            .map(ShelfItem.init)
        // An init assignment skips `didSet`.
        canAirDrop = AirDropSender.canSend(items.map(\.url))
        save()
        items.forEach(watch)
    }

    var isEmpty: Bool { items.isEmpty }
    var tally: ItemTally { ItemTally(items) }
    var room: Int { max(0, Self.capacity - items.count) }

    /// At `capacity`: the face says so, and the drop face's Keep stops
    /// lighting.
    var isFull: Bool { room == 0 }

    /// The folder "Start Claude here" means on the shelf as a whole: its one
    /// folder, when it holds exactly one. With two, there's no telling which.
    var onlyFolder: ShelfItem? {
        let folders = items.filter(\.isFolder)
        return folders.count == 1 ? folders[0] : nil
    }

    /// Keeps what fits, oldest first, and skips anything already kept.
    /// Returns how many went on.
    @discardableResult
    func add(_ urls: [URL]) -> Int {
        let fresh = Self.unique(urls).filter { url in
            Self.exists(url) && !items.contains { $0.url.path == url.path }
        }
        let kept = fresh.prefix(room).map(ShelfItem.init)
        guard !kept.isEmpty else { return 0 }
        items.append(contentsOf: kept)
        kept.forEach(watch)
        save()
        return kept.count
    }

    /// How many of these a drop would actually keep — what the drop face's
    /// "Keep on shelf" has to say before it's released.
    func wouldKeep(_ urls: [URL]) -> Int {
        let fresh = Self.unique(urls).filter { url in !items.contains { $0.url.path == url.path } }
        return min(fresh.count, room)
    }

    func remove(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        items.removeAll { ids.contains($0.id) }
        ids.forEach(unwatch)
        save()
    }

    func clear() {
        items.map(\.id).forEach(unwatch)
        items.removeAll()
        save()
    }

    /// Drops anything that's no longer where it was put. Called by every
    /// watch that fires and every time the panel opens.
    func prune() {
        let gone = Set(items.filter { !Self.exists($0.url) }.map(\.id))
        if !gone.isEmpty {
            remove(gone)
        }
    }

    func icon(for item: ShelfItem) -> NSImage {
        if let cached = icons[item.id] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: item.url.path)
        icons[item.id] = icon
        return icon
    }

    // MARK: - Private

    private func save() {
        settings.shelfPaths = items.map(\.id)
    }

    /// Watches one item for leaving its path. A rename or delete that still
    /// leaves something at the path (a safe-save swaps a new file in) keeps
    /// the item and re-arms the watch on whatever is there now.
    private func watch(_ item: ShelfItem) {
        unwatch(item.id)
        let fd = open(item.url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.delete, .rename, .revoke], queue: .main
        )
        let id = item.id
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.prune()
                if let still = self.items.first(where: { $0.id == id }) {
                    self.icons[id] = nil
                    self.watch(still)
                }
            }
        }
        source.setCancelHandler { close(fd) }
        watches[id] = source
        source.resume()
    }

    private func unwatch(_ id: String) {
        watches.removeValue(forKey: id)?.cancel()
        icons[id] = nil
    }

    private static func exists(_ url: URL) -> Bool {
        url.isFileURL && FileManager.default.fileExists(atPath: url.path)
    }

    /// File URLs, standardised, each once, in the order given.
    static func unique(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter(\.isFileURL)
            .map(\.standardizedFileURL)
            .filter { seen.insert($0.path).inserted }
    }
}
