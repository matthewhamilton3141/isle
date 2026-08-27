//
//  IsleMode.swift
//
//  What the user wants Isle to be. Chosen on first launch (onboarding —
//  Milestone 2) and changeable in Settings (Milestone 6). Every subsystem
//  reads from this: media capture and the Claude bridge each run only when
//  the active mode asks for them, so a Claude-only user never triggers the
//  Automation/Audio permission prompts and a music-only user never watches
//  a status file.
//

import Foundation

enum IsleMode: String, CaseIterable, Identifiable {
    /// Spotify now-playing island only.
    case music

    /// Claude Code live-activity island only.
    case claude

    /// Both sources at once — collapsed view splits, expanded view tabs.
    case both

    var id: String { rawValue }

    /// Whether the media subsystems (adapter, Spotify, audio) should run and
    /// music content should render.
    var showsMusic: Bool {
        self == .music || self == .both
    }

    /// Whether the Claude bridge should run and the glyph should render.
    var showsClaude: Bool {
        self == .claude || self == .both
    }

    // MARK: - Display copy (onboarding + settings)

    var title: String {
        switch self {
        case .music: return "Music"
        case .claude: return "Claude Code"
        case .both: return "Both"
        }
    }

    var subtitle: String {
        switch self {
        case .music:
            return "A Spotify island — now playing, controls, and a live waveform."
        case .claude:
            return "A live status island for your Claude Code session."
        case .both:
            return "Music and Claude Code, side by side."
        }
    }

    var symbolName: String {
        switch self {
        case .music: return "music.note"
        case .claude: return "sparkle"
        case .both: return "rectangle.split.2x1"
        }
    }
}
