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
//  None of it touches the file system on the main thread. A path on a
//  network volume can take seconds to answer — longer still for a server
//  that has gone away — and the checks run at launch and on every hover
//  open. So every look at the disk (does it exist, is it a folder, the
//  watch's open and close) goes to one serial queue, and what it finds
//  comes back to the main thread to be published. An item that has just
//  gone can show for as long as that takes; it can't stay, because the
//  answer always lands.
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

    init(url: URL, isFolder: Bool) {
        self.url = url
        self.isFolder = isFolder
    }

    /// Asks the file system. Not for the main thread with a path that may
    /// be on a network volume — see `ShelfFileSystem`.
    init(url: URL) {
        self.init(url: url, isFolder: ShelfFileSystem.live.isFolder(url))
    }
}

/// The questions the shelf asks the disk, kept apart so a harness can stand
/// in a slow volume. Only ever asked on the shelf's queue.
struct ShelfFileSystem: Sendable {
    var exists: @Sendable (URL) -> Bool
    var isFolder: @Sendable (URL) -> Bool

    static let live = ShelfFileSystem(
        exists: { $0.isFileURL && FileManager.default.fileExists(atPath: $0.path) },
        isFolder: { url in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            return (values?.isDirectory ?? false) && !(values?.isPackage ?? false)
        }
    )
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
    private let fileSystem: ShelfFileSystem

    /// Where every look at the disk happens. Serial, so a check and the
    /// watch it leads to land in the order they were asked for.
    private let queue = DispatchQueue(label: "com.isle.shelf", qos: .utility)

    /// One vnode watch per item, keyed by path. Lives on `queue`.
    private let watcher: ShelfWatcher

    /// Paths saved last time and not yet checked: launch's read of the disk
    /// is still out. They count against the room and against duplicates, so
    /// a drop that lands first can't promise space they'll take back.
    private var pending: [String]

    /// A prune is out on the queue, and whether another was asked for while
    /// it was. One at a time: a hover-open over a volume that has hung
    /// shouldn't stack up a check behind it every time.
    private var isPruning = false
    private var pruneAgain = false

    /// Bumped on every add, and noted against what was added, so a prune
    /// that started before an item went back on can't take it off again.
    private var addCount = 0
    private var addedAt: [String: Int] = [:]

    /// File icons, keyed by path. `NSWorkspace.icon(forFile:)` is a Launch
    /// Services lookup; the face redraws on a selection, and asking again
    /// each time bought nothing.
    private var icons: [String: NSImage] = [:]

