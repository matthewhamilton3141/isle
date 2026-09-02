//
//  OnboardingView.swift
//
//  First-run picker. Asks what the user wants Isle to be — Music, Claude
//  Code, or Both — then which of the permission-costing extras they
//  want (the live waveform, device batteries, calendar and reminders), so
//  the app configures itself and only ever asks macOS for what was actually
//  chosen. For Claude/Both it
//  offers to install the hook inline, so the bridge is live immediately.
//
//  The mode is written *last*, after the extras step: on a first launch the
//  island doesn't start until a mode exists (see IsleApp), and the island
//  starting is what triggers the permission prompts. Writing the mode any
//  earlier would ask the questions this screen exists to ask first.
//
//  Shown once (when AppSettings has no mode); re-openable from the menu bar
//  as "Setup…".
//

import SwiftUI

struct OnboardingView: View {
    @ObservedObject var settings: AppSettings

    /// Called when the user finishes (or skips the optional hook step). The
    /// window controller closes the window in response.
    var onComplete: () -> Void

    private enum Step {
        case pickMode
        case extras
        case connectClaude
    }

    @State private var step: Step = .pickMode
    @State private var selection: IsleMode
    @State private var liveWaveform: Bool
    @State private var deviceBattery: Bool
    @State private var agenda: Bool
    @State private var hookInstalled = HookInstaller.isInstalled
    @State private var hookError: String?

