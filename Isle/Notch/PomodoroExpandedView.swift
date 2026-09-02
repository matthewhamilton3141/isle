//
//  PomodoroExpandedView.swift
//
//  The Pomodoro face of the expanded panel. Same skeleton as the music and
//  Claude tabs — a 114pt hero on the left where the album art sits, then a
//  text column — so switching tabs doesn't jump anything around. The hero is
//  the progress ring with the clock inside it; the column carries the phase,
//  a one-line status, the cycle tally, and the transport-style controls.
//

import SwiftUI

struct PomodoroExpandedView: View {
    @ObservedObject var viewModel: NotchViewModel
    var palette: ArtworkPalette

    private var timer: PomodoroTimer { viewModel.pomodoro }

    var body: some View {
        HStack(spacing: 14) {
            hero
                // Matches the album's raise into the housing band; safe for the
                // same reason — the hero sits left of the camera cutout.
                .frame(width: 114, height: 114)
                .offset(y: -11)

            VStack(alignment: .leading, spacing: 0) {
                Spacer(minLength: 0)

                Text(timer.phase.title)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .contentTransition(.opacity)
                    .padding(.trailing, 36)

                Spacer().frame(height: 2)

                Text(detail)
                    .font(.system(size: 12.5, weight: .regular))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .contentTransition(.opacity)

                Spacer().frame(height: 11)

                HStack(spacing: 10) {
                    cycleDots
                    controls
                    Spacer(minLength: 0)
                }

                Spacer(minLength: 0)
            }
            .frame(minWidth: 340, maxWidth: 340, maxHeight: .infinity, alignment: .leading)
            // Only a slight raise, unlike the Claude tab's -21: this column has
            // a controls row rather than a chip row, so lifted that far the
            // headline ran up under the camera housing and got cut off.
            .offset(y: -6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(.white)
        .animation(.easeInOut(duration: 0.2), value: timer.phase)
        .animation(.easeInOut(duration: 0.2), value: timer.isRunning)
    }

    // MARK: - Hero

    /// The ring with the clock inside. Ticks once a second while running;
    /// paused, the schedule still fires but reads the same value, which is a
    /// no-op redraw.
    private var hero: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            ZStack {
                PomodoroRing(
                    progress: timer.progress(at: context.date),
                    tint: tint,
                    lineWidth: 6
                )
                Text(PomodoroTimer.clock(timer.remaining(at: context.date)))
                    .font(.system(size: clockPointSize(for: context.date), weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    // Inside the ring's stroke with clear air on both sides.
                    .padding(.horizontal, 16)
            }
        }
    }

    /// Past an hour the clock grows a third group, so it steps down a size to
    /// stay inside the ring.
    private func clockPointSize(for date: Date) -> CGFloat {
        timer.remaining(at: date) >= 3600 ? 18 : 23
    }

    private var tint: Color {
        timer.phase.isBreak ? palette.secondary : palette.accent
    }

    // MARK: - Text

    private var detail: String {
        if timer.isRunning {
            return timer.phase.isBreak ? "Step away — the next focus waits for you" : "Heads down"
        }
        if timer.isActive {
            return "Paused"
        }
        return timer.phase.isBreak ? "Ready when you are" : "Press play to start a focus session"
    }

    // MARK: - Cycle tally

    /// One dot per focus interval in the cycle, filled as they're completed.
    private var cycleDots: some View {
        let total = max(1, viewModel.pomodoroSessionsPerCycle)
        return HStack(spacing: 4) {
            ForEach(0..<total, id: \.self) { index in
                Circle()
                    .fill(index < timer.completedInCycle ? tint : .white.opacity(0.22))
                    .frame(width: 6, height: 6)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Capsule().fill(.white.opacity(0.12)))
        .animation(.easeInOut(duration: 0.2), value: timer.completedInCycle)
        .accessibilityLabel("\(timer.completedInCycle) of \(total) focus sessions done")
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 14) {
            controlButton("arrow.counterclockwise", size: 14, active: timer.isActive) {
                timer.reset()
            }
            .disabled(!timer.isActive)

            controlButton(timer.isRunning ? "pause.fill" : "play.fill", size: 22) {
                timer.toggle()
            }

            controlButton("forward.end.fill", size: 14) {
                timer.skip()
            }
        }
    }

    private func controlButton(
        _ symbol: String,
        size: CGFloat,
        active: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(active ? .white : .white.opacity(0.35))
                .frame(width: size + 7, height: size + 7)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
