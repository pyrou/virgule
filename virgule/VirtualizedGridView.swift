import AppKit

/// Supplies the values that are currently available to the grid. The data
/// source is deliberately index-based: callers can back it with a paginated
/// SQLite result without materializing every row in AppKit.
protocol VirtualizedGridDataSource: AnyObject {
    func numberOfRows(in grid: VirtualizedGridView) -> Int
    func numberOfColumns(in grid: VirtualizedGridView) -> Int
    /// Returns the user-facing, stable identifier for a result row. This is
    /// intentionally separate from its current viewport index so a future
    /// filtered or paginated result can retain source row numbers.
    func grid(_ grid: VirtualizedGridView, rowNumberForRow row: Int) -> Int
    func grid(_ grid: VirtualizedGridView, valueForRow row: Int, column: Int) -> String
    func grid(_ grid: VirtualizedGridView, titleForColumn column: Int) -> String
}

extension VirtualizedGridDataSource {
    func grid(_ grid: VirtualizedGridView, rowNumberForRow row: Int) -> Int {
        row + 1
    }

    func grid(_ grid: VirtualizedGridView, titleForColumn column: Int) -> String {
        "Column \(column + 1)"
    }
}

/// A scrollable AppKit grid which creates row and cell views only for the
/// current viewport. Its header stays above the scrolling document while
/// virtualizing its visible column labels independently of row cells.
final class VirtualizedGridView: NSView {
    weak var dataSource: VirtualizedGridDataSource? {
        didSet { reloadData() }
    }

    private let scrollView = NSScrollView()
    private let documentView = VirtualizedGridDocumentView()
    private let headerClipView = NSClipView()
    private let headerDocumentView = VirtualizedGridHeaderDocumentView()
    private let rowNumberClipView = NSClipView()
    private let rowNumberDocumentView = VirtualizedGridRowNumberDocumentView()
    private let rowNumberHeaderView = VirtualizedGridRowNumberHeaderView()
    private let columnLayout = VirtualizedGridColumnLayout()
    private var boundsObserver: NSObjectProtocol?

    /// Useful for UI tests and diagnostics: this count is bounded by the
    /// viewport, rather than by the number of rows in the result.
    var visibleRowViewCount: Int { documentView.visibleRowViewCount }
    var visibleCellViewCount: Int { documentView.visibleCellViewCount }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureViews()
        reloadData()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureViews()
    }

    private func configureViews() {
        headerClipView.drawsBackground = false
        headerClipView.documentView = headerDocumentView
        headerDocumentView.grid = self
        headerDocumentView.columnLayout = columnLayout
        headerDocumentView.resizeColumn = { [weak self] column, width in
            self?.setWidth(width, forColumn: column)
        }

        rowNumberClipView.drawsBackground = false
        rowNumberClipView.documentView = rowNumberDocumentView
        rowNumberDocumentView.grid = self

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .lineBorder
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.documentView = documentView
        documentView.grid = self
        documentView.columnLayout = columnLayout

        addSubview(headerClipView)
        addSubview(rowNumberHeaderView)
        addSubview(rowNumberClipView)
        addSubview(scrollView)
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            self?.refreshVisibleViews()
        }
    }

    deinit {
        if let boundsObserver {
            NotificationCenter.default.removeObserver(boundsObserver)
        }
    }

    override func layout() {
        super.layout()
        rowNumberHeaderView.frame = NSRect(x: 0, y: 0, width: Self.rowNumberWidth, height: Self.headerHeight)
        rowNumberClipView.frame = NSRect(
            x: 0,
            y: Self.headerHeight,
            width: Self.rowNumberWidth,
            height: max(0, bounds.height - Self.headerHeight)
        )
        headerClipView.frame = NSRect(
            x: Self.rowNumberWidth,
            y: 0,
            width: max(0, bounds.width - Self.rowNumberWidth),
            height: Self.headerHeight
        )
        scrollView.frame = NSRect(
            x: Self.rowNumberWidth,
            y: Self.headerHeight,
            width: max(0, bounds.width - Self.rowNumberWidth),
            height: max(0, bounds.height - Self.headerHeight)
        )
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

    fileprivate func rowNumber(forRow row: Int) -> Int {
        dataSource?.grid(self, rowNumberForRow: row) ?? row + 1
    }

    fileprivate func title(forColumn column: Int) -> String {
        dataSource?.grid(self, titleForColumn: column) ?? ""
    }

    private func refreshVisibleViews() {
        documentView.refreshVisibleViews()
        headerClipView.scroll(to: NSPoint(x: scrollView.contentView.bounds.minX, y: 0))
        headerDocumentView.refreshVisibleViews()
        rowNumberClipView.scroll(to: NSPoint(x: 0, y: scrollView.contentView.bounds.minY))
        rowNumberDocumentView.refreshVisibleViews()
    }

    private func updateDocumentMetrics() {
        let rows = max(0, dataSource?.numberOfRows(in: self) ?? 0)
        let columns = max(0, dataSource?.numberOfColumns(in: self) ?? 0)
        columnLayout.updateColumnCount(columns)
        documentView.updateMetrics(
            rowCount: rows,
            columnCount: columns,
            viewportWidth: scrollView.contentView.bounds.width
        )
        rowNumberDocumentView.updateMetrics(
            rowCount: rows,
            width: rowNumberClipView.bounds.width,
            height: documentView.bounds.height
        )
        headerDocumentView.updateMetrics(columnCount: columns, width: documentView.bounds.width)
        refreshVisibleViews()
    }

    private func setWidth(_ width: CGFloat, forColumn column: Int) {
        guard columnLayout.setWidth(width, forColumn: column) else { return }
        updateDocumentMetrics()
    }

    private static let headerHeight: CGFloat = 24
    private static let rowNumberWidth: CGFloat = 56
}

