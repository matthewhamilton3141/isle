//
//  live-strip-tests.swift
//
//  Tests for the live strip's rules (Isle/Notch/LiveStrip.swift): which face
//  leads, what the strip under it holds, what a takeover leaves, and what an
//  open's hold keeps. Compiled against that file and the face list alone —
//  no app, no window. Run with scripts/test-live-strip.sh.
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

func equal<T: Equatable>(_ got: T, _ want: T, _ name: String) {
    check(got == want, name, "want \(want), got \(got)")
}

let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
func at(_ minutes: Double) -> Date { now.addingTimeInterval(minutes * 60) }

func event(_ id: String, _ start: Double, _ length: Double = 30, joinable: Bool = false,
           allDay: Bool = false, reminder: Bool = false) -> LiveStrip.Event {
    LiveStrip.Event(id: id, start: at(start), end: reminder ? nil : at(start + length), isAllDay: allDay,
                    isEvent: !reminder, joinable: joinable)
}

let everyFace: [IsleTab] = [.music, .claude, .pomodoro, .agenda, .shelf]

func inputs(tabs: [IsleTab] = everyFace, session: Bool = true, asking: Bool = false, track: Bool = false,
            timer: Bool = false, events: [LiveStrip.Event] = [], shelf: Int = 0) -> LiveStrip.Inputs {
    LiveStrip.Inputs(tabs: tabs, claudeSession: session, claudeAsking: asking, hasTrack: track,
                     timerActive: timer, events: events, shelfCount: shelf, now: now)
}

print("Which face leads")
equal(LiveStrip.primary(inputs(track: true, timer: true)), .claude, "a Claude session leads whatever else is live")
equal(LiveStrip.primary(inputs(session: false, track: true, timer: true)), .music, "no session: the track")
equal(LiveStrip.primary(inputs(session: false, timer: true)), .pomodoro, "no session, no track: a started timer")
equal(LiveStrip.primary(inputs(session: false)), .claude, "nothing live: Claude's face, as the mode has it")
equal(LiveStrip.primary(inputs(tabs: [.music, .agenda], session: false)), nil,
      "no Claude in the mode and nothing live: no lead, the island opens where it was")
equal(LiveStrip.primary(inputs(tabs: [.music, .pomodoro], session: true, timer: true)), .pomodoro,
      "a session the mode doesn't show doesn't lead")

print("What the strip holds")
equal(LiveStrip.content(on: .claude, inputs()), LiveStrip.Content(), "nothing live: no strip")
check(LiveStrip.content(on: .claude, inputs()).isEmpty, "and it says so")
var all = LiveStrip.content(on: .claude, inputs(track: true, timer: true, events: [event("a", 20)], shelf: 3))
equal(all, LiveStrip.Content(music: true, timer: true, event: "a", joinable: false, shelf: 3), "everything live, in grid order")
equal(all.count, 4, "four cards")
equal(LiveStrip.content(on: .music, inputs(session: false, track: true, timer: true)).music, false,
      "the face above isn't in its own strip")
equal(LiveStrip.content(on: .pomodoro, inputs(session: false, timer: true)).timer, false, "nor the timer's")
equal(LiveStrip.content(on: .claude, inputs(events: [event("far", 61)])).event, nil, "an event over an hour away: no card")
equal(LiveStrip.content(on: .claude, inputs(events: [event("soon", 59)])).event, "soon", "within the hour: a card")
equal(LiveStrip.content(on: .claude, inputs(events: [event("now", -10)])).event, "now", "under way: a card")
equal(LiveStrip.content(on: .claude, inputs(events: [event("over", -40)])).event, nil, "over: no card")
equal(LiveStrip.content(on: .claude, inputs(events: [event("day", -60, 1440, allDay: true)])).event, nil,
      "an all-day event: no card")
equal(LiveStrip.content(on: .claude, inputs(events: [event("r", 10, reminder: true)])).event, nil, "a reminder: no card")
equal(LiveStrip.content(on: .claude, inputs(events: [event("a", 20), event("call", 40, joinable: true)])).event, "call",
      "a call you can join comes before an earlier event")
equal(LiveStrip.content(on: .claude, inputs(tabs: [.music, .claude], track: true, timer: true, shelf: 2)),
      LiveStrip.Content(music: true), "faces the mode doesn't offer: no cards")

print("Takeover: Claude asking")
let busy = inputs(asking: true, track: true, timer: true, events: [event("a", 20)], shelf: 3)
check(LiveStrip.content(on: .claude, busy).isEmpty, "an approval with nothing pressing: no strip")
let call = inputs(asking: true, track: true, timer: true, events: [event("call", 4, joinable: true)], shelf: 3)
equal(LiveStrip.content(on: .claude, call), LiveStrip.Content(event: "call", joinable: true),
      "a call you can join now: that alone")
equal(LiveStrip.content(on: .music, inputs(session: false, asking: true, track: true, timer: true)).timer, true,
      "not Claude's face: no takeover")

print("The hold")
let up = LiveStrip.Hold(primary: .claude, shown: true, takeover: false, enabled: true)
let down = LiveStrip.Hold(primary: .claude, shown: false, takeover: false, enabled: true)
equal(LiveStrip.hold(previous: nil, live: up), up, "an open settles on the moment")
equal(LiveStrip.hold(previous: down, live: up), down, "a card arriving mid-open doesn't add the strip")
equal(LiveStrip.hold(previous: up, live: down), up, "the last card going keeps the strip's height")
let music = LiveStrip.Hold(primary: .music, shown: true, takeover: false, enabled: true)
equal(LiveStrip.hold(previous: music, live: up), music, "a session starting mid-open doesn't move the face")
let asking = LiveStrip.Hold(primary: .claude, shown: true, takeover: true, enabled: true)
equal(LiveStrip.hold(previous: down, live: asking), asking, "a takeover settles it again")
equal(LiveStrip.hold(previous: asking, live: up), up, "and so does its end")
let off = LiveStrip.Hold(primary: nil, shown: false, takeover: false, enabled: false)
equal(LiveStrip.hold(previous: off, live: up), up, "so does the setting changing")

print("Room")
check(LiveStrip.topGap + 4 >= 16, "an action row's pills keep 16pt above a card", "\(LiveStrip.topGap + 4)")
check(104 + LiveStrip.height <= 188, "a standard face and the strip fit the cap under a 32pt housing",
      "\(104 + LiveStrip.height)")

print("\n\(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
