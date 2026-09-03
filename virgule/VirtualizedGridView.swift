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
    /// Announces the rows currently needed to render the viewport. Data
    /// sources must return immediately from value lookup and can load these
    /// rows asynchronously from a paginated backing store.
    func grid(_ grid: VirtualizedGridView, willDisplayRows rows: Range<Int>)
}

extension VirtualizedGridDataSource {
    func grid(_ grid: VirtualizedGridView, rowNumberForRow row: Int) -> Int {
        row + 1
    }

    func grid(_ grid: VirtualizedGridView, titleForColumn column: Int) -> String {
        "Column \(column + 1)"
    }

    func grid(_ grid: VirtualizedGridView, willDisplayRows rows: Range<Int>) {}
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
    private let headerMaterialView = NSVisualEffectView()
    private let headerFadeView = VirtualizedGridHeaderFadeView()
    private var boundsObserver: NSObjectProtocol?

    /// Useful for UI tests and diagnostics: this count is bounded by the
    /// viewport, rather than by the number of rows in the result.
    var visibleRowViewCount: Int { documentView.visibleRowViewCount }
    var visibleCellViewCount: Int { documentView.visibleCellViewCount }

    override var isFlipped: Bool { true }

    /// Scrolls the document to a model row. Kept internal for deterministic
    /// AppKit verification that scrolling does not create off-screen views.
    func scrollToRow(_ row: Int) {
        let y = max(0, Self.headerHeight + CGFloat(row) * VirtualizedGridDocumentView.rowHeight)
        scrollView.contentView.scroll(to: NSPoint(x: scrollView.contentView.bounds.minX, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        refreshVisibleViews()
    }

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
        wantsLayer = true
        layer?.backgroundColor = FinderGridPalette.background.cgColor

        headerMaterialView.material = .headerView
        headerMaterialView.blendingMode = .withinWindow
        headerMaterialView.state = .active

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
        scrollView.borderType = .noBorder
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.documentView = documentView
        documentView.grid = self
        documentView.columnLayout = columnLayout

        addSubview(rowNumberClipView)
        addSubview(scrollView)
        addSubview(headerMaterialView)
        addSubview(rowNumberHeaderView)
        addSubview(headerClipView)
        addSubview(headerFadeView)
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
        headerMaterialView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: Self.headerHeight)
        rowNumberHeaderView.frame = NSRect(x: 0, y: 0, width: Self.rowNumberWidth, height: Self.headerHeight)
        rowNumberClipView.frame = NSRect(
            x: 0,
            y: 0,
            width: Self.rowNumberWidth,
            height: bounds.height
        )
        headerClipView.frame = NSRect(
            x: Self.rowNumberWidth,
            y: 0,
            width: max(0, bounds.width - Self.rowNumberWidth),
            height: Self.headerHeight
        )
        headerFadeView.frame = NSRect(
            x: 0,
            y: Self.headerHeight - Self.headerFadeHeight,
            width: bounds.width,
            height: Self.headerFadeHeight
        )
        scrollView.frame = NSRect(
            x: Self.rowNumberWidth,
            y: 0,
            width: max(0, bounds.width - Self.rowNumberWidth),
            height: bounds.height
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

    private static let headerHeight: CGFloat = 30
    private static let headerFadeHeight: CGFloat = 1
    private static let rowNumberWidth: CGFloat = 52
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
    static let rowHeight: CGFloat = 28
    static let headerInset: CGFloat = 30

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
            height: Self.headerInset + CGFloat(rowCount) * Self.rowHeight
        )
        refreshVisibleViews()
    }

