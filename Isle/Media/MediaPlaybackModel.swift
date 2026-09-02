//
//  MediaPlaybackModel.swift
//
//  A snapshot of what's playing, from whatever app happens to own the
//  system's now-playing session — Spotify, Music, a browser tab, anything.
//
//  Deliberately a struct: NotchViewModel holds this behind `@Published`,
//  and nesting one ObservableObject inside another silently fails to
//  propagate changes to SwiftUI. A value type just works.
//

import Foundation
import AppKit

struct MediaPlaybackModel: Equatable {
    var title: String = ""
    var artist: String = ""
    var album: String = ""

    /// Track length in seconds. Zero when unknown.
    var duration: TimeInterval = 0

    /// Elapsed time *as reported*, paired with `timestamp` below. Read
    /// `elapsed(at:)` instead of using this directly — between updates the
    /// real position has moved on and this value is stale.
    var reportedElapsed: TimeInterval = 0

    /// When `reportedElapsed` was measured, per the adapter.
    var timestamp: Date = .distantPast

    /// 0 when paused, 1 at normal speed. Used to extrapolate the scrubber
    /// between updates rather than asking the adapter 60 times a second.
    var playbackRate: Double = 0

    var isPlaying: Bool = false
    var isShuffled: Bool = false
    var repeatMode: RepeatMode = .off

    /// Bundle id of the app that owns playback, e.g. `com.spotify.client`.
    var bundleIdentifier: String = ""

    var artwork: NSImage?

    /// Volume is not exposed by MediaRemote at all — it's filled in over
    /// AppleScript, which only works for Spotify and Music. Nil means "this
    /// source doesn't support volume control", and the slider should hide.
    var volume: Double?

    var hasTrack: Bool {
        !title.isEmpty || !artist.isEmpty
    }

    /// Equal in every field a view reads — everything but the elapsed/timestamp
    /// pair. Those two move on every source report while a track plays, but
    /// nothing draws them: the scrubber runs off `NotchViewModel`'s own anchor
    /// (see `displayProgress`). Publishing a model that differs only there
    /// invalidated the whole notch once a second for a change no one could see.
    func hasSameDisplay(as other: MediaPlaybackModel) -> Bool {
        var lhs = self
        var rhs = other
        lhs.reportedElapsed = 0
        rhs.reportedElapsed = 0
        lhs.timestamp = .distantPast
        rhs.timestamp = .distantPast
        return lhs == rhs
    }

    /// Position at a given wall-clock instant, extrapolated from the last
    /// report. Clamped to the track so a late update can't push the
    /// scrubber past the end.
    func elapsed(at date: Date = Date()) -> TimeInterval {
        guard isPlaying, playbackRate != 0 else { return reportedElapsed }
        let projected = reportedElapsed + (date.timeIntervalSince(timestamp) * playbackRate)
        guard duration > 0 else { return max(0, projected) }
        return min(max(0, projected), duration)
    }

    func progress(at date: Date = Date()) -> Double {
        guard duration > 0 else { return 0 }
        return elapsed(at: date) / duration
    }

    /// Name of the source app, for the little attribution label. Falls back
    /// to the raw bundle id if the app isn't installed where we can see it.
    var sourceAppName: String? {
        guard !bundleIdentifier.isEmpty else { return nil }
        guard let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: bundleIdentifier
        ) else { return bundleIdentifier }
        return FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
    }
}

/// Mirrors MediaRemote's repeat constants so the raw values can be passed
/// straight back to `MRMediaRemoteSetRepeatMode`.
enum RepeatMode: Int, Equatable, CaseIterable {
    case off = 1
    case one = 2
    case all = 3

    /// Cycle order for the repeat button: off → all → one → off. Matches
    /// what Music and Spotify both do, so the button feels unsurprising.
    var next: RepeatMode {
        switch self {
        case .off: return .all
        case .all: return .one
        case .one: return .off
        }
    }

    var symbolName: String {
        switch self {
        case .off, .all: return "repeat"
        case .one: return "repeat.1"
        }
    }

    var isActive: Bool { self != .off }
}

/// Formats seconds as m:ss / h:mm:ss for the scrubber labels.
enum TimeFormatter {
    static func string(from interval: TimeInterval) -> String {
        guard interval.isFinite, interval >= 0 else { return "0:00" }
        let total = Int(interval.rounded(.down))
        let seconds = total % 60
        let minutes = (total / 60) % 60
        let hours = total / 3600

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}
