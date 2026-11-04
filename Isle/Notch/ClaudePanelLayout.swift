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
//  The question face is the one that grows, and the panel is sized from these
//  same numbers before it's drawn (`questionContentHeight`, read by
//  `NotchMetrics.questionPanelHeight`). The view sets each row's height from
//  here too, so the two can't disagree.
//

import SwiftUI
import AppKit

@MainActor
enum ClaudePanelLayout {
    // MARK: - Columns

    /// The marker: the album cover's footprint on the music face, raised the
    /// same distance into the housing band (safe there — no hardware left of
    /// the cutout). Top-aligned, so it lands on one spot on every face.
    static let glyphSize: CGFloat = 114
    static let glyphRaise: CGFloat = 15
    static let glyphGap: CGFloat = 14

    /// The text column, fixed so the glyph + column pair centres in the panel
    /// exactly as the music face's album + text pair does.
    static let columnWidth: CGFloat = 340

    /// Kept clear at the column's right edge by rows level with the waveform
    /// pinned at the panel's top-right (the eyebrow and the title).
    static let waveformClearance: CGFloat = 36

    /// Kept clear at the column's right edge by rows that reach the corner
    /// face toggle in Both mode (see `NotchRootView.tabToggle`).
    static let toggleClearance: CGFloat = 44

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
    /// A label-only row, under `.hidden`: two points shorter, so four options
    /// fit under the cap beside a two-line question.
    static let optionRowHeightHidden: CGFloat = 20
    /// Above and below a stacked row's text, under `.full`.
    static let optionStackedPadding: CGFloat = 5
    /// Label → description in a stacked row.
    static let optionStackedGap: CGFloat = 1
    /// The most a description wraps to under `.full` before it's cut off.
    static let fullDescriptionLines = 3
    /// Checkbox and its gap, ahead of a multi-select label.
    static let checkboxWidth: CGFloat = 18

    /// How many lines a description takes under `.full` in a row whose text
    /// is `width` wide; 0 when the row shows none.
    static func descriptionLines(_ option: ClaudeQuestion.Option,
                                 descriptions: OptionDescriptions,
                                 width: CGFloat) -> Int {
        guard descriptions == .full, let text = option.description, !text.isEmpty else { return 0 }
        return min(fullDescriptionLines, lineCount(text, font: optionDescriptionFont, size: optionDescriptionSize,
                                                   line: optionDescriptionLine, width: width))
    }

    static func optionRowHeight(_ option: ClaudeQuestion.Option,
                                descriptions: OptionDescriptions,
                                textWidth: CGFloat) -> CGFloat {
        switch descriptions {
        case .hidden:
            return optionRowHeightHidden
        case .oneLine:
            return optionRowHeight
        case .full:
            let lines = descriptionLines(option, descriptions: descriptions, width: textWidth)
            guard lines > 0 else { return optionRowHeight }
            return optionStackedPadding * 2 + optionLabelLine + optionStackedGap
                + CGFloat(lines) * optionDescriptionLine
        }
    }

    /// The width a row's text has: the column, less the toggle's corner, the
    /// row's own padding, and the checkbox of a multi-select.
    static func optionTextWidth(multiSelect: Bool, trailingClearance: CGFloat) -> CGFloat {
        columnWidth - trailingClearance - optionHorizontalPadding * 2 - (multiSelect ? checkboxWidth : 0)
    }

    static func optionsHeight(_ question: ClaudeQuestion,
                              descriptions: OptionDescriptions,
                              trailingClearance: CGFloat) -> CGFloat {
        let width = optionTextWidth(multiSelect: question.multiSelect, trailingClearance: trailingClearance)
        let rows = question.options.map { optionRowHeight($0, descriptions: descriptions, textWidth: width) }
        return rows.reduce(0, +) + optionGap * CGFloat(max(0, rows.count - 1))
    }

    // MARK: - Question face

    /// One line or two: what the question needs at the column's width,
    /// short of the waveform.
    static func naturalQuestionLines(_ question: ClaudeQuestion) -> Int {
        min(2, lineCount(question.question, font: questionFont, size: questionSize, line: questionLine,
                         width: columnWidth - waveformClearance))
    }

    /// Everything on the question face but the options, for a question of
    /// `questionLines` lines.
    static func questionChromeHeight(questionLines: Int) -> CGFloat {
        eyebrowHeight + eyebrowGap + CGFloat(questionLines) * questionLine + questionGap
            + actionGap + actionHeight + bottomInset
    }

    /// The content height the question face wants for `question`, uncapped.
    static func questionContentHeight(_ question: ClaudeQuestion,
                                      descriptions: OptionDescriptions,
                                      trailingClearance: CGFloat,
                                      questionLines: Int? = nil) -> CGFloat {
        questionChromeHeight(questionLines: questionLines ?? naturalQuestionLines(question))
            + optionsHeight(question, descriptions: descriptions, trailingClearance: trailingClearance)
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
