//
//  SettingsView.swift
//
//  The Settings window. Change the mode (which restarts the affected
//  subsystems live — no relaunch), toggle the media controls from spec 3.4,
//  and manage the Claude Code hook. Sections show or hide with the active
//  mode, so a music-only user never sees Claude options and vice versa.
//

import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject private var updater = Updater.shared

    @State private var hookInstalled = HookInstaller.isInstalled
    @State private var hookMessage: String?

    var body: some View {
        Form {
            modeSection

            notchSection

            if settings.effectiveMode.showsMusic {
                musicSection
            }

            if settings.effectiveMode.showsClaude {
                claudeSection
            }

            powerSection

            updatesSection
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 440)
    }

    // MARK: - Updates

    /// Mirrors Retermina's Version tab: the app version, a "Check for Updates"
    /// button whose errors surface here (unlike the silent launch check), and
    /// the live download/ready states off the shared `Updater` phase.
    @ViewBuilder
    private var updatesSection: some View {
        Section("Updates") {
            LabeledContent("Version", value: appVersion)

            switch updater.phase {
            case .downloading(let pct):
                VStack(alignment: .leading, spacing: 6) {
                    Text("Downloading update…").font(.caption)
                    ProgressView(value: Double(pct), total: 100)
                }
            case .ready:
                Text("Update installed — relaunching…")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
            default:
                HStack(spacing: 10) {
                    Button {
                        Task { await updater.check() }
                    } label: {
                        if case .checking = updater.phase {
                            Label("Checking…", systemImage: "arrow.triangle.2.circlepath")
                        } else {
                            Text("Check for Updates")
                        }
                    }
                    .disabled(updaterIsBusy)

                    if case let .available(version, _) = updater.phase {
                        Button("Install \(version)") {
                            Task { await updater.install() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }

                if case .upToDate = updater.phase {
                    Text("You're on the latest version.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if case let .available(_, notes) = updater.phase,
                   let notes, !notes.isEmpty {
                    Text(notes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if case let .error(message) = updater.phase {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private var updaterIsBusy: Bool {
        switch updater.phase {
        case .checking, .downloading: return true
        default: return false
        }
    }

    // MARK: - Mode

    private var modeSection: some View {
        Section("Mode") {
            Picker("Isle shows", selection: modeBinding) {
                ForEach(IsleMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Text(settings.effectiveMode.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// The mode picker reads `effectiveMode` (never nil) and writes through to
    /// the stored optional, which flips onboarding's "has chosen" too.
    private var modeBinding: Binding<IsleMode> {
        Binding(
            get: { settings.effectiveMode },
            set: { settings.mode = $0 }
        )
    }

    // MARK: - Notch

    private var notchSection: some View {
        Section("Notch") {
            VStack(alignment: .leading, spacing: 4) {
                Picker("Show island on", selection: $settings.displayScope) {
                    ForEach(DisplayScope.allCases) { scope in
                        Text(scope.title).tag(scope)
                    }
                }
                Text(settings.displayScope.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 4) {
                Toggle("Haptic feedback", isOn: $settings.haptics)
                Text("A soft tap from the trackpad each time the notch opens or closes. Macs without a Force Touch trackpad feel nothing either way.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Power

    /// Unconditional, unlike Music and Claude: power isn't a mode, it's
    /// ambient. A charger going in matters whichever source the island is
    /// running.
    ///
    /// Two independent switches, neither nested under the other. They are
    /// different questions about different hardware — this Mac's battery, and
    /// the batteries of things attached to it — and someone who only wants to
    /// hear about their headphones should be able to say so.
    private var powerSection: some View {
        Section("Power") {
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Show battery updates", isOn: $settings.showBatteryEvents)
                Text("Plugging in, unplugging, a full charge, a low battery and Low Power Mode appear briefly in the notch, then hand it back to whatever was there.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 4) {
                Toggle("Show device updates", isOn: $settings.showDeviceBattery)
                Text("A Bluetooth device's battery level appears when it connects — and when you plug the Mac in, if battery updates are on. Devices that don't report a level show nothing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Switching one off stops Isle watching for it, so it costs nothing. Either way macOS keeps its own battery behaviour, alerts and Bluetooth exactly as they are.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Music

    private var musicSection: some View {
        Section("Music") {
            Toggle("Show scrubber", isOn: $settings.showScrubber)
            Toggle("Show shuffle & repeat", isOn: $settings.showShuffleRepeat)
        }
    }

    // MARK: - Claude

    private var claudeSection: some View {
        Section("Claude Code") {
            HStack {
                Label(
                    hookInstalled ? "Hook installed" : "Hook not installed",
                    systemImage: hookInstalled ? "checkmark.circle.fill" : "circle"
                )
                .foregroundStyle(hookInstalled ? .green : .secondary)

                Spacer()

                if hookInstalled {
                    Button("Remove", role: .destructive) { removeHook() }
                } else {
                    Button("Install") { installHook() }
                }
            }

            if let hookMessage {
                Text(hookMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            accentPicker

            LabeledContent("Keep “done” checkmark for") {
                HStack(spacing: 8) {
                    Text("\(Int(settings.doneToastSeconds))s")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Stepper(
                        "",
                        value: $settings.doneToastSeconds,
                        in: 1...15,
                        step: 1
                    )
                    .labelsHidden()
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Toggle("Show “Waiting” in the island", isOn: $settings.showWaitingStatus)
                Text(settings.showWaitingStatus
                     ? "The island shows when Claude has handed the turn back to you."
                     : "Waiting stays out of the island; the expanded panel still shows it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 4) {
                Toggle("Expand notch for alerts", isOn: $settings.expandOnAlert)
                Text(settings.expandOnAlert
                     ? "Questions and errors pop the notch open."
                     : "Delivered minimized — the collapsed island shows the alert; hover to open.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 4) {
                Toggle("Dismiss alert panel on hover-out / click", isOn: $settings.dismissAlertPanel)
                Text(settings.dismissAlertPanel
                     ? "Hover away or click to retract the panel; the alert stays in the island until resolved."
                     : "The panel stays open until the alert resolves (e.g. you answer).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .disabled(!settings.expandOnAlert)
        }
    }

    // MARK: - Accent

    /// A swatch row plus a custom well, rather than a bare colour picker.
    ///
    /// macOS's own accent setting has this shape, and two things here make it
    /// the right one beyond consistency. The accent has to yield *three* stops
    /// — `DotColors.paletteRamp` walks primary → accent → secondary — so a
    /// swatch can ship its ramp pre-derived and correct, where an arbitrary hue
    /// has to derive one and degrades at the extremes. And two regions of the
    /// space are actively wrong: near-black vanishes against the camera
    /// housing, and near-red or near-green impersonates `failed` and `done`,
    /// which is exactly what holding the semantic markers fixed is meant to
    /// prevent. The swatches are measured against those; a custom colour is
    /// floored by `ClaudeAccent.derive` but carries no such guarantee.
    @ViewBuilder
    private var accentPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Accent") {
                HStack(spacing: 6) {
                    ForEach(ClaudeAccent.swatches) { swatch in
                        swatchChip(swatch)
                    }
                    CustomAccentWell(
                        hex: $settings.claudeAccentHex,
                        isSelected: settings.claudeAccent == .custom,
                        size: Self.chipSize
                    ) {
                        settings.claudeAccent = .custom
                    }
                }
            }

            Text(accentCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One size for every chip in the accent row, the custom well included —
    /// it is the reason that well is hand-drawn rather than a `ColorPicker`.
    private static let chipSize: CGFloat = 24

    private func swatchChip(_ swatch: ClaudeAccent) -> some View {
        let selected = settings.claudeAccent == swatch
        return Button {
            settings.claudeAccent = swatch
        } label: {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(swatch.chipColor(customHex: settings.claudeAccentHex))
                .frame(width: Self.chipSize, height: Self.chipSize)
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(.primary.opacity(0.15), lineWidth: 1)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: selected ? 2 : 0)
                        .padding(-3)
                }
        }
        .buttonStyle(.plain)
        .help(swatch.title)
        .accessibilityLabel(swatch.title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    /// The family's own explanation, plus a qualifier in `.both` — where the
    /// accent is real but intermittent: `NotchViewModel.palette` prefers album
    /// art whenever there is any, and only falls through to the accent when
    /// nothing is playing. Saying so is better than hiding the control, which
    /// would leave a Both-mode user watching a colour they can't change.
    private var accentCaption: String {
        guard settings.effectiveMode == .both else { return familyCaption }
        return familyCaption
            + " While music is playing the island takes its colour from the album art instead — this applies when nothing is."
    }

    private var familyCaption: String {
        switch settings.claudeAccent.family {
        case .chromatic:
            return "\(settings.claudeAccent.title). Questions, errors and the done checkmark keep their own colours — those mean something."
        case .muted:
            return "\(settings.claudeAccent.title) — muted rather than grey. A true grey can't be told apart from the disconnected and paused states, which already use it."
        case .snapped:
            let name = ClaudeAccent.nearestSwatch(to: .controlAccentColor).title
            return "Follows your system accent, snapped to the nearest colour Isle can use — \(name). Five of the eight macOS accents are colours that already mean something here."
        case .derived:
            if let clash = ClaudeAccent.collision(forCustom: settings.claudeAccentHex) {
                return "This is close to the colour Isle uses for \(clash), so a working island may read as one. Still applied — it's your choice."
            }
            return "A custom colour. Clear of the colours Isle uses for questions, errors and success."
        }
    }

    // MARK: - Hook actions

    private func installHook() {
        do {
            try HookInstaller.install()
            hookInstalled = true
            hookMessage = "Installed to ~/.isle/bin and wired into ~/.claude/settings.json."
        } catch {
            hookMessage = error.localizedDescription
        }
    }

    private func removeHook() {
        do {
            try HookInstaller.uninstall()
            hookInstalled = false
            hookMessage = "Removed. Your other Claude Code hooks were left untouched."
        } catch {
            hookMessage = error.localizedDescription
        }
    }
}
