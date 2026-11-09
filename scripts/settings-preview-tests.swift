//
//  settings-preview-tests.swift
//
//  Tests for the island's live preview while Settings is configured
//  (Isle/Core/SettingsPreview.swift): which setting opens which face, when
//  a change opens the island and when it doesn't, which changes count at
//  all (read off AppSettings itself), and when the preview's hold ends.
//  Compiled with every Isle source by scripts/test-settings-preview.sh.
//
//  No window, no app: settings go to a scratch UserDefaults suite, and the
//  islands are `IslandPresentation`s with nothing drawn.
//

import AppKit
import Combine
import Foundation

var failures = 0
var passes = 0

func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    if ok {
        passes += 1
        print("  ok    \(name)")
    } else {
        failures += 1
        let more = detail()
        print("  FAIL  \(name)" + (more.isEmpty ? "" : "\n        \(more)"))
    }
}

func equal<T: Equatable>(_ got: T, _ want: T, _ name: String) {
    check(got == want, name, "want \(want)\n        got  \(got)")
}

typealias Change = SettingsPreviewChange
typealias Plan = SettingsPreviewPlan
typealias Ctx = SettingsPreviewPlan.Context

@MainActor
func scratchSettings() -> (AppSettings, String) {
    let suite = "isle.settings-preview-tests.\(UUID().uuidString)"
    return (AppSettings(defaults: UserDefaults(suiteName: suite)!), suite)
}

