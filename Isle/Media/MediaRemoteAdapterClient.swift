//
//  MediaRemoteAdapterClient.swift
//
//  Reads system now-playing state by running the bundled
//  mediaremote-adapter Perl script as a long-lived subprocess and parsing
//  the JSON-lines it writes to stdout.
//
//  Why a subprocess at all: since roughly macOS 15.4, calling
//  MRMediaRemoteGetNowPlayingInfo in-process returns an empty dictionary
//  for unentitled apps. /usr/bin/perl is Apple-signed and does hold the
//  entitlement, so the adapter loads MediaRemote there and pipes results
//  back. Commands are sent to Spotify directly over AppleScript — see
//  SpotifyController.
//
//  Upstream: github.com/ungive/mediaremote-adapter (BSD-3-Clause).
//  Build it with scripts/build-mediaremote-adapter.sh.
//

import Foundation
import AppKit

@MainActor
final class MediaRemoteAdapterClient {
    /// Called on the main actor whenever playback state changes.
    var onUpdate: ((MediaPlaybackModel) -> Void)?

    private var process: Process?
    private var readSource: DispatchSourceRead?

    /// Where the pipe is read, split into lines and decoded — JSON and
    /// artwork both. Serial, so lines reach the main actor in the order the
    /// adapter wrote them. Its own queue rather than a global one so that
    /// ordering is a property of the queue and not of luck.
    private static let readerQueue = DispatchQueue(
        label: "com.isle.mediaremote-reader", qos: .utility
    )

    /// Accumulated state. The adapter streams *diffs* by default, so each
    /// line may carry only the keys that changed; we merge into this.
    private var current = MediaPlaybackModel()

