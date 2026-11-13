//
//  meter-watchdog-tests.swift
//
//  Tests for the level meter's watchdog (Isle/Media/MeterWatchdog.swift),
//  compiled against that file alone: no app, no Core Audio. Readings come
//  once a second, as they do off the display timer.
//
//  Run with scripts/test-meter-watchdog.sh.
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
        print("  FAIL  \(name) \(detail())")
    }
}

/// Feeds one reading a second from `from` to `to` (inclusive) with the
/// callback count `count(t)`, and returns the seconds at which it asked for
/// a rebuild.
func run(_ dog: inout MeterWatchdog, from: Int, to: Int, playing: (Int) -> Bool = { _ in true },
         count: (Int) -> Int) -> [Int] {
    var rebuilds: [Int] = []
    for t in from...to {
        if dog.observe(callbacks: count(t), at: TimeInterval(t), playing: playing(t)) == .rebuild {
            rebuilds.append(t)
        }
    }
    return rebuilds
}

print("healthy")
do {
    var dog = MeterWatchdog()
    dog.begin(callbacks: 0, at: 0)
    let r = run(&dog, from: 1, to: 600) { $0 * 94 }
    check(r.isEmpty, "a meter at 94 callbacks a second is never rebuilt", "\(r)")
    check(dog.attempts == 0, "and has used no tries")
}

print("paused")
do {
    var dog = MeterWatchdog()
    dog.begin(callbacks: 500, at: 0)
    let r = run(&dog, from: 1, to: 600, playing: { _ in false }) { _ in 500 }
    check(r.isEmpty, "silence while paused is never a stall", "\(r)")
}

print("the stall of 13 Nov: 94 a second, then none, while playing")
do {
    var dog = MeterWatchdog()
    dog.begin(callbacks: 0, at: 0)
    // Running until t=100, then the IOProc stops for good.
    let count: (Int) -> Int = { min($0, 100) * 94 }
    let r = run(&dog, from: 1, to: 160, count: count)
    check(r.first == 104, "first rebuild 3s after the first silent reading", "\(r)")
    check(r == [104, 114, 144], "then after 10s and 30s more, and no more", "\(r)")
    check(dog.gaveUp, "out of tries")
    let later = run(&dog, from: 161, to: 1200, count: count)
    check(later.isEmpty, "a player that is never heard (Spotify Connect) gets three tries, not a loop", "\(later)")
}

print("grace")
do {
    var dog = MeterWatchdog()
    dog.begin(callbacks: 0, at: 0)
    // Playing reported a second or two before the player's audio arrives.
    let r = run(&dog, from: 1, to: 30) { $0 < 2 ? 0 : ($0 - 2) * 94 }
    check(r.isEmpty, "two silent seconds after a resume are a start, not a stall", "\(r)")
    var slow = MeterWatchdog()
    slow.begin(callbacks: 0, at: 0)
    let s = run(&slow, from: 1, to: 2) { _ in 0 }
    check(s.isEmpty, "nothing before 3s of silence")
    check(slow.observe(callbacks: 0, at: 3, playing: true) == .rebuild, "rebuild at 3s")
}

print("recovery")
do {
    var dog = MeterWatchdog()
    dog.begin(callbacks: 1000, at: 0)
    check(run(&dog, from: 1, to: 3) { _ in 1000 } == [3], "stalled: rebuilt at 3s")
    // The rebuild brings the meter back (publishing restarts: begin).
    dog.begin(callbacks: 1000, at: 4)
    let r = run(&dog, from: 5, to: 60) { 1000 + ($0 - 4) * 94 }
    check(r.isEmpty && dog.attempts == 0, "callbacks again: tries forgotten", "\(r) attempts \(dog.attempts)")
    // A second stall later gets the short wait again, not the long one.
    let again = run(&dog, from: 61, to: 70) { _ in 1000 + 56 * 94 }
    check(again == [64], "a later stall is rebuilt after 3s again", "\(again)")
}

print("a rebuild that brings nothing back counts as a try")
do {
    var dog = MeterWatchdog()
    dog.begin(callbacks: 0, at: 0)
    check(run(&dog, from: 1, to: 3) { _ in 0 } == [3], "first try at 3s")
    // Publishing restarts after the rebuild, still silent.
    dog.begin(callbacks: 0, at: 3.2)
    let r = run(&dog, from: 4, to: 20) { _ in 0 }
    check(r == [14], "next try 10s after the rebuild, not 3s", "\(r)")
}

print("silence while suspended does not count")
do {
    var dog = MeterWatchdog()
    dog.begin(callbacks: 0, at: 0)
    _ = run(&dog, from: 1, to: 2) { _ in 0 }
    // Paused at 2.5 and suspended for a minute; publishing resumes at 62.
    dog.reset()
    dog.begin(callbacks: 0, at: 62)
    check(dog.observe(callbacks: 0, at: 63, playing: true) == .waiting, "a second after resuming: waiting")
    check(dog.observe(callbacks: 0, at: 64, playing: true) == .waiting, "two seconds: still waiting")
    check(dog.observe(callbacks: 0, at: 65, playing: true) == .rebuild, "three seconds after resuming: rebuild")
}

print("reset")
do {
    var dog = MeterWatchdog()
    dog.begin(callbacks: 0, at: 0)
    _ = run(&dog, from: 1, to: 200) { _ in 0 }
    check(dog.gaveUp, "given up after three tries")
    dog.reset()
    check(dog == MeterWatchdog(), "reset forgets everything")
    dog.begin(callbacks: 0, at: 300)
    check(run(&dog, from: 301, to: 303) { _ in 0 } == [303], "a click or a new stretch of playback gets the tries back")
}

print("pausing mid-silence")
do {
    var dog = MeterWatchdog()
    dog.begin(callbacks: 0, at: 0)
    // Silent for 2s, paused for 5s (still publishing, within the grace
    // before the suspend), playing again.
    let r = run(&dog, from: 1, to: 9, playing: { !(3...7).contains($0) }) { _ in 0 }
    check(r.isEmpty, "the paused seconds don't add to the silence", "\(r)")
    check(dog.observe(callbacks: 0, at: 10, playing: true) == .waiting, "two seconds into playing again: waiting")
    check(dog.observe(callbacks: 0, at: 11, playing: true) == .rebuild, "three: rebuild")
}

print("\n\(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
