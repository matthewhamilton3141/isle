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
//  running, so the read path guards on the process existing (asked of the
//  workspace, in-process) before ever addressing Spotify, and never launches it.
//

import Foundation
import AppKit

@MainActor
final class SpotifyController {
    /// Latest Spotify state, or nil when Spotify isn't running or is stopped.
    var onUpdate: ((MediaPlaybackModel?) -> Void)?

    /// Asked at every tick whether the read should run at full rate. Nil, or
    /// true, means once a second; false relaxes it to every `relaxedEvery`
    /// ticks. See `tick` for what the owner is expected to answer.
    var wantsFullRate: (() -> Bool)?

    private var timer: Timer?

    /// Ticks since the last read, for the relaxed cadence.
    private var ticksSinceRead = 0

    /// How many ticks a relaxed poll waits between reads. Three seconds is
    /// short enough that a state change the adapter *didn't* push (shuffle,
    /// repeat) still lands before the panel is opened on it, and long enough
    /// to take two thirds of the AppleScript traffic off a collapsed island.
    private static let relaxedEvery = 3

    /// AppleScript is synchronous and can block on an unresponsive Spotify, so
    /// every script runs here rather than on the main thread.
    private static let queue = DispatchQueue(label: "com.isle.spotify")

    nonisolated static let bundleID = "com.spotify.client"

    // MARK: - Polling lifecycle

    func start() {
        guard timer == nil else { return }
        // .common so polling continues while the notch is being tracked/dragged.
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // A fifth of a second of slack lets the kernel coalesce this with
        // other wakeups. Nothing here is timing-critical at that scale — the
        // scrubber runs off its own clock between reads.
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        poll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        ticksSinceRead = 0
    }

    /// Read now rather than at the next tick — for when the panel opens and
    /// the position on screen should be current, not up to three seconds old.
    func pollNow() {
        guard timer != nil else { return }
        poll()
    }

    /// The 1 Hz timer stays; what it does each second depends on whether
    /// anyone is looking. The read costs ~45ms of Apple events (see below),
    /// which is worth paying every second while the panel is open — the
    /// scrubber and the toggles are on screen — or while this poll is the only
    /// source there is. Collapsed, with the adapter already pushing Spotify's
    /// state, nothing it reads is drawn, so it reads every third second.
    private func tick() {
        ticksSinceRead += 1
        let full = wantsFullRate?() ?? true
        guard full || ticksSinceRead >= Self.relaxedEvery else { return }
        poll()
    }