    private var isRunning: Bool { process?.isRunning ?? false }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }

        guard let scriptURL = Bundle.main.url(
            forResource: "mediaremote-adapter",
            withExtension: "pl"
        ) else {
            NSLog("Isle: mediaremote-adapter.pl missing from bundle — run scripts/build-mediaremote-adapter.sh")
            return
        }

        let frameworkURL = scriptURL
            .deletingLastPathComponent()
            .appendingPathComponent("MediaRemoteAdapter.framework")

        guard FileManager.default.fileExists(atPath: frameworkURL.path) else {
            NSLog("Isle: MediaRemoteAdapter.framework missing from bundle — run scripts/build-mediaremote-adapter.sh")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [
            scriptURL.path,
            frameworkURL.path,
            "stream",
            // Coalesce bursts. Scrubbing in Spotify emits a lot of updates
            // and we only redraw at display rate anyway.
            "--debounce=100",
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = nil

        // Diffing stays on (the default) so full artwork isn't re-sent on
        // every tick — it's a base64 JPEG and dominates the payload.
        process.terminationHandler = { [weak self] ended in
            Task { @MainActor in self?.handleTermination(of: ended) }
        }

        do {
            try process.run()
        } catch {
            NSLog("Isle: failed to launch mediaremote-adapter: \(error)")
            return
        }

        self.process = process
        attachReader(to: pipe.fileHandleForReading)
    }

    func stop() {
        readSource?.cancel()
        readSource = nil

        let wasRunning = process != nil
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil

        // Report an empty model so the notch doesn't hold a stale track while
        // the feed is off. Done here rather than left to the termination
        // handler, which no longer acts for a process that has been let go —
        // see `handleTermination(of:)`.
        if wasRunning {
            current = MediaPlaybackModel()
            onUpdate?(current)
        }
    }

    // MARK: - Reading

    private func attachReader(to handle: FileHandle) {
        // A DispatchSource on the raw fd rather than readabilityHandler:
        // the handler-based API delivers on an internal queue and is
        // awkward to cancel cleanly when the process dies mid-read.
        let source = DispatchSource.makeReadSource(
            fileDescriptor: handle.fileDescriptor,
            queue: Self.readerQueue
        )

        // The process this reader belongs to. A `stop()` then `start()` in
        // quick succession leaves the old reader draining its last bytes
        // while a new process is already up; the main-side handler checks
        // this so a dead process can't write into the live one's state.
        let owner = process
        let parser = LineParser()

        source.setEventHandler { [weak self] in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, self.process === owner else { return }
                        self.stop()
                    }
                }
                return
            }

            // Everything expensive happens here, on the reader queue: the
            // line split, the JSON decode and — the part that used to hitch
            // the main thread once per track — the base64 and JPEG decode of
            // a 640px cover. The main actor receives values ready to merge.
            let decoded = parser.lines(appending: chunk).compactMap(Self.decode)
            guard !decoded.isEmpty else { return }

            // `DispatchQueue.main.async` rather than a Task hop: it is FIFO,
            // which keeps diffs applying in the order the adapter emitted them.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.process === owner else { return }
                    for line in decoded {
                        self.handle(line)
                    }
                }
            }
        }

        source.resume()
        readSource = source
    }

    /// Splits the pipe's bytes into lines. Touched only on `readerQueue`.
    ///
    /// The adapter emits one JSON object per line. Artwork payloads run to
    /// hundreds of KB and routinely arrive split across reads, so any trailing
    /// partial line is held until its newline shows up. `scanned` remembers
    /// how far that partial line has already been searched: without it every
    /// chunk re-scanned the whole buffer from the start, which on a 300KB
    /// cover arriving in 8KB pieces was several megabytes of comparisons and
    /// copies per track.
    private final class LineParser: @unchecked Sendable {
        private var buffer = Data()
        private var scanned = 0

        func lines(appending chunk: Data) -> [Data] {
            buffer.append(chunk)

            var lines: [Data] = []
            var lineStart = buffer.startIndex
            var search = scanned
            // The slice shares `buffer`'s indices, so `newline` indexes
            // `buffer` directly.
            while let newline = buffer[search...].firstIndex(of: UInt8(ascii: "\n")) {
                lines.append(buffer.subdata(in: lineStart..<newline))
                lineStart = buffer.index(after: newline)
                search = lineStart
            }

            // Rebase once per chunk rather than per line. A fresh `Data` from
            // a slice starts at index 0, which is what makes `scanned` a
            // plain offset that survives the rebase.
            if lineStart != buffer.startIndex {
                buffer = Data(buffer[lineStart...])
            }
            scanned = buffer.endIndex
            return lines
        }
    }

    /// One adapter line, decoded as far as it can be off the main actor.
    private struct DecodedLine: @unchecked Sendable {
        enum Artwork {
            /// The payload carried no artwork key at all.
            case absent
            /// It carried one, and this is what it decoded to (nil if the
            /// bytes weren't an image).
            case set(NSImage?)
            /// It carried one that wasn't valid base64. Left as it was.
            case undecodable
        }

        let envelope: StreamEnvelope
        let artwork: Artwork
    }

    private nonisolated static func decode(_ line: Data) -> DecodedLine? {
        guard !line.isEmpty,
              let envelope = try? JSONDecoder().decode(StreamEnvelope.self, from: line)
        else {
            return nil  // partial or unrecognised line; nothing useful to do
        }

        let artwork: DecodedLine.Artwork
        if let base64 = envelope.payload.artworkData {
            let cleaned = base64.trimmingCharacters(in: .whitespacesAndNewlines)
            if let data = Data(base64Encoded: cleaned) {
                artwork = .set(decodeArtwork(data))
            } else {
                artwork = .undecodable
            }
        } else {
            artwork = .absent
        }
        return DecodedLine(envelope: envelope, artwork: artwork)
    }

    /// Isle is scoped to Spotify. MediaRemote reports whichever app owns the
    /// system now-playing session — Music, a browser tab, anything — so any
    /// non-Spotify owner is treated as "nothing playing" and collapses the
    /// notch rather than surfacing another app's track.
    private static let spotifyBundleID = "com.spotify.client"

    private func handle(_ line: DecodedLine) {
        let envelope = line.envelope
        merge(envelope.payload, artwork: line.artwork, isDiff: envelope.diff ?? false)

        // `current` still tracks the true system owner (merged from diffs), but
        // we only publish it when that owner is Spotify. Publishing an empty
        // model otherwise keeps stale non-Spotify data off screen without
        // discarding what we know about the current session.
        if current.bundleIdentifier == Self.spotifyBundleID {
            onUpdate?(current)
        } else {
            onUpdate?(MediaPlaybackModel())
        }
    }

    /// The adapter died on its own. Only the *current* process gets to tear
    /// the client down: a `stop()` followed quickly by a `start()` — the
    /// screen locking and unlocking, a mode flipped twice — has the old
    /// process's termination arriving after the new one is already running,
    /// and acting on it cancelled the new reader and dropped the new process
    /// reference. That left a perl subprocess nobody was reading from, which
    /// eventually blocked on a full pipe and lingered until Isle quit, and a
    /// notch that showed nothing until the next restart.
    private func handleTermination(of ended: Process) {
        guard ended === process else { return }
        readSource?.cancel()
        readSource = nil
        process = nil

        // Report an empty model so the notch collapses rather than freezing
        // on a stale track if the adapter dies.
        current = MediaPlaybackModel()
        onUpdate?(current)
    }

    // MARK: - Merging

    /// Applies a payload over the accumulated state.
    ///
    /// When `isDiff` is true, absent keys mean "unchanged" and are kept.
    /// When it's false the payload is authoritative, so absent keys are
    /// cleared — otherwise a track with no album would inherit the previous
    /// track's album.
    private func merge(_ payload: StreamPayload, artwork: DecodedLine.Artwork, isDiff: Bool) {
        func take<T>(_ new: T?, _ existing: T, default fallback: T) -> T {
            if let new { return new }
            return isDiff ? existing : fallback
        }

        current.title = take(payload.title, current.title, default: "")
        current.artist = take(payload.artist, current.artist, default: "")
        current.album = take(payload.album, current.album, default: "")
        current.duration = take(payload.duration, current.duration, default: 0)
        current.playbackRate = take(payload.playbackRate, current.playbackRate, default: 0)
        current.isPlaying = take(payload.playing, current.isPlaying, default: false)
        current.bundleIdentifier = take(
            payload.parentApplicationBundleIdentifier ?? payload.bundleIdentifier,
            current.bundleIdentifier,
            default: ""
        )

        if let shuffle = payload.shuffleMode {
            // The adapter uses MediaRemote's constants, where 1 means off.
            current.isShuffled = shuffle != 1
        } else if !isDiff {
            current.isShuffled = false
        }

        if let repeatRaw = payload.repeatMode {
            current.repeatMode = RepeatMode(rawValue: repeatRaw) ?? .off
        } else if !isDiff {
            current.repeatMode = .off
        }

        // Elapsed and timestamp are a matched pair — "position P, measured at
        // time T" — and must move together or not at all. The old code
        // advanced the timestamp on *every* diff, including the many that
        // carry no new elapsedTime; that re-stamped a stale position as
        // "measured now", freezing the scrubber there and making the stale
        // value look fresh enough to override a real seek. So only touch the
        // clock when a new elapsed actually arrives; a diff without one leaves
        // both fields alone and extrapolation keeps running from the last real
        // reading.
        if let elapsed = payload.elapsedTime {
            current.reportedElapsed = elapsed
            if let stamp = payload.timestamp, let date = Self.parseTimestamp(stamp) {
                current.timestamp = date
            } else {
                current.timestamp = Date()
            }
        } else if !isDiff {
            current.reportedElapsed = 0
            current.timestamp = Date()
        }

        // Already decoded on the reader queue — see `decode`.
        switch artwork {
        case .set(let image):
            current.artwork = image
        case .undecodable:
            break
        case .absent:
            if !isDiff { current.artwork = nil }
        }
    }

    /// Decodes artwork with its `size` pinned to the bitmap's true pixel
    /// dimensions.
    ///
    /// `NSImage(data:)` derives `size` from the file's DPI metadata, not its
    /// pixel count. Artwork from Spotify and Music routinely carries a
    /// non-72 DPI tag, so a 640x640 JPEG can arrive claiming to be 320x320
    /// points — and AppKit then treats it as a low-resolution image, throwing
    /// away half the detail before SwiftUI ever scales it. Overriding `size`
    /// to the real pixel dimensions makes the full bitmap available, which is
    /// what makes the 18pt collapsed thumbnail look sharp instead of mushy.
    private nonisolated static func decodeArtwork(_ data: Data) -> NSImage? {
        guard let rep = NSBitmapImageRep(data: data) else {
            return NSImage(data: data)
        }
        let image = NSImage(size: NSSize(width: rep.pixelsWide, height: rep.pixelsHigh))
        rep.size = image.size
        image.addRepresentation(rep)
        return image
    }

    /// The adapter emits whole-second timestamps (`2026-08-25T19:12:47Z`) but
    /// switches to fractional seconds under `--micros`. ISO8601DateFormatter is
    /// strict about which of the two it will accept, so try both — a formatter
    /// configured for fractional seconds returns nil on a whole-second string,
    /// which would silently peg every timestamp to `Date()` and make the
    /// scrubber drift.
    private static func parseTimestamp(_ string: String) -> Date? {
        wholeSecondFormatter.date(from: string)
            ?? fractionalFormatter.date(from: string)
    }

    private static let wholeSecondFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

// MARK: - Wire format

/// The adapter's `stream` output: one of these per line.
private struct StreamEnvelope: Decodable {
    let diff: Bool?
    let payload: StreamPayload
}

private struct StreamPayload: Decodable {
    let title: String?
    let artist: String?
    let album: String?
    let duration: Double?
    let elapsedTime: Double?
    let shuffleMode: Int?
    let repeatMode: Int?
    let artworkData: String?
    let timestamp: String?
    let playbackRate: Double?
    let playing: Bool?
    let bundleIdentifier: String?
    let parentApplicationBundleIdentifier: String?
}
