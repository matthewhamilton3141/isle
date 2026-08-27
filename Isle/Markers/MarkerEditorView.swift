//
//  MarkerEditorView.swift
//
//  Design tool for the dot-matrix markers. Pick an event on the left, paint
//  the 4x4 grid, choose how it's coloured and animated, and watch the live
//  preview — the same renderer the notch uses, reading and writing the same
//  MarkerStore, so edits land in the island immediately.
//

import SwiftUI

struct MarkerEditorView: View {
    @ObservedObject private var store = MarkerStore.shared
    @State private var selectedKind: MarkerKind = .working

    /// A vivid palette so `Artwork` colour mode is visible in the editor even
    /// with no music playing.
    private let previewPalette = ArtworkPalette(primary: .pink, secondary: .blue, accent: .orange)

    private var design: MarkerDesign { store.design(for: selectedKind) }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 210)
            Divider()
            editor
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 760, height: 640)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selectedKind) {
            ForEach(MarkerCategory.allCases) { category in
                Section(category.title) {
                    ForEach(kinds(in: category)) { kind in
                        HStack {
                            Text(kind.title)
                            Spacer()
                            if store.isCustomised(kind) {
                                Circle().fill(.tint).frame(width: 6, height: 6)
                            }
                        }
                        .tag(kind)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func kinds(in category: MarkerCategory) -> [MarkerKind] {
        MarkerKind.allCases.filter { $0.category == category }
    }

    // MARK: - Editor

    private var editor: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                heading
                preview
                gridEditor
                controls
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(selectedKind.title)
                    .font(.system(size: 20, weight: .bold))
                if !isLiveKind {
                    Text("not yet triggered live")
                        .font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(.secondary.opacity(0.15)))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if store.isCustomised(selectedKind) {
                    Button("Reset to default") { store.reset(selectedKind) }
                        .controlSize(.small)
                }
            }
            Text(selectedKind.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    /// Only the lifecycle kinds are emitted by the hook bridge today.
    private var isLiveKind: Bool {
        selectedKind.category == .lifecycle
    }

    private var preview: some View {
        HStack(spacing: 20) {
            previewTile("On artwork", palette: previewPalette)
            previewTile("On black", palette: .fallback)
            Spacer()
        }
    }

    private func previewTile(_ label: String, palette: ArtworkPalette) -> some View {
        VStack(spacing: 8) {
            DotMatrixView(design: design, palette: palette)
                .frame(width: 96, height: 96)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.black))
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Grid painter

    private var gridEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Dots").font(.headline)
            VStack(spacing: 6) {
                ForEach(0..<MarkerDesign.dimension, id: \.self) { row in
                    HStack(spacing: 6) {
                        ForEach(0..<MarkerDesign.dimension, id: \.self) { col in
                            cell(row * MarkerDesign.dimension + col)
                        }
                    }
                }
            }
        }
    }

    private func cell(_ index: Int) -> some View {
        let lit = design.dots[index]
        return Button {
            toggleDot(index)
        } label: {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(lit ? Color.accentColor : Color.secondary.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(.secondary.opacity(0.25), lineWidth: 1)
                )
                .frame(width: 34, height: 34)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Controls

    private var controls: some View {
        Form {
            Picker("Colour", selection: bind(\.colorMode)) {
                ForEach(MarkerDesign.ColorMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            if design.colorMode == .fixed {
                ColorPicker("Fixed colour", selection: fixedColorBinding, supportsOpacity: false)
            }

            Picker("Animation", selection: bind(\.animation)) {
                ForEach(MarkerDesign.MarkerAnimation.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            LabeledContent("Speed") {
                Slider(value: bind(\.speed), in: 0.5...8, step: 0.1)
            }
            LabeledContent("Brightness") {
                Slider(value: bind(\.intensity), in: 0.1...1, step: 0.05)
            }
            Toggle("Show unlit dots faintly", isOn: bind(\.ghost))
        }
        .formStyle(.grouped)
    }

    // MARK: - Editing

    private func toggleDot(_ index: Int) {
        var updated = design
        updated.dots[index].toggle()
        store.update(updated, for: selectedKind)
    }

    /// A binding onto one field of the selected kind's design that writes back
    /// through the store (so only real edits mark a kind as customised).
    private func bind<T>(_ keyPath: WritableKeyPath<MarkerDesign, T>) -> Binding<T> {
        Binding(
            get: { store.design(for: selectedKind)[keyPath: keyPath] },
            set: { newValue in
                var updated = store.design(for: selectedKind)
                updated[keyPath: keyPath] = newValue
                store.update(updated, for: selectedKind)
            }
        )
    }

    private var fixedColorBinding: Binding<Color> {
        Binding(
            get: { Color(hex: store.design(for: selectedKind).fixedColorHex) },
            set: { newColor in
                var updated = store.design(for: selectedKind)
                updated.fixedColorHex = newColor.hexString
                store.update(updated, for: selectedKind)
            }
        )
    }
}
