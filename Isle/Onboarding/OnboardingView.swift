//
//  OnboardingView.swift
//
//  First-run picker. Asks what the user wants Isle to be — Music, Claude
//  Code, or Both — so the app configures itself (and only requests the
//  permissions that mode needs) instead of defaulting everyone into the
//  music overlay. For Claude/Both it offers to install the hook inline, so
//  the bridge is live immediately.
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
        case connectClaude
    }

    @State private var step: Step = .pickMode
    @State private var selection: IsleMode = .both
    @State private var hookInstalled = HookInstaller.isInstalled
    @State private var hookError: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            Group {
                switch step {
                case .pickMode: pickMode
                case .connectClaude: connectClaude
                }
            }
            .padding(32)
        }
        .frame(width: 520, height: 460)
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
                Button(action: advanceFromMode) {
                    Text("Continue")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(.white)
                .foregroundStyle(.black)
            }
        }
    }

    private func modeCard(_ mode: IsleMode) -> some View {
        let selected = selection == mode
        return Button {
            selection = mode
        } label: {
            HStack(spacing: 14) {
                Image(systemName: mode.symbolName)
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 26)
                    .foregroundStyle(selected ? .white : .white.opacity(0.7))

                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.title)
                        .font(.system(size: 14, weight: .semibold))
                    Text(mode.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                    Text(consequence(for: mode))
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.4))
                        .padding(.top, 1)
                }

                Spacer(minLength: 0)

                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
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
        .buttonStyle(.plain)
    }

    /// The permission / setup consequence of each mode, stated up front.
    private func consequence(for mode: IsleMode) -> String {
        switch mode {
        case .music:
            return "Asks to control Spotify and capture its audio. No Claude changes."
        case .claude:
            return "Adds a hook to your Claude Code settings. No media permissions."
        case .both:
            return "Spotify control + audio, plus the Claude Code hook."
        }
    }

    private func advanceFromMode() {
        settings.mode = selection
        if selection.showsClaude {
            hookInstalled = HookInstaller.isInstalled
            step = .connectClaude
        } else {
            onComplete()
        }
    }

    // MARK: - Step 2: connect Claude Code

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
