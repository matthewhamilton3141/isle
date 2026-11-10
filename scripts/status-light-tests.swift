//
//  status-light-tests.swift
//
//  Tests for the status light's rules and arithmetic (`StatusLight`): which
//  Claude state lights which colour, which wrap the outline and how each
//  moves, the blend with the cover, and the pulse's and flash's curves.
//  Compiled against Isle/Notch/StatusLight.swift and IslandGlass.swift (with
//  what it needs) alone. Run with scripts/test-status-light.sh.
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

func near(_ a: Double, _ b: Double, _ eps: Double = 1e-9) -> Bool { abs(a - b) <= eps }

print("which status")
do {
    let k = StatusLightKind.forMarker
    check(k("working") == .working && k("compacting") == .working, "working, and compacting, are working")
    check(k("needsApproval") == .approval && k("planReview") == .approval, "an approval, and a plan to review, want approval")
    check(k("needsQuestion") == .question, "a question")
    check(k("done") == .done && k("success") == .done, "done")
    check(["rateLimited", "apiError", "serverError", "networkOffline"].allSatisfy { k($0) == .limit }, "a limit or an error is a limit")
    check(["idle", "disconnected", "waitingInput", "paused", "warning", ""].allSatisfy { k($0) == nil },
          "idle, at the prompt, no session, paused: no status — the cover alone")
    check(StatusLightKind.allCases.allSatisfy { k($0.marker) == $0 }, "each status's marker maps back to it")
}

print("colours")
do {
    let hex = Dictionary(uniqueKeysWithValues: StatusLightKind.allCases.map { ($0, StatusLight.RGB(hex: $0.defaultHex)!) })
    check(hex[.working]!.b > hex[.working]!.g && hex[.working]!.r > hex[.working]!.g, "working is purple")
    check(hex[.approval]!.r > 0.9 && hex[.approval]!.g > 0.6 && hex[.approval]!.b < 0.2, "approval is amber")
    check(hex[.question]!.b > hex[.question]!.r && hex[.question]!.b > hex[.question]!.g, "a question is blue")
    check(hex[.done]!.g > hex[.done]!.r && hex[.done]!.g > hex[.done]!.b, "done is green")
    check(hex[.limit]!.r > 0.9 && hex[.limit]!.g < 0.4, "a limit is red")
    check(StatusLight.RGB(hex: "#FF8000") == StatusLight.RGB(1, 128.0 / 255, 0) && StatusLight.RGB(hex: "zz") == nil, "hex parsing")
    check(Set(StatusLightKind.allCases.map(\.defaultHex)).count == 5, "five different colours")
}

print("the blend")
do {
    let cover = StatusLight.RGB(0.2, 0.4, 1.0), status = StatusLight.RGB(1, 0.6, 0)
    check(StatusLight.blend(cover, status: nil) == cover, "no status: the cover's colour")
    let b = StatusLight.blend(cover, status: status)
    check(near(b.r, 0.2 + 0.8 * StatusLight.mix) && near(b.b, 1.0 - 1.0 * StatusLight.mix), "mix of the way to the status", "\(b)")
    check(StatusLight.mix > 0.5 && StatusLight.mix < 0.9, "mostly the status, the cover still in it", "\(StatusLight.mix)")
    check(cover.mixed(toward: status, by: 2) == status && cover.mixed(toward: status, by: -1) == cover, "the mix clamps")
}

print("wrap and motion")
do {
    check(StatusLightKind.allCases.filter(\.wraps) == [.approval, .question, .done, .limit], "approval, a question, done and a limit wrap the outline")
    check(!StatusLightKind.working.wraps, "working keeps to the lower edge")
    check(StatusLightKind.approval.motion == .pulse && StatusLightKind.question.motion == .pulse, "approval and a question pulse")
    check(StatusLightKind.done.motion == .flash, "done flashes once")
    check(StatusLightKind.limit.motion == .still && StatusLightKind.working.motion == .still, "a limit, and working, are still")
    check(StatusLightKind.approval.symbol == "exclamationmark" && StatusLightKind.question.symbol == "questionmark"
          && StatusLightKind.done.symbol == "checkmark" && StatusLightKind.limit.symbol == "clock" && StatusLightKind.working.symbol == nil,
          "icons: ! ? ✓ and a clock; none for working")
    check(StatusLight.iconWidth > 10 && StatusLight.iconWidth < 24, "the icon grows the island a little", "\(StatusLight.iconWidth)")
}

print("pulse")
do {
    let p = StatusLight.pulseOpacity
    check(near(p(0), 1) && near(p(StatusLight.pulsePeriod), 1), "full at the start of each breath")
    check(near(p(StatusLight.pulsePeriod / 2), StatusLight.pulseLow), "at its lowest half way")
    var lo = 1.0, hi = 0.0, step = 0.0, prev = p(0)
    for i in 0...2000 {
        let v = p(Double(i) / 1000 * StatusLight.pulsePeriod)
        lo = min(lo, v); hi = max(hi, v); step = max(step, abs(v - prev)); prev = v
    }
    check(lo >= StatusLight.pulseLow - 1e-9 && hi <= 1 + 1e-9, "between pulseLow and 1")
    check(step < 0.005, "smooth: no step", "\(step)")
    check(StatusLight.pulseLow >= 0.5, "gentle: never below half", "\(StatusLight.pulseLow)")
    check(StatusLight.pulsePeriod >= 1.5 && StatusLight.pulsePeriod <= 3, "slow: a breath every couple of seconds", "\(StatusLight.pulsePeriod)")
}

print("flash")
do {
    let f = StatusLight.flashOpacity
    check(f(0) == 0 && f(StatusLight.flashDuration) == 0 && f(-1) == 0 && f(5) == 0, "nothing before or after")
    check(near(f(StatusLight.flashDuration * StatusLight.flashRise), StatusLight.flashPeak), "peaks early")
    var step = 0.0, prev = 0.0, peak = 0.0
    for i in 0...1000 {
        let v = f(Double(i) / 1000 * StatusLight.flashDuration)
        step = max(step, abs(v - prev)); prev = v; peak = max(peak, v)
    }
    check(step < 0.02, "no step on the way up or down", "\(step)")
    check(near(peak, StatusLight.flashPeak, 1e-3) && peak <= 1, "up to its peak, no further")
    check(StatusLight.flashDuration <= 1.2, "over within about a second")
}

print("\n\(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
