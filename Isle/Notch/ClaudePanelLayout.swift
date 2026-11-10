//
//  ClaudePanelLayout.swift
//
//  The Claude face's one layout, as numbers. Every face — a status, an
//  approval, a question — is the same regions in the same column:
//
//    wings     the housing band either side of the camera. Left: the
//              marker and the state in its colour, or the question's
//              header and step. Right: the other live sessions, ahead of
//              the crumb. Nothing within `wingClearance` of the cutout.
//    hero      right under the housing: the exact command to approve (on a
//              card), what Claude said when its turn ended, what it's doing,
//              or the question itself.
//    meta      one quiet line: the project, how long ago, the agents, the
//              keep-awake cup, a guard's chip; and at most one line more
//              for a block, what the turn left running, or the agents.
//    actions   one row of pills at the face's foot: Approve / Deny /
//              Terminal, Answer in terminal / Next, or the terminal and the
//              reply field.
//
//  The wings and the hero sit at the same height on every face, so moving
//  between states cross-fades text in place rather than shuffling rows; the
//  action row sits at the foot of the face, so it's where the pointer left
//  it whatever the body above holds.
//
//  A turn in progress swaps the meta and the action row for rows of its own
//  (`workSlots` of them: the agents running, a block, a reply on its way,
//  the calls it has finished) and puts the terminal at the meta line's end.
//  With no row yet it's the short panel; with one, all the slots are held,
//  so a row arriving never moves the panel.
//
//  The question face is the one that grows: the question and its options
//  run the face's width, and the panel is sized from these same numbers
//  before it's drawn (`questionContentHeight`, read by
//  `NotchMetrics.panelHeight`); the view lays the rows out from the same
//  `OptionsFit`, so the two can't disagree.
//
//  Every option is always in view. `AskUserQuestion` sends at most four, and
//  when the panel's cap can't hold them as the description setting draws
//  them, the descriptions give way — shorter, then beside the label, then
//  gone — never the options themselves (see `fit`).
//

import SwiftUI
import AppKit

@MainActor
enum ClaudePanelLayout {
    // MARK: - Columns

    /// The face: one column, the width the music face's album and text
    /// take together, centred in the panel. Every face — status, approval,
    /// question, the session list — spends all of it, so the wings and
    /// the hero sit at one place whichever is up.
    static let faceWidth: CGFloat = 468

    // MARK: - Wings

    /// The housing band either side of the camera: as tall as the cutout,
    /// ordinary screen to its left and right. The face puts what it's about
    /// there — its status and where it is on the left, the other sessions on
    /// the right, ahead of the crumb — so the body starts right under the
    /// housing. Nothing is drawn within `wingClearance` of the cutout.
    static let wingClearance: CGFloat = 12
    /// On a screen with no notch there's no cutout to clear: the wings are
    /// one top row, split by this much air.
    static let wingGutter: CGFloat = 24
    /// Between a wing's content and the crumb (or the gear) at its end.
    static let crumbGap: CGFloat = 10
    /// A control in a wing — the sessions chip — and a tag in the body.
    static let chipHeight: CGFloat = 20

    struct Wings: Equatable {
        /// The left wing's width, from the face's leading edge.
        var left: CGFloat
        /// The right wing's width, ending `trailing` short of the face's
        /// trailing edge.
        var right: CGFloat
        /// Held for the crumb or the gear, which `NotchRootView` draws at
        /// the face's trailing edge.
        var trailing: CGFloat
        var band: CGFloat
    }

    /// The wings for a housing `notch` wide and `band` tall, or for a screen
    /// with none. `crumb` is the width of what sits at the right wing's end.
    static func wings(notch: CGFloat, band: CGFloat, physical: Bool, crumb: CGFloat) -> Wings {
        let gap = physical ? notch + wingClearance * 2 : wingGutter
        let side = max(0, (faceWidth - gap) / 2)
        let trailing = crumb > 0 ? crumb + crumbGap : 0
        return Wings(left: side, right: max(0, side - trailing), trailing: trailing, band: band)
    }

