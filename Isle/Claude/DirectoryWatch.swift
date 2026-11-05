//
//  DirectoryWatch.swift
//
//  A directory watch that follows the *path*, not the vnode.
//
//  A DispatchSource file-system watch holds an open descriptor, and so a
//  vnode. Delete the directory and make it again — a reinstall, `rm -rf
//  ~/.isle` — and the new one is a different vnode: the old watch keeps
//  pointing at the dead one and never fires again, so the bridge goes deaf
//  until it is stopped and started. This one notices its directory being
//  deleted or renamed away, and re-arms on whatever is at the path now.
//
//  While the directory is missing, it watches the nearest ancestor that does
//  exist (the parent, or further up if that went too), and walks back down as
//  each level reappears. Event-driven all the way: no timer ever checks.
//

import Foundation

final class DirectoryWatch {
    /// What the directory being watched did.
    enum Change {
        /// An entry inside it was added, removed or renamed.
        case contents
        /// It went away, or a new directory took its place: rescan from
        /// scratch (an empty scan when it's gone).
        case replaced
    }

    private let url: URL
    private let queue: DispatchQueue
    private let onChange: (Change) -> Void

    // Touched only on `queue`.
    private var source: DispatchSourceFileSystemObject?
    private var watchingTarget = false
    private var isStopped = true

    /// `onChange` is called on `queue`.
    init(url: URL, queue: DispatchQueue, onChange: @escaping (Change) -> Void) {
        self.url = url
        self.queue = queue
        self.onChange = onChange
    }

    deinit {
        source?.cancel()
    }

    func start() {
        queue.async { [self] in
            guard isStopped else { return }
            isStopped = false
            arm()
        }
    }

    func stop() {
        queue.async { [self] in
            isStopped = true
            source?.cancel()
            source = nil
        }
    }

    /// Opens the deepest existing directory on the way to `url` and watches
    /// it. On `queue`.
    private func arm() {
        source?.cancel()
        source = nil
        guard !isStopped else { return }

        var target = url
        var fd = open(target.path, O_EVTONLY)
        while fd < 0 {
            // Only a missing level is a reason to look further up; anything
            // else (permissions) won't be fixed by watching the parent.
            guard errno == ENOENT || errno == ENOTDIR else { return }
            let parent = target.deletingLastPathComponent()
            guard parent.path != target.path else { return }
            target = parent
            fd = open(target.path, O_EVTONLY)
        }
        watchingTarget = target.path == url.path

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .revoke],
            queue: queue
        )
        source.setEventHandler { [weak self, unowned source] in
            self?.handle(source.data)
        }
        source.setCancelHandler { close(fd) }
        self.source = source
        source.resume()

        // The watch registers on this queue once this block returns, so check
        // after that: anything that happened in between fired no event.
        let path = target.path
        queue.async { [weak self] in
            self?.verify(source, fd: fd, path: path)
        }
    }

    /// Catches what the watch can't have seen, going up: the directory it
    /// opened deleted before the watch registered (a `rm -rf` in progress —
    /// an unlinked directory never reports its own deletion), or, while on an
    /// ancestor, the next level down appearing in the meantime.
    private func verify(_ armed: DispatchSourceFileSystemObject, fd: Int32, path: String) {
        guard !isStopped, source === armed else { return }
        var held = stat(), atPath = stat()
        let intact = fstat(fd, &held) == 0 && stat(path, &atPath) == 0
            && held.st_dev == atPath.st_dev && held.st_ino == atPath.st_ino
        if !intact {
            arm()
            onChange(.replaced)
        } else if !watchingTarget,
                  access(nextLevel(below: URL(fileURLWithPath: path)).path, F_OK) == 0 {
            arm()
            if watchingTarget { onChange(.replaced) }
        }
    }

    /// The path one level below `ancestor` on the way to `url`.
    private func nextLevel(below ancestor: URL) -> URL {
        let have = ancestor.pathComponents.count
        var next = ancestor
        next.appendPathComponent(url.pathComponents[have])
        return next
    }

    private func handle(_ event: DispatchSource.FileSystemEvent) {
        guard !isStopped else { return }
        if watchingTarget {
            if event.isDisjoint(with: [.delete, .rename, .revoke]) {
                onChange(.contents)
            } else {
                // Gone, or moved out from under the path: whatever is at the
                // path now (possibly nothing yet) is what counts.
                arm()
                onChange(.replaced)
            }
        } else {
            // Something changed in an ancestor — perhaps the next level down
            // (or the directory itself) now exists, or the ancestor went too.
            arm()
            if watchingTarget { onChange(.replaced) }
        }
    }
}