    init(settings: AppSettings, fileSystem: ShelfFileSystem = .live) {
        self.settings = settings
        self.fileSystem = fileSystem
        self.watcher = ShelfWatcher(queue: queue)
        pending = settings.shelfPaths

        watcher.onEvent = { [weak self] path in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.watchFired(path) }
            }
        }

        // Empty until the disk answers, and then what's still there.
        let paths = pending
        queue.async { [weak self] in
            let found = paths
                .map { URL(fileURLWithPath: $0) }
                .filter(fileSystem.exists)
                .map { ShelfItem(url: $0, isFolder: fileSystem.isFolder($0)) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.loaded(found) }
            }
        }
    }

    var isEmpty: Bool { items.isEmpty }
    var tally: ItemTally { ItemTally(items) }
    var room: Int { max(0, Self.capacity - items.count - pending.count) }

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
    ///
    /// Takes the drop's items as the drag read them, so nothing here asks
    /// the disk. Each one's watch is set up on the queue, and one that
    /// can't be — gone in the moment since the drop — is pruned straight
    /// off.
    @discardableResult
    func add(_ dropped: [ShelfItem]) -> Int {
        var seen = Set<String>()
        let fresh = dropped.filter { seen.insert($0.id).inserted && !isKept($0.id) }
        let kept = Array(fresh.prefix(room))
        guard !kept.isEmpty else { return 0 }
        addCount += 1
        items.append(contentsOf: kept)
        for item in kept {
            addedAt[item.id] = addCount
            watch(item)
        }
        save()
        return kept.count
    }

    /// How many of these a drop would actually keep — what the drop face's
    /// "Keep on shelf" has to say before it's released.
    func wouldKeep(_ urls: [URL]) -> Int {
        let fresh = Self.unique(urls).filter { !isKept($0.path) }
        return min(fresh.count, room)
    }

    func remove(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        items.removeAll { ids.contains($0.id) }
        pending.removeAll { ids.contains($0) }
        ids.forEach(unwatch)
        save()
    }

    func clear() {
        items.map(\.id).forEach(unwatch)
        items.removeAll()
        pending.removeAll()
        save()
    }

    /// Drops anything that's no longer where it was put. Called by every
    /// watch that fires and every time the panel opens. Returns at once:
    /// the check runs on the queue, and what it finds gone is removed when
    /// it lands.
    func prune() {
        guard !isPruning else {
            pruneAgain = true
            return
        }
        isPruning = true
        pruneAgain = false
        let urls = items.map(\.url)
        let asOf = addCount
        let fileSystem = fileSystem
        queue.async { [weak self] in
            let gone = Set(urls.filter { !fileSystem.exists($0) }.map(\.path))
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.pruned(gone, asOf: asOf) }
            }
        }
    }

    func icon(for item: ShelfItem) -> NSImage {
        if let cached = icons[item.id] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: item.url.path)
        icons[item.id] = icon
        return icon
    }

    // MARK: - Private

    private func isKept(_ path: String) -> Bool {
        items.contains { $0.id == path } || pending.contains(path)
    }

    /// Launch's read of the disk landed. Whatever was saved and is still
    /// there goes back on, ahead of anything dropped in the meantime —
    /// unless it was taken off (or the shelf cleared) while the read was out.
    private func loaded(_ found: [ShelfItem]) {
        let wanted = Set(pending)
        pending = []
        let back = found.filter { item in wanted.contains(item.id) && !items.contains { $0.id == item.id } }
        items = back + items
        back.forEach(watch)
        save()
    }

    private func pruned(_ gone: Set<String>, asOf: Int) {
        isPruning = false
        remove(gone.filter { (addedAt[$0] ?? 0) <= asOf })
        if pruneAgain { prune() }
    }

    /// A watch saw its item's path change, or couldn't be set up at all.
    /// The watcher has already re-armed on whatever is at the path now (a
    /// safe-save swaps a new file in); the prune says whether it stays.
    private func watchFired(_ path: String) {
        icons[path] = nil
        prune()
    }

    private func save() {
        settings.shelfPaths = pending + items.map(\.id)
    }

    private func watch(_ item: ShelfItem) {
        watcher.watch(item.id)
    }

    private func unwatch(_ id: String) {
        watcher.unwatch(id)
        icons[id] = nil
        addedAt[id] = nil
    }

    /// File URLs, standardised, each once, in the order given.
    static func unique(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter(\.isFileURL)
            .map(\.standardizedFileURL)
            .filter { seen.insert($0.path).inserted }
    }
}

/// The shelf's vnode watches. Everything here runs on the shelf's queue —
/// `open` on a network volume can block, and so can the `close` a cancel
/// makes — so the dictionary needs no lock, and a watch and the unwatch
/// after it can't pass each other: a source is only ever cancelled after
/// it was set up, and its descriptor is closed by its own cancel handler.
private final class ShelfWatcher: @unchecked Sendable {
    private let queue: DispatchQueue
    private var sources: [String: DispatchSourceFileSystemObject] = [:]

    /// A watched path was deleted, renamed or revoked, or couldn't be
    /// opened to watch. Called on the queue; set once, before any watch.
    var onEvent: (@Sendable (String) -> Void)?

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    func watch(_ path: String) {
        queue.async {
            if !self.arm(path) { self.onEvent?(path) }
        }
    }

    func unwatch(_ path: String) {
        queue.async {
            self.sources.removeValue(forKey: path)?.cancel()
        }
    }

    /// Replaces any watch on `path` with one on whatever is there now.
    /// False when nothing could be opened there.
    private func arm(_ path: String) -> Bool {
        sources.removeValue(forKey: path)?.cancel()
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return false }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.delete, .rename, .revoke], queue: queue
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            // A rename or delete that still leaves something at the path
            // keeps the item: watch that instead. Either way, ask again.
            _ = self.arm(path)
            self.onEvent?(path)
        }
        source.setCancelHandler { close(fd) }
        sources[path] = source
        source.resume()
        return true
    }
}
