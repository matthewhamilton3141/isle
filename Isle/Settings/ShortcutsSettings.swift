//
//  ShortcutsSettings.swift
//
//  Settings › Shortcuts: each global shortcut with its keys, a recorder to
//  change them, a reset, and an on/off — and, under a row, why its keys
//  might not work: refused by macOS (another app holds them), or a
//  well-known owner a registration can't detect.
//

import Carbon.HIToolbox
import SwiftUI

struct ShortcutsSettingsSection: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var center: HotKeyCenter

    /// What the last recording came to, per row, until the next one.
    @State private var messages: [ShortcutAction: String] = [:]
    /// The recorder taking keys, if any. One at a time.
    @State private var recording: ShortcutAction?

    init(settings: AppSettings, center: HotKeyCenter? = nil) {
        self.settings = settings
        self.center = center ?? .shared
    }

    var body: some View {
        Section {
            Text("Work the island from the keyboard — no permission to grant. Approve, Deny and the option keys are Isle’s only while a request is waiting on you; the rest of the time those keys are your other apps’ again.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            row(.toggleIsland, subtitle: "Opens on the pointer’s screen and stays until you press it again, click elsewhere, or visit it and leave. Esc stays your other apps’.")
        } header: {
            Text("Shortcuts")
        }

        if settings.effectiveMode.showsClaude {
            Section {
                row(.approve, subtitle: "Also Always…’s Confirm, and Done on a question that takes several answers.")
                row(.deny, subtitle: "Also Always…’s Back.")
                optionsRow
                Text("A press does what the button does, on the request the island is showing. A guarded command takes two presses: the first opens the island to it, the second approves. A number key picks only once the question is on screen; the first press opens it. Keys are taken half a second after a request appears, so a keystroke already on its way to another app stays there.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("While Claude is waiting on you")
            }
        }
    }

    // MARK: - Rows

    private func row(_ action: ShortcutAction, subtitle: String) -> some View {
        let binding = settings.shortcuts[action]
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(action.title)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                recorder(action)
                resetButton([action])
                Toggle(action.title, isOn: isOn([action]))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            statusLine(action, combo: binding.combo, isOn: binding.isOn)
        }
    }

    /// The four option keys share a row, a switch and a reset: they're one
    /// idea, four keys.
    private var optionsRow: some View {
        let actions = ShortcutAction.options
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pick option 1–4")
                    Text("Toggles an option on a question that takes several.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                HStack(spacing: 4) {
                    ForEach(actions, id: \.self) { recorder($0, compact: true) }
                }
                resetButton(actions)
                Toggle("Pick option 1–4", isOn: isOn(actions))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            ForEach(actions, id: \.self) { action in
                let binding = settings.shortcuts[action]
                statusLine(action, combo: binding.combo, isOn: binding.isOn, prefix: "\(action.title): ")
            }
        }
    }

    private func recorder(_ action: ShortcutAction, compact: Bool = false) -> some View {
        let binding = settings.shortcuts[action]
        return ShortcutRecorder(
            combo: binding.combo,
            isOn: binding.isOn,
            compact: compact,
            isRecording: recording == action,
            onBegin: { begin(action) },
            onEnd: { end(action) },
            onRecord: { record($0, for: action) }
        )
        .accessibilityLabel("\(action.title) shortcut, \(binding.combo.spoken)")
    }

    private func resetButton(_ actions: [ShortcutAction]) -> some View {
        let allDefault = actions.allSatisfy { settings.shortcuts.isDefault($0) }
        return Button {
            for action in actions {
                // A default another action has taken since stays with it:
                // reset never makes a press mean two things.
                if let other = settings.shortcuts.clash(for: action.defaultCombo, besides: action) {
                    messages[action] = "\(action.defaultCombo.display()) is \(other.title)’s now."
                    continue
                }
                settings.shortcuts.reset(action)
                center.clearStatus(action)
                messages[action] = nil
            }
        } label: {
            Image(systemName: "arrow.counterclockwise")
        }
        .buttonStyle(.borderless)
        .disabled(allDefault)
        .help(actions.count == 1
              ? "Back to \(actions[0].defaultCombo.display())"
              : "Back to " + actions.map { $0.defaultCombo.display() }.joined(separator: " "))
        .accessibilityLabel("Reset to default")
    }

    private func isOn(_ actions: [ShortcutAction]) -> Binding<Bool> {
        Binding(
            get: { actions.contains { settings.shortcuts[$0].isOn } },
            set: { on in
                for action in actions { settings.shortcuts[action].isOn = on }
            }
        )
    }

    /// Why the keys might not work, when there's a reason: what this
    /// recording came to, a refusal from macOS, or a known owner.
    @ViewBuilder
    private func statusLine(_ action: ShortcutAction, combo: KeyCombo, isOn: Bool, prefix: String = "") -> some View {
        if let message = messages[action] {
            Label(prefix + message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        } else if isOn, case .refused(let status)? = center.status[action] {
            Label(prefix + "\(combo.display()) isn’t working: " + HotKeyCenter.describe(status) + " Pick another.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        } else if isOn, prefix.isEmpty, let note = ShortcutNotes.note(for: combo) {
            Text(note)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Recording

    private func begin(_ action: ShortcutAction) {
        recording = action
        messages[action] = nil
        // Let go of every shortcut, so the keys being typed reach the
        // recorder rather than firing.
        center.isSuspended = true
    }

    private func end(_ action: ShortcutAction) {
        guard recording == action else { return }
        recording = nil
        center.isSuspended = false
    }

    private func record(_ combo: KeyCombo, for action: ShortcutAction) {
        var next = settings.shortcuts
        switch next.assign(combo, to: action) {
        case .needsModifier:
            messages[action] = "Hold ⌥, ⌃ or ⌘ with the key — a bare key is typing."
            return
        case .clashes(let other):
            messages[action] = "\(combo.display()) is already \(other.title)’s."
            return
        case .assigned:
            break
        }
        // Asked now, not the next time a request waits: another app that
        // holds the keys exclusively says so to the probe.
        let probe = center.probe(combo)
        guard probe == noErr else {
            messages[action] = "\(combo.display()): " + HotKeyCenter.describe(probe)
            return
        }
        settings.shortcuts = next
        center.clearStatus(action)
        messages[action] = nil
    }
}

// MARK: - Recorder

/// The keys, in a field-like capsule. Click to record: the next key press
/// with ⌥, ⌃ or ⌘ is the new shortcut; Esc (or a click elsewhere) leaves it
/// as it was. Reads keys through a local monitor — Settings is Isle's own
/// window, so that needs no permission either.
struct ShortcutRecorder: View {
    let combo: KeyCombo
    let isOn: Bool
    var compact = false
    let isRecording: Bool
    let onBegin: () -> Void
    let onEnd: () -> Void
    let onRecord: (KeyCombo) -> Void

    @State private var monitor: Any?
    @State private var heldModifiers: UInt32 = 0

    var body: some View {
        Button {
            isRecording ? stop() : start()
        } label: {
            Text(label)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(isRecording ? Color.accentColor : (isOn ? Color.primary : Color.secondary))
                .lineLimit(1)
                .frame(minWidth: compact ? 34 : 64)
                .padding(.horizontal, 7)
                .frame(height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(isRecording ? Color.accentColor : Color.secondary.opacity(0.35),
                                      lineWidth: isRecording ? 1.5 : 0.5)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isRecording ? "Type the new shortcut; Esc to cancel" : "Click to change")
        .onDisappear { stop() }
        .onChange(of: isRecording) { _, now in
            if !now { removeMonitor() }
        }
    }

    private var label: String {
        guard isRecording else { return combo.display() }
        let held = KeyCombo(keyCode: 0, modifiers: heldModifiers).modifierSymbols
        return held.isEmpty ? (compact ? "…" : "Type keys…") : held + "…"
    }

    private func start() {
        guard monitor == nil else { return }
        heldModifiers = 0
        onBegin()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .leftMouseDown]) { event in
            switch event.type {
            case .flagsChanged:
                heldModifiers = KeyCombo(keyCode: event.keyCode, cocoaFlags: event.modifierFlags.rawValue).modifiers
                return nil
            case .keyDown:
                let pressed = KeyCombo(keyCode: event.keyCode, cocoaFlags: event.modifierFlags.rawValue)
                if pressed.modifiers == 0, Int(event.keyCode) == kVK_Escape {
                    stop()
                    return nil
                }
                stop()
                onRecord(pressed)
                return nil
            default:
                // A click anywhere ends it, and still lands where it was aimed.
                stop()
                return event
            }
        }
    }

    private func stop() {
        removeMonitor()
        onEnd()
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        heldModifiers = 0
    }
}
