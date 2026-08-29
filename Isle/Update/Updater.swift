//
//  Updater.swift
//
//  Isle's auto-updater, ported from Retermina's `store/updater.ts`. Same small
//  state machine — idle → checking → available/uptodate/error → downloading →
//  ready → relaunch — but where Retermina leaned on Tauri's updater plugin to
//  fetch the manifest, verify the minisign signature, download, install and
//  relaunch, this does each of those natively.
//
//  Design constraints carried over verbatim:
//    • On launch it checks *silently* — an unreachable endpoint stays quiet
//      (phase returns to idle), never an error in the user's face.
//    • A manual "Check for Updates" is *not* silent — errors surface.
//    • Declining an update remembers that exact version (one UserDefaults
//      string) so it won't nag again until a newer one ships.
//    • No polling, no rollout logic, no persisted state beyond that one string.
//

import Foundation
import AppKit
import CryptoKit

// MARK: - Configuration

enum UpdaterConfig {
    /// Where the "latest release" manifest lives. GitHub always resolves
    /// `/releases/latest/download/<name>` to the newest tag's asset, so this one
    /// URL is the whole channel — no per-version endpoints, no rollout logic.
    ///
    static let manifestURL = URL(string:
        "https://github.com/matthewhamilton3141/isle/releases/latest/download/latest.json")!

    /// Base64 of the Ed25519 *public* key whose private half signs release
    /// artifacts (its private half lives at `~/.isle-signing/ed25519.key`, used
    /// by `scripts/sign-release.sh`). Empty would mean "not configured":
    /// verification fails closed, so an unsigned build can never install.
    static let publicKeyBase64 = "ecAGZF0fncXUQu8c0NWYQfIJnGUBxSeI1mEnE41lsbw="
}

// MARK: - Phase

/// Transient phase of the check/install flow — the direct analogue of
/// Retermina's `UpdatePhase` union. Never persisted.
enum UpdatePhase: Equatable {
    case idle
    case checking
    case upToDate
    case available(version: String, notes: String?)
    case downloading(pct: Int)
    case ready
    case error(message: String)
}

// MARK: - Updater

@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    @Published private(set) var phase: UpdatePhase = .idle

    private let defaults: UserDefaults
    private static let dismissedKey = "isle.updater.dismissedVersion"

    /// The version the user dismissed — the only thing that survives a relaunch.
    /// Persisted directly (not through AppSettings) to keep the updater's single
    /// piece of state self-contained, exactly as Retermina persisted just this.
    private(set) var dismissedVersion: String? {
        get { defaults.string(forKey: Self.dismissedKey) }
        set { defaults.set(newValue, forKey: Self.dismissedKey) }
    }

    /// The resolved manifest for the pending update. Held here rather than in
    /// `phase` because it isn't part of the UI state and there's only ever one.
    private var pending: UpdateManifest?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Whether a prompt should actually be shown for the current phase: an
    /// available update that the user hasn't already dismissed. (The manual
    /// settings surface ignores this and always shows what a check found.)
    var shouldPrompt: Bool {
        if case let .available(version, _) = phase { return version != dismissedVersion }
        return false
    }

    // MARK: Check

    /// Hit the manifest endpoint. `silent` keeps a failed check quiet (phase
    /// returns to idle) — used for the check-on-launch, where an unreachable or
    /// unconfigured endpoint shouldn't surface an error.
    func check(silent: Bool = false) async {
        switch phase {
        case .checking, .downloading: return   // a run is already in flight
        default: break
        }
        phase = .checking
        pending = nil
        do {
            var request = URLRequest(url: UpdaterConfig.manifestURL)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 15
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw UpdateError("Unexpected response from the update server.")
            }
            let manifest = try JSONDecoder().decode(UpdateManifest.self, from: data)
            if manifest.isNewer(than: .current) {
                pending = manifest
                phase = .available(version: manifest.version, notes: manifest.notes)
            } else {
                phase = .upToDate
            }
        } catch {
            phase = silent
                ? .idle
                : .error(message: "Could not reach the update server. "
                    + "This build may not have an update channel configured yet.")
        }
    }

    // MARK: Install

    /// Download + verify + install the pending update, then relaunch. The app
    /// quits as the last step; the swap-and-reopen runs from a detached helper
    /// that waits for this process to exit first.
    func install() async {
        guard let manifest = pending else { return }
        do {
            phase = .downloading(pct: 0)
            let downloader = ArtifactDownloader { [weak self] fraction in
                Task { @MainActor in
                    guard let self, case .downloading = self.phase else { return }
                    self.phase = .downloading(pct: Int((fraction * 100).rounded()))
                }
            }
            let dmg = try await downloader.download(manifest.url)
            try verifySignature(of: dmg, base64: manifest.signature)
            let newApp = try UpdateInstaller.unpackApp(from: dmg)
            phase = .ready
            try UpdateInstaller.installAndRelaunch(newApp)   // spawns helper, then terminates
        } catch {
            phase = .error(message: "The update could not be installed.")
        }
    }

    /// Verifies the artifact's Ed25519 signature against the embedded public key.
    /// Fails closed: no key configured, or a bad signature, both throw — an
    /// unverified build is never installed.
    private func verifySignature(of fileURL: URL, base64 signatureBase64: String) throws {
        guard !UpdaterConfig.publicKeyBase64.isEmpty,
              let keyData = Data(base64Encoded: UpdaterConfig.publicKeyBase64),
              let signature = Data(base64Encoded: signatureBase64) else {
            throw UpdateError("Update signing isn't configured for this build.")
        }
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
        let artifact = try Data(contentsOf: fileURL)
        guard key.isValidSignature(signature, for: artifact) else {
            throw UpdateError("The update's signature could not be verified.")
        }
    }

    // MARK: Dismiss

    /// Hide the prompt for the currently-available version and remember it, so
    /// the same update won't re-nag — but a newer one will.
    func dismiss() {
        if case let .available(version, _) = phase { dismissedVersion = version }
        phase = .idle
    }
}

