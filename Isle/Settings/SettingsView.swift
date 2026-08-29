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

    @State private var hookInstalled = HookInstaller.isInstalled
    @State private var hookMessage: String?

    var body: some View {
        Form {
            modeSection

            if settings.effectiveMode.showsMusic {
                musicSection
            }

            if settings.effectiveMode.showsClaude {
                claudeSection
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 440)
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

    // MARK: - Music

    private var musicSection: some View {
        Section("Music") {
            Toggle("Show waveform when collapsed", isOn: $settings.showWaveform)
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
                     ? "Approvals, questions, and API errors pop the notch open."
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
