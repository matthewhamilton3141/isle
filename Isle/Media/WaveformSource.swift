//
//  WaveformSource.swift
//
//  Where the notch waveform gets its motion. Three-way rather than on/off
//  because the procedural pattern is worth keeping on its own: it is the one
//  choice that never touches Core Audio, and so the one that never triggers
//  the audio-capture permission prompt. Someone who would rather not grant
//  that should be able to say so once and keep a waveform that looks alive.
//
//  Chosen in onboarding (Live or Animated) and changeable in Settings, where
//  Off is also on offer.
//

import Foundation

enum WaveformSource: String, CaseIterable, Identifiable {
    /// Taps Spotify's audio. Asks for Audio Recording permission the first
    /// time music plays.
    case live

    /// The procedural sine pattern whenever something is playing. Never
    /// starts the tap — no prompt, no Core Audio.
    case animated

    /// No waveform. In music mode the bars' slot is left empty so the album
    /// stays put and the island keeps its shape; when Claude shares the island
    /// the space goes back and the island narrows instead.
    case off

    var id: String { rawValue }

    /// Whether the audio tap should run at all.
    var capturesAudio: Bool { self == .live }

    /// Whether a waveform is drawn at all.
    var isShown: Bool { self != .off }

    var title: String {
        switch self {
        case .live: return "Live"
        case .animated: return "Animated"
        case .off: return "Off"
        }
    }

    var subtitle: String {
        switch self {
        case .live:
            return "Moves with the music. Needs Audio Recording permission; nothing is recorded."
        case .animated:
            return "Moves on its own while something plays. Isle never listens."
        case .off:
            return "No waveform: just the album cover, or a narrower island beside Claude."
        }
    }
}