/// Shared geometry for the document and the pinned header. Keeping this in one
/// place means a resized column has exactly the same bounds in both views.
private final class VirtualizedGridColumnLayout {
    private static let defaultWidth: CGFloat = 160
    private static let minimumWidth: CGFloat = 60
    private var widths: [CGFloat] = []
    private var offsets: [CGFloat] = [0]

    var totalWidth: CGFloat { offsets.last ?? 0 }

    func updateColumnCount(_ count: Int) {
        if widths.count < count {
            widths.append(contentsOf: repeatElement(Self.defaultWidth, count: count - widths.count))
        } else if widths.count > count {
            widths.removeLast(widths.count - count)
        }
        rebuildOffsets()
    }

    func width(forColumn column: Int) -> CGFloat {
        widths.indices.contains(column) ? widths[column] : Self.defaultWidth
    }

    func xOffset(forColumn column: Int) -> CGFloat {
        guard column > 0 else { return 0 }
        return offsets[min(column, widths.count)]
    }

    func setWidth(_ width: CGFloat, forColumn column: Int) -> Bool {
        guard widths.indices.contains(column) else { return false }
        let clampedWidth = max(Self.minimumWidth, width)
        guard widths[column] != clampedWidth else { return false }
        widths[column] = clampedWidth
        rebuildOffsets()
        return true
    }

    func visibleColumnRange(in rect: NSRect) -> Range<Int> {
        guard !widths.isEmpty, rect.width > 0 else { return 0 ..< 0 }
        let first = column(at: max(0, rect.minX))
        let last = column(at: max(0, rect.maxX - 1))
        return first ..< min(widths.count, last + 1)
    }