    /// How far the crumb (`⊞ › Claude`) reaches in from the face's trailing
    /// edge, or the gear on an island with no Home. Measured from the views
    /// themselves, once.
    static func crumbWidth(showsHome: Bool) -> CGFloat {
        if let cached = crumbWidthCache[showsHome] { return cached }
        let width: CGFloat
        if showsHome {
            width = ceil(NSHostingView(rootView: NotchCrumb(face: .claude, attention: false, goHome: {})).fittingSize.width)
        } else {
            // The gear's 22pt target, centred 5pt further out than the
            // crumb's end (see `NotchRootView`).
            width = 22 - 5
        }
        crumbWidthCache[showsHome] = width
        return width
    }

    private static var crumbWidthCache: [Bool: CGFloat] = [:]

    // MARK: - Rows

    /// The meta line under the hero: project · time · agents, and a
    /// guard chip's 17pt.
    static let metaHeight: CGFloat = 18
    /// Hero → meta line on a status or approval face.
    static let heroGap: CGFloat = 4
    /// Question → options.
    static let questionGap: CGFloat = 6
    /// The least room above the question face's action row.
    static let actionGap: CGFloat = 6
    /// The least room between a status or approval face's body and its
    /// action row, which sits at the face's foot.
    static let bodyGap: CGFloat = 10
    static let actionHeight: CGFloat = 22

    /// Under the action row, on top of the panel's own bottom inset.
    static let bottomInset: CGFloat = 4

    // MARK: - Type
    //
    // From the island's one scale (`IsleType`): what Claude is doing is a
    // title, what it said the lead, the state in the wing and the question
    // headlines, the command mono, every meta line meta, options and pills
    // labels.

    static let questionSize: CGFloat = IsleType.Size.headline
    static let optionDescriptionSize: CGFloat = IsleType.Size.meta
    /// A shortcut's keys on a button (`ShortcutHints`).
    static let keyHintSize: CGFloat = IsleType.Size.caption
    /// Kept clear for a key over a stacked option's top corner, at the
    /// least — what ⌥1 takes, so the default keys' rows are as they were.
    static let keyHintClearance: CGFloat = 26
    /// The widest key a stacked option row carries over its corner: three
    /// modifiers and a word ("⌃⌥⇧Space", 60pt) fit. A longer chord
    /// ("⌃⌥⇧⌘Space") would take a fifth of the label; the row drops it
    /// instead, and the key still works.
    static let keyHintMaxWidth: CGFloat = 64
    /// Between a stacked option's label and the key over its corner.
    static let keyHintGap: CGFloat = 10

    static var metaFont: Font { IsleType.meta }
    /// The state in the left wing, and a question's header.
    static var statusFont: Font { IsleType.headline }
    static var headlineFont: Font { IsleType.title }
    /// What Claude said, as the hero of the faces after a turn.
    static var saidFont: Font { IsleType.lead }
    static var questionFont: Font { IsleType.headline }
    static var detailFont: Font { IsleType.body }
    static var commandFont: Font { IsleType.mono }
    static var optionLabelFont: Font { IsleType.label }
    static var optionDescriptionFont: Font { IsleType.fine }
    static var pillFont: Font { IsleType.label }
    static var keyHintFont: Font { IsleType.note }

    /// The marker, in the left wing before the state: the collapsed
    /// island's marker at the collapsed island's size (`CollapsedSize.dots`),
    /// so opening the island grows the pill's mark and word into the wing.
    static let glyphSize: CGFloat = 16
    static let glyphGap: CGFloat = 7

    /// The working face's rows under the headline (agents, a block, a reply
    /// on its way, the finished calls): this many slots, held whole once
    /// there's one row, so a row arriving moves nothing.
    static let workSlots = 3
    /// The turn's prompt keeps the oldest slot once steps arrive, rather
    /// than giving it up to them as they fill the slots: the steps read as
    /// what Claude is doing about it, and a long turn doesn't lose what it
    /// was for.
    static let promptRowStays = true
    /// The most of the slots replies queued mid-turn take, the rest counted
    /// on the last.
    static let queuedRows = 2
    /// The reply field grows to this many lines, then scrolls.
    static let replyMaxLines = 4
    static let workRowHeight: CGFloat = 15
    /// The most of the slots the agents take, the rest counted on the last.
    static let agentRows = 2
    /// A row's symbol, in a slot of its own.
    static let rowSymbolWidth: CGFloat = 12

