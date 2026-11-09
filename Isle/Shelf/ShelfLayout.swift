//
//  ShelfLayout.swift
//
//  The shelf face's numbers, and the height it asks the panel for. Pure, so
//  the face, the view model and a render all reach the same answers.
//
//  The face is the album's square on the left — the stack and, level with
//  the buttons, the count — and on the right a column of five cells a row
//  over the action row. Up to five items are one row of large cells under a
//  line that says what a click does; six to ten are two rows of smaller
//  ones, every one of them in view. Each cell is a thumbnail over a name of
//  up to two lines, and every cell is the same height whatever its name, so
//  the panel's height depends on the rows and nothing else: it moves when
//  the shelf goes from five to six and back, and never for an item that
//  comes or goes within a row.
//

import CoreGraphics

enum ShelfLayout {
    /// The most cells in a row, and the most items one row takes.
    static let columns = 5

    /// The right-hand column, and one cell of it: five across with a gap of
    /// `cellGap`, edge to edge.
    static let columnWidth: CGFloat = 340
    static let cellWidth: CGFloat = 64
    static let cellGap: CGFloat = 5

    /// The square on the left: the album's footprint, so the panel keeps its
    /// weight where it was switching faces.
    static let stackSide: CGFloat = 114

    /// Lifted into the housing band, as the album is. Safe: the square is
    /// left of the camera cutout, on ordinary screen. The album is centred
    /// in the 104pt content area and raised 11, which lands its top 16 above
    /// the content's; this face is pinned to the top, so it's raised the 16.
    static let stackRaise: CGFloat = 16

    /// One fanned thumbnail in the square.
    static let fanSide: CGFloat = 60

    /// The size thumbnails are made at: the largest place one is drawn — the
    /// fan, just over a large cell — so every smaller place scales one down
    /// rather than asking QuickLook again.
    static let thumbnailSide: CGFloat = 64

    /// The column's cells run under the camera cutout, whose hardware edge
    /// is a point below the band the safe area reports. Their hard edges —
    /// thumbnails, icons, a selection's outline — keep this much clear of
    /// the band; the content area already starts 2pt below it.
    static let cutoutClearance: CGFloat = 4

    /// The line over a single row.
    static let headlineHeight: CGFloat = 14
    static let headlineGap: CGFloat = 3

    /// The buttons, and the count level with them: one height, one baseline.
    static let barHeight: CGFloat = 24
    static let barBottom: CGFloat = 2

    /// The least room between the cells and the buttons.
    static let barGap: CGFloat = 6

    /// The two sizes of cell.
    struct Cell {
        /// The thumbnail's square, or the icon's.
        var side: CGFloat
        /// Inside the cell's lit square, all round.
        var padding: CGFloat
        /// Between the thumbnail and the name.
        var spacing: CGFloat
        var nameSize: CGFloat
        /// Two lines of the name, whether it takes them or not: exactly two
        /// lines as SwiftUI sets them (11pt a line at 9pt, 13 at 10). Any
        /// less and a long name quietly gives up its second line.
        var nameHeight: CGFloat

        var height: CGFloat { padding + side + spacing + nameHeight + padding }
    }

    /// One row: room for the file to be seen.
    static let large = Cell(side: 56, padding: 3, spacing: 3, nameSize: 10, nameHeight: 26)

    /// Two rows.
    static let small = Cell(side: 44, padding: 2, spacing: 2, nameSize: 9, nameHeight: 22)

    static let rowGap: CGFloat = 4

    /// Rows for this many items: one up to five, two past that.
    static func rows(for count: Int) -> Int {
        count > columns ? 2 : 1
    }

    static func cell(rows: Int) -> Cell {
        rows > 1 ? small : large
    }

    /// What the face asks the panel for (see
    /// `NotchViewModel.faceContentHeight`). One row is 144, the agenda's
    /// height, so swiping between the two doesn't move the panel; two rows
    /// are 184, inside the shared cap with the bar's gap to spare.
    static func contentHeight(rows: Int) -> CGFloat {
        let cell = cell(rows: rows)
        let heading = rows > 1 ? 0 : headlineHeight + headlineGap
        let grid = cell.height * CGFloat(rows) + rowGap * CGFloat(rows - 1)
        return cutoutClearance + heading + grid + barGap + barHeight + barBottom
    }
}