    init(settings: AppSettings, onComplete: @escaping () -> Void) {
        self.settings = settings
        self.onComplete = onComplete
        // Re-opened from the menu bar, the screen starts from what's already
        // chosen rather than the first-run defaults.
        _selection = State(initialValue: settings.mode ?? .both)
        _liveWaveform = State(initialValue: settings.waveformSource.capturesAudio)
        _deviceBattery = State(initialValue: settings.showDeviceBattery)
        // Ticked on a first run, like the other two — the prompt is expected
        // here. Re-opened, it reflects what's actually on: the stored default
        // is off, so an install that predates the feature never gets asked
        // for Calendar access on the strength of an update.
        _agenda = State(initialValue: settings.hasChosenMode
                        ? settings.showCalendarEvents || settings.showReminders
                        : true)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            Group {
                switch step {
                case .pickMode: pickMode
                case .extras: extras
                case .connectClaude: connectClaude
                }
            }
            .padding(32)
        }
        .frame(width: 520, height: 500)
        .foregroundStyle(.white)
    }

    // MARK: - Step 1: pick a mode

    private var pickMode: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Welcome to Isle")
                .font(.system(size: 24, weight: .bold))
            Text("A Dynamic Island for your MacBook notch. What should it do?")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.6))
                .padding(.top, 4)

            VStack(spacing: 10) {
                ForEach(IsleMode.allCases) { mode in
                    modeCard(mode)
                }
            }
            .padding(.top, 24)

            Spacer(minLength: 0)

            HStack {
                Spacer()
                primaryButton("Continue") { step = .extras }
            }
        }
    }

    private func modeCard(_ mode: IsleMode) -> some View {
        let selected = selection == mode
        return Button {
            selection = mode
        } label: {
            cardLabel(
                symbol: mode.symbolName,
                title: mode.title,
                subtitle: mode.subtitle,
                consequence: consequence(for: mode),
                selected: selected,
                indicator: selected ? "checkmark.circle.fill" : "circle"
            )
        }
        .buttonStyle(.plain)
    }

    /// The permission / setup consequence of each mode, stated up front.
    /// Audio capture is deliberately not listed here — it is its own choice on
    /// the next step, and saying so is what makes that step expected.
    private func consequence(for mode: IsleMode) -> String {
        switch mode {
        case .music:
            return "Asks to control Spotify. Listening for the waveform is a separate choice, next."
        case .claude:
            return "Adds a hook to your Claude Code settings. No media permissions."
        case .both:
            return "Spotify control plus the Claude Code hook. Listening for the waveform is a separate choice, next."
        }
    }

    // MARK: - Step 2: the extras that cost a permission

    /// Two features, each behind a macOS permission prompt, each ticked by
    /// default. The point is not to talk anyone out of them — the live
    /// waveform is the best thing in the island — but to have the consequence
    /// read *before* the prompt appears, and to let someone who doesn't want
    /// the feature decline it here rather than in a system dialog.
    private var extras: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("What Isle may ask for")
                .font(.system(size: 24, weight: .bold))
            Text("Each of these needs a macOS permission. Choose here, so Isle only asks for what you actually want.")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.6))
                .padding(.top, 4)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 10) {
                if selection.showsMusic {
                    optionCard(
                        symbol: "waveform",
                        title: "Live waveform",
                        subtitle: "The bars in the notch move with the music.",
                        consequence: "Asks for Audio Recording the first time something plays. Unticked, the waveform still animates — it just doesn't listen.",
                        isOn: $liveWaveform
                    )
                }
                optionCard(
                    symbol: "headphones",
                    title: "Device batteries",
                    subtitle: "A Bluetooth device's battery level shows in the notch when it connects.",
                    consequence: "Asks for Bluetooth access as soon as you continue. Unticked, Isle never looks.",
                    isOn: $deviceBattery
                )
                // One card for two permissions: at this size the screen can't
                // seat a fourth, and the two are one idea to someone deciding
                // whether Isle may read their day. Settings splits them.
                optionCard(
                    symbol: "calendar",
                    title: "Events & reminders",
                    subtitle: "The expanded notch lists today's events and reminders, and the island shows each as it comes up.",
                    consequence: "Asks for Calendar and Reminders access as soon as you continue. Unticked, Isle never looks.",
                    isOn: $agenda
                )
            }
            .padding(.top, 24)

            Text("Isle is signed without an Apple Developer ID, so macOS ties these answers to this exact build and asks again after an update. All of these can be changed any time in Settings.")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.4))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)

            Spacer(minLength: 0)

            HStack {
                Button("Back") { step = .pickMode }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.6))

                Spacer()

                primaryButton("Continue", action: advanceFromExtras)
            }
        }
    }

    private func optionCard(
        symbol: String, title: String, subtitle: String, consequence: String,
        isOn: Binding<Bool>
    ) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            cardLabel(
                symbol: symbol,
                title: title,
                subtitle: subtitle,
                consequence: consequence,
                selected: isOn.wrappedValue,
                indicator: isOn.wrappedValue ? "checkmark.square.fill" : "square"
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn.wrappedValue ? [.isSelected] : [])
    }

    /// Writes the choices and, last, the mode. On a first launch the mode is
    /// what brings the island up — and with it the Bluetooth registration, so
    /// that prompt lands right here if it was asked for. The waveform choice
    /// is only written when it actually changed, so re-running Setup doesn't
    /// quietly turn a Settings-chosen "Off" into "Animated".
    private func advanceFromExtras() {
        if selection.showsMusic, liveWaveform != settings.waveformSource.capturesAudio {
            settings.waveformSource = liveWaveform ? .live : .animated
        }
        settings.showDeviceBattery = deviceBattery
        // One tick stands for two switches, so it's only written when it
        // actually changed — re-running Setup with just reminders on keeps
        // it that way rather than quietly switching the calendar on too.
        if agenda != (settings.showCalendarEvents || settings.showReminders) {
            settings.showCalendarEvents = agenda
            settings.showReminders = agenda
        }
        settings.mode = selection

        if selection.showsClaude {
            hookInstalled = HookInstaller.isInstalled
            step = .connectClaude
        } else {
            onComplete()
        }
    }

    // MARK: - Step 3: connect Claude Code

    private var connectClaude: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Connect Claude Code")
                .font(.system(size: 24, weight: .bold))
            Text("Isle watches a small status file that Claude Code's hooks write. Installing the hook sets that up.")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.6))
                .padding(.top, 4)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                detail("Drops the isle-cli helper into ~/.isle/bin.")
                detail("Merges hook entries into ~/.claude/settings.json — your existing hooks are left alone.")
                detail("Removable any time from the menu bar.")
            }
            .padding(.top, 20)

            if hookInstalled {
                Label("Hook installed", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.green)
                    .padding(.top, 20)
            } else if let hookError {
                Label(hookError, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .padding(.top, 20)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            HStack {
                Button("Skip for now", action: onComplete)
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.6))

                Spacer()

                if hookInstalled {
                    primaryButton("Done", action: onComplete)
                } else {
                    primaryButton("Install hook", action: installHook)
                }
            }
        }
    }

    // MARK: - Shared pieces

    /// One card face for both the radio-style mode pick and the checkbox
    /// extras, so the two steps read as the same screen.
    private func cardLabel(
        symbol: String, title: String, subtitle: String, consequence: String,
        selected: Bool, indicator: String
    ) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .frame(width: 26)
                .foregroundStyle(selected ? .white : .white.opacity(0.7))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
                Text(consequence)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.4))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 1)
            }

            Spacer(minLength: 0)

            Image(systemName: indicator)
                .font(.system(size: 16))
                .foregroundStyle(selected ? .white : .white.opacity(0.25))
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.white.opacity(selected ? 0.12 : 0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(.white.opacity(selected ? 0.35 : 0), lineWidth: 1)
                )
        )
    }

    private func detail(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "circle.fill")
                .font(.system(size: 4))
                .foregroundStyle(.white.opacity(0.4))
                .padding(.top, 6)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
        }
        .buttonStyle(.borderedProminent)
        .tint(.white)
        .foregroundStyle(.black)
    }

    private func installHook() {
        do {
            try HookInstaller.install()
            hookError = nil
            hookInstalled = true
        } catch {
            hookError = error.localizedDescription
        }
    }
}
