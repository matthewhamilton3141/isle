//
//  AppSettings.swift
//
//  Single source of truth for user preferences that outlive a launch.
//  Milestone 1 owns just the mode; later milestones add the media-control
//  toggles (spec 3.4) and the Claude section here.
//
//  A shared singleton rather than an injected instance so the notch, the
//  menu bar, onboarding, and the (future) Settings window all read and
//  mutate the same state without threading one object through every init.
//

import Foundation
import Combine
import SwiftUI

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults: UserDefaults
    private static let modeKey = "isle.mode"
    private static let tabKey = "isle.lastTab"
    private static let showScrubberKey = "isle.showScrubber"
    private static let showShuffleRepeatKey = "isle.showShuffleRepeat"
    private static let doneToastKey = "isle.doneToastSeconds"
    private static let hapticsKey = "isle.haptics"
    private static let displayScopeKey = "isle.displayScope"
    private static let expandOnAlertKey = "isle.expandOnAlert"
    private static let dismissAlertPanelKey = "isle.dismissAlertPanel"
    private static let showWaitingKey = "isle.showWaiting"
    private static let claudeAccentKey = "isle.claudeAccent"
    private static let claudeAccentHexKey = "isle.claudeAccentHex"

    /// The user's chosen mode, or `nil` until onboarding sets one
    /// (Milestone 2). Persisted on change.
    @Published var mode: IsleMode? {
        didSet {
            guard mode != oldValue else { return }
            if let mode {
                defaults.set(mode.rawValue, forKey: Self.modeKey)
            } else {
                defaults.removeObject(forKey: Self.modeKey)
            }
        }
    }

    /// Last tab the user selected in `.both` mode, restored across launches.
    @Published var lastTab: IsleTab {
        didSet {
            guard lastTab != oldValue else { return }
            defaults.set(lastTab.rawValue, forKey: Self.tabKey)
        }
    }

    // MARK: - Notch

    /// Whether opening and closing the notch taps the trackpad. Silent on Macs
    /// without a Force Touch trackpad either way — `NSHapticFeedbackManager`
    /// simply does nothing there — so this is only ever felt by the people it
    /// can annoy.
    @Published var haptics: Bool {
        didSet { defaults.set(haptics, forKey: Self.hapticsKey) }
    }

    /// Which screens the island is drawn on. `.builtIn` by default, which is
    /// the behaviour Isle has always had — nobody's island moves unless they
    /// ask for it. See `DisplayScope`.
    @Published var displayScope: DisplayScope {
        didSet {
            guard displayScope != oldValue else { return }
            defaults.set(displayScope.rawValue, forKey: Self.displayScopeKey)
        }
    }

    // MARK: - Media controls (spec 3.4)

    /// Show the seekable scrubber in the expanded panel.
    @Published var showScrubber: Bool {
        didSet { defaults.set(showScrubber, forKey: Self.showScrubberKey) }
    }

    /// Show the shuffle and repeat toggles alongside the transport keys in the
    /// expanded panel. Off leaves just prev / play-pause / next.
    @Published var showShuffleRepeat: Bool {
        didSet { defaults.set(showShuffleRepeat, forKey: Self.showShuffleRepeatKey) }
    }

    // MARK: - Claude

    /// How long the `done` checkmark lingers before easing back to idle.
    @Published var doneToastSeconds: Double {
        didSet { defaults.set(doneToastSeconds, forKey: Self.doneToastKey) }
    }

    /// Whether an attention event (approval, question, API error) pops the panel
    /// open on its own. Off delivers it minimized — the collapsed island shows
    /// the alert glyph/label, but the notch doesn't take over the screen; the
    /// user expands on hover to act.
    @Published var expandOnAlert: Bool {
        didSet { defaults.set(expandOnAlert, forKey: Self.expandOnAlertKey) }
    }

    /// When an auto-opened alert panel can be dismissed by hovering away or
    /// clicking it — retracting to the collapsed island while the alert glyph
    /// stays until it's resolved. Off pins the panel open until the underlying
    /// state clears (the original behaviour). Either way, answering still
    /// auto-collapses it. Only relevant when `expandOnAlert` is on.
    @Published var dismissAlertPanel: Bool {
        didSet { defaults.set(dismissAlertPanel, forKey: Self.dismissAlertPanelKey) }
    }

    /// Whether the `waiting` state — Claude has handed the turn back and is
    /// waiting on you to type — claims the collapsed island. Off treats it like
    /// `idle`: still shown in the expanded panel, but the island stays with the
    /// music instead of splitting to seat a "Waiting" that says nothing you
    /// don't already know, since you're the one it's waiting on. Every other
    /// state (working, questions, errors) is unaffected.
    @Published var showWaitingStatus: Bool {
        didSet { defaults.set(showWaitingStatus, forKey: Self.showWaitingKey) }
    }

    /// The colour a Claude-only island draws itself in — it supplies the
    /// palette that album artwork supplies for music. Without one, a
    /// Claude-only user is stuck on `ArtworkPalette.fallback`, which is three
    /// greys, and every `.palette` marker renders flat. See `ClaudeAccent`.
    @Published var claudeAccent: ClaudeAccent {
        didSet {
            guard claudeAccent != oldValue else { return }
            defaults.set(claudeAccent.rawValue, forKey: Self.claudeAccentKey)
        }
    }

    /// The colour behind `ClaudeAccent.custom`. Kept separately so switching to
    /// a swatch and back doesn't lose what the user picked.
    @Published var claudeAccentHex: String {
        didSet {
            guard claudeAccentHex != oldValue else { return }
            defaults.set(claudeAccentHex, forKey: Self.claudeAccentHexKey)
        }
    }

    /// The resolved palette for the current accent, ready to draw with.
    var claudeAccentPalette: ArtworkPalette {
        claudeAccent.palette(customHex: claudeAccentHex)
    }

    /// Whether the user has ever picked a mode. Onboarding keys off this.
    var hasChosenMode: Bool { mode != nil }

    /// The mode to actually run. Until onboarding exists and the user has
    /// picked, treat "unset" as `.both` so nothing is hidden and behaviour
    /// matches the pre-mode build.
    var effectiveMode: IsleMode { mode ?? .both }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Assigning a stored property in init does not fire didSet, so these
        // loads don't write straight back to defaults. `object(forKey:)` rather
        // than `bool(forKey:)` so an absent key can default to true, not false.
        if let raw = defaults.string(forKey: Self.modeKey) {
            mode = IsleMode(rawValue: raw)
        }
        lastTab = IsleTab(rawValue: defaults.string(forKey: Self.tabKey) ?? "") ?? .music
        haptics = defaults.object(forKey: Self.hapticsKey) as? Bool ?? true
        displayScope = DisplayScope(rawValue: defaults.string(forKey: Self.displayScopeKey) ?? "")
            ?? .builtIn
        showScrubber = defaults.object(forKey: Self.showScrubberKey) as? Bool ?? true
        showShuffleRepeat = defaults.object(forKey: Self.showShuffleRepeatKey) as? Bool ?? true
        doneToastSeconds = defaults.object(forKey: Self.doneToastKey) as? Double ?? 4
        expandOnAlert = defaults.object(forKey: Self.expandOnAlertKey) as? Bool ?? true
        dismissAlertPanel = defaults.object(forKey: Self.dismissAlertPanelKey) as? Bool ?? true
        showWaitingStatus = defaults.object(forKey: Self.showWaitingKey) as? Bool ?? true
        claudeAccent = ClaudeAccent(rawValue: defaults.string(forKey: Self.claudeAccentKey) ?? "")
            ?? .system
        claudeAccentHex = defaults.string(forKey: Self.claudeAccentHexKey) ?? "#9438E0"
    }
}
