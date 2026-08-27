//
//  MarkerStore.swift
//
//  Holds every marker's design and persists them to ~/.isle/markers.json.
//  The editor writes here; the notch reads here — so a design change shows up
//  live in the island. Any kind without a saved design falls back to its
//  built-in default, so new kinds work before they've ever been edited.
//

import Foundation
import Combine

@MainActor
final class MarkerStore: ObservableObject {
    static let shared = MarkerStore()

    /// Saved overrides, keyed by kind. Missing kinds use `.default(for:)`.
    @Published private var overrides: [MarkerKind: MarkerDesign]

    private let fileURL: URL

    init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".isle", isDirectory: true)
        fileURL = dir.appendingPathComponent("markers.json")
        overrides = Self.load(from: fileURL)
    }

    /// The design to render for a kind — a saved override, or the default.
    func design(for kind: MarkerKind) -> MarkerDesign {
        overrides[kind] ?? .default(for: kind)
    }

    /// Whether the user has customised this kind away from its default.
    func isCustomised(_ kind: MarkerKind) -> Bool {
        overrides[kind] != nil
    }

    func update(_ design: MarkerDesign, for kind: MarkerKind) {
        overrides[kind] = design
        save()
    }

    func reset(_ kind: MarkerKind) {
        overrides.removeValue(forKey: kind)
        save()
    }

    // MARK: - Persistence

    // Stored keyed by the kind's raw string so it round-trips as a plain JSON
    // object rather than Codable's array-of-pairs form for enum-keyed maps.
    private func save() {
        let raw = Dictionary(uniqueKeysWithValues: overrides.map { ($0.key.rawValue, $0.value) })
        do {
            let data = try JSONEncoder().encode(raw)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Isle: failed to save markers: \(error)")
        }
    }

    private static func load(from url: URL) -> [MarkerKind: MarkerDesign] {
        guard let data = try? Data(contentsOf: url),
              let raw = try? JSONDecoder().decode([String: MarkerDesign].self, from: data)
        else { return [:] }

        var result: [MarkerKind: MarkerDesign] = [:]
        for (key, design) in raw {
            // Drop designs saved against a different grid size (e.g. an old
            // 4x4 file after the switch to 5x5) — they'd render wrong. The kind
            // falls back to its default and is re-saved on the next edit.
            guard design.dots.count == MarkerDesign.dotCount else { continue }
            if let kind = MarkerKind(rawValue: key) {
                result[kind] = design
            }
        }
        return result
    }
}
