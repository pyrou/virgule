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

    @Test func gridBackgroundFollowsAppearanceInBothDirections() {
        let grid = VirtualizedGridView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
        var backgrounds: [CGColor] = []
        for name in [NSAppearance.Name.aqua, .darkAqua, .aqua, .darkAqua] {
            grid.appearance = NSAppearance(named: name)
            grid.viewDidChangeEffectiveAppearance()
            guard let background = grid.layer?.backgroundColor else {
                Issue.record("Grid background is missing")
                return
            }
            backgrounds.append(background)
        }
        #expect(backgrounds[0] != backgrounds[1])
        #expect(backgrounds[0] == backgrounds[2])
        #expect(backgrounds[1] == backgrounds[3])
    }

    @Test func tableFooterShowsDisplayedQueryRows() {
        #expect(ContentViewController.tableFooterText(
            displayedRowCount: 150,
            sourceRowCount: 300,
            isSearching: false
        ) == "150 rows out of 300 rows")
    }

    @Test func tableFooterShowsSearchMatchesOutOfSourceRows() {
        #expect(ContentViewController.tableFooterText(
            displayedRowCount: 150,
            sourceRowCount: 300,
            isSearching: true
        ) == "150 matching rows out of 300 rows")
    }

    @Test func displayedColumnCountIgnoresPreviewColumnsAfterImport() {
        let previewRows = [["Ada", "Paris", "France"]]

        #expect(ContentViewController.displayedColumnCount(
            cachePathIsAvailable: false,
            columnTitlesCount: 1,
            columnCount: 0,
            previewRows: previewRows
        ) == 3)

        #expect(ContentViewController.displayedColumnCount(
            cachePathIsAvailable: true,
            columnTitlesCount: 1,
            columnCount: 1,
            previewRows: previewRows
        ) == 1)
    }

    @Test func datasetSearchBuildsTextSearchAcrossEveryColumn() {
        let sql = DatasetSearch.filteredSQL(
            baseSQL: "SELECT name, city FROM csv",
            columns: ["name", "city"],
            search: DatasetSearch(text: "O'Brien", column: nil, usesRegularExpression: false)
        )

        #expect(sql.contains("instr(lower(CAST(\"name\" AS TEXT)), lower('O''Brien')) > 0"))
        #expect(sql.contains("instr(lower(CAST(\"city\" AS TEXT)), lower('O''Brien')) > 0"))
    }

    @Test func datasetSearchBuildsRegexForOneColumnAndClearsWithoutChangingQuery() {
        let search = DatasetSearch(text: "^Ada", column: "name", usesRegularExpression: true)
        let sql = DatasetSearch.filteredSQL(baseSQL: "SELECT name FROM csv", columns: ["name"], search: search)

        #expect(sql.contains("virgule_regexp('^Ada', CAST(\"name\" AS TEXT))"))
        #expect(DatasetSearch.filteredSQL(baseSQL: "SELECT name FROM csv", columns: ["name"], search: nil) == "SELECT name FROM csv")
    }

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

    @Test func gridSizesRowNumberGutterForTheLargestRowNumber() {
        let dataSource = GridDataSource(rows: 1_000_000, columns: 1)
        let grid = VirtualizedGridView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        grid.dataSource = dataSource
        grid.layoutSubtreeIfNeeded()

        #expect(grid.rowNumberColumnWidth > 52)
    }

    @Test func gridCopiesMultipleSelectedRowsAsTSV() {
        let dataSource = GridDataSource(rows: 4, columns: 3)
        let grid = VirtualizedGridView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        grid.dataSource = dataSource
        grid.setSelectedRows(IndexSet([1, 3, 8]))
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("virgule-tests-\(UUID().uuidString)"))

        #expect(grid.selectedRows == IndexSet([1, 3]))
        #expect(grid.copySelection(to: pasteboard))
        #expect(pasteboard.string(forType: .string) == "1,0\t1,1\t1,2\n3,0\t3,1\t3,2")
    }

    @Test func gridSelectsContinuousRowsFromRowNumberDrag() {
        let dataSource = GridDataSource(rows: 10, columns: 2)
        let grid = VirtualizedGridView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        grid.dataSource = dataSource
        grid.setSelectedRows(IndexSet(integer: 0))

        grid.selectRowRange(from: 6, through: 3, preservesSelection: false)
        #expect(grid.selectedRows == IndexSet(integersIn: 3..<7))

        grid.selectRowRange(from: 8, through: 9, preservesSelection: true)
        #expect(grid.selectedRows == IndexSet([3, 4, 5, 6, 8, 9]))
    }

    @Test func gridExtendsRowSelectionFromItsShiftClickAnchor() {
        let dataSource = GridDataSource(rows: 10, columns: 2)
        let grid = VirtualizedGridView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        grid.dataSource = dataSource

        // setSelectedRows establishes the same anchor that a first gutter
        // click does; a subsequent Shift-click extends from that row.
        grid.setSelectedRows(IndexSet(integer: 2))
        grid.extendRowSelection(to: 7, preservesSelection: false)

        #expect(grid.selectedRows == IndexSet(integersIn: 2..<8))
    }

    @Test func sqlEditorHighlightsKeywordsAndComments() {
        let sql = "SELECT COUNT(*) FROM csv -- all rows"
        let highlighted = SQLQueryBar.highlightedText(for: sql)
        let selectRange = (sql as NSString).range(of: "SELECT")
        let commentRange = (sql as NSString).range(of: "-- all rows")

        #expect(highlighted.attribute(.foregroundColor, at: selectRange.location, effectiveRange: nil) as? NSColor == .systemPurple)
        #expect(highlighted.attribute(.foregroundColor, at: commentRange.location, effectiveRange: nil) as? NSColor == .secondaryLabelColor)
    }

    @Test func sqlEditorHighlightsFriendlySourceAndRowIdentifiers() {
        let path = "/Users/michael/Downloads/myfile.csv"
        let sql = "SELECT * FROM \(path) ORDER BY $virgule_row_id"
        let highlighted = SQLQueryBar.highlightedText(for: sql, sourcePath: path)
        let pathRange = (sql as NSString).range(of: path)
        let rowIDRange = (sql as NSString).range(of: "$virgule_row_id")

        #expect(highlighted.attribute(.foregroundColor, at: pathRange.location, effectiveRange: nil) as? NSColor == .systemTeal)
        #expect(highlighted.attribute(.foregroundColor, at: rowIDRange.location, effectiveRange: nil) as? NSColor == .tertiaryLabelColor)
    }

    @Test func portableCSVSourceWorksAcrossFilesAndPreservesOtherTokens() {
        let query = "SELECT * FROM file.csv WHERE name = 'file.csv' -- file.csv"
        for path in ["/tmp/first.csv", "/tmp/second.csv"] {
            let presentation = SQLQueryPresentation(sourcePath: path)
            #expect(presentation.engineSQL(for: query) == "SELECT * FROM csv WHERE name = 'file.csv' -- file.csv")
            #expect(presentation.engineSQL(for: "SELECT file.csv.name FROM file.csv") == "SELECT file.csv.name FROM csv")
            #expect(presentation.engineSQL(for: "SELECT * FROM myfile.csv") == "SELECT * FROM myfile.csv")
            #expect(presentation.engineSQL(for: "SELECT * FROM file.csv FORM") == "SELECT * FROM csv FORM")
            #expect(presentation.displayedError("Invalid SQL query at line 1, column 19: syntax error", for: "SELECT * FROM file.csv FORM").contains("line 1, column 24"))
        }
        #expect(SQLQueryPresentation(sourcePath: "").engineSQL(for: "SELECT * FROM file.csv") == "SELECT * FROM csv")
    }

    @Test func sqlPresentationMapsSQLiteLocationsBackToFriendlyQuery() {
        let path = "/Users/michael/Downloads/myfile.csv"
        let presentation = SQLQueryPresentation(sourcePath: path)
        let displayedSQL = "SELECT * FROM \(path) FORM"

        #expect(presentation.engineSQL(for: displayedSQL) == "SELECT * FROM csv FORM")
        let expectedColumn = "SELECT * FROM ".unicodeScalars.count + path.unicodeScalars.count + 2
        let error = presentation.displayedError(
            "Invalid SQL query at line 1, column 19: near \\\"FORM\\\": syntax error",
            for: displayedSQL
        )

        #expect(error.contains("line 1, column \(expectedColumn)"))
    }

    @Test func sqlEditorPrettyPrintsClausesAndConditions() {
        let formatted = SQLQueryBar.prettyPrintedSQL(for: "select name,count(*) from csv where active=1 and score>10 order by name desc")

        #expect(formatted == """
        SELECT name, COUNT(*)
        FROM csv
        WHERE active = 1
        AND score > 10
        ORDER BY name DESC
        """)
    }

    @Test func sqlEditorPrettyPrintIndentsSubqueries() {
        let formatted = SQLQueryBar.prettyPrintedSQL(for: "select * from (select name from csv where active=1) as active_rows")

        #expect(formatted == """
        SELECT *
        FROM (
            SELECT name
            FROM csv
            WHERE active = 1
        ) AS active_rows
        """)
    }

    @Test func sqlEditorPrettyPrintPreservesQuotedValuesAndComments() {
        let formatted = SQLQueryBar.prettyPrintedSQL(for: "select 'from  x', \"order by\" from csv -- retain  spaces\nwhere name='O''Brien'")

        #expect(formatted.contains("'from  x'"))
        #expect(formatted.contains("\"order by\""))
        #expect(formatted.contains("-- retain  spaces"))
        #expect(formatted.contains("name = 'O''Brien'"))
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

    @Test func sqlEditorDisplaysAndClearsValidationErrors() {
        let editor = SQLQueryBar()

        editor.setValidationMessage("Invalid SQL query at line 2, column 6")
        #expect(editor.validationMessage == "Invalid SQL query at line 2, column 6")

        editor.setValidationMessage(nil)
        #expect(editor.validationMessage == nil)
    }

    @Test func sqlEditorCompletesTablesOnlyAfterFrom() {
        let suggestions = SQLQueryBar.completionCandidates(
            for: "SELECT * FROM c",
            cursor: 15,
            columns: ["name", "total cost"]
        )

        #expect(suggestions == ["csv"])
        #expect(SQLQueryBar.completionCandidates(for: "SELECT * FROM f", cursor: 15, columns: []) == ["file.csv"])
    }

    @Test func sqlEditorCompletesKeywordsFunctionsAndQuotedColumns() {
        let suggestions = SQLQueryBar.completionCandidates(
            for: "SELECT co",
            cursor: 9,
            columns: ["company", "total cost"]
        )

        #expect(suggestions.contains("company"))
        #expect(suggestions.contains("COALESCE"))
        #expect(suggestions.contains("COUNT"))

        let quotedColumn = SQLQueryBar.completionCandidates(
            for: "SELECT \"to",
            cursor: 10,
            columns: ["company", "total cost"]
        )
        #expect(quotedColumn.contains("\"total cost\""))

    }

    @Test func sqlEditorProvidesQuickHelpForFunctionsAndOperators() {
        let function = SQLQueryBar.quickHelp(
            for: "SELECT COUNT(*) FROM csv",
            selectedRange: NSRange(location: 8, length: 0)
        )
        let operation = SQLQueryBar.quickHelp(
            for: "SELECT total >= 10 FROM csv",
            selectedRange: NSRange(location: 13, length: 0)
        )

        #expect(function == SQLQuickHelp(title: "COUNT", detail: "COUNT(expression) returns the number of non-NULL values; COUNT(*) counts rows."))
        #expect(operation == SQLQuickHelp(title: ">=", detail: "Greater than or equal to."))
    }

    @Test func sqlEditorKeepsDeDuplicatedExecutionHistory() {
        let editor = SQLQueryBar()
        editor.sql = "SELECT name FROM csv"
        editor.executeQuery()
        editor.sql = "SELECT COUNT(*) FROM csv"
        editor.executeQuery()
        editor.sql = "SELECT name FROM csv"
        editor.executeQuery()

        #expect(editor.queryHistory == ["SELECT name FROM csv", "SELECT COUNT(*) FROM csv"])
        #expect(SQLQueryBar.historyTitle(for: String(repeating: "a", count: 73)).hasSuffix("…"))
    }

    @Test func sqlEditorCopiesQueryAndUsesNativeUndoManager() {
        let editor = SQLQueryBar()
        editor.sql = "SELECT name FROM csv"
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("virgule-tests-\(UUID().uuidString)"))

        #expect(editor.copyQuery(to: pasteboard))
        #expect(pasteboard.string(forType: .string) == "SELECT name FROM csv")

        guard let undoManager = editor.textView.undoManager else {
            Issue.record("The SQL text editor must provide an undo manager")
            return
        }
        undoManager.registerUndo(withTarget: editor.textView) { textView in
            let original = textView.string
            textView.undoManager?.registerUndo(withTarget: textView) { target in target.string = original }
            textView.string = ""
        }
        undoManager.undo()
        #expect(editor.textView.string.isEmpty)
        undoManager.redo()
        #expect(editor.textView.string == "SELECT name FROM csv")
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
