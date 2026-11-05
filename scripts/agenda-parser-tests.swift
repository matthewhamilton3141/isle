//
//  agenda-parser-tests.swift
//
//  Tests for the agenda's two parsers — the Join link finder and the quick
//  add line — compiled against their sources alone, with no app and no
//  calendar. Run with scripts/test-agenda-parsers.sh.
//
//  The quick add cases are written against the real clock, because
//  NSDataDetector resolves "tomorrow" against it and takes no reference
//  date; expectations are computed from today rather than fixed.
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

// MARK: - Meeting links

func link(_ url: String?, location: String? = nil, notes: String? = nil) -> String? {
    MeetingLink.find(url: url.flatMap(URL.init(string:)), location: location, notes: notes)?.absoluteString
}

print("Meeting links")

let accepted: [(String, String)] = [
    ("Zoom, plain", "https://zoom.us/j/1234567890"),
    ("Zoom, vanity subdomain + pwd", "https://us02web.zoom.us/j/85012345678?pwd=aBcDeFgHiJkLmNoP.1"),
    ("Zoom, company subdomain", "https://acme.zoom.us/j/98765432100"),
    ("Zoom, personal room", "https://acme.zoom.us/my/matthew.h"),
    ("Zoom, webinar", "https://zoom.us/w/91234567890?tk=abc"),
    ("Zoom, web client", "https://app.zoom.us/wc/join/85012345678"),
    ("ZoomGov", "https://acme.zoomgov.com/j/1612345678"),
    ("Google Meet", "https://meet.google.com/abc-defg-hij"),
    ("Google Meet, authuser", "https://meet.google.com/abc-defg-hij?authuser=1&hs=122"),
    ("Google Meet, lookup", "https://meet.google.com/lookup/b2wfcxyz"),
    ("Teams, meetup-join", "https://teams.microsoft.com/l/meetup-join/19%3ameeting_NjM4ZjE5ZTQt%40thread.v2/0?context=%7b%22Tid%22%3a%22abc%22%7d"),
    ("Teams, short meet", "https://teams.microsoft.com/meet/3456789012345?p=AbCdEfGh"),
    ("Teams, personal", "https://teams.live.com/meet/9876543210123?p=xyz"),
    ("FaceTime", "https://facetime.apple.com/join#v=1&p=AbCdEf123&k=GhIjKl"),
    ("Webex, j.php", "https://acme.webex.com/acme/j.php?MTID=m1234567890abcdef"),
    ("Webex, personal room", "https://acme.webex.com/meet/matthew"),
    ("Webex, my subdomain", "https://acme.my.webex.com/meet/pr12345"),
    ("GoTo", "https://meet.goto.com/123456789"),
    ("GoToMeeting", "https://global.gotomeeting.com/join/123456789"),
    ("Whereby", "https://whereby.com/team-standup"),
    ("Jitsi", "https://meet.jit.si/IsleWeeklySync"),
    ("Chime", "https://chime.aws/1234567890"),
    ("http scheme", "http://zoom.us/j/1234567890"),
    ("Upper-case host", "https://ZOOM.US/j/1234567890"),
]
for (name, url) in accepted {
    let found = link(url)
    check(found == url, "accepts \(name)", "got \(found ?? "nil")")
}

let rejected: [(String, String)] = [
    ("look-alike suffix", "https://zoom.us.evil.com/j/1234567890"),
    ("look-alike prefix", "https://evilzoom.us/j/1234567890"),
    ("userinfo trick", "https://zoom.us@evil.com/j/1234567890"),
    ("userinfo on real host", "https://evil.com@zoom.us/j/1234567890"),
    ("Meet look-alike", "https://meet.google.com.evil.io/abc-defg-hij"),
    ("Meet subdomain", "https://evil.meet.google.com/abc-defg-hij"),
    ("Teams look-alike", "https://teams.microsoft.com.phish.net/l/meetup-join/19%3a"),
    ("Teams on other MS host", "https://microsoft.com/l/meetup-join/19%3a"),
    ("FaceTime look-alike", "https://facetime-apple.com/join#v=1"),
    ("Webex look-alike", "https://acme.webex.com.evil.org/meet/matthew"),
    ("Webex lookalike TLD", "https://acme.webex.co/meet/matthew"),
    ("Zoom home page", "https://zoom.us/"),
    ("Zoom pricing page", "https://zoom.us/pricing"),
    ("Meet home page", "https://meet.google.com/"),
    ("Meet bad code", "https://meet.google.com/not-a-meeting-code"),
    ("Webex home page", "https://www.webex.com/"),
    ("Teams home", "https://teams.microsoft.com/"),
    ("javascript scheme", "javascript:alert('zoom.us/j/1')"),
    ("file scheme", "file:///zoom.us/j/1"),
    ("custom port", "https://zoom.us:8443/j/1234567890"),
    ("Zoom via redirector", "https://www.google.com/url?q=https://zoom.us/j/123"),
]
for (name, url) in rejected {
    let found = link(url)
    check(found == nil, "rejects \(name)", "got \(found ?? "nil")")
}

