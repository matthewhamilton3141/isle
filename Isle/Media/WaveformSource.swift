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

    /// No waveform. The collapsed island gives the space back.
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
            return "The bars move with the music. Needs Audio Recording permission — macOS asks the first time something plays. Audio is analysed in memory and never recorded."
        case .animated:
            return "The bars move on their own whenever something is playing. Isle never listens, so macOS never asks."
        case .off:
            return "No waveform. The island shows just the album cover."
        }
    }
}
