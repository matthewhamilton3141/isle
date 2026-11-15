//
//  MeterWatchdog.swift
//
//  Decides when a level meter that should be moving has stalled, and when
//  rebuilding it is worth another try. Pure logic: `SystemAudioLevels` feeds
//  it the analyzer's callback count about once a second from the publish
//  path it already runs, and acts on what it says.
//
//  What it is for, seen on 13 Nov 2026: Spotify playing on AirPods, the
//  meter "running" by every account Core Audio gave (each AudioDeviceStart
//  returned noErr, the session logged `Started Input`), and the IOProc not
//  called once in eight minutes. coreaudiod had torn the aggregate's IO
//  context down at 13:45:57 ("ending the transport, stopping the io
//  thread") and never brought it back, and every resume after that started
//  nothing. Only a new tap and aggregate recover from that, so this asks
//  for one.
//
//  Two things make silence ambiguous, and both shape the rule:
//
//  - The aggregate is built with `TapAutoStart`, so a start waits for the
//    player's first audio. A player reporting "playing" while it buffers,
//    or just before its stream is up, is silent for a moment and healthy.
//    Hence a grace period before the first rebuild.
//  - The player can report "playing" with no local audio at all: Spotify
//    Connect playing on a phone or a speaker. No rebuild will ever bring
//    callbacks then. Hence a few tries, spaced further apart each time,
//    then none until something changes: callbacks arrive, playback stops
//    and starts, or the user clicks the waveform.
//

import Foundation

struct MeterWatchdog: Equatable {
    /// How long the meter may be silent while playing before the first
    /// rebuild, then before each further one. Its length is the number of
    /// automatic rebuilds per stretch of playback.
    static let waits: [TimeInterval] = [3, 10, 30]

    enum Verdict: Equatable {
        /// Callbacks are arriving, or nothing is playing: nothing to do.
        case fine
        /// Silent while playing, but not for long enough, or out of tries.
        case waiting
        /// Rebuild the tap now.
        case rebuild
    }

    /// The callback count at the last reading.
    private(set) var lastCount: Int?
    /// When the count stopped moving while playing, or when the last
    /// rebuild was asked for; nil while it moves.
    private(set) var silentSince: TimeInterval?
    /// Rebuilds asked for since callbacks last arrived.
    private(set) var attempts = 0

    var gaveUp: Bool { attempts >= Self.waits.count }

    /// Forget everything: a new stretch of playback, a new target, a
    /// rebuild the user asked for.
    mutating func reset() {
        self = MeterWatchdog()
    }

    /// Publishing (re)started: count silence from now, not from before a
    /// suspend, when the meter was meant to be quiet. Tries already made
    /// stand, so a rebuild that brings no callbacks still counts as one.
    mutating func begin(callbacks: Int, at now: TimeInterval) {
        lastCount = callbacks
        silentSince = now
    }

    /// One reading. `playing` is the owner's word that the player is
    /// playing; `callbacks` the analyzer's running count.
    mutating func observe(callbacks: Int, at now: TimeInterval, playing: Bool) -> Verdict {
        defer { lastCount = callbacks }
        guard playing else {
            silentSince = nil
            return .fine
        }
        if let lastCount, callbacks != lastCount {
            // Moving: the meter is alive, whatever happened before.
            silentSince = nil
            attempts = 0
            return .fine
        }
        guard let since = silentSince else {
            silentSince = now
            return .waiting
        }
        guard !gaveUp, now - since >= Self.waits[attempts] else { return .waiting }
        attempts += 1
        silentSince = now
        return .rebuild
    }
}