// MARK: - Errors

private struct UpdateError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - Download (with progress)

/// Downloads to a stable temp file, reporting fractional progress. A delegate
/// (rather than `URLSession.data`) so the download bar in the settings surface
/// can move — the analogue of Tauri's `downloadAndInstall` progress events.
private final class ArtifactDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: (Double) -> Void
    private var continuation: CheckedContinuation<URL, Error>?

    init(progress: @escaping (Double) -> Void) {
        self.progress = progress
    }

    func download(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
            session.downloadTask(with: url).resume()
            session.finishTasksAndInvalidate()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // The temp file is reaped when this callback returns, so move it out now.
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".dmg")
        do {
            try FileManager.default.moveItem(at: location, to: dest)
            continuation?.resume(returning: dest)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        if let error {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }
}

// MARK: - Install + relaunch

private enum UpdateInstaller {
    /// Mounts the downloaded `.dmg`, copies the `Isle.app` out of it, and
    /// unmounts. The copy is load-bearing: the mounted volume is read-only and
    /// about to be detached, so the returned app has to live somewhere that
    /// survives the unmount.
    static func unpackApp(from dmgURL: URL) throws -> URL {
        let mountPoint = FileManager.default.temporaryDirectory
            .appendingPathComponent("isle-dmg-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)

        // Mount quietly: read-only, no Finder window, at a mount point we choose
        // so there's no plist output to parse.
        let attach = Process()
        attach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        attach.arguments = ["attach", dmgURL.path, "-nobrowse", "-readonly",
                            "-mountpoint", mountPoint.path, "-quiet"]
        try attach.run()
        attach.waitUntilExit()
        guard attach.terminationStatus == 0 else {
            throw UpdateError("Could not mount the update.")
        }

        // Always detach, even if the copy below fails.
        defer {
            let detach = Process()
            detach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            detach.arguments = ["detach", mountPoint.path, "-quiet"]
            if (try? detach.run()) != nil { detach.waitUntilExit() }
        }

        guard let mountedApp = try FileManager.default
            .contentsOfDirectory(at: mountPoint, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" }) else {
            throw UpdateError("The update didn't contain an app.")
        }

        // Copy the app off the read-only volume before it's unmounted. `ditto`
        // preserves the bundle structure and any code signature intact.
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("isle-update-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let stagedApp = staging.appendingPathComponent(mountedApp.lastPathComponent)

        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = [mountedApp.path, stagedApp.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else {
            throw UpdateError("Could not copy the update.")
        }

        return stagedApp
    }

    /// Swaps the new app over the installed one and reopens it — from a detached
    /// shell that first waits for *this* process to exit, then terminates the
    /// app. The helper re-parents to launchd when we quit, so it outlives us.
    static func installAndRelaunch(_ newApp: URL) throws {
        let dest = Bundle.main.bundleURL
        let pid = ProcessInfo.processInfo.processIdentifier

        let script = """
        #!/bin/sh
        while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done
        /bin/rm -rf "\(dest.path)"
        /usr/bin/ditto "\(newApp.path)" "\(dest.path)"
        /usr/bin/xattr -dr com.apple.quarantine "\(dest.path)" 2>/dev/null
        /usr/bin/open "\(dest.path)"
        """

        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("isle-relaunch-" + UUID().uuidString + ".sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = [scriptURL.path]
        try helper.run()   // detached — do not wait; it blocks on our PID instead

        Task { @MainActor in NSApp.terminate(nil) }
    }
}
