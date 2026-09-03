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
import AppKit
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
    private static let waveformSourceKey = "isle.waveformSource"
    private static let doneToastKey = "isle.doneToastSeconds"
    private static let hapticsKey = "isle.haptics"
    private static let displayScopeKey = "isle.displayScope"
    private static let expandOnAlertKey = "isle.expandOnAlert"
    private static let dismissAlertPanelKey = "isle.dismissAlertPanel"
    private static let showWaitingKey = "isle.showWaiting"
    private static let claudeAccentKey = "isle.claudeAccent"
    private static let claudeAccentHexKey = "isle.claudeAccentHex"
    private static let showBatteryEventsKey = "isle.showBatteryEvents"
    private static let showDeviceBatteryKey = "isle.showDeviceBattery"
    private static let showCalendarEventsKey = "isle.showCalendarEvents"
    private static let showRemindersKey = "isle.showReminders"
    private static let eventLeadMinutesKey = "isle.eventLeadMinutes"
    private static let pomodoroEnabledKey = "isle.pomodoro.enabled"
    private static let pomodoroFocusMinutesKey = "isle.pomodoro.focusMinutes"
    private static let pomodoroShortBreakMinutesKey = "isle.pomodoro.shortBreakMinutes"
    private static let pomodoroLongBreakMinutesKey = "isle.pomodoro.longBreakMinutes"
    private static let pomodoroSessionsPerCycleKey = "isle.pomodoro.sessionsPerCycle"
    /// The pre-0.5 on/off switch. Read once at launch to seed the picker
    /// below for an install that had turned the chime off; never written.
    private static let legacyPomodoroSoundKey = "isle.pomodoro.sound"
    private static let pomodoroSoundEnabledKey = "isle.pomodoro.soundEnabled"
    private static let pomodoroSoundKey = "isle.pomodoro.soundName"
    private static let claudeAlertSoundEnabledKey = "isle.claudeAlertSoundEnabled"
    private static let claudeAlertSoundKey = "isle.claudeAlertSound"
    private static let claudeDoneSoundEnabledKey = "isle.claudeDoneSoundEnabled"
    private static let claudeDoneSoundKey = "isle.claudeDoneSound"
    private static let agendaSoundEnabledKey = "isle.agendaSoundEnabled"
    private static let agendaSoundKey = "isle.agendaSound"

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

    /// Where the waveform gets its motion — and, with it, whether the audio
    /// tap ever runs. Only `.live` starts the tap, so this is the switch that
    /// decides whether macOS ever asks for Audio Recording. See `WaveformSource`.
    ///
    /// Defaults to `.live` so an install that predates the setting keeps the
    /// waveform it already granted permission for.
    @Published var waveformSource: WaveformSource {
        didSet {
            guard waveformSource != oldValue else { return }
            defaults.set(waveformSource.rawValue, forKey: Self.waveformSourceKey)
        }
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

    // Every sound is a switch plus a choice rather than a picker with a
    // "None" entry. The switch is what makes it optional — off by default for
    // the Claude and agenda chimes, since an update must not start making
    // noise on its own — and keeping the choice separate means switching a
    // sound on lands on a sensible pick rather than an empty menu.

    /// Whether Claude needing the user — an approval, a question, or an
    /// error — plays a sound. It earns its keep for the person who prompts,
    /// switches to another window, and would otherwise miss the island asking
    /// for them; someone whose terminal is in front of them has no use for it.
    @Published var claudeAlertSoundEnabled: Bool {
        didSet { defaults.set(claudeAlertSoundEnabled, forKey: Self.claudeAlertSoundEnabledKey) }
    }

    @Published var claudeAlertSound: NotificationSound {
        didSet {
            guard claudeAlertSound != oldValue else { return }
            defaults.set(claudeAlertSound.rawValue, forKey: Self.claudeAlertSoundKey)
        }
    }

    /// Whether a finished turn plays a sound. Separate from the alert because
    /// the two mean different things — one asks for you, the other lets you
    /// go — and a single chime for both would say neither.
    @Published var claudeDoneSoundEnabled: Bool {
        didSet { defaults.set(claudeDoneSoundEnabled, forKey: Self.claudeDoneSoundEnabledKey) }
    }

    @Published var claudeDoneSound: NotificationSound {
        didSet {
            guard claudeDoneSound != oldValue else { return }
            defaults.set(claudeDoneSound.rawValue, forKey: Self.claudeDoneSoundKey)
        }
    }

    /// The resolved palette for the current accent, ready to draw with.
    ///
    /// Cached against the two inputs. Resolving is not cheap — `.system`, the
    /// default, measures the system accent against every swatch, which means
    /// parsing three hex strings and bridging a `Color` to `NSColor` for each
    /// of seven candidates and running the Lab conversion on all of them — and
    /// the notch reads this several times per body evaluation whenever there
    /// is no artwork to draw from. The system accent itself is the one input
    /// that changes without touching either key, so `systemColorsDidChange`
    /// drops the cache (see `init`).
    var claudeAccentPalette: ArtworkPalette {
        if let cached = accentPaletteCache,
           cached.accent == claudeAccent, cached.hex == claudeAccentHex {
            return cached.palette
        }
        let palette = claudeAccent.palette(customHex: claudeAccentHex)
        accentPaletteCache = (claudeAccent, claudeAccentHex, palette)
        return palette
    }

    private var accentPaletteCache: (accent: ClaudeAccent, hex: String, palette: ArtworkPalette)?
    private var systemColorsObserver: NSObjectProtocol?

    // MARK: - Power

    /// Whether this Mac's own battery briefly claims the collapsed island —
    /// the charger going in or out, reaching full, crossing a low-battery
    /// threshold, Low Power Mode switching.
    ///
    /// Ambient rather than a mode: a power event is transient, so it borrows
    /// the island for a few seconds and hands it back, and there is nothing
    /// here you would run Isle *as*.
    @Published var showBatteryEvents: Bool {
        didSet { defaults.set(showBatteryEvents, forKey: Self.showBatteryEventsKey) }
    }

    /// Whether a connecting Bluetooth device's level is shown, and whether
    /// plugging the Mac in re-checks peripherals for a flat one.
    ///
    /// Independent of `showBatteryEvents`, not nested under it: these are
    /// different questions about different hardware, and they cost differently.
    /// The Mac's own battery is a free IOKit callback; a peripheral's level is
    /// only readable by shelling out to `system_profiler`. Someone who would
    /// rather Isle never spawned a subprocess can turn this off and keep the
    /// rest, and someone who only cares about their headphones can do the
    /// reverse.
    @Published var showDeviceBattery: Bool {
        didSet { defaults.set(showDeviceBattery, forKey: Self.showDeviceBatteryKey) }
    }

    // MARK: - Agenda

    /// Whether a calendar event briefly claims the collapsed island shortly
    /// before it starts. Off by default: unlike the power switches, this one
    /// costs a macOS permission, and an install that predates it must not
    /// start asking for Calendar access on the strength of an update. Setup
    /// ticks it for a fresh install, where the prompt is expected.
    @Published var showCalendarEvents: Bool {
        didSet { defaults.set(showCalendarEvents, forKey: Self.showCalendarEventsKey) }
    }

    /// Whether a reminder claims the island as it comes due. Independent of
    /// `showCalendarEvents` for the same reason the two power switches are:
    /// different data behind different permissions, and someone who keeps
    /// their calendar elsewhere may still want their reminders.
    @Published var showReminders: Bool {
        didSet { defaults.set(showReminders, forKey: Self.showRemindersKey) }
    }

    /// How many minutes before an event its toast appears. Zero means at the
    /// start. See `EventLead` for the choices Settings offers.
    @Published var eventLeadMinutes: Int {
        didSet {
            guard eventLeadMinutes != oldValue else { return }
            defaults.set(eventLeadMinutes, forKey: Self.eventLeadMinutesKey)
        }
    }

    /// Whether an event or reminder toast plays a sound. One switch for both,
    /// since both are "something is about to happen on your schedule" and each
    /// already has its own show/hide switch above. Battery toasts have no
    /// sound: macOS chimes for a charger itself, and the rest are glanceable
    /// rather than urgent.
    @Published var agendaSoundEnabled: Bool {
        didSet { defaults.set(agendaSoundEnabled, forKey: Self.agendaSoundEnabledKey) }
    }

    @Published var agendaSound: NotificationSound {
        didSet {
            guard agendaSound != oldValue else { return }
            defaults.set(agendaSound.rawValue, forKey: Self.agendaSoundKey)
        }
    }

    // MARK: - Pomodoro

    /// Whether the built-in Pomodoro timer exists at all. Off by default and
    /// only switchable from Settings: it adds a third tab to the expanded panel
    /// and a seat in the collapsed island, so it's opt-in rather than something
    /// every install carries. Off also stops and resets any running timer.
    @Published var pomodoroEnabled: Bool {
        didSet { defaults.set(pomodoroEnabled, forKey: Self.pomodoroEnabledKey) }
    }

    /// Length of a focus interval, in minutes.
    @Published var pomodoroFocusMinutes: Int {
        didSet { defaults.set(pomodoroFocusMinutes, forKey: Self.pomodoroFocusMinutesKey) }
    }

    /// Length of the short break between focus intervals, in minutes.
    @Published var pomodoroShortBreakMinutes: Int {
        didSet { defaults.set(pomodoroShortBreakMinutes, forKey: Self.pomodoroShortBreakMinutesKey) }
    }

    /// Length of the long break that ends a cycle, in minutes.
    @Published var pomodoroLongBreakMinutes: Int {
        didSet { defaults.set(pomodoroLongBreakMinutes, forKey: Self.pomodoroLongBreakMinutesKey) }
    }

    /// How many focus intervals make a cycle — the long break follows the last.
    @Published var pomodoroSessionsPerCycle: Int {
        didSet { defaults.set(pomodoroSessionsPerCycle, forKey: Self.pomodoroSessionsPerCycleKey) }
    }

    /// Whether an interval ending plays a sound. On by default, as the timer
    /// has always rung — a Pomodoro is a timer and a silent one is a clock.
    @Published var pomodoroSoundEnabled: Bool {
        didSet { defaults.set(pomodoroSoundEnabled, forKey: Self.pomodoroSoundEnabledKey) }
    }

    @Published var pomodoroSound: NotificationSound {
        didSet {
            guard pomodoroSound != oldValue else { return }
            defaults.set(pomodoroSound.rawValue, forKey: Self.pomodoroSoundKey)
        }
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
        waveformSource = WaveformSource(rawValue: defaults.string(forKey: Self.waveformSourceKey) ?? "")
            ?? .live
        doneToastSeconds = defaults.object(forKey: Self.doneToastKey) as? Double ?? 4
        expandOnAlert = defaults.object(forKey: Self.expandOnAlertKey) as? Bool ?? true
        dismissAlertPanel = defaults.object(forKey: Self.dismissAlertPanelKey) as? Bool ?? true
        showWaitingStatus = defaults.object(forKey: Self.showWaitingKey) as? Bool ?? true
        claudeAccent = ClaudeAccent(rawValue: defaults.string(forKey: Self.claudeAccentKey) ?? "")
            ?? .system
        claudeAccentHex = defaults.string(forKey: Self.claudeAccentHexKey) ?? "#9438E0"
        showBatteryEvents = defaults.object(forKey: Self.showBatteryEventsKey) as? Bool ?? true
        showDeviceBattery = defaults.object(forKey: Self.showDeviceBatteryKey) as? Bool ?? true
        showCalendarEvents = defaults.object(forKey: Self.showCalendarEventsKey) as? Bool ?? false
        showReminders = defaults.object(forKey: Self.showRemindersKey) as? Bool ?? false
        eventLeadMinutes = defaults.object(forKey: Self.eventLeadMinutesKey) as? Int ?? EventLead.default.rawValue
        pomodoroEnabled = defaults.object(forKey: Self.pomodoroEnabledKey) as? Bool ?? false
        pomodoroFocusMinutes = defaults.object(forKey: Self.pomodoroFocusMinutesKey) as? Int ?? 25
        pomodoroShortBreakMinutes = defaults.object(forKey: Self.pomodoroShortBreakMinutesKey) as? Int ?? 5
        pomodoroLongBreakMinutes = defaults.object(forKey: Self.pomodoroLongBreakMinutesKey) as? Int ?? 15
        pomodoroSessionsPerCycle = defaults.object(forKey: Self.pomodoroSessionsPerCycleKey) as? Int ?? 4
        claudeAlertSoundEnabled = defaults.object(forKey: Self.claudeAlertSoundEnabledKey) as? Bool ?? false
        claudeAlertSound = NotificationSound(rawValue: defaults.string(forKey: Self.claudeAlertSoundKey) ?? "")
            ?? .alert
        claudeDoneSoundEnabled = defaults.object(forKey: Self.claudeDoneSoundEnabledKey) as? Bool ?? false
        claudeDoneSound = NotificationSound(rawValue: defaults.string(forKey: Self.claudeDoneSoundKey) ?? "")
            ?? .simple2
        agendaSoundEnabled = defaults.object(forKey: Self.agendaSoundEnabledKey) as? Bool ?? false
        agendaSound = NotificationSound(rawValue: defaults.string(forKey: Self.agendaSoundKey) ?? "")
            ?? .simple1
        // Prefer the new switch; fall back to the pre-0.5 one so an install
        // that had silenced the timer stays silent after the update.
        pomodoroSoundEnabled = defaults.object(forKey: Self.pomodoroSoundEnabledKey) as? Bool
            ?? (defaults.object(forKey: Self.legacyPomodoroSoundKey) as? Bool ?? true)
        pomodoroSound = NotificationSound(rawValue: defaults.string(forKey: Self.pomodoroSoundKey) ?? "")
            ?? .fanfare

        // A change to the system accent in System Settings changes what
        // `.system` resolves to without either cache key moving. Drop the cache
        // and publish, so an island drawn from the accent follows the change
        // rather than holding the old colour until something else re-renders it.
        systemColorsObserver = NotificationCenter.default.addObserver(
            forName: NSColor.systemColorsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.claudeAccent == .system else { return }
                self.accentPaletteCache = nil
                self.objectWillChange.send()
            }
        }
    }

    deinit {
        if let systemColorsObserver {
            NotificationCenter.default.removeObserver(systemColorsObserver)
        }
    }
}

/// The lead times Settings offers for an event's toast. A fixed ladder rather
/// than a free stepper: these are the intervals people actually set alerts
/// for, and a segmented row of five reads faster than a number to dial.
enum EventLead: Int, CaseIterable, Identifiable {
    case atStart = 0
    case five = 5
    case ten = 10
    case fifteen = 15
    case thirty = 30

    static let `default`: EventLead = .five

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .atStart: return "At start"
        default: return "\(rawValue) min before"
        }
    }
}
