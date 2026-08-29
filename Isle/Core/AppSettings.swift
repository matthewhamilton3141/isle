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

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults: UserDefaults
    private static let modeKey = "isle.mode"
    private static let tabKey = "isle.lastTab"
    private static let showScrubberKey = "isle.showScrubber"
    private static let showShuffleRepeatKey = "isle.showShuffleRepeat"
    private static let doneToastKey = "isle.doneToastSeconds"
    private static let expandOnAlertKey = "isle.expandOnAlert"
    private static let dismissAlertPanelKey = "isle.dismissAlertPanel"

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
        showScrubber = defaults.object(forKey: Self.showScrubberKey) as? Bool ?? true
        showShuffleRepeat = defaults.object(forKey: Self.showShuffleRepeatKey) as? Bool ?? true
        doneToastSeconds = defaults.object(forKey: Self.doneToastKey) as? Double ?? 4
        expandOnAlert = defaults.object(forKey: Self.expandOnAlertKey) as? Bool ?? true
        dismissAlertPanel = defaults.object(forKey: Self.dismissAlertPanelKey) as? Bool ?? true
    }
}