@main
enum SettingsPreviewTests {
    @MainActor
    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        faces()
        opening()
        notOpening()
        whatCounts()
        closing()
        print("\n\(passes) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - Which face

    @MainActor
    static func faces() {
        print("Which face a change shows")
        for c in [Change.showScrubber, .showShuffleRepeat, .waveformSource] {
            equal(c.face, .music, "\(c.rawValue): Music")
        }
        for c in [Change.optionDescriptions, .answerFromNotch] {
            equal(c.face, .claude, "\(c.rawValue): Claude")
        }
        for c in [Change.pomodoroEnabled, .pomodoroFocusMinutes, .pomodoroShortBreakMinutes,
                  .pomodoroLongBreakMinutes, .pomodoroSessionsPerCycle] {
            equal(c.face, .pomodoro, "\(c.rawValue): the timer")
        }
        for c in [Change.showCalendarEvents, .showReminders, .eventLeadMinutes] {
            equal(c.face, .agenda, "\(c.rawValue): the agenda")
        }
        for c in [Change.mode, .panelBackground, .panelNotchGlow, .liveStrip, .claudeAccent, .claudeAccentHex] {
            equal(c.face, nil, "\(c.rawValue): whatever face is up (it shows on every one)")
        }
    }

    // MARK: - When it opens

    @MainActor
    static func opening() {
        print("When a change opens the island")
        let ctx = Ctx()
        equal(Plan.decide(.waveformSource, context: ctx), .open(face: .music), "waveform, in Settings: open on Music")
        equal(Plan.decide(.optionDescriptions, context: ctx), .open(face: .claude), "option descriptions: open on Claude")
        equal(Plan.decide(.pomodoroEnabled, context: ctx), .open(face: .pomodoro), "Pomodoro switched on: the timer")
        equal(Plan.decide(.showCalendarEvents, context: ctx), .open(face: .agenda), "Calendar switched on: the agenda")
        equal(Plan.decide(.panelBackground, context: ctx), .open(face: nil), "Black/Glass/Smoked: open where it is")
        equal(Plan.decide(.panelNotchGlow, context: ctx), .open(face: nil), "the glow: open where it is")
        equal(Plan.decide(.claudeAccent, context: ctx), .open(face: nil), "the accent: open where it is")
        equal(Plan.decide(.mode, context: ctx), .open(face: nil), "the mode: open where it is (or Home)")

        var gone = Ctx(); gone.availableTabs = [.music, .claude]
        equal(Plan.decide(.pomodoroEnabled, context: gone), .open(face: nil),
              "Pomodoro switched off: its face is gone, so stay where it is")
        equal(Plan.decide(.showReminders, context: gone), .open(face: nil),
              "the agenda not offered (no access yet): stay where it is")
        var musicOnly = Ctx(); musicOnly.availableTabs = [.music]
        equal(Plan.decide(.optionDescriptions, context: musicOnly), .open(face: nil),
              "Claude's setting with Claude not shown: open on what there is")

        var request = Ctx(); request.requestShowing = true
        equal(Plan.decide(.waveformSource, context: request), .open(face: nil),
              "an approval or question on screen: open, but never switch away from it")
        equal(Plan.decide(.optionDescriptions, context: request), .open(face: nil),
              "and a Claude setting leaves it as it is too")
    }

    // MARK: - When it doesn't

    @MainActor
    static func notOpening() {
        print("When a change leaves the island alone")
        var away = Ctx(); away.settingsInFront = false
        for c in Change.allCases {
            check(Plan.decide(c, context: away) == .none, "\(c.rawValue), Settings not in front: nothing")
        }
        var stopped = Ctx(); stopped.running = false
        equal(Plan.decide(.waveformSource, context: stopped), .none, "the islands hidden from the menu bar: nothing")
        var drop = Ctx(); drop.dropInProgress = true
        equal(Plan.decide(.waveformSource, context: drop), .none, "a drop under way wins")
        equal(Plan.decide(.panelBackground, context: drop), .none, "even for the look")
        var typing = Ctx(); typing.composing = true
        equal(Plan.decide(.pomodoroEnabled, context: typing), .none, "a field taking keys wins")
        var both = Ctx(); both.requestShowing = true; both.composing = true
        equal(Plan.decide(.showScrubber, context: both), .none, "a reply being typed to a request: nothing")
    }

    // MARK: - What counts

    /// Read off AppSettings itself: every published setting is either one
    /// the preview shows or one it deliberately doesn't, so a new setting
    /// can't be left out by accident.
    static let ignored: Set<String> = [
        // Where the island opens and what's on the shelf: the island's own.
        "lastTab", "lastOnHome", "shelfPaths",
        // Shortcut bindings: the recorder holds the keys while they change.
        "shortcuts",
        // Which displays: re-places the islands, which waits for them to close.
        "displayScope",
        // Felt or heard, or said by the collapsed island, which an open one hides.
        "haptics", "showWaitingStatus", "showBatteryEvents", "showDeviceBattery", "doneToastSeconds",
        // What an alert does, not how it looks.
        "expandOnAlert", "dismissAlertPanel", "keepAwakeWhileWorking", "guardCommands", "guardedCommands",
        // Sounds.
        "claudeAlertSoundEnabled", "claudeAlertSound", "claudeDoneSoundEnabled", "claudeDoneSound",
        "agendaSoundEnabled", "agendaSound", "pomodoroSoundEnabled", "pomodoroSound",
    ]

    @MainActor
    static func whatCounts() {
        print("Which changes count, read off AppSettings")
        let (settings, suite) = scratchSettings()
        let published = Set(Mirror(reflecting: settings).children.compactMap { child -> String? in
            guard let label = child.label, label.hasPrefix("_"),
                  String(describing: type(of: child.value)).hasPrefix("Published<") else { return nil }
            return String(label.dropFirst())
        })
        let previewed = Set(Change.allCases.map(\.rawValue))
        check(published.count > 30, "found AppSettings' published settings", "\(published.count)")
        for name in published.sorted() {
            check(previewed.contains(name) != ignored.contains(name),
                  "\(name): \(previewed.contains(name) ? "previewed" : "not previewed"), and only that")
        }
        check(previewed.isSubset(of: published), "every preview case is a real setting",
              "\(previewed.subtracting(published))")

        var seen: [Change] = []
        let sub = settings.previewChanges.sink { seen.append($0) }
        equal(seen, [], "subscribing (Settings opening) sends nothing: only a change does")

        settings.showScrubber.toggle()
        settings.waveformSource = settings.waveformSource == .live ? .animated : .live
        settings.panelBackground = .glass
        settings.optionDescriptions = settings.optionDescriptions == .hidden ? .full : .hidden
        settings.pomodoroEnabled = true
        settings.pomodoroFocusMinutes = 30
        settings.showCalendarEvents = true
        settings.mode = .claude
        settings.claudeAccentHex = "#123456"
        equal(seen, [.showScrubber, .waveformSource, .panelBackground, .optionDescriptions, .pomodoroEnabled,
                     .pomodoroFocusMinutes, .showCalendarEvents, .mode, .claudeAccentHex],
              "each change, once, as it's made")

        seen = []
        settings.panelBackground = .glass
        settings.pomodoroFocusMinutes = 30
        equal(seen, [], "the same value again: nothing")

        settings.shortcuts.assign(KeyCombo(0x10, KeyCombo.option), to: .approve)
        settings.shortcuts[.deny].isOn = false
        equal(seen, [], "a shortcut binding: nothing")
        settings.lastTab = .claude
        settings.lastOnHome = false
        settings.shelfPaths = ["/tmp/x"]
        equal(seen, [], "the island's own place and shelf: nothing")
        settings.displayScope = .all
        settings.claudeAlertSoundEnabled = true
        settings.expandOnAlert = false
        settings.showWaitingStatus = false
        settings.haptics = false
        equal(seen, [], "displays, sounds, alert behaviour, the collapsed island: nothing")
        sub.cancel()
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }

    // MARK: - When it closes

    @MainActor
    static func closing() {
        print("When the preview's hold ends")
        var hold = SettingsPreviewHold<Int>()
        equal(hold.end(.settingsClosed), nil, "nothing opened: Settings closing closes nothing")
        hold.opened(1)
        equal(hold.end(.settingsClosed), 1, "Settings closed: the island it opened goes")
        equal(hold.end(.settingsClosed), nil, "once")
        hold.opened(1)
        equal(hold.end(.appResignedActive), 1, "Isle no longer the active app: it goes")
        hold.opened(2)
        hold.released(1)
        equal(hold.island, 2, "another island's hold ending is no business of this one")
        hold.released(2)
        equal(hold.end(.settingsClosed), nil,
              "the hold already ended another way (a visit, the shortcut): Settings closing leaves it")

        print("When the preview's hold ends: on a real island")
        let (settings, suite) = scratchSettings()
        settings.mode = .both
        let vm = NotchViewModel(settings: settings)
        let island = IslandPresentation(content: vm)
        var preview = SettingsPreviewHold<Int>()
        var bag = Set<AnyCancellable>()
        // As NotchWindowController wires it.
        island.$isHeldOpen.removeDuplicates().filter { !$0 }
            .sink { _ in preview.released(7) }
            .store(in: &bag)
        func open() {
            island.openFromShortcut()
            preview.opened(7)
        }
        func end(_ reason: SettingsPreviewEnd) {
            if preview.end(reason) == 7, island.isHeldOpen { island.setHovering(false) }
        }

        open()
        check(island.isHovering && island.isHeldOpen, "a change in Settings: open, and held")
        // The pointer moving about in Settings never reaches the panel's
        // stay-open zone, so nothing calls `notePointerInside`, and a hold
        // isn't closed by `setHovering(false)` from the hover rule (which
        // skips held islands).
        check(island.isHeldOpen, "the pointer moving about in Settings: still held")
        end(.settingsClosed)
        check(!island.isHovering, "Settings closed: put away")

        RunLoop.main.run(until: Date().addingTimeInterval(0.4))   // past the collapse lock
        open()
        end(.appResignedActive)
        check(!island.isHovering, "Isle went to the back: put away")

        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        open()
        island.notePointerInside()
        check(island.isHovering && !island.isHeldOpen, "the pointer visited: an ordinary hover now")
        equal(preview.island, nil, "and no longer the preview's")
        end(.settingsClosed)
        check(island.isHovering, "so Settings closing doesn't pull it from under the pointer")
        island.setHovering(false)
        check(!island.isHovering, "leaving closes it, as any hover")

        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        open()
        island.setHovering(false)       // the shortcut, or a click in another app
        equal(preview.island, nil, "closed by the shortcut or a click elsewhere: released")
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        island.openFromShortcut()       // the shortcut's own hold, later
        end(.settingsClosed)
        check(island.isHeldOpen, "a later shortcut hold isn't taken for the preview's")
        island.setHovering(false)
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }
}
