//
//  QuickAddBar.swift
//
//  "Add event or reminder…" along the bottom of the agenda face. At rest a
//  quiet capsule that takes no keys; a click makes it a field, and the panel
//  key — through `NotchViewModel.composing`, the same way the Claude face's
//  reply field does it, without activating Isle — until Esc, a click
//  elsewhere, or the add landing hands the keys straight back.
//
//  Return reads the line (`QuickAddParser`) and shows what it would add, in
//  full, above the field: event or reminder, title, when, and which calendar
//  or list. Nothing is saved from that. Add — or Return again on the same,
//  unchanged line — saves it; Cancel, or any edit, drops the preview. A
//  line it can't read says why instead.
//

import SwiftUI

struct QuickAddBar: View {
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject var agenda: AgendaModel

    private var isComposing: Bool { viewModel.composing == .quickAdd }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let review = agenda.review {
                ReviewLine(review: review, isSaving: agenda.isSaving,
                           add: { agenda.confirm() },
                           cancel: {
                               agenda.cancel()
                               viewModel.endCompose()
                           })
                    .transition(.opacity)
            }
            Group {
                if isComposing {
                    QuickAddField(
                        text: $agenda.draft,
                        onSubmit: { viewModel.sendCompose() },
                        onCancel: { viewModel.endCompose() },
                        onClose: { agenda.closed() }
                    )
                } else {
                    idle
                }
            }
            .frame(height: AgendaLayout.barHeight)
        }
        .animation(.easeInOut(duration: 0.18), value: agenda.review)
    }

    private var idle: some View {
        Button {
            agenda.closed()
            viewModel.beginCompose(.quickAdd)
        } label: {
            HStack(spacing: 6) {
                if let added = agenda.added {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color(hex: "#30D158"))
                    Text("Added \u{201C}\(added)\u{201D}")
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.45))
                    Text(agenda.draft.isEmpty ? "Add event or reminder…" : agenda.draft)
                        .foregroundStyle(.white.opacity(agenda.draft.isEmpty ? 0.4 : 0.7))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Capsule().fill(.white.opacity(0.06)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add event or reminder")
    }
}

/// The field itself, while the panel is key for it. Takes focus as it
/// appears; Return goes to the view model's `sendCompose`, Esc ends
/// composing, and leaving the screen for any reason ends it too, so the
/// panel never holds the keys for a field nobody can see.
private struct QuickAddField: View {
    @Binding var text: String
    let onSubmit: () -> Void
    let onCancel: () -> Void
    let onClose: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.6))
            TextField(text: $text, prompt: Text("Lunch with Sam tomorrow 1pm").foregroundStyle(.white.opacity(0.35))) {
                Text("Add event or reminder")
            }
            .textFieldStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white)
            .focused($focused)
            .onSubmit {
                guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                onSubmit()
            }
            .onExitCommand(perform: onCancel)

            Image(systemName: "return")
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(.white.opacity(text.isEmpty ? 0.2 : 0.5))
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Capsule().fill(.white.opacity(0.08)))
        .overlay(Capsule().inset(by: 0.5).stroke(.white.opacity(0.4), lineWidth: 1))
        .onAppear {
            // After the panel has been made key, which the window controller
            // does on the same turn of the run loop that put this on screen.
            DispatchQueue.main.async { focused = true }
        }
        .onDisappear {
            onCancel()
            onClose()
        }
    }
}

/// What Return found: the draft, spelled out, with Add and Cancel; or the
/// reason there's nothing to add.
private struct ReviewLine: View {
    let review: AgendaModel.Review
    let isSaving: Bool
    let add: () -> Void
    let cancel: () -> Void

    var body: some View {
        switch review {
        case .preview(let draft, let destination):
            // The title and the buttons on one line, the details on their
            // own full-width line under it, so where it goes is never the
            // part cut short.
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    if draft.kind == .event {
                        Circle().fill(destination?.color ?? .white.opacity(0.6)).frame(width: 7, height: 7)
                    } else {
                        Circle().strokeBorder(destination?.color ?? .white.opacity(0.6), lineWidth: 1.5)
                            .frame(width: 8, height: 8)
                    }
                    Text(draft.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 6)
                    RowPill(title: "Cancel", fill: .white.opacity(0.12), foreground: .white, action: cancel)
                    RowPill(title: isSaving ? "Adding…" : "Add", fill: .white, foreground: .black, action: add)
                        .disabled(isSaving)
                }
                Text(Self.detail(draft, destination))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(height: 34)
        case .problem(let message):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AgendaRow.overdue)
                Text(message)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                RowPill(title: "Cancel", fill: .white.opacity(0.12), foreground: .white, action: cancel)
            }
            .frame(height: 20)
        }
    }

    /// "Event · Thu 6 Nov, 1:00 PM · Calendar: Home". Where it goes is said
    /// outright, or that macOS will ask first when Isle can't see yet.
    static func detail(_ draft: QuickAddDraft, _ destination: AgendaMonitor.Destination?) -> String {
        let kind = draft.kind == .event ? "Event" : "Reminder"
        let when: String
        if let date = draft.date {
            let day = date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
            when = draft.hasTime ? "\(day), \(date.formatted(date: .omitted, time: .shortened))" : day
        } else {
            when = "No date"
        }
        let place: String
        if let destination {
            place = draft.kind == .event ? "Calendar: \(destination.title)" : "List: \(destination.title)"
        } else {
            place = draft.kind == .event ? "asks for Calendar access" : "asks for Reminders access"
        }
        return [kind, when, place].joined(separator: " · ")
    }
}