    private func column(at x: CGFloat) -> Int {
        var low = 0
        var high = widths.count
        while low < high {
            let middle = (low + high) / 2
            if offsets[middle + 1] <= x {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return min(low, max(0, widths.count - 1))
    }

    private func rebuildOffsets() {
        offsets = [0]
        offsets.reserveCapacity(widths.count + 1)
        for width in widths {
            offsets.append((offsets.last ?? 0) + width)
        }
    }
}

private final class VirtualizedGridDocumentView: NSView {
    private static let rowHeight: CGFloat = 24

    private var rowCount = 0
    private var columnCount = 0
    private var activeRows: [Int: VirtualizedGridRowView] = [:]
    private var recycledRows: [VirtualizedGridRowView] = []

    weak var grid: VirtualizedGridView? {
        didSet { refreshVisibleViews() }
    }
    var columnLayout: VirtualizedGridColumnLayout? {
        didSet { refreshVisibleViews() }
    }

    var visibleRowViewCount: Int { activeRows.count }
    var visibleCellViewCount: Int { activeRows.values.reduce(0) { $0 + $1.visibleCellViewCount } }

    override var isFlipped: Bool { true }

    func updateMetrics(rowCount: Int, columnCount: Int, viewportWidth: CGFloat) {
        self.rowCount = rowCount
        self.columnCount = columnCount
        let contentWidth = max(viewportWidth, columnLayout?.totalWidth ?? 0)
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
                columnLayout: columnLayout,
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
        guard columnCount > 0 else { return 0 ..< 0 }
        return columnLayout?.visibleColumnRange(in: visibleRect) ?? (0 ..< 0)
    }
}

/// The row-number gutter is a separate document view so it stays pinned while
/// the data columns scroll horizontally. It mirrors the body's vertical
/// viewport and virtualizes labels with the same geometry as data rows.
private final class VirtualizedGridRowNumberDocumentView: NSView {
    private static let rowHeight: CGFloat = 24

    private var rowCount = 0
    private var activeLabels: [Int: VirtualizedGridRowNumberView] = [:]
    private var recycledLabels: [VirtualizedGridRowNumberView] = []

    weak var grid: VirtualizedGridView? {
        didSet { refreshVisibleViews() }
    }

    override var isFlipped: Bool { true }

    func updateMetrics(rowCount: Int, width: CGFloat, height: CGFloat) {
        self.rowCount = rowCount
        frame = NSRect(x: 0, y: 0, width: width, height: height)
        refreshVisibleViews()
    }

    func refreshVisibleViews() {
        let visibleRows = visibleRowRange()
        let requiredRows = Set(visibleRows)

        for row in activeLabels.keys.filter({ !requiredRows.contains($0) }) {
            guard let label = activeLabels.removeValue(forKey: row) else { continue }
            label.removeFromSuperview()
            recycledLabels.append(label)
        }

        for row in visibleRows {
            let label: VirtualizedGridRowNumberView
            if let existing = activeLabels[row] {
                label = existing
            } else if let recycled = recycledLabels.popLast() {
                label = recycled
                activeLabels[row] = label
                addSubview(label)
            } else {
                label = VirtualizedGridRowNumberView()
                activeLabels[row] = label
                addSubview(label)
            }

            label.frame = NSRect(x: 0, y: CGFloat(row) * Self.rowHeight, width: bounds.width, height: Self.rowHeight)
            label.stringValue = String(grid?.rowNumber(forRow: row) ?? (row + 1))
        }
    }

    private func visibleRowRange() -> Range<Int> {
        guard rowCount > 0, visibleRect.height > 0 else { return 0 ..< 0 }
        let lower = max(0, Int(floor(visibleRect.minY / Self.rowHeight)))
        let upper = min(rowCount, Int(ceil(visibleRect.maxY / Self.rowHeight)))
        return lower ..< max(lower, upper)
    }
}

private final class VirtualizedGridRowNumberHeaderView: NSTextField {
    init() {
        super.init(frame: .zero)
        stringValue = "#"
        isEditable = false
        isSelectable = false
        isBordered = false
        alignment = .right
        drawsBackground = true
        backgroundColor = .controlBackgroundColor
        font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
        wantsLayer = true
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class VirtualizedGridRowNumberView: NSTextField {
    init() {
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBordered = false
        alignment = .right
        textColor = .secondaryLabelColor
        drawsBackground = false
        font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        wantsLayer = true
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class VirtualizedGridHeaderDocumentView: NSView {
    private static let headerHeight: CGFloat = 24

    private var columnCount = 0
    private var activeCells: [Int: VirtualizedGridHeaderCellView] = [:]
    private var recycledCells: [VirtualizedGridHeaderCellView] = []

    weak var grid: VirtualizedGridView? {
        didSet { refreshVisibleViews() }
    }
    var columnLayout: VirtualizedGridColumnLayout? {
        didSet { refreshVisibleViews() }
    }
    var resizeColumn: ((Int, CGFloat) -> Void)?

    override var isFlipped: Bool { true }

    func updateMetrics(columnCount: Int, width: CGFloat) {
        self.columnCount = columnCount
        frame = NSRect(x: 0, y: 0, width: width, height: Self.headerHeight)
        refreshVisibleViews()
    }

    func refreshVisibleViews() {
        let visibleColumns = visibleColumnRange()
        let requiredColumns = Set(visibleColumns)

        for column in activeCells.keys.filter({ !requiredColumns.contains($0) }) {
            guard let cell = activeCells.removeValue(forKey: column) else { continue }
            cell.removeFromSuperview()
            recycledCells.append(cell)
        }

        for column in visibleColumns {
            let cell: VirtualizedGridHeaderCellView
            if let existing = activeCells[column] {
                cell = existing
            } else if let recycled = recycledCells.popLast() {
                cell = recycled
                activeCells[column] = cell
                addSubview(cell)
            } else {
                cell = VirtualizedGridHeaderCellView()
                activeCells[column] = cell
                addSubview(cell)
            }

            cell.frame = NSRect(
                x: columnLayout?.xOffset(forColumn: column) ?? 0,
                y: 0,
                width: columnLayout?.width(forColumn: column) ?? 0,
                height: bounds.height
            )
            cell.stringValue = grid?.title(forColumn: column) ?? ""
            cell.column = column
            cell.resizeColumn = resizeColumn
        }
    }

    private func visibleColumnRange() -> Range<Int> {
        guard columnCount > 0 else { return 0 ..< 0 }
        return columnLayout?.visibleColumnRange(in: visibleRect) ?? (0 ..< 0)
    }
}

private final class VirtualizedGridHeaderCellView: NSTextField {
    private static let resizeHandleWidth: CGFloat = 8
    var column = 0
    var resizeColumn: ((Int, CGFloat) -> Void)?

    init() {
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = true
        backgroundColor = .controlBackgroundColor
        font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
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

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(
            NSRect(x: bounds.maxX - Self.resizeHandleWidth, y: 0, width: Self.resizeHandleWidth, height: bounds.height),
            cursor: .resizeLeftRight
        )
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard point.x >= bounds.maxX - Self.resizeHandleWidth else {
            super.mouseDown(with: event)
            return
        }

        let initialWidth = bounds.width
        let initialX = event.locationInWindow.x
        var tracking = true
        while tracking, let nextEvent = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            switch nextEvent.type {
            case .leftMouseDragged:
                resizeColumn?(column, initialWidth + nextEvent.locationInWindow.x - initialX)
            case .leftMouseUp:
                tracking = false
            default:
                break
            }
        }
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
        columnLayout: VirtualizedGridColumnLayout?,
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
            cell.frame = NSRect(
                x: columnLayout?.xOffset(forColumn: column) ?? 0,
                y: 0,
                width: columnLayout?.width(forColumn: column) ?? 0,
                height: bounds.height
            )
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
