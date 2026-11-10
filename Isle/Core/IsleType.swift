//
//  IsleType.swift
//
//  The open island's type scale, in one place. Every face draws its text
//  from these few styles rather than picking a size of its own, so a title
//  on the Claude face and a title on the Pomodoro face are the same title,
//  and a meta line reads as a meta line wherever it sits.
//
//    title     17 semibold   the face's headline: Claude's state, the
//                            timer's phase, an empty agenda, the drop
//    lead      15 medium     prose as a face's hero: what Claude said
//                            when its turn ended
//    headline  13 semibold   the second voice: a question, an agenda line,
//                            the track playing
//    body      12 regular    what Claude is doing, an artist, a detail
//    label     12 semibold   what you press: option rows and pills, one
//                            family
//    meta      11 medium     where and when: project · time, session rows,
//                            agent lines. Quieter, at `Tone.meta`.
//    fine      11 regular    prose at meta size: an option's description
//    caption   10 semibold   a tile's name, a chip in a tight row
//    note      10 medium     a tile's second line, a key hint, a file's name
//    micro      9 medium     the scrubber's times, the timeline's hours
//
//  Plus `mono` for commands and `numeral(_:)` for the big digits (the
//  timer's clock, the date card), which are drawn to fit their shapes rather
//  than to the scale.
//
//  All SF Pro: the system face, never a bundled one.
//

import SwiftUI

enum IsleType {
    enum Size {
        static let title: CGFloat = 17
        static let lead: CGFloat = 15
        static let headline: CGFloat = 13
        static let body: CGFloat = 12
        static let meta: CGFloat = 11
        static let caption: CGFloat = 10
        static let micro: CGFloat = 9
    }

    /// The design titles are drawn in. `.default` is SF Pro.
    static let titleDesign: Font.Design = .default

    static var title: Font { .system(size: Size.title, weight: .semibold, design: titleDesign) }
    /// Prose that leads a face: a title's weight would shout a sentence.
    static var lead: Font { .system(size: Size.lead, weight: .medium) }
    static var headline: Font { .system(size: Size.headline, weight: .semibold) }
    static var body: Font { .system(size: Size.body, weight: .regular) }
    static var label: Font { .system(size: Size.body, weight: .semibold) }
    static var meta: Font { .system(size: Size.meta, weight: .medium) }
    /// A meta line's lead: the session's name in a list row, a chip's word.
    static var metaStrong: Font { .system(size: Size.meta, weight: .semibold) }
    /// Prose at meta size, which wraps and truncates as it always did.
    static var fine: Font { .system(size: Size.meta, weight: .regular) }
    static var caption: Font { .system(size: Size.caption, weight: .semibold) }
    static var note: Font { .system(size: Size.caption, weight: .medium) }
    static var micro: Font { .system(size: Size.micro, weight: .medium) }
    static var mono: Font { .system(size: Size.meta, design: .monospaced) }

    /// Big digits: a clock or a date, sized to the shape they sit in.
    static func numeral(_ size: CGFloat) -> Font {
        .system(size: size, weight: .semibold).monospacedDigit()
    }

    /// Letter-spacing for small caps ("MON") and tracked captions.
    static let capsTracking: CGFloat = 1.2

    /// How bright each voice is against the panel, as an `islandSecondary`
    /// opacity. Body text under a title, and the quieter meta lines.
    enum Tone {
        static let secondary: Double = 0.7
        static let meta: Double = 0.5
        /// The oldest of a fading list: a working face's earliest step.
        static let faint: Double = 0.35
        /// `faint` on a glass panel, where the tint behind it takes more of
        /// the contrast (and `islandSecondary` lifts it from there).
        static let faintOnGlass: Double = 0.4
    }
}
