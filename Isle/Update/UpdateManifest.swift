//
//  UpdateManifest.swift
//
//  The "latest release" manifest Isle fetches to decide whether a newer signed
//  build exists. Ported from Retermina's Tauri updater, whose plugin consumed a
//  `latest.json` off the GitHub release; here we parse and verify it ourselves.
//
//  The manifest is a single JSON object served from the newest release (GitHub
//  always resolves `/releases/latest/download/<name>` to the newest tag), so
//  there's no rollout logic or channel state — just "what's the latest, and is
//  it newer than us."
//

import Foundation

/// One release, as published in `latest.json`.
struct UpdateManifest: Decodable {
    /// Marketing version of the release, e.g. "0.2.0".
    let version: String
    /// Optional human-readable release notes shown in the prompt.
    let notes: String?
    /// Direct download URL of the signed artifact (the `Isle.dmg`).
    let url: URL
    /// Base64 Ed25519 signature over the artifact's raw bytes, verified against
    /// the public key baked into the app (`UpdaterConfig.publicKeyBase64`).
    let signature: String
    /// Optional floor, e.g. "14.0" — skip the update on older macOS.
    let minimumSystemVersion: String?

    /// True when this release is strictly newer than `current` and this Mac
    /// meets `minimumSystemVersion` (if given).
    func isNewer(than current: SemanticVersion) -> Bool {
        guard let releaseVersion = SemanticVersion(version), releaseVersion > current else {
            return false
        }
        if let floor = minimumSystemVersion, !SemanticVersion.systemMeets(floor) {
            return false
        }
        return true
    }
}

/// A minimal, tolerant semantic version: numeric `major.minor.patch`, with any
/// `-prerelease` / `+build` suffix and a leading `v` ignored. Enough for the
/// only question the updater asks — "is this strictly newer than that?"
struct SemanticVersion: Comparable, CustomStringConvertible {
    let components: [Int]

    init?(_ raw: String) {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        // Drop pre-release / build metadata; compare the numeric core only.
        s = s.split(whereSeparator: { $0 == "-" || $0 == "+" }).first.map(String.init) ?? s
        let parts = s.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        components = parts.map { $0! }
    }

    private init(components: [Int]) { self.components = components }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for i in 0..<count {
            let l = i < lhs.components.count ? lhs.components[i] : 0
            let r = i < rhs.components.count ? rhs.components[i] : 0
            if l != r { return l < r }
        }
        return false
    }

    var description: String { components.map(String.init).joined(separator: ".") }

    /// This app's current marketing version (CFBundleShortVersionString).
    static var current: SemanticVersion {
        let raw = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return raw.flatMap(SemanticVersion.init) ?? SemanticVersion(components: [0])
    }

    /// Whether the running macOS is at least `floor` (e.g. "14.0").
    static func systemMeets(_ floor: String) -> Bool {
        guard let required = SemanticVersion(floor) else { return true }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let current = SemanticVersion(components: [os.majorVersion, os.minorVersion, os.patchVersion])
        return current >= required
    }
}
