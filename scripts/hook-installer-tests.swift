//
//  hook-installer-tests.swift
//
//  How the helper lands: executable the instant it's in place, never a
//  0644 file a hook firing mid-install can't run. Writes only under the
//  directory scripts/test-hook-installer.sh passes in.
//

import Foundation

var failures = 0
var passes = 0

func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    if ok {
        passes += 1
        print("  ok    \(name)")
    } else {
        failures += 1
        let more = detail()
        print("  FAIL  \(name)" + (more.isEmpty ? "" : "\n        \(more)"))
    }
}

func mode(_ url: URL) -> Int? {
    (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
}

/// What a watcher saw while the installer rewrote the helper.
final class Looks: @unchecked Sendable {
    private let lock = NSLock()
    private var _looks = 0, _misses = 0, _missing = 0
    func note(exists: Bool, executable: Bool) {
        lock.lock(); defer { lock.unlock() }
        if !exists { _missing += 1; return }
        _looks += 1
        if !executable { _misses += 1 }
    }
    var counts: (looks: Int, misses: Int, missing: Int) {
        lock.lock(); defer { lock.unlock() }
        return (_looks, _misses, _missing)
    }
}

@main
enum Tests {
    static func main() {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let bin = root.appendingPathComponent(".isle/bin", isDirectory: true)
        let script = bin.appendingPathComponent("isle-cli")
        let fm = FileManager.default

        print("Writing the helper")
        do { try HookInstaller.writeScript(to: script) } catch { check(false, "first write", "\(error)") }
        check(mode(script) == 0o755, "a fresh install is 0755", "mode \(String(mode(script) ?? -1, radix: 8))")
        let body = (try? String(contentsOf: script, encoding: .utf8)) ?? ""
        check(body.hasPrefix("#!"), "and is the script")
        check(fm.isExecutableFile(atPath: script.path), "executable")

        print("Rewriting it while something keeps looking")
        // A watcher stats the path as fast as it can while the installer
        // rewrites it: every look must find an executable file. The old
        // write-then-chmod left a 0644 window here.
        let looks = Looks()
        let stop = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        let path = script.path
        Thread.detachNewThread {
            while stop.wait(timeout: .now()) == .timedOut {
                var st = stat()
                let exists = stat(path, &st) == 0
                looks.note(exists: exists, executable: st.st_mode & 0o111 == 0o111)
            }
            done.signal()
        }
        var errors = 0
        for _ in 0..<400 {
            do { try HookInstaller.writeScript(to: script) } catch { errors += 1 }
        }
        stop.signal()
        done.wait()
        let seen = looks.counts
        check(errors == 0, "400 rewrites, no errors", "\(errors) errors")
        check(seen.looks > 0, "the watcher got its looks in", "\(seen.looks)")
        check(seen.misses == 0, "never seen without its execute bits", "\(seen.misses) of \(seen.looks)")
        check(seen.missing == 0, "never seen missing (rename replaces in place)", "\(seen.missing)")
        let leftovers = ((try? fm.contentsOfDirectory(atPath: bin.path)) ?? []).filter { $0 != "isle-cli" }
        check(leftovers.isEmpty, "no temp files left behind", "\(leftovers)")
        check(mode(script) == 0o755, "still 0755")

        print("\n\(passes) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
