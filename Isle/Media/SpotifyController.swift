//
//  SpotifyController.swift
//
//  All interaction with Spotify over AppleScript, both directions:
//
//   - Reading now-playing state, polled once a second. This is the fallback
//     source for when Spotify isn't the system's now-playing owner — e.g. a
//     YouTube tab has grabbed the MediaRemote session — so the notch still
//     shows Spotify whenever Spotify is running, which MediaRemote alone
//     cannot do (it only ever exposes the single active session).
//
//   - Sending every transport command. Isle is Spotify-scoped, so commands
//     must target Spotify by name. MediaRemote's send-command path aims at
//     whichever app owns the now-playing session, which may be a browser —
//     pressing play there would control the wrong app.
//
//  Sending a command to `application "Spotify"` launches it if it isn't
//  running, so the read path guards on the process existing (via System
//  Events) before ever addressing Spotify, and never launches it.
//

import Foundation
import AppKit

@MainActor
final class SpotifyController {
    /// Latest Spotify state, or nil when Spotify isn't running or is stopped.
    var onUpdate: ((MediaPlaybackModel?) -> Void)?

    private var timer: Timer?

    /// AppleScript is synchronous and can block on an unresponsive Spotify, so
    /// every script runs here rather than on the main thread.
    private static let queue = DispatchQueue(label: "com.isle.spotify")

    nonisolated static let bundleID = "com.spotify.client"

    // MARK: - Polling lifecycle

    func start() {
        guard timer == nil else { return }
        // .common so polling continues while the notch is being tracked/dragged.
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        poll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        Self.queue.async {
            let state = Self.readState()
            Task { @MainActor in self.emit(state) }
        }
    }

    // MARK: - Commands

    func playPause() { run("playpause") }
    func nextTrack() { run("next track") }
    func previousTrack() { run("previous track") }
    func seek(to seconds: TimeInterval) { run("set player position to \(max(0, seconds))") }

    private func run(_ statement: String) {
        let source = "tell application \"Spotify\" to \(statement)"
        Self.queue.async {
            guard let script = NSAppleScript(source: source) else { return }
            var error: NSDictionary?
            script.executeAndReturnError(&error)
            if let error {
                NSLog("Isle: Spotify command failed (\(statement)): \(error)")
            }
        }
    }

    // MARK: - Reading

    /// One RS-delimited line describing the current track, or a short status
    /// token. Guarded so it never launches Spotify.
    private nonisolated static let readSource = """
    set d to (ASCII character 30)
    tell application "System Events"
        if not (exists process "Spotify") then return "NR"
    end tell
    tell application "Spotify"
        set ps to (player state as text)
        if ps is "stopped" then return "ST"
        set tk to current track
        set out to "OK" & d & (name of tk) & d & (artist of tk) & d & (album of tk) & d & ((duration of tk) as text) & d & ((player position) as text) & d & ps & d & ((shuffling) as text) & d & ((repeating) as text) & d
        try
            set out to out & (artwork url of tk)
        end try
        return out
    end tell
    """

    private struct RawState: Equatable {
        var title = ""
        var artist = ""
        var album = ""
        var durationMillis: Double = 0
        var position: Double = 0
        var isPlaying = false
        var isShuffled = false
        var isRepeating = false
        var artworkURL = ""
    }

    /// Parses the AppleScript line. Runs off the main thread.
    private nonisolated static func readState() -> RawState? {
        guard let script = NSAppleScript(source: readSource) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            NSLog("Isle: Spotify read failed: \(error)")
            return nil
        }
        guard let line = result.stringValue else { return nil }

        let fields = line.components(separatedBy: "\u{1e}")
        guard fields.first == "OK", fields.count >= 10 else { return nil }

        var state = RawState()
        state.title = fields[1]
        state.artist = fields[2]
        state.album = fields[3]
        state.durationMillis = Double(fields[4]) ?? 0
        state.position = Double(fields[5]) ?? 0
        state.isPlaying = fields[6] == "playing"
        state.isShuffled = fields[7] == "true"
        state.isRepeating = fields[8] == "true"
        state.artworkURL = fields[9]
        return state
    }

    // MARK: - Model assembly

    /// Cached so a steady track doesn't re-download its cover every second.
    private var artworkURL: String?
    private var artworkImage: NSImage?

    /// Last raw read, to suppress redundant emits. Without this the 1 Hz poll
    /// republishes an identical model every second (a paused track never
    /// changes), and that constant view invalidation upstream disrupts the
    /// notch's hover tracking — the panel can stick open and swallow clicks.
    /// When the track is actually playing, `position` advances each tick so
    /// this correctly lets real updates through.
    private var lastRaw: RawState?

    private func emit(_ raw: RawState?) {
        guard raw != lastRaw else { return }
        lastRaw = raw

        guard let raw else {
            artworkURL = nil
            artworkImage = nil
            onUpdate?(nil)
            return
        }

        var model = MediaPlaybackModel()
        model.title = raw.title
        model.artist = raw.artist
        model.album = raw.album
        model.duration = raw.durationMillis / 1000
        model.reportedElapsed = raw.position
        model.timestamp = Date()
        model.isPlaying = raw.isPlaying
        model.playbackRate = raw.isPlaying ? 1 : 0
        model.isShuffled = raw.isShuffled
        model.repeatMode = raw.isRepeating ? .all : .off
        model.bundleIdentifier = Self.bundleID

        if raw.artworkURL == artworkURL {
            model.artwork = artworkImage
            onUpdate?(model)
        } else {
            // New cover: emit immediately without it (the gradient shows
            // meanwhile), then re-emit once the image lands.
            artworkURL = raw.artworkURL.isEmpty ? nil : raw.artworkURL
            artworkImage = nil
            onUpdate?(model)
            if let url = URL(string: raw.artworkURL) {
                fetchArtwork(from: url, for: raw.artworkURL, base: model)
            }
        }
    }

    private func fetchArtwork(from url: URL, for key: String, base: MediaPlaybackModel) {
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data, let image = NSImage(data: data) else { return }
            Task { @MainActor in
                guard let self, self.artworkURL == key else { return }  // track moved on
                self.artworkImage = image
                var updated = base
                updated.artwork = image
                self.onUpdate?(updated)
            }
        }.resume()
    }
}