    private func poll() {
        ticksSinceRead = 0
        // Whether Spotify is running is answered in-process. The read script
        // used to open with `tell application "System Events" to exists process
        // "Spotify"`, which costs an Apple-event round trip and a LaunchServices
        // lookup every single second — and it was paid even with Spotify closed,
        // when there was nothing to read. Asking the workspace instead is a
        // local lookup, and it means a closed Spotify costs no AppleScript at all.
        //
        // This still keeps the read path from ever launching Spotify, which is
        // what the System Events guard was there for. The check races the script
        // by however long the hop to `queue` takes — but only by that, and the
        // in-script guard raced the `tell` block that followed it just the same.
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty else {
            emit(nil)
            return
        }
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

    /// Shuffle and repeat are both plain booleans in Spotify's AppleScript — it
    /// exposes no repeat-one, so repeat is only off↔on (surfaced as .off/.all,
    /// see `emit`). We flip the value in-place with `not` rather than passing a
    /// target, so a stale local read can't fight what Spotify actually has.
    func toggleShuffle() { run("set shuffling to not shuffling") }
    func toggleRepeat() { run("set repeating to not repeating") }

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

    // Reading is split in two because every property in a Spotify AppleScript
    // read costs its own Apple-event round trip, and Spotify answers each one in
    // about 10ms. The old single script asked for nine of them, so a poll took
    // ~90ms of the second it ran in — by far the most expensive thing the app did.
    //
    // Five of those nine (title, artist, album, duration, artwork) are properties
    // of the *track*, and cannot change unless the track does. So the per-second
    // read asks only for what actually moves, plus the track's id; the descriptive
    // fields are re-read only when that id changes, and cached against it in
    // between. Nothing goes stale — a field is only served from cache while the
    // track it describes is still the one playing — and the steady-state poll
    // drops to ~45ms.

    /// The per-second read: player state, position, shuffle/repeat, and the id
    /// that says whether the cached track fields still apply.
    private nonisolated static let pulseSource = """
    set d to (ASCII character 30)
    tell application "Spotify"
        set ps to (player state as text)
        if ps is "stopped" then return "ST"
        return "LT" & d & (id of current track) & d & ((player position) as text) & d & ps & d & ((shuffling) as text) & d & ((repeating) as text)
    end tell
    """

    /// The full read, run only when the track changes. Returns the id too, so
    /// what gets cached is keyed by the same read that produced it.
    private nonisolated static let trackSource = """
    set d to (ASCII character 30)
    tell application "Spotify"
        set ps to (player state as text)
        if ps is "stopped" then return "ST"
        set tk to current track
        set out to "OK" & d & (id of tk) & d & (name of tk) & d & (artist of tk) & d & (album of tk) & d & ((duration of tk) as text) & d & ((player position) as text) & d & ps & d & ((shuffling) as text) & d & ((repeating) as text) & d
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

    /// The track fields the pulse read doesn't fetch, and the id they describe.
    private struct TrackInfo {
        var id: String
        var title: String
        var artist: String
        var album: String
        var durationMillis: Double
        var artworkURL: String
    }

    /// Compiled scripts and the track cache. `NSAppleScript` compiles lazily on
    /// first execution and a fresh instance recompiles from source, so building
    /// one per poll meant recompiling — security policy check and all — once a
    /// second forever. All three are touched only from `queue`, which is serial.
    private nonisolated(unsafe) static var compiledPulse: NSAppleScript?
    private nonisolated(unsafe) static var compiledTrack: NSAppleScript?
    private nonisolated(unsafe) static var cachedTrack: TrackInfo?

    /// Compiles on first use and reuses thereafter. Queue-only, like the statics.
    private nonisolated static func compiled(
        _ cache: inout NSAppleScript?, _ source: String, _ label: String
    ) -> NSAppleScript? {
        if let cache { return cache }
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        guard script.compileAndReturnError(&error) else {
            NSLog("Isle: Spotify \(label) script failed to compile: \(error ?? [:])")
            return nil
        }
        cache = script
        return script
    }

    /// Runs a compiled script and splits its RS-delimited line into fields.
    private nonisolated static func fields(_ script: NSAppleScript, _ label: String) -> [String]? {
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            NSLog("Isle: Spotify \(label) read failed: \(error)")
            return nil
        }
        guard let line = result.stringValue else { return nil }
        return line.components(separatedBy: "\u{1e}")
    }

    /// Current Spotify state, or nil when it's stopped or the read failed.
    /// Runs off the main thread, on `queue`.
    private nonisolated static func readState() -> RawState? {
        guard let pulse = compiled(&compiledPulse, pulseSource, "pulse"),
              let parts = fields(pulse, "pulse") else { return nil }

        // Stopped, or a shape we don't recognise: drop the cache so a later
        // resume can't be answered with fields from before it.
        guard parts.first == "LT", parts.count >= 6 else {
            cachedTrack = nil
            return nil
        }

        let id = parts[1]
        var state = RawState()
        state.position = Double(parts[2]) ?? 0
        state.isPlaying = parts[3] == "playing"
        state.isShuffled = parts[4] == "true"
        state.isRepeating = parts[5] == "true"

        if let track = cachedTrack, track.id == id {
            state.title = track.title
            state.artist = track.artist
            state.album = track.album
            state.durationMillis = track.durationMillis
            state.artworkURL = track.artworkURL
            return state
        }

        // New track: pay for the descriptive fields, and take the whole state
        // from that read so every field in it came from one moment.
        return readTrack()
    }

    /// The full read. Refreshes the track cache and returns a complete state.
    private nonisolated static func readTrack() -> RawState? {
        guard let script = compiled(&compiledTrack, trackSource, "track"),
              let parts = fields(script, "track") else { return nil }
        guard parts.first == "OK", parts.count >= 11 else {
            cachedTrack = nil
            return nil
        }

        var state = RawState()
        state.title = parts[2]
        state.artist = parts[3]
        state.album = parts[4]
        state.durationMillis = Double(parts[5]) ?? 0
        state.position = Double(parts[6]) ?? 0
        state.isPlaying = parts[7] == "playing"
        state.isShuffled = parts[8] == "true"
        state.isRepeating = parts[9] == "true"
        state.artworkURL = parts[10]

        cachedTrack = TrackInfo(
            id: parts[1],
            title: state.title,
            artist: state.artist,
            album: state.album,
            durationMillis: state.durationMillis,
            artworkURL: state.artworkURL
        )
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
