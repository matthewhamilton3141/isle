//
//  FileDrop.swift
//
//  Files dragged onto the notch: noticing the drag, and what the drop face
//  offers for it.
//
//  A drag sends no `mouseMoved`, so the hover monitor goes quiet for its
//  whole length, and the notch window is non-activating, so it gets nothing
//  of its own until the pointer is over it. Two things the system really
//  reports carry it instead:
//
//  - **While the drag is in flight**, the global `leftMouseDragged` events,
//    and the drag pasteboard (`NSPasteboard(name: .drag)`), whose change
//    count moves when a drag starts and whose types say whether it carries
//    files. A drag is "files in flight" from the first dragged event after
//    the button went down that finds a fresh pasteboard with file URLs on
//    it, until the button comes up. That's `FileDragWatch`. Mouse events
//    need no permission for a global monitor (Apple gates only key events
//    behind Accessibility), the same as the `mouseMoved` monitor already
//    running — so this asks for nothing new.
//
//  - **Over the island**, the window is an ordinary drag destination
//    (`NotchWindow.registerForDraggedTypes`), so AppKit hands it the drag's
//    own `draggingEntered` / `Updated` / `Exited` / `performDragOperation`,
//    with the real pasteboard and the real pointer. That's what opens the
//    drop face and lights a target. It works only if the window isn't
//    transparent to the mouse at that moment, which is the other thing the
//    dragged events are for: they keep click-through current while
//    `mouseMoved` is silent.
//
//  Nothing here runs on a timer. Every state change is an event.
//

import AppKit

/// Something a drop can do. The drop face shows only the ones this drop
/// supports, in this order.
enum DropTarget: Hashable, CaseIterable {
    case startClaude
    case keep
    case airDrop
}

/// The files a drag carries, read off its pasteboard when it reaches the
/// island, and what each target would make of them.
struct DropPayload: Equatable {
    let items: [ShelfItem]
    /// AirDrop can take these items on this Mac. Asked once, as the drag
    /// arrives, not on every draw of the face.
    let canAirDrop: Bool

    init(items: [ShelfItem], canAirDrop: Bool) {
        self.items = items
        self.canAirDrop = canAirDrop
    }

    @MainActor
    init(urls: [URL]) {
        items = ShelfStore.unique(urls).map(ShelfItem.init)
        canAirDrop = AirDropSender.canSend(items.map(\.url))
    }

    var urls: [URL] { items.map(\.url) }
    var tally: ItemTally { ItemTally(items) }

    /// The folder "Start Claude here" would open: exactly one item, and a
    /// folder Terminal can be sent into.
    var claudeFolder: URL? {
        guard items.count == 1, let only = items.first, only.isFolder,
              ClaudeLauncher.canStart(in: only.url)
        else { return nil }
        return only.url
    }

    /// "1 folder · isle-website", "3 files · invoice.pdf, mock.png, notes.md".
    var headline: String {
        let kinds = tally.kindsLine
        let names = items.map(\.name).joined(separator: ", ")
        return names.isEmpty ? kinds : "\(kinds) · \(names)"
    }

    /// The URLs a drag pasteboard carries as files, or nil when it carries
    /// none — a promise (Mail, Photos) or plain text isn't a file Isle can
    /// point at.
    static func fileURLs(on pasteboard: NSPasteboard) -> [URL]? {
        guard pasteboard.types?.contains(.fileURL) == true,
              let urls = pasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
              ) as? [URL],
              !urls.isEmpty
        else { return nil }
        return urls
    }
}

/// Tells a file drag under way from every other drag the left button makes
/// — a window, a selection, a slider — from the global mouse events alone.
///
/// Fed by `NotchWindowController`'s global monitor. Only ever reads the drag
/// pasteboard's change count and types; the contents are read when the drag
/// reaches the island, from the drag itself.
@MainActor
final class FileDragWatch {
    /// A drag carrying files is in flight. Reported on every change.
    var onChange: ((Bool) -> Void)?

    private(set) var isDraggingFiles = false {
        didSet {
            guard isDraggingFiles != oldValue else { return }
            onChange?(isDraggingFiles)
        }
    }

    private let pasteboard = NSPasteboard(name: .drag)

    /// The drag pasteboard's change count when the button went down. Nil
    /// while the button is up, or once this press has been decided.
    private var countAtPress: Int?

    func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            isDraggingFiles = false
            countAtPress = pasteboard.changeCount
        case .leftMouseDragged:
            // Decided once per press: the pasteboard is written when the
            // drag starts and not again, so after a fresh write with files
            // on it there's nothing more to learn, and a press that started
            // a drag without files (a window, a selection) costs a change
            // count read per event and nothing else.
            guard let countAtPress, !isDraggingFiles else { return }
            guard pasteboard.changeCount != countAtPress else { return }
            self.countAtPress = nil
            isDraggingFiles = pasteboard.types?.contains(.fileURL) == true
        case .leftMouseUp, .mouseMoved:
            // `mouseMoved` comes only with no button held, so it also ends a
            // drag whose button-up went somewhere a global monitor can't see.
            countAtPress = nil
            isDraggingFiles = false
        default:
            break
        }
    }

    /// The drag ended at Isle's own window — a drop, or the drag leaving
    /// for good — which can arrive before the button-up does.
    func dragConcluded() {
        countAtPress = nil
        isDraggingFiles = false
    }
}