    /// The approval's command card.
    static let cardPadding = CGSize(width: 10, height: 6)
    static let cardRadius: CGFloat = 9

    // MARK: - Line heights

    /// Measured by laying the fonts out in SwiftUI itself, once, so a row
    /// framed to `n * line` holds exactly `n` lines. Not derived from
    /// `NSFont` metrics: SwiftUI rounds each line to whole points by a rule
    /// of its own (11pt is 14, 20pt bold is 24), and a frame a point short
    /// silently drops the last line.
    static let headlineLine = lineHeight(headlineFont)
    static let saidLine = lineHeight(saidFont)
    static let questionLine = lineHeight(questionFont)
    static let detailLine = lineHeight(detailFont)
    static let commandLine = lineHeight(commandFont)
    static let optionLabelLine = lineHeight(optionLabelFont)
    static let optionDescriptionLine = lineHeight(optionDescriptionFont)

    private static func lineHeight(_ font: Font) -> CGFloat {
        textHeight("Wg", font: font, width: nil)
    }

    /// The most lines the approval's command takes.
    static let commandLines = 2

    /// What Claude said last, on a status face (Milestone 15): two lines at
    /// most, which the status face's standard panel seats above its row.
    static let saidLines = 2

    // MARK: - Session list (Milestone 16)

    /// One line a session: its marker, project, state, what it's doing, how
    /// long since it moved, and its Jump. Five fit the standard panel under
    /// a 32pt housing, the list's back and count up in the wings; more
    /// scroll.
    static let sessionRowHeight: CGFloat = 20
    static let sessionRowGap: CGFloat = 1
    static let sessionGlyphSize: CGFloat = 12
    static let sessionRowPadding: CGFloat = 6
    /// Under the last row. Less than the action row's `bottomInset`: there's
    /// no pill here to sit clear of the panel's rounded foot, and the two
    /// points are what seat the fourth row.
    static let sessionListBottomInset: CGFloat = 2
    /// The Jump chip at a row's end, and the room held for it on a row
    /// without one, so the times stay in one column.
    static let sessionJumpWidth: CGFloat = 24
    /// A background session's own name (Milestone 21) — a sentence, often,
    /// like "Redesign grid system and modernize app chrome" — gets more of
    /// the row than a project folder, since its detail is short.
    static let sessionNameMaxWidth: CGFloat = 170

    static var sessionProjectFont: Font { IsleType.metaStrong }
    static var sessionStateFont: Font { IsleType.metaStrong }
    static var sessionDetailFont: Font { IsleType.meta }

    /// The rows' height, for `count` of them.
    static func sessionRowsHeight(_ count: Int) -> CGFloat {
        CGFloat(count) * sessionRowHeight + CGFloat(max(0, count - 1)) * sessionRowGap
    }

    // MARK: - Options

    static let optionGap: CGFloat = 3
    static let optionHorizontalPadding: CGFloat = 8
    /// A row with a single line of text: the label, or label and description
    /// side by side.
    static let optionRowHeight: CGFloat = 22
    /// A label-only row, under `.hidden`: two points shorter, the densest
    /// form a row takes.
    static let optionRowHeightHidden: CGFloat = 20
    /// Above and below a stacked row's text, under `.full`.
    static let optionStackedPadding: CGFloat = 5
    /// Label → description in a stacked row.
    static let optionStackedGap: CGFloat = 1
    /// The most a description wraps to under `.full` before it's cut off.
    static let fullDescriptionLines = 3
    /// Checkbox and its gap, ahead of a multi-select label.
    static let checkboxWidth: CGFloat = 18

