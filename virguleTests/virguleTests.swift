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

    @Test func gridVirtualizesOneMillionRowsWhileScrolling() {
        let dataSource = GridDataSource(rows: 1_000_000, columns: 24)
        let grid = VirtualizedGridView(frame: NSRect(x: 0, y: 0, width: 1_280, height: 720))
        grid.dataSource = dataSource
        grid.layoutSubtreeIfNeeded()

        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for row in stride(from: 0, through: 999_999, by: 25_000) {
                grid.scrollToRow(row)
            }
        }

        // The grid may retain only the current viewport. This deliberately
        // stays independent of the one-million-row model size.
        #expect(grid.visibleRowViewCount > 0)
        #expect(grid.visibleRowViewCount < 100)
        #expect(grid.visibleCellViewCount > 0)
        #expect(grid.visibleCellViewCount < 1_000)
        #expect(elapsed < .seconds(1))
    }

    @Test func sqlEditorHighlightsKeywordsAndComments() {
        let sql = "SELECT COUNT(*) FROM csv -- all rows"
        let highlighted = SQLQueryBar.highlightedText(for: sql)
        let selectRange = (sql as NSString).range(of: "SELECT")
        let commentRange = (sql as NSString).range(of: "-- all rows")

        #expect(highlighted.attribute(.foregroundColor, at: selectRange.location, effectiveRange: nil) as? NSColor == .systemPurple)
        #expect(highlighted.attribute(.foregroundColor, at: commentRange.location, effectiveRange: nil) as? NSColor == .secondaryLabelColor)
    }

    @Test func sqlEditorExecutesItsCompleteMultilineQuery() {
        let editor = SQLQueryBar()
        let query = """
        SELECT name
        FROM csv
        WHERE active = 1
        """
        var executedQuery: String?
        editor.sql = query
        editor.onExecute = { executedQuery = $0 }

        editor.executeQuery()

        #expect(executedQuery == query)
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
