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
