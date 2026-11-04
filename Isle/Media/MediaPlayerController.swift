//
//  MediaPlayerController.swift
//
//  The player-specific half of the music island, behind one shape. Isle
//  reads whatever owns the system now-playing session through the
//  MediaRemote adapter, but every transport command, the position poll, and
//  the artwork fallback have to address a player *by name* over AppleScript —
//  and there are two of those now: Spotify and Apple Music.
//
//  `NotchViewModel` holds one controller per supported player and routes
//  commands to the one whose track the island is showing (see
//  `NotchViewModel.recomputeSource`). Each controller owns its own poll,
//  its own artwork cache, and its own "never launch the app" guard; the view
//  model only ever talks to the protocol.
//

import Foundation
import AppKit

@MainActor
protocol MediaPlayerController: AnyObject {
    /// The bundle id the controller addresses — what `MediaPlaybackModel.
    /// bundleIdentifier` reads for a track this player owns.
    var bundleID: String { get }

    /// The player's name as shown to the user ("Spotify", "Music").
    var displayName: String { get }

    /// Latest polled state, or nil when the player isn't running or is
    /// stopped. Called on the main actor.
    var onUpdate: ((MediaPlaybackModel?) -> Void)? { get set }

    /// Asked at every tick whether the poll should run at full rate. Nil, or
    /// true, means once a second; false relaxes it.
    var wantsFullRate: (() -> Bool)? { get set }

    /// Asked before a cover is fetched. Nil, or true, fetches at once; false
    /// holds it until `fetchArtworkIfNeeded`.
    var wantsArtwork: (() -> Bool)? { get set }

    func start()
    func stop()

    /// Read now rather than at the next tick.
    func pollNow()

    /// Fetches a cover that was held back, if `wantsArtwork` now allows it.
    func fetchArtworkIfNeeded()

    func playPause()
    func nextTrack()
    func previousTrack()
    func seek(to seconds: TimeInterval)
    func toggleShuffle()
    func toggleRepeat()
}

/// What the machine has, for copy that names a player rather than assuming
/// one. Installation is asked of LaunchServices; running, of the workspace.
/// Both are local lookups — neither touches the player.
enum MediaPlayers {
    static let spotifyBundleID = "com.spotify.client"
    static let appleMusicBundleID = "com.apple.Music"

    /// Every bundle id the island will show and control. Order is the
    /// cold-start preference when both are running and nothing says which.
    static let supported = [spotifyBundleID, appleMusicBundleID]

    static func isInstalled(_ bundleID: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    static func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    static func displayName(_ bundleID: String) -> String {
        switch bundleID {
        case spotifyBundleID: return "Spotify"
        case appleMusicBundleID: return "Music"
        default: return bundleID
        }
    }

    /// Names of the installed players, in preference order. Empty when
    /// neither is installed.
    static var installedNames: [String] {
        supported.filter(isInstalled).map(displayName)
    }

    /// "Spotify and Music", "Music", or a hedge when neither is installed —
    /// for the onboarding line that says what Automation will ask for.
    static var installedList: String {
        let names = installedNames
        switch names.count {
        case 0: return "Spotify or Music"
        case 1: return names[0]
        default: return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
    }
}