    /// The height of one row drawn in `style`, with its description wrapped
    /// to `descriptionLines` lines when the style is `.full`.
    static func optionRowHeight(style: OptionDescriptions, descriptionLines: Int) -> CGFloat {
        switch style {
        case .hidden:
            return optionRowHeightHidden
        case .oneLine:
            return optionRowHeight
        case .full:
            guard descriptionLines > 0 else { return optionRowHeight }
            return optionStackedPadding * 2 + optionLabelLine + optionStackedGap
                + CGFloat(descriptionLines) * optionDescriptionLine
        }
    }

    /// The width a row's text has: the face, less the toggle's corner, the
    /// row's own padding, and the checkbox of a multi-select.
    static func optionTextWidth(multiSelect: Bool, trailingClearance: CGFloat) -> CGFloat {
        faceWidth - trailingClearance - optionHorizontalPadding * 2 - (multiSelect ? checkboxWidth : 0)
    }

    /// How many lines a description wraps to under `.full`, up to the most a
    /// row shows; 0 for an option without one.
    private static func naturalDescriptionLines(_ option: ClaudeQuestion.Option, width: CGFloat) -> Int {
        guard let text = option.description, !text.isEmpty else { return 0 }
        return min(fullDescriptionLines, lineCount(text, font: optionDescriptionFont, size: optionDescriptionSize,
                                                   line: optionDescriptionLine, width: width))
    }

    // MARK: - Question face

    /// One line or two: what the question needs across the face.
    static func naturalQuestionLines(_ question: ClaudeQuestion) -> Int {
        min(2, lineCount(question.question, font: questionFont, size: questionSize, line: questionLine,
                         width: faceWidth))
    }

    /// Everything on the question face but the options, for a question of
    /// `questionLines` lines.
    static func questionChromeHeight(questionLines: Int) -> CGFloat {
        CGFloat(questionLines) * questionLine + questionGap
            + actionGap + actionHeight + bottomInset
    }

    /// How one question is drawn in the room it has: the question's lines,
    /// the row form, and each description's lines. Computed once for the
    /// panel's height (with no limit) and again by the face in the room the
    /// capped panel gives it.
    struct OptionsFit: Equatable {
        var questionLines: Int
        /// The form the rows are drawn in: the setting's, or a denser one
        /// when the setting's doesn't fit.
        var style: OptionDescriptions
        /// Per option, the lines its description wraps to under `.full`.
        var descriptionLines: [Int]
        var optionsHeight: CGFloat
        /// The whole face: the options and everything around them.
        var contentHeight: CGFloat
        /// Even label-only rows under a one-line question don't fit, so the
        /// options scroll. Out of reach while `AskUserQuestion` caps a
        /// question at four options (five label-only rows fit at the cap);
        /// kept so a schema change degrades to a scroll rather than a clip.
        var scrolls = false
    }

