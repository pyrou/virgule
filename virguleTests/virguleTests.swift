//
//  virguleTests.swift
//  virguleTests
//
//  Created by michael on 03/09/2026.
//

import AppKit
import Testing
@testable import virgule

@MainActor
struct virguleTests {

    @Test func gridOnlyCreatesViewsForVisibleRowsAndColumns() {
        let dataSource = GridDataSource(rows: 1_000, columns: 100)
        let grid = VirtualizedGridView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        grid.dataSource = dataSource
        grid.layoutSubtreeIfNeeded()

        let totalCells = dataSource.rows * dataSource.columns
        #expect(grid.visibleRowViewCount > 0)
        #expect(grid.visibleRowViewCount < dataSource.rows)
        #expect(grid.visibleCellViewCount > 0)
        #expect(grid.visibleCellViewCount < totalCells)

        grid.scrollToRow(700)

        #expect(grid.visibleRowViewCount < dataSource.rows)
        #expect(grid.visibleCellViewCount < totalCells)
    }

    @Test func sqlEditorHighlightsKeywordsAndComments() {
        let sql = "SELECT COUNT(*) FROM csv -- all rows"
        let highlighted = SQLQueryBar.highlightedText(for: sql)
        let selectRange = (sql as NSString).range(of: "SELECT")
        let commentRange = (sql as NSString).range(of: "-- all rows")

        #expect(highlighted.attribute(.foregroundColor, at: selectRange.location, effectiveRange: nil) as? NSColor == .systemPurple)
        #expect(highlighted.attribute(.foregroundColor, at: commentRange.location, effectiveRange: nil) as? NSColor == .secondaryLabelColor)
    }
}

private final class GridDataSource: VirtualizedGridDataSource {
    let rows: Int
    let columns: Int

    init(rows: Int, columns: Int) {
        self.rows = rows
        self.columns = columns
    }

    func numberOfRows(in grid: VirtualizedGridView) -> Int { rows }
    func numberOfColumns(in grid: VirtualizedGridView) -> Int { columns }
    func grid(_ grid: VirtualizedGridView, valueForRow row: Int, column: Int) -> String { "\(row),\(column)" }
}