    func refreshVisibleViews() {
        let visibleRows = visibleRowRange()
        let visibleColumns = visibleColumnRange()
        if let grid {
            grid.dataSource?.grid(grid, willDisplayRows: visibleRows)
        }
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
                y: Self.headerInset + CGFloat(row) * Self.rowHeight,
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
        let lower = max(0, Int(floor((visibleRect.minY - Self.headerInset) / Self.rowHeight)))
        let upper = min(rowCount, Int(ceil((visibleRect.maxY - Self.headerInset) / Self.rowHeight)))
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
    private static let rowHeight: CGFloat = 28
    private static let headerInset: CGFloat = 30

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

            label.frame = NSRect(
                x: 0,
                y: Self.headerInset + CGFloat(row) * Self.rowHeight,
                width: bounds.width,
                height: Self.rowHeight
            )
            label.stringValue = String(grid?.rowNumber(forRow: row) ?? (row + 1))
        }
    }

    private func visibleRowRange() -> Range<Int> {
        guard rowCount > 0, visibleRect.height > 0 else { return 0 ..< 0 }
        let lower = max(0, Int(floor((visibleRect.minY - Self.headerInset) / Self.rowHeight)))
        let upper = min(rowCount, Int(ceil((visibleRect.maxY - Self.headerInset) / Self.rowHeight)))
        return lower ..< max(lower, upper)
    }
}

private final class VirtualizedGridRowNumberHeaderView: NSView {
    private let label = NSTextField(labelWithString: "#")

    init() {
        super.init(frame: .zero)
        label.isSelectable = false
        label.alignment = .right
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        wantsLayer = true
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class VirtualizedGridRowNumberView: NSView {
    private let label = NSTextField(labelWithString: "")
    var stringValue: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    init() {
        super.init(frame: .zero)
        label.isSelectable = false
        label.alignment = .right
        label.textColor = .secondaryLabelColor
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        wantsLayer = true
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class VirtualizedGridHeaderDocumentView: NSView {
    private static let headerHeight: CGFloat = 30

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

private final class VirtualizedGridHeaderCellView: NSView {
    private static let resizeHandleWidth: CGFloat = 8
    private static let horizontalPadding: CGFloat = 14
    private let label = NSTextField(labelWithString: "")
    var column = 0
    var resizeColumn: ((Int, CGFloat) -> Void)?
    var stringValue: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    init() {
        super.init(frame: .zero)
        label.isSelectable = false
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.horizontalPadding),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.horizontalPadding),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        wantsLayer = true
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.cgColor
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

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let row = rowIndex else { return }
        guard row.isMultiple(of: 2) else { return }
        FinderGridPalette.alternateRow.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 2), xRadius: 6, yRadius: 6).fill()
    }

    var visibleCellViewCount: Int { activeCells.count }
    private var rowIndex: Int?

    func configure(
        row: Int,
        columns: Range<Int>,
        columnLayout: VirtualizedGridColumnLayout?,
        value: (Int, Int) -> String
    ) {
        rowIndex = row
        needsDisplay = true
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

private final class VirtualizedGridCellView: NSView {
    private static let horizontalPadding: CGFloat = 14
    private let label = NSTextField(labelWithString: "")
    var stringValue: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    init() {
        super.init(frame: .zero)
        label.isSelectable = true
        label.font = .systemFont(ofSize: 13, weight: .regular)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.horizontalPadding),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.horizontalPadding),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// A soft edge below the pinned header recalls Finder's translucent list
/// header while keeping row rendering and scrolling fully virtualized.
private final class VirtualizedGridHeaderFadeView: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let colors = [
            NSColor.separatorColor.withAlphaComponent(0.18).cgColor,
            NSColor.clear.cgColor,
        ] as CFArray
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors,
            locations: [0, 1]
        ) else { return }
        context.drawLinearGradient(
            gradient,
            start: NSPoint(x: 0, y: 0),
            end: NSPoint(x: 0, y: bounds.height),
            options: []
        )
    }
}

private enum FinderGridPalette {
    static let background = NSColor(name: "FinderGridBackground") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedRed: 0.125, green: 0.145, blue: 0.185, alpha: 1)
            : NSColor.windowBackgroundColor
    }

    static let alternateRow = NSColor(name: "FinderGridAlternateRow") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedRed: 0.16, green: 0.185, blue: 0.23, alpha: 1)
            : NSColor.black.withAlphaComponent(0.035)
    }
}
