//
//  PomodoroTimer.swift
//
//  The Pomodoro state machine: focus → short break → … → long break, with
//  start / pause / skip / reset. Owned by NotchViewModel and only ever alive
//  while the Pomodoro setting is on.
//
//  The countdown is anchored to a wall-clock end date rather than decremented
//  by a timer. The views read `remaining(at:)` off a TimelineView so the digits
//  are exact at any frame, and the single one-shot Timer here, armed for the
//  end date itself, exists only to notice that an interval has ended and roll
//  to the next phase — so a late fire can never make the clock drift.
//

import AppKit
import Combine

/// Which interval is on the clock.
enum PomodoroPhase: Equatable {
    case focus
    case shortBreak
    case longBreak

    var title: String {
        switch self {
        case .focus: return "Focus"
        case .shortBreak: return "Short break"
        case .longBreak: return "Long break"
        }
    }

    var isBreak: Bool { self != .focus }
}

@MainActor
final class PomodoroTimer: ObservableObject {

    /// The interval currently on the clock.
    @Published private(set) var phase: PomodoroPhase = .focus

    /// Counting down. False both before the first start and while paused.
    @Published private(set) var isRunning = false

    /// Focus intervals completed in the current cycle (0..<sessionsPerCycle).
    /// Resets when the long break begins.
    @Published private(set) var completedInCycle = 0

    /// Whole intervals the clock has finished since the timer was last reset,
    /// for the tally in the expanded panel.
    @Published private(set) var completedFocusTotal = 0

    /// The moment the current interval ends, while running. Nil while paused
    /// or idle — `remainingWhenPaused` carries the time then.
    @Published private(set) var endDate: Date?

    /// Seconds left on a paused (or not yet started) interval.
    @Published private(set) var remainingWhenPaused: TimeInterval

    /// Full length of the current interval, for the progress ring.
    @Published private(set) var phaseDuration: TimeInterval

    private let settings: AppSettings
    private var tick: Timer?

    /// Fires when an interval runs out, after the phase has already rolled
    /// over — for the sound, and for anything that wants to react.
    var onIntervalEnded: ((PomodoroPhase) -> Void)?

    init(settings: AppSettings) {
        self.settings = settings
        let duration = TimeInterval(settings.pomodoroFocusMinutes * 60)
        phaseDuration = duration
        remainingWhenPaused = duration
    }

    /// The timer has been touched: running, paused mid-interval, or sitting on
    /// a completed count. False only in the pristine state a reset returns to,
    /// which is what decides whether the collapsed island gives it a seat —
    /// once started it keeps that seat (a finished cycle included) until reset.
    var isActive: Bool {
        isRunning || remainingWhenPaused < phaseDuration
            || completedInCycle > 0 || completedFocusTotal > 0
    }

    /// Whole seconds left, clamped at zero.
    func remaining(at date: Date = Date()) -> TimeInterval {
        guard let endDate else { return remainingWhenPaused }
        return max(0, endDate.timeIntervalSince(date))
    }

    /// 0 at the start of an interval, 1 when it's up.
    func progress(at date: Date = Date()) -> Double {
        guard phaseDuration > 0 else { return 0 }
        return min(1, max(0, 1 - remaining(at: date) / phaseDuration))
    }

    // MARK: - Controls

    func start() {
        guard !isRunning else { return }
        isRunning = true
        endDate = Date().addingTimeInterval(remainingWhenPaused)
        startTick()
    }

    func pause() {
        guard isRunning else { return }
        remainingWhenPaused = remaining()
        endDate = nil
        isRunning = false
        stopTick()
    }

    func toggle() {
        isRunning ? pause() : start()
    }

    /// Abandon the current interval and move to the next one, paused. Skipping
    /// a focus interval doesn't count it as completed.
    func skip() {
        advance(completed: false)
    }

    /// Back to a fresh focus interval with nothing counted.
    func reset() {
        stopTick()
        isRunning = false
        endDate = nil
        phase = .focus
        completedInCycle = 0
        completedFocusTotal = 0
        phaseDuration = duration(of: .focus)
        remainingWhenPaused = phaseDuration
    }

    // MARK: - Ticking

    /// One timer, armed for the moment the interval ends. This used to be a
    /// half-second repeating poll asking "is it over yet?" — two wakeups a
    /// second for the length of every interval, with no tolerance, to learn
    /// nothing until the last one. The end date is known the instant the
    /// clock starts, so the timer is simply set for it. In `.common` mode so
    /// an open menu can't hold the roll-over until it closes.
    private func startTick() {
        stopTick()
        guard isRunning, let endDate else { return }
        let timer = Timer(fire: endDate, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.intervalMayHaveEnded() }
        }
        timer.tolerance = 0.25
        RunLoop.main.add(timer, forMode: .common)
        tick = timer
    }

    private func intervalMayHaveEnded() {
        tick = nil
        guard isRunning else { return }
        // Fired ahead of the end (tolerance, or a clock adjustment): re-arm
        // for what's left rather than ending an interval early.
        guard remaining() <= 0 else {
            startTick()
            return
        }
        let ended = phase
        advance(completed: true)
        // Breaks roll straight into the next interval; the next focus waits
        // to be started so a break ending doesn't put you on the clock
        // without asking.
        if ended.isBreak == false {
            start()
        }
        onIntervalEnded?(ended)
    }

    private func stopTick() {
        tick?.invalidate()
        tick = nil
    }

    /// Roll to the next phase, paused, with the new interval's full length on
    /// the clock. `completed` decides whether a focus interval counts.
    private func advance(completed: Bool) {
        stopTick()
        isRunning = false
        endDate = nil

        let next: PomodoroPhase
        switch phase {
        case .focus:
            if completed {
                completedFocusTotal += 1
                completedInCycle += 1
            }
            next = completedInCycle >= max(1, settings.pomodoroSessionsPerCycle) ? .longBreak : .shortBreak
        case .shortBreak:
            next = .focus
        case .longBreak:
            completedInCycle = 0
            next = .focus
        }
        phase = next
        phaseDuration = duration(of: next)
        remainingWhenPaused = phaseDuration
    }

    private func duration(of phase: PomodoroPhase) -> TimeInterval {
        let minutes: Int
        switch phase {
        case .focus: minutes = settings.pomodoroFocusMinutes
        case .shortBreak: minutes = settings.pomodoroShortBreakMinutes
        case .longBreak: minutes = settings.pomodoroLongBreakMinutes
        }
        return TimeInterval(max(1, minutes) * 60)
    }

    // MARK: - Formatting

    /// `m:ss`, or `h:mm:ss` past an hour. Whole seconds, rounded up so the
    /// clock reads the full length the instant it starts rather than one
    /// second short.
    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.up))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
