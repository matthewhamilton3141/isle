//
//  AppleMusicController.swift
//
//  Apple Music over AppleScript, both directions — the same job
//  `SpotifyController` does for Spotify, and deliberately the same shape:
//  a 1 Hz poll that relaxes when nobody is looking, a split read (a cheap
//  per-second pulse and a full track read only when the track changes),
//  compiled scripts reused across polls, and a process-exists guard so the
//  read path never launches Music.
//
//  Where Music differs from Spotify:
//
//   - `song repeat` is three-state (off / one / all) where Spotify's is a
//     boolean. The island's repeat control stays a toggle in both players —
//     off ↔ all, and *one* (set in Music itself) clears to off — so the same
//     button means the same thing whichever player it's aimed at. The model
//     still reads back `.one` faithfully; only the command is a toggle.
//   - Durations are in seconds, not milliseconds.
//   - There is no artwork URL. The cover is `raw data of artwork 1 of current
//     track` — a data blob over an Apple event — so it is read only on a
//     track change, and only when the owner says the cover would be drawn
//     (`wantsArtwork`), exactly as Spotify's CDN fetch is gated.
//

import Foundation
import AppKit

@MainActor
final class AppleMusicController: MediaPlayerController {
    var onUpdate: ((MediaPlaybackModel?) -> Void)?
    var wantsFullRate: (() -> Bool)?
    var wantsArtwork: (() -> Bool)?

    nonisolated static let bundleID = MediaPlayers.appleMusicBundleID
    var bundleID: String { Self.bundleID }
    var displayName: String { "Music" }

    private var timer: Timer?
    private var ticksSinceRead = 0
    private static let relaxedEvery = 3

    /// AppleScript is synchronous and can block on an unresponsive Music, so
    /// every script runs here rather than on the main thread.
    private static let queue = DispatchQueue(label: "com.isle.applemusic")

    // MARK: - Polling lifecycle

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
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

    func pollNow() {
        guard timer != nil else { return }
        poll()
    }

    private func tick() {
        ticksSinceRead += 1
        let full = wantsFullRate?() ?? true
        guard full || ticksSinceRead >= Self.relaxedEvery else { return }
        poll()
    }