// Where the link is found, and in what order.
check(link(nil, location: "Zoom: https://us02web.zoom.us/j/85012345678?pwd=abc") == "https://us02web.zoom.us/j/85012345678?pwd=abc",
      "finds a link in the location")
check(link(nil, location: "Room 4B", notes: "Join: https://meet.google.com/abc-defg-hij\nOr dial in…") == "https://meet.google.com/abc-defg-hij",
      "falls through a plain location to the notes")
check(link("https://acme.zoom.us/j/111", location: "https://meet.google.com/abc-defg-hij") == "https://acme.zoom.us/j/111",
      "prefers the URL field over the location")
check(link("https://example.com/agenda", location: "https://meet.google.com/abc-defg-hij") == "https://meet.google.com/abc-defg-hij",
      "skips a URL field that isn't a call")
check(link(nil, location: "https://meet.google.com/abc-defg-hij", notes: "https://zoom.us/j/999") == "https://meet.google.com/abc-defg-hij",
      "prefers the location over the notes")
check(link(nil, notes: "Join https://zoom.us/j/123 or https://teams.microsoft.com/meet/456?p=a") == nil,
      "two services in the notes is ambiguous")
check(link(nil, notes: "Room A https://zoom.us/j/111 · Room B https://zoom.us/j/222") == nil,
      "two Zoom rooms is ambiguous")
check(link(nil, location: "https://zoom.us/j/1 https://zoom.us/j/2", notes: "https://meet.google.com/abc-defg-hij") == nil,
      "an ambiguous location doesn't fall through to the notes")
check(link(nil, notes: "Join https://zoom.us/j/123\n\nMeeting link: https://zoom.us/j/123?pwd=xyz") == "https://zoom.us/j/123?pwd=xyz",
      "a repeated link is one meeting, keeping the passcode copy")
check(link(nil, notes: "https://zoom.us.evil.com/j/1 and https://meet.google.com/abc-defg-hij") == "https://meet.google.com/abc-defg-hij",
      "a look-alike in the notes is ignored, the real link kept")
check(link(nil, notes: "Agenda attached. Dial +1 555 0100.") == nil, "plain notes find nothing")
check(link(nil, notes: "We'll zoom through the agenda: https://docs.example.com/zoom") == nil,
      "the word zoom alone is not a link")
check(link(nil, location: "Microsoft Teams Meeting", notes: """
________________________________________________________________________________
Microsoft Teams meeting
Join on your computer, mobile app or room device
Click here to join the meeting<https://teams.microsoft.com/l/meetup-join/19%3ameeting_ZGQ%40thread.v2/0?context=%7b%7d>
Meeting ID: 123 456 789
""") == "https://teams.microsoft.com/l/meetup-join/19%3ameeting_ZGQ%40thread.v2/0?context=%7b%7d",
      "Teams invitation boilerplate")

// MARK: - Quick add

print("\nQuick add")

let cal = Calendar.current
let now = Date()
let today = cal.startOfDay(for: now)
let tomorrow = cal.date(byAdding: .day, value: 1, to: today)!

func at(_ day: Date, _ hour: Int, _ minute: Int = 0) -> Date {
    cal.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
}

/// The next given weekday after today (Friday on a Friday is next week's,
/// as the detector reads it).
func next(_ weekday: Int) -> Date {
    var day = tomorrow
    while cal.component(.weekday, from: day) != weekday { day = cal.date(byAdding: .day, value: 1, to: day)! }
    return day
}

func describe(_ r: Result<QuickAddDraft, QuickAddError>) -> String {
    switch r {
    case .success(let d):
        let f = DateFormatter(); f.dateFormat = "EEE d MMM HH:mm"
        return "\(d.kind) '\(d.title)' \(d.date.map(f.string(from:)) ?? "no date") time=\(d.hasTime) dur=\(Int(d.duration / 60))m"
    case .failure(let e): return "error \(e)"
    }
}

