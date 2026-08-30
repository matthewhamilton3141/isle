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
                Toggle("Haptic feedback", isOn: $settings.haptics)
                Text("A soft tap from the trackpad each time the notch opens or closes. Macs without a Force Touch trackpad feel nothing either way.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