    private func poll() {
        ticksSinceRead = 0
        // Answered in-process, so a closed Music costs no AppleScript at all
        // and the read can never be what launches it.
        guard MediaPlayers.isRunning(Self.bundleID) else {
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

    /// Flipped in place rather than set from a local read, so a stale poll
    /// can't fight what Music actually has.
    func toggleShuffle() { run("set shuffle enabled to not shuffle enabled") }

    /// Off ↔ all. A `one` set in Music clears to off, which is what the
    /// island's lit repeat key reads as: on, so pressing it turns it off.
    func toggleRepeat() {
        run("if song repeat is off then\nset song repeat to all\nelse\nset song repeat to off\nend if")
    }

    private func run(_ statement: String) {
        // Sending to `application "Music"` launches it if it isn't running;
        // the island only offers controls while a track is showing, and the
        // guard here covers the race where Music quit under the pointer.
        guard MediaPlayers.isRunning(Self.bundleID) else { return }
        let source = "tell application \"Music\"\n\(statement)\nend tell"
        Self.queue.async {
            guard let script = NSAppleScript(source: source) else { return }
            var error: NSDictionary?
            script.executeAndReturnError(&error)
            if let error {
                NSLog("Isle: Music command failed (\(statement)): \(error)")
            }
        }
    }

    // MARK: - Reading

    /// The per-second read: state, position, shuffle/repeat, and the id that
    /// says whether the cached track fields still apply. `persistent ID` is
    /// stable for the track's lifetime in the library, and for a streamed
    /// track for as long as it's the current one.
    private nonisolated static let pulseSource = """
    set d to (ASCII character 30)
    tell application "Music"
        set ps to (player state as text)
        if ps is "stopped" then return "ST"
        try
            set tk to current track
        on error
            return "ST"
        end try
        return "LT" & d & (persistent ID of tk) & d & ((player position) as text) & d & ps & d & ((shuffle enabled) as text) & d & ((song repeat) as text)
    end tell
    """

    /// The full read, run only when the track changes.
    private nonisolated static let trackSource = """
    set d to (ASCII character 30)
    tell application "Music"
        set ps to (player state as text)
        if ps is "stopped" then return "ST"
        try
            set tk to current track
        on error
            return "ST"
        end try
        return "OK" & d & (persistent ID of tk) & d & (name of tk) & d & (artist of tk) & d & (album of tk) & d & ((duration of tk) as text) & d & ((player position) as text) & d & ps & d & ((shuffle enabled) as text) & d & ((song repeat) as text)
    end tell
    """

    /// The cover bytes, in whatever format Music holds them (JPEG or PNG in
    /// practice). An empty string when the track has no artwork.
    private nonisolated static let artworkSource = """
    tell application "Music"
        try
            return raw data of artwork 1 of current track
        on error
            return ""
        end try
    end tell
    """

    private struct RawState: Equatable {
        var title = ""
        var artist = ""
        var album = ""
        var duration: Double = 0
        var position: Double = 0
        var isPlaying = false
        var isShuffled = false
        var repeatMode: RepeatMode = .off
        /// The persistent id, which is also the key the cover is cached under.
        var trackID = ""
    }

    private struct TrackInfo {
        var id: String
        var title: String
        var artist: String
        var album: String
        var duration: Double
    }

    /// Compiled scripts and the track cache, touched only from `queue`.
    private nonisolated(unsafe) static var compiledPulse: NSAppleScript?
    private nonisolated(unsafe) static var compiledTrack: NSAppleScript?
    private nonisolated(unsafe) static var compiledArtwork: NSAppleScript?
    private nonisolated(unsafe) static var cachedTrack: TrackInfo?

    private nonisolated static func compiled(
        _ cache: inout NSAppleScript?, _ source: String, _ label: String
    ) -> NSAppleScript? {
        if let cache { return cache }
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        guard script.compileAndReturnError(&error) else {
            NSLog("Isle: Music \(label) script failed to compile: \(error ?? [:])")
            return nil
        }
        cache = script
        return script
    }

    private nonisolated static func fields(_ script: NSAppleScript, _ label: String) -> [String]? {
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            NSLog("Isle: Music \(label) read failed: \(error)")
            return nil
        }
        guard let line = result.stringValue else { return nil }
        return line.components(separatedBy: "\u{1e}")
    }

    /// AppleScript renders a real with the user's decimal separator, so a
    /// position of 12.5 arrives as "12,5" in half of Europe. `missing value`
    /// (Music between tracks) parses as zero.
    private nonisolated static func number(_ text: String) -> Double {
        Double(text.replacingOccurrences(of: ",", with: ".")) ?? 0
    }

    /// "playing" and the two scan states all mean the clock is moving.
    private nonisolated static func isPlaying(_ state: String) -> Bool {
        state == "playing" || state == "fast forwarding" || state == "rewinding"
    }

    private nonisolated static func repeatMode(_ text: String) -> RepeatMode {
        switch text {
        case "one": return .one
        case "all": return .all
        default: return .off
        }
    }

    private nonisolated static func readState() -> RawState? {
        guard let pulse = compiled(&compiledPulse, pulseSource, "pulse"),
              let parts = fields(pulse, "pulse") else { return nil }

        guard parts.first == "LT", parts.count >= 6 else {
            cachedTrack = nil
            return nil
        }

        let id = parts[1]
        var state = RawState()
        state.trackID = id
        state.position = number(parts[2])
        state.isPlaying = isPlaying(parts[3])
        state.isShuffled = parts[4] == "true"
        state.repeatMode = repeatMode(parts[5])

        if let track = cachedTrack, track.id == id {
            state.title = track.title
            state.artist = track.artist
            state.album = track.album
            state.duration = track.duration
            return state
        }

        return readTrack()
    }

    private nonisolated static func readTrack() -> RawState? {
        guard let script = compiled(&compiledTrack, trackSource, "track"),
              let parts = fields(script, "track") else { return nil }
        guard parts.first == "OK", parts.count >= 10 else {
            cachedTrack = nil
            return nil
        }

        var state = RawState()
        state.trackID = parts[1]
        state.title = parts[2]
        state.artist = parts[3]
        state.album = parts[4]
        state.duration = number(parts[5])
        state.position = number(parts[6])
        state.isPlaying = isPlaying(parts[7])
        state.isShuffled = parts[8] == "true"
        state.repeatMode = repeatMode(parts[9])

        cachedTrack = TrackInfo(
            id: parts[1],
            title: state.title,
            artist: state.artist,
            album: state.album,
            duration: state.duration
        )
        return state
    }

    /// The cover for the current track, decoded. Nil when there is none or
    /// it won't decode. Runs on `queue`.
    private nonisolated static func readArtwork() -> NSImage? {
        guard let script = compiled(&compiledArtwork, artworkSource, "artwork") else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            NSLog("Isle: Music artwork read failed: \(error)")
            return nil
        }
        let data = result.data
        guard !data.isEmpty else { return nil }
        return NSImage(data: data)
    }

    // MARK: - Model assembly

    /// The track the cached cover belongs to, and the cover itself.
    private var artworkKey: String?
    private var artworkImage: NSImage?

    /// A cover that was declined by `wantsArtwork` and can still be fetched.
    private var pendingArtwork: String?

    private var lastModel: MediaPlaybackModel?
    private var lastRaw: RawState?

    private func emit(_ raw: RawState?) {
        guard raw != lastRaw else { return }
        lastRaw = raw

        guard let raw else {
            artworkKey = nil
            artworkImage = nil
            pendingArtwork = nil
            lastModel = nil
            onUpdate?(nil)
            return
        }

        var model = MediaPlaybackModel()
        model.title = raw.title
        model.artist = raw.artist
        model.album = raw.album
        model.duration = raw.duration
        model.reportedElapsed = raw.position
        model.timestamp = Date()
        model.isPlaying = raw.isPlaying
        model.playbackRate = raw.isPlaying ? 1 : 0
        model.isShuffled = raw.isShuffled
        model.repeatMode = raw.repeatMode
        model.bundleIdentifier = Self.bundleID

        if raw.trackID == artworkKey {
            model.artwork = artworkImage
            lastModel = model
            onUpdate?(model)
        } else {
            // New track: emit at once without the cover (the gradient shows
            // meanwhile), then re-emit once the bytes land — if wanted.
            artworkKey = raw.trackID
            artworkImage = nil
            pendingArtwork = raw.trackID
            lastModel = model
            onUpdate?(model)
            fetchArtworkIfNeeded()
        }
    }

    func fetchArtworkIfNeeded() {
        guard let key = pendingArtwork, wantsArtwork?() ?? true else { return }
        pendingArtwork = nil
        Self.queue.async { [weak self] in
            let image = Self.readArtwork()
            Task { @MainActor in
                // Dropped if the track moved on while this was in flight.
                guard let self, self.artworkKey == key, var updated = self.lastModel else { return }
                self.artworkImage = image
                guard let image else { return }
                updated.artwork = image
                self.lastModel = updated
                self.onUpdate?(updated)
            }
        }
    }
}
