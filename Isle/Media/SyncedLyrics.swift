//
//  SyncedLyrics.swift
//
//  A track's lyrics as timed lines, parsed from LRC — the format LRCLIB
//  hands back in `syncedLyrics`:
//
//      [00:17.12] I feel your breath upon my neck
//      [00:21.40] A soft caress as cold as death
//      [03:25.72]
//
//  Each line holds from its own timestamp until the next one. A timestamp with
//  no words is a gap marker: it ends the line before it (a break, the outro)
//  and shows nothing.
//
//  Only ever built from lyrics that carry timestamps. Plain lyrics have no
//  timing to back a line up with, and pacing them across the track by guesswork
//  would put words on screen that aren't being sung — so there is no init for
//  them, and a file with no timed line parses to nil.
//
//  Foundation only, so it can be compiled on its own against a test harness.
//

import Foundation

struct SyncedLyrics: Equatable {
    struct Line: Equatable {
        /// Seconds from the start of the track at which the line begins.
        let time: TimeInterval
        /// Empty for a gap marker.
        let text: String
    }

    /// Sorted by time. Never empty, and at least one line has words.
    let lines: [Line]

    /// Parses LRC. Nil when nothing in it is both timed and worded — plain
    /// lyrics, an empty string, or a file of nothing but gap markers.
    init?(lrc: String) {
        var parsed: [Line] = []
        var offset: TimeInterval = 0

        for raw in lrc.components(separatedBy: .newlines) {
            var rest = Substring(raw).drop(while: \.isWhitespace)
            var stamps: [TimeInterval] = []

            // Every leading `[…]` is a tag: a timestamp (one line can carry
            // several, for a repeated chorus), or metadata like `[ar:Queen]`.
            while rest.first == "[", let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex)..<close]
                if let time = Self.timestamp(tag) {
                    stamps.append(time)
                } else if let shift = Self.offset(tag) {
                    offset = shift
                }
                rest = rest[rest.index(after: close)...].drop(while: \.isWhitespace)
            }

            guard !stamps.isEmpty else { continue }
            let text = Self.stripWordTimings(String(rest))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            for time in stamps {
                parsed.append(Line(time: time, text: text))
            }
        }

        // `[offset:+500]` means the lyrics run half a second early: positive
        // shows every line sooner. Applied after the loop so a tag placed
        // anywhere in the header counts.
        if offset != 0 {
            parsed = parsed.map { Line(time: max(0, $0.time - offset), text: $0.text) }
        }

        guard parsed.contains(where: { !$0.text.isEmpty }) else { return nil }

        // Stable, so two lines sharing a timestamp keep file order and the
        // later one wins — the same thing a reader of the file would assume.
        lines = parsed.enumerated()
            .sorted { $0.element.time != $1.element.time
                ? $0.element.time < $1.element.time
                : $0.offset < $1.offset }
            .map(\.element)
    }

    /// Index of the line in effect at `position`, or nil before the first one.
    /// A gap marker counts — it is in effect, it just has no words.
    func index(at position: TimeInterval) -> Int? {
        // Last line whose time is at or before `position`.
        var low = 0
        var high = lines.count
        while low < high {
            let mid = (low + high) / 2
            if lines[mid].time <= position {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low == 0 ? nil : low - 1
    }

    /// Words to show at `position`: nil before the first line and in a gap.
    func text(at position: TimeInterval) -> String? {
        guard let index = index(at: position) else { return nil }
        let text = lines[index].text
        return text.isEmpty ? nil : text
    }

    /// When the line in effect next changes, strictly after `position`. Nil
    /// once the last line has begun — it holds to the end of the track.
    func nextChange(after position: TimeInterval) -> TimeInterval? {
        // `index(at:)` is the *last* line at or before `position`, so the one
        // after it is already strictly later — lines sharing a stamp included.
        let next = index(at: position).map { $0 + 1 } ?? 0
        return next < lines.count ? lines[next].time : nil
    }

    // MARK: - Tags

    /// `mm:ss`, `mm:ss.xx` or `mm:ss.xxx` (a colon before the fraction is
    /// accepted too; some editors write one). The fraction is a decimal
    /// fraction of a second whatever its length, so `.5`, `.50` and `.500`
    /// all mean half a second.
    private static func timestamp(_ tag: Substring) -> TimeInterval? {
        let parts = tag.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              let minutes = Int(parts[0].trimmingCharacters(in: .whitespaces)),
              minutes >= 0 else { return nil }

        let rest = parts[1].trimmingCharacters(in: .whitespaces)
        let secondsAndFraction = rest.split(
            omittingEmptySubsequences: false,
            whereSeparator: { $0 == "." || $0 == ":" }
        )
        guard (1...2).contains(secondsAndFraction.count),
              let seconds = Int(secondsAndFraction[0]),
              (0..<60).contains(seconds),
              secondsAndFraction[0].count <= 2 else { return nil }

        var fraction: TimeInterval = 0
        if secondsAndFraction.count == 2 {
            let digits = secondsAndFraction[1]
            guard !digits.isEmpty, digits.count <= 3,
                  digits.allSatisfy(\.isASCII), let value = Int(digits) else { return nil }
            fraction = TimeInterval(value) / pow(10, TimeInterval(digits.count))
        }
        return TimeInterval(minutes * 60 + seconds) + fraction
    }

    /// `offset:+500` / `offset:-250`, in milliseconds, as seconds.
    private static func offset(_ tag: Substring) -> TimeInterval? {
        let parts = tag.split(separator: ":", maxSplits: 1)
        guard parts.count == 2,
              parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "offset" else { return nil }
        var value = parts[1].trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("+") { value.removeFirst() }
        guard let millis = Int(value) else { return nil }
        return TimeInterval(millis) / 1000
    }

    /// Enhanced LRC times individual words as `<mm:ss.xx>` inside the line.
    /// Isle shows the line whole, so the word stamps are dropped.
    private static func stripWordTimings(_ text: String) -> String {
        guard text.contains("<") else { return text }
        return text
            .replacingOccurrences(
                of: #"<\d{1,3}:\d{1,2}(?:[.:]\d{1,3})?>"#,
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
    }
}
