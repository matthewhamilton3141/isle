//
//  ClaudePanelLayout.swift
//
//  The Claude face's one layout, as numbers. Every face — a status, an
//  approval, a question — is the same four regions in the same column:
//
//    eyebrow   where it is and what else is going on: the project and how
//              long ago, or the question's header and step; on the right,
//              the other live sessions and the keep-awake mark.
//    title     the state as a headline, or the question itself.
//    body      what Claude is doing, the exact command to approve, or the
//              options to pick from.
//    actions   one row of pills pinned to the bottom: Approve / Deny /
//              Terminal, Answer in terminal / Next. Held empty on a status
//              face, where it is the room reserved for Milestones 11 (jump
//              to the session, leading) and 12 (the usage row, trailing).
//
//  The eyebrow and title sit at the same height on every face, so moving
//  between states cross-fades text in place rather than shuffling rows; the
//  action row is pinned to the bottom, so the buttons don't move with the
//  length of what's above them.
//
//  The question face is the one that grows, and the one that rearranges: the
//  glyph leaves, and the eyebrow, the question and the options take the
//  face's whole width. The panel is sized from these same numbers before it's drawn
//  (`questionContentHeight`, read by `NotchMetrics.panelHeight`), and
//  the view lays the rows out from the same `OptionsFit`, so the two can't
//  disagree.
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

    /// The marker: the album cover's footprint on the music face, raised the
    /// same distance into the housing band (safe there — no hardware left of
    /// the cutout). Top-aligned, so it lands on one spot on every face, and
    /// its top-left corner stays put when the question face shrinks it.
    static let glyphSize: CGFloat = 114
    static let glyphRaise: CGFloat = 15
    static let glyphGap: CGFloat = 14

    /// The text column, fixed so the glyph + column pair centres in the panel
    /// exactly as the music face's album + text pair does.
    static let columnWidth: CGFloat = 340

    /// The glyph and the column together: the whole face. The question face
    /// spends all of it on the options.
    static let faceWidth = glyphSize + glyphGap + columnWidth

    /// Kept clear at the column's right edge by rows level with the waveform
    /// pinned at the panel's top-right (the eyebrow and the title).
    static let waveformClearance: CGFloat = 36

    // MARK: - Rows

    static let eyebrowHeight: CGFloat = 14
    /// Eyebrow → title.
    static let eyebrowGap: CGFloat = 4
    /// Headline → detail on a status face.
    static let headlineGap: CGFloat = 2
    /// Question → options.
    static let questionGap: CGFloat = 6
    /// The least room above the action row. On the standard panel a status
    /// face has far more; an approval has about this much.
    static let actionGap: CGFloat = 6
    static let actionHeight: CGFloat = 22
    /// Under the action row, on top of the panel's own bottom inset.
    static let bottomInset: CGFloat = 4

    // MARK: - Type

    static let eyebrowSize: CGFloat = 10.5
    static let headlineSize: CGFloat = 20
    static let questionSize: CGFloat = 13
    static let detailSize: CGFloat = 12
    static let commandSize: CGFloat = 11
    static let optionLabelSize: CGFloat = 12
    static let optionDescriptionSize: CGFloat = 11
    static let pillSize: CGFloat = 11.5

    static var eyebrowFont: Font { .system(size: eyebrowSize, weight: .semibold) }
    static var headlineFont: Font { .system(size: headlineSize, weight: .bold) }
    static var questionFont: Font { .system(size: questionSize, weight: .semibold) }
    static var detailFont: Font { .system(size: detailSize, weight: .regular) }
    static var commandFont: Font { .system(size: commandSize, design: .monospaced) }
    static var optionLabelFont: Font { .system(size: optionLabelSize, weight: .semibold) }
    static var optionDescriptionFont: Font { .system(size: optionDescriptionSize, weight: .regular) }
    static var pillFont: Font { .system(size: pillSize, weight: .semibold) }

    // MARK: - Line heights

    /// Measured by laying the fonts out in SwiftUI itself, once, so a row
    /// framed to `n * line` holds exactly `n` lines. Not derived from
    /// `NSFont` metrics: SwiftUI rounds each line to whole points by a rule
    /// of its own (11pt is 14, 20pt bold is 24), and a frame a point short
    /// silently drops the last line.
    static let headlineLine = lineHeight(headlineFont)
    static let questionLine = lineHeight(questionFont)
    static let detailLine = lineHeight(detailFont)
    static let commandLine = lineHeight(commandFont)
    static let optionLabelLine = lineHeight(optionLabelFont)
    static let optionDescriptionLine = lineHeight(optionDescriptionFont)

    private static func lineHeight(_ font: Font) -> CGFloat {
        textHeight("Wg", font: font, width: nil)
    }

    /// The approval's command: two lines, so the buttons below never move
    /// with its length.
    static let commandLines = 2

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

    /// One line or two: what the question needs across the face, short of
    /// the waveform.
    static func naturalQuestionLines(_ question: ClaudeQuestion) -> Int {
        min(2, lineCount(question.question, font: questionFont, size: questionSize, line: questionLine,
                         width: faceWidth - waveformClearance))
    }

    /// Everything on the question face but the options, for a question of
    /// `questionLines` lines.
    static func questionChromeHeight(questionLines: Int) -> CGFloat {
        eyebrowHeight + eyebrowGap + CGFloat(questionLines) * questionLine + questionGap
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
