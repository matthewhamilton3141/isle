//
//  PowerMonitor.swift
//
//  The Mac's own power source, read from IOKit and diffed into the handful of
//  moments worth interrupting the island for.
//
//  Event-driven, not polled: `IOPSNotificationCreateRunLoopSource` fires the
//  callback whenever anything about the power source changes — the adapter
//  going in or out, a percentage tick, a time-remaining estimate resolving.
//  All of that lands in one `refresh()`, which takes a snapshot and asks what
//  changed. Public IOKit, no usage-description key, no permission prompt.
//
//  Follows the shape of ClaudeStatusWatcher: a plain @MainActor class with a
//  single `onEvent` callback, idempotent start/stop, and no @Published state
//  of its own — NotchViewModel owns the observable side.
//

import Foundation
import IOKit.ps

@MainActor
final class PowerMonitor {
    /// A toast worth showing. Fired only for a real transition, never for the
    /// steady state, and never for the first reading after `start()`.
    var onEvent: ((IslandToast) -> Void)?

    /// The Mac was just connected to power. Separate from `onEvent` because
    /// it's also the cue to re-read peripheral batteries (see
    /// `BluetoothBatteryMonitor.refreshLowDevices`) — a different consumer
    /// than the toast queue, and one that shouldn't have to pattern-match a
    /// toast kind to notice.
    var onPluggedIn: (() -> Void)?

    /// The most recent snapshot, or nil until the first refresh. Exposed so
    /// the view model can answer "what's the level right now" without its own
    /// IOKit call.
    private(set) var snapshot: MacPowerSnapshot?

    /// Battery levels that are worth saying out loud on the way down. macOS
    /// has its own alert at 10%, so 20 is the one that earns its place; 10 is
    /// kept because by then it's the only number on screen that matters.
    private nonisolated static let lowThresholds = [20, 10]

    private var runLoopSource: CFRunLoopSource?
    private var lowPowerObserver: NSObjectProtocol?
    private var isRunning = false

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true

        // Take a baseline first, so the very first callback compares against
        // reality rather than firing "On battery · 89%" a second after launch.
        snapshot = Self.read()

        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource(Self.callback, context)?
            .takeRetainedValue()
        else {
            NSLog("Isle: IOPSNotificationCreateRunLoopSource failed — power events disabled")
            isRunning = false
            return
        }

        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)

        // Low Power Mode is not a power *source* change, so it never reaches
        // the IOKit callback — it has its own notification. Routed into the
        // same `refresh()` so there is one path that turns state into toasts.
        // `queue: .main` because the notification is posted from an arbitrary
        // thread and everything downstream is main-actor.
        lowPowerObserver = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false

        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
        }
        runLoopSource = nil

        if let lowPowerObserver {
            NotificationCenter.default.removeObserver(lowPowerObserver)
        }
        lowPowerObserver = nil
        snapshot = nil
    }

    // MARK: - Callback

    /// A C function pointer, so it can't capture — `self` arrives as the
    /// context pointer that `start()` handed to IOKit. The source is scheduled
    /// on the main run loop, so this is already on the main thread; the
    /// address round-trip is only to keep the pointer out of the closure's
    /// capture list, which the concurrency checker would otherwise flag.
    private static let callback: IOPowerSourceCallbackType = { context in
        guard let context else { return }
        MainActor.assumeIsolated {
            Unmanaged<PowerMonitor>.fromOpaque(context).takeUnretainedValue().refresh()
        }
    }

    private func refresh() {
        guard isRunning, let now = Self.read() else { return }
        defer { snapshot = now }

        guard let before = snapshot, before != now else { return }
        for toast in Self.events(from: before, to: now) {
            onEvent?(toast)
        }
        if !before.isPluggedIn && now.isPluggedIn {
            onPluggedIn?()
        }
    }

    // MARK: - Diffing

    /// The whole editorial policy of the feature, in one function: which
    /// transitions are worth a few seconds of the island.
    ///
    /// Order matters when more than one fires at once. Reaching 100% while
    /// plugging in should read as "Fully charged", not "Charging · 100%", so
    /// the terminal state is emitted and the plug-in suppressed.
    /// `nonisolated` because it is pure — two snapshots in, a list of toasts
    /// out, no state touched. That keeps the editorial policy testable without
    /// standing up a monitor or a run loop.
    nonisolated static func events(from before: MacPowerSnapshot, to now: MacPowerSnapshot) -> [IslandToast] {
        var toasts: [IslandToast] = []

        // Newly full *and* on the adapter — which happens two ways: the
        // percentage climbing to 100 while plugged in, or the charger going
        // into a Mac that was already at 100. The second case matters because
        // it would otherwise announce "Charging · 100%", which is a claim
        // about something that isn't going to happen.
        let reachedFull = now.isPluggedIn && now.percent >= 100
            && (before.percent < 100 || !before.isPluggedIn)
        if reachedFull {
            toasts.append(.fullyCharged())
        }

        if now.isPluggedIn != before.isPluggedIn {
            if now.isPluggedIn {
                if !reachedFull {
                    toasts.append(.pluggedIn(percent: now.percent, minutesToFull: now.minutesToFull))
                }
            } else {
                toasts.append(.unplugged(percent: now.percent, minutesToEmpty: now.minutesToEmpty))
            }
        }

        // Only on the way down, and only on the battery — a threshold crossed
        // while charging is good news and doesn't need saying. Crossing back
        // up re-arms it for free, since this is a pure comparison of the two
        // readings rather than a latched flag.
        if !now.isPluggedIn {
            for threshold in lowThresholds where before.percent > threshold && now.percent <= threshold {
                toasts.append(.lowBattery(percent: now.percent))
                break   // one toast per crossing, even if a sleep skipped both
            }
        }

        // Independent of the adapter, and deliberately last: plugging in can
        // switch Low Power Mode off by itself, and when it does, "Charging"
        // is the headline and the mode change is the footnote.
        if now.isLowPowerMode != before.isLowPowerMode {
            toasts.append(.lowPowerMode(on: now.isLowPowerMode, percent: now.percent))
        }

        return toasts
    }

    // MARK: - Reading

    /// The internal battery's current state, or nil on a Mac that has none
    /// (a Studio, a Mini) — where every event above is meaningless anyway.
    static func read() -> MacPowerSnapshot? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?
                .takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  description[kIOPSIsPresentKey] as? Bool == true,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let max = description[kIOPSMaxCapacityKey] as? Int, max > 0
            else { continue }

            let state = description[kIOPSPowerSourceStateKey] as? String
            return MacPowerSnapshot(
                // Normalised rather than assumed: IOKit reports capacity
                // against a max that happens to be 100 on every Mac seen, but
                // the API doesn't promise it.
                percent: min(100, Int((Double(current) / Double(max) * 100).rounded())),
                isCharging: description[kIOPSIsChargingKey] as? Bool ?? false,
                isPluggedIn: state == kIOPSACPowerValue,
                minutesToFull: minutes(description[kIOPSTimeToFullChargeKey]),
                minutesToEmpty: minutes(description[kIOPSTimeToEmptyKey]),
                isLowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled
            )
        }
        return nil
    }

    /// IOKit uses -1 for "still calculating" and 0 for "doesn't apply right
    /// now". Both mean Isle has no figure it can stand behind, so both become
    /// nil and the toast simply omits the clause.
    private static func minutes(_ value: Any?) -> Int? {
        guard let value = value as? Int, value > 0 else { return nil }
        return value
    }
}