    /// The fullest drawing of `question` that fits in `room`, giving way in
    /// order of what matters least:
    ///
    /// 1. under `.full`, the longest description loses a line (from the
    ///    bottom of the list on a tie, since Claude leads with the option it
    ///    recommends), until every description is down to one;
    /// 2. the descriptions move beside their labels, as under `.oneLine`;
    /// 3. the descriptions go, as under `.hidden`;
    /// 4. the question gives up its second line.
    ///
    /// The setting is where this starts, never something it exceeds: `.hidden`
    /// starts at 3. Four options fit at step 2 under a two-line question below
    /// a 32pt housing, and at step 3 below any.
    static func fit(_ question: ClaudeQuestion,
                    descriptions: OptionDescriptions,
                    trailingClearance: CGFloat,
                    room: CGFloat = .infinity) -> OptionsFit {
        let width = optionTextWidth(multiSelect: question.multiSelect, trailingClearance: trailingClearance)
        let natural = question.options.map { naturalDescriptionLines($0, width: width) }

        func layout(_ style: OptionDescriptions, _ lines: [Int], questionLines: Int) -> OptionsFit {
            let rows = lines.map { optionRowHeight(style: style, descriptionLines: style == .full ? $0 : 0) }
            let height = rows.reduce(0, +) + optionGap * CGFloat(max(0, rows.count - 1))
            return OptionsFit(questionLines: questionLines, style: style, descriptionLines: lines,
                              optionsHeight: height,
                              contentHeight: questionChromeHeight(questionLines: questionLines) + height)
        }

        var last: OptionsFit?
        for questionLines in Set([naturalQuestionLines(question), 1]).sorted(by: >) {
            var tries: [OptionsFit] = []
            if descriptions == .full {
                var lines = natural
                tries.append(layout(.full, lines, questionLines: questionLines))
                while let longest = lines.indices.reversed().max(by: { lines[$0] < lines[$1] }),
                      lines[longest] > 1 {
                    lines[longest] -= 1
                    tries.append(layout(.full, lines, questionLines: questionLines))
                }
            }
            if descriptions != .hidden {
                tries.append(layout(.oneLine, natural, questionLines: questionLines))
            }
            tries.append(layout(.hidden, natural, questionLines: questionLines))

            if let fits = tries.first(where: { $0.contentHeight <= room + 0.5 }) { return fits }
            last = tries.last
        }
        var scrolling = last!
        scrolling.scrolls = true
        return scrolling
    }

    /// The content height the question face wants for `question` in a panel
    /// whose content can be at most `room` tall — the height of the fullest
    /// drawing that fits, so a face whose descriptions had to give way doesn't
    /// keep the room they'd have taken.
    static func questionContentHeight(_ question: ClaudeQuestion,
                                      descriptions: OptionDescriptions,
                                      trailingClearance: CGFloat,
                                      room: CGFloat) -> CGFloat {
        fit(question, descriptions: descriptions, trailingClearance: trailingClearance, room: room).contentHeight
    }

    // MARK: - Measuring

    /// Line counts already measured. Read on every layout of the root view
    /// while a question is live (the panel's height comes from them), and
    /// the inputs come from one request's handful of strings.
    private static var lineCache: [String: Int] = [:]

    /// How many lines `text` wraps to at `width`, as SwiftUI wraps it — the
    /// same layout engine the row is drawn by, so the count and the drawing
    /// can't disagree about where a line breaks.
    private static func lineCount(_ text: String, font: Font, size: CGFloat, line: CGFloat, width: CGFloat) -> Int {
        let key = "\(size)|\(width)|\(text)"
        if let cached = lineCache[key] { return cached }
        let height = textHeight(text, font: font, width: width)
        let count = max(1, Int((height / line).rounded()))
        if lineCache.count > 256 { lineCache.removeAll() }
        lineCache[key] = count
        return count
    }

    /// How wide a key hint draws — measured by SwiftUI, like the lines.
    static func keyHintWidth(_ key: String) -> CGFloat {
        if let cached = keyWidthCache[key] { return cached }
        let width = ceil(NSHostingView(rootView: Text(key).font(keyHintFont).fixedSize()).fittingSize.width)
        if keyWidthCache.count > 64 { keyWidthCache.removeAll() }
        keyWidthCache[key] = width
        return width
    }

    /// What a stacked option's label keeps clear for `key` over its corner:
    /// the key's own width and a gap, never less than the default keys
    /// take. Nil when the key is too long for an option row to carry.
    static func keyHintClearance(for key: String) -> CGFloat? {
        let width = keyHintWidth(key)
        guard width <= keyHintMaxWidth else { return nil }
        return max(keyHintClearance, width + keyHintGap)
    }

    private static var keyWidthCache: [String: CGFloat] = [:]

    /// The height SwiftUI lays `text` out at, unwrapped or wrapped to `width`.
    private static func textHeight(_ text: String, font: Font, width: CGFloat?) -> CGFloat {
        let host = NSHostingView(rootView:
            Text(text)
                .font(font)
                .frame(width: width)
                .fixedSize(horizontal: width == nil, vertical: true)
        )
        return host.fittingSize.height
    }
}