func expect(_ phrase: String, _ kind: QuickAddDraft.Kind, _ title: String, date: Date?, hasTime: Bool, minutes: Int? = nil) {
    let r = QuickAddParser.parse(phrase, now: now)
    guard case .success(let d) = r else {
        check(false, "“\(phrase)”", describe(r)); return
    }
    var ok = d.kind == kind && d.title == title && d.hasTime == hasTime
    if let date { ok = ok && d.date.map { abs($0.timeIntervalSince(date)) < 61 } == true } else { ok = ok && d.date == nil }
    if let minutes { ok = ok && Int(d.duration / 60) == minutes }
    check(ok, "“\(phrase)” → \(describe(r))", "")
}

func expectError(_ phrase: String, _ error: QuickAddError) {
    let r = QuickAddParser.parse(phrase, now: now)
    check(r == .failure(error), "“\(phrase)” → \(describe(r))", "(wanted \(error))")
}

expect("Lunch with Sam tomorrow 1pm", .event, "Lunch with Sam", date: at(tomorrow, 13), hasTime: true, minutes: 60)
expect("Call mom in 30 min", .event, "Call mom", date: now.addingTimeInterval(30 * 60), hasTime: true)
expect("Dentist Friday 3:30", .event, "Dentist", date: at(next(6), 15, 30), hasTime: true)
expect("remind me to buy milk tomorrow", .reminder, "Buy milk", date: tomorrow, hasTime: false)
expect("Remind me to call the bank tomorrow 9am", .reminder, "Call the bank", date: at(tomorrow, 9), hasTime: true)
expect("Buy milk", .reminder, "Buy milk", date: nil, hasTime: false)
expect("Meeting 1-2pm tomorrow", .event, "Meeting", date: at(tomorrow, 13), hasTime: true, minutes: 60)
expect("Coffee at 10:30 tomorrow", .event, "Coffee", date: at(tomorrow, 10, 30), hasTime: true)
expect("Dentist Friday", .reminder, "Dentist", date: next(6), hasTime: false)
expect("Lunch tomorrow", .reminder, "Lunch", date: tomorrow, hasTime: false)
expect("Gym Monday morning", .reminder, "Gym", date: next(2), hasTime: false)
expect("Zoom with Ana tomorrow at 9 for 45 minutes", .event, "Zoom with Ana", date: at(tomorrow, 9), hasTime: true, minutes: 45)
expect("Review in an hour", .event, "Review", date: now.addingTimeInterval(3600), hasTime: true)
expect("Stretch in half an hour", .event, "Stretch", date: now.addingTimeInterval(1800), hasTime: true)
expect("Read 1984 tomorrow", .reminder, "Read 1984", date: tomorrow, hasTime: false)
expect("Pick up dry cleaning tomorrow at noon", .event, "Pick up dry cleaning", date: at(tomorrow, 12), hasTime: true)
expect("Lunch 1pm tomorrow", .event, "Lunch", date: at(tomorrow, 13), hasTime: true)
expect("Planning session tomorrow 2pm for 2 hours", .event, "Planning session", date: at(tomorrow, 14), hasTime: true, minutes: 120)

// Dates whose year or week depends on today: kind, title and a date only.
func expectLoose(_ phrase: String, _ kind: QuickAddDraft.Kind, _ title: String) {
    let r = QuickAddParser.parse(phrase, now: now)
    if case .success(let d) = r, d.kind == kind, d.title == title, d.date != nil {
        check(true, "“\(phrase)” → \(describe(r))")
    } else {
        check(false, "“\(phrase)”", describe(r))
    }
}
expectLoose("Party next Saturday 8pm", .event, "Party")
expectLoose("Doctor 15 Nov", .reminder, "Doctor")

expectError("", .empty)
expectError("   ", .empty)
expectError("Standup at 9", .ambiguousHour("9"))
expectError("call mom at 3", .ambiguousHour("3"))
expectError("tomorrow 3pm", .noTitle)
expectError("remind me tomorrow", .noTitle)
expectError("Lunch 1pm Friday or Saturday 2pm", .twoDates)
expectError("Call in 20 min tomorrow 5pm", .twoDates)
expectError("Pay rent on the 1st", .unreadableDate)
// The detector reads a bare time as today's; earlier than now is past. Only
// checkable when the test runs late enough in the day.
if cal.component(.hour, from: now) >= 1 {
    expectError("Wake up 12:01am", .inThePast)
}

print("\n\(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
