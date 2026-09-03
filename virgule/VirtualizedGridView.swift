import AppKit

/// Supplies the values that are currently available to the grid. The data
/// source is deliberately index-based: callers can back it with a paginated
/// SQLite result without materializing every row in AppKit.
protocol VirtualizedGridDataSource: AnyObject {
    func numberOfRows(in grid: VirtualizedGridView) -> Int
    func numberOfColumns(in grid: VirtualizedGridView) -> Int
    func grid(_ grid: VirtualizedGridView, valueForRow row: Int, column: Int) -> String
}

/// A scrollable AppKit grid which creates row and cell views only for the
/// current viewport. Headers, sizing controls, and page loading are kept out
/// of this view so they can be layered on without changing its virtualization
/// contract.
final class VirtualizedGridView: NSView {
    weak var dataSource: VirtualizedGridDataSource? {
        didSet { reloadData() }
    }

    private let scrollView = NSScrollView()
    private let documentView = VirtualizedGridDocumentView()
    private var boundsObserver: NSObjectProtocol?

    /// Useful for UI tests and diagnostics: this count is bounded by the
    /// viewport, rather than by the number of rows in the result.
    var visibleRowViewCount: Int { documentView.visibleRowViewCount }
    var visibleCellViewCount: Int { documentView.visibleCellViewCount }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .lineBorder
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.documentView = documentView
        documentView.grid = self

        addSubview(scrollView)
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            self?.documentView.refreshVisibleViews()
        }
        reloadData()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .lineBorder
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.documentView = documentView
        documentView.grid = self

        addSubview(scrollView)
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            self?.documentView.refreshVisibleViews()
        }
    }

    deinit {
        if let boundsObserver {
            NotificationCenter.default.removeObserver(boundsObserver)
        }
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        updateDocumentMetrics()
    }

    /// Re-reads row and column counts, discarding active views that no longer
    /// have a corresponding model row. Call after changing a query result.
    func reloadData() {
        updateDocumentMetrics()
    }

    fileprivate func value(forRow row: Int, column: Int) -> String {
        dataSource?.grid(self, valueForRow: row, column: column) ?? ""
    }

    private func updateDocumentMetrics() {
        let rows = max(0, dataSource?.numberOfRows(in: self) ?? 0)
        let columns = max(0, dataSource?.numberOfColumns(in: self) ?? 0)
        documentView.updateMetrics(
            rowCount: rows,
            columnCount: columns,
            viewportWidth: scrollView.contentView.bounds.width
        )
    }
}

private final class VirtualizedGridDocumentView: NSView {
    private static let rowHeight: CGFloat = 24
    private static let columnWidth: CGFloat = 160

    private var rowCount = 0
    private var columnCount = 0
    private var activeRows: [Int: VirtualizedGridRowView] = [:]
    private var recycledRows: [VirtualizedGridRowView] = []

    weak var grid: VirtualizedGridView? {
        didSet { refreshVisibleViews() }
    }

    var visibleRowViewCount: Int { activeRows.count }
    var visibleCellViewCount: Int { activeRows.values.reduce(0) { $0 + $1.visibleCellViewCount } }

    override var isFlipped: Bool { true }

    func updateMetrics(rowCount: Int, columnCount: Int, viewportWidth: CGFloat) {
        self.rowCount = rowCount
        self.columnCount = columnCount
        let contentWidth = max(viewportWidth, CGFloat(columnCount) * Self.columnWidth)
        frame = NSRect(
            x: 0,
            y: 0,
            width: contentWidth,
            height: CGFloat(rowCount) * Self.rowHeight
        )
        refreshVisibleViews()
    }

    func refreshVisibleViews() {
        let visibleRows = visibleRowRange()
        let visibleColumns = visibleColumnRange()
        let requiredRows = Set(visibleRows)

        let rowsToRecycle = activeRows.keys.filter { !requiredRows.contains($0) }
        for row in rowsToRecycle {
            guard let rowView = activeRows.removeValue(forKey: row) else { continue }
            rowView.removeFromSuperview()
            rowView.recycle()
            recycledRows.append(rowView)
        }

        for row in visibleRows {
            let rowView: VirtualizedGridRowView
            if let existing = activeRows[row] {
                rowView = existing
            } else if let recycled = recycledRows.popLast() {
                rowView = recycled
                activeRows[row] = rowView
                addSubview(rowView)
            } else {
                rowView = VirtualizedGridRowView()
                activeRows[row] = rowView
                addSubview(rowView)
            }

            rowView.frame = NSRect(
                x: 0,
                y: CGFloat(row) * Self.rowHeight,
                width: bounds.width,
                height: Self.rowHeight
            )
            rowView.configure(
                row: row,
                columns: visibleColumns,
                columnWidth: Self.columnWidth,
                value: { [weak self] row, column in
                    self?.grid?.value(forRow: row, column: column) ?? ""
                }
            )
        }
    }

    private func visibleRowRange() -> Range<Int> {
        guard rowCount > 0, visibleRect.height > 0 else { return 0 ..< 0 }
        let lower = max(0, Int(floor(visibleRect.minY / Self.rowHeight)))
        let upper = min(rowCount, Int(ceil(visibleRect.maxY / Self.rowHeight)))
        return lower ..< max(lower, upper)
    }

    private func visibleColumnRange() -> Range<Int> {
        guard columnCount > 0, visibleRect.width > 0 else { return 0 ..< 0 }
        let lower = max(0, Int(floor(visibleRect.minX / Self.columnWidth)))
        let upper = min(columnCount, Int(ceil(visibleRect.maxX / Self.columnWidth)))
        return lower ..< max(lower, upper)
    }
}

private final class VirtualizedGridRowView: NSView {
    private var activeCells: [Int: VirtualizedGridCellView] = [:]
    private var recycledCells: [VirtualizedGridCellView] = []

    override var isFlipped: Bool { true }

    var visibleCellViewCount: Int { activeCells.count }

    func configure(
        row: Int,
        columns: Range<Int>,
        columnWidth: CGFloat,
        value: (Int, Int) -> String
    ) {
        let requiredColumns = Set(columns)
        let columnsToRecycle = activeCells.keys.filter { !requiredColumns.contains($0) }
        for column in columnsToRecycle {
            guard let cell = activeCells.removeValue(forKey: column) else { continue }
            cell.removeFromSuperview()
            recycledCells.append(cell)
        }

        for column in columns {
            let cell: VirtualizedGridCellView
            if let existing = activeCells[column] {
                cell = existing
            } else if let recycled = recycledCells.popLast() {
                cell = recycled
                activeCells[column] = cell
                addSubview(cell)
            } else {
                cell = VirtualizedGridCellView()
                activeCells[column] = cell
                addSubview(cell)
            }
            cell.frame = NSRect(x: CGFloat(column) * columnWidth, y: 0, width: columnWidth, height: bounds.height)
            cell.stringValue = value(row, column)
        }
    }

    func recycle() {
        for cell in activeCells.values {
            cell.removeFromSuperview()
            recycledCells.append(cell)
        }
        activeCells.removeAll(keepingCapacity: true)
    }
}

private final class VirtualizedGridCellView: NSTextField {
    init() {
        super.init(frame: .zero)
        isEditable = false
        isSelectable = true
        drawsBackground = false
        isBordered = false
        font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        lineBreakMode = .byTruncatingTail
        cell?.lineBreakMode = .byTruncatingTail
        wantsLayer = true
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.cgColor
        translatesAutoresizingMaskIntoConstraints = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
