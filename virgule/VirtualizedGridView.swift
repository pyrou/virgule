import AppKit

enum GridSortDirection {
    case ascending
    case descending
}

/// Supplies the values that are currently available to the grid. The data
/// source is deliberately index-based: callers can back it with a paginated
/// SQLite result without materializing every row in AppKit.
protocol VirtualizedGridDataSource: AnyObject {
    func numberOfRows(in grid: VirtualizedGridView) -> Int
    func numberOfColumns(in grid: VirtualizedGridView) -> Int
    /// Returns the largest row number that may be displayed in the gutter.
    /// This can be larger than the result count for filtered queries.
    func maximumRowNumber(in grid: VirtualizedGridView) -> Int
    /// Returns the user-facing, stable identifier for a result row. This is
    /// intentionally separate from its current viewport index so a future
    /// filtered or paginated result can retain source row numbers.
    func grid(_ grid: VirtualizedGridView, rowNumberForRow row: Int) -> Int
    func grid(_ grid: VirtualizedGridView, valueForRow row: Int, column: Int) -> String
    func grid(_ grid: VirtualizedGridView, titleForColumn column: Int) -> String
    /// Called when the user clicks a header outside its resize handle. Shift
    /// preserves existing sort keys so a view can be ordered by multiple
    /// columns.
    func grid(_ grid: VirtualizedGridView, didRequestSortColumn column: Int, appending: Bool)
    func grid(_ grid: VirtualizedGridView, sortDirectionForColumn column: Int) -> GridSortDirection?
    /// Records a user-initiated resize by stable result-column title.
    func grid(_ grid: VirtualizedGridView, didResizeColumn column: Int, width: CGFloat)
    func grid(_ grid: VirtualizedGridView, contextMenuForColumn column: Int) -> NSMenu?
    /// Announces the rows currently needed to render the viewport. Data
    /// sources must return immediately from value lookup and can load these
    /// rows asynchronously from a paginated backing store.
    func grid(_ grid: VirtualizedGridView, willDisplayRows rows: Range<Int>)
}

extension VirtualizedGridDataSource {
    func maximumRowNumber(in grid: VirtualizedGridView) -> Int {
        max(1, numberOfRows(in: grid))
    }

    func grid(_ grid: VirtualizedGridView, rowNumberForRow row: Int) -> Int {
        row + 1
    }

    func grid(_ grid: VirtualizedGridView, titleForColumn column: Int) -> String {
        "Column \(column + 1)"
    }

    func grid(_ grid: VirtualizedGridView, willDisplayRows rows: Range<Int>) {}

    func grid(_ grid: VirtualizedGridView, didRequestSortColumn column: Int, appending: Bool) {}

    func grid(_ grid: VirtualizedGridView, sortDirectionForColumn column: Int) -> GridSortDirection? { nil }

    func grid(_ grid: VirtualizedGridView, didResizeColumn column: Int, width: CGFloat) {}
    func grid(_ grid: VirtualizedGridView, contextMenuForColumn column: Int) -> NSMenu? { nil }
}

/// A scrollable AppKit grid which creates row and cell views only for the
/// current viewport. Its header stays above the scrolling document while
/// virtualizing its visible column labels independently of row cells.
final class VirtualizedGridView: NSView, NSMenuItemValidation {
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
    private var rowNumberWidth: CGFloat = 52

    /// Useful for UI tests and diagnostics: this count is bounded by the
    /// viewport, rather than by the number of rows in the result.
    var visibleRowViewCount: Int { documentView.visibleRowViewCount }
    var visibleCellViewCount: Int { documentView.visibleCellViewCount }
    var rowNumberColumnWidth: CGFloat { rowNumberWidth }
    /// Model row indexes selected from the row-number gutter. This is kept in
    /// the grid (rather than in recycled views) so selection survives scrolls.
    private(set) var selectedRows = IndexSet()
    /// The row from which Shift-click selections extend. This also lives in
    /// the grid so virtualized row-number views never lose the selection's
    /// starting point when they are recycled.
    private var selectionAnchorRow: Int?

    override var acceptsFirstResponder: Bool { true }

    override var isFlipped: Bool { true }

    /// Scrolls the document to a model row. Kept internal for deterministic
    /// AppKit verification that scrolling does not create off-screen views.
    func scrollToRow(_ row: Int) {
        let y = max(0, CGFloat(row) * VirtualizedGridDocumentView.rowHeight)
        scrollView.contentView.scroll(to: NSPoint(x: scrollView.contentView.bounds.minX, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        refreshVisibleViews()
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureViews()
        reloadData()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = FinderGridPalette.background.cgColor
        }
        needsDisplay = true
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
        headerDocumentView.requestSort = { [weak self] column, appending in
            guard let self else { return }
            self.dataSource?.grid(self, didRequestSortColumn: column, appending: appending)
        }
        headerDocumentView.contextMenuForColumn = { [weak self] column in
            guard let self else { return nil }
            return self.dataSource?.grid(self, contextMenuForColumn: column)
        }

        rowNumberClipView.drawsBackground = false
        rowNumberClipView.documentView = rowNumberDocumentView
        rowNumberDocumentView.grid = self
        rowNumberDocumentView.beginRowSelection = { [weak self] row, preservesSelection, extendsRange in
            self?.selectRow(
                row,
                preservesSelection: preservesSelection,
                extendsRange: extendsRange
            )
        }
        rowNumberDocumentView.extendRowSelection = { [weak self] origin, row, preservesSelection in
            self?.selectRowRange(from: origin, through: row, preservesSelection: preservesSelection)
        }

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
        rowNumberHeaderView.frame = NSRect(x: 0, y: 0, width: rowNumberWidth, height: Self.headerHeight)
        rowNumberClipView.frame = NSRect(
            x: 0,
            y: Self.headerHeight,
            width: rowNumberWidth,
            height: max(0, bounds.height - Self.headerHeight)
        )
        headerClipView.frame = NSRect(
            x: rowNumberWidth,
            y: 0,
            width: max(0, bounds.width - rowNumberWidth),
            height: Self.headerHeight
        )
        headerFadeView.frame = NSRect(
            x: 0,
            y: Self.headerHeight - Self.headerFadeHeight,
            width: bounds.width,
            height: Self.headerFadeHeight
        )
        scrollView.frame = NSRect(
            x: rowNumberWidth,
            y: Self.headerHeight,
            width: max(0, bounds.width - rowNumberWidth),
            height: max(0, bounds.height - Self.headerHeight)
        )
        updateDocumentMetrics()
    }

    /// Re-reads row and column counts, discarding active views that no longer
    /// have a corresponding model row. Call after changing a query result.
    func reloadData() {
        let rowCount = max(0, dataSource?.numberOfRows(in: self) ?? 0)
        selectedRows = selectedRows.intersection(IndexSet(integersIn: 0..<rowCount))
        if let selectionAnchorRow, !selectedRows.contains(selectionAnchorRow) {
            self.selectionAnchorRow = selectedRows.first
        }
        updateDocumentMetrics()
    }

    /// Programmatic counterpart to row-number clicks, also useful for tests.
    func setSelectedRows(_ rows: IndexSet) {
        let rowCount = max(0, dataSource?.numberOfRows(in: self) ?? 0)
        selectedRows = rows.intersection(IndexSet(integersIn: 0..<rowCount))
        selectionAnchorRow = selectedRows.first
        refreshVisibleViews()
    }

    /// Copies full selected rows as TSV. The values are deliberately read from
    /// the data source at copy time so virtualized cell views never define the
    /// selection's contents.
    @discardableResult
    func copySelection(to pasteboard: NSPasteboard = .general) -> Bool {
        guard !selectedRows.isEmpty else { return false }
        let columns = max(0, dataSource?.numberOfColumns(in: self) ?? 0)
        guard columns > 0 else { return false }
        let rows = selectedRows.map { row in
            (0..<columns).map { value(forRow: row, column: $0) }.joined(separator: "\t")
        }
        pasteboard.clearContents()
        return pasteboard.setString(rows.joined(separator: "\n"), forType: .string)
    }

    @objc func copy(_ sender: Any?) {
        _ = copySelection()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(copy(_:)) {
            return !selectedRows.isEmpty
        }
        return true
    }

    /// Restores widths using result-column titles, so a SQL query may reorder
    /// its selected columns without changing the user's layout.
    func restoreColumnWidths(_ widths: [String: CGFloat]) {
        let columns = max(0, dataSource?.numberOfColumns(in: self) ?? 0)
        columnLayout.updateColumnCount(columns)
        for column in 0..<columns {
            let title = title(forColumn: column)
            if let width = widths[title] {
                _ = columnLayout.setWidth(width, forColumn: column)
            }
        }
        updateDocumentMetrics()
    }

    /// Computes a readable initial width from the header and a bounded sample.
    static func optimalColumnWidth(title: String, values: [String]) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 13)
        let widestText = ([title] + values).map {
            ceil(($0 as NSString).size(withAttributes: [.font: font]).width)
        }.max() ?? 0
        // Matches the horizontal insets used by header and body cells.
        return min(480, max(60, widestText + 24))
    }

    fileprivate func value(forRow row: Int, column: Int) -> String {
        dataSource?.grid(self, valueForRow: row, column: column) ?? ""
    }

    fileprivate func rowNumber(forRow row: Int) -> Int {
        dataSource?.grid(self, rowNumberForRow: row) ?? row + 1
    }

    func title(forColumn column: Int) -> String {
        dataSource?.grid(self, titleForColumn: column) ?? ""
    }

    fileprivate func sortDirection(forColumn column: Int) -> GridSortDirection? {
        dataSource?.grid(self, sortDirectionForColumn: column)
    }

    fileprivate func isRowSelected(_ row: Int) -> Bool {
        selectedRows.contains(row)
    }

    /// Handles a row-number click. Shift extends from the most recently
    /// selected anchor, while Command-Shift keeps any separate selected rows.
    @discardableResult
    private func selectRow(
        _ row: Int,
        preservesSelection: Bool,
        extendsRange: Bool
    ) -> Int? {
        guard row >= 0, row < (dataSource?.numberOfRows(in: self) ?? 0) else { return nil }
        if extendsRange {
            let origin = selectionAnchorRow ?? row
            extendRowSelection(to: row, preservesSelection: preservesSelection)
            return origin
        }
        if preservesSelection {
            if selectedRows.contains(row) {
                selectedRows.remove(row)
            } else {
                selectedRows.insert(row)
            }
        } else {
            selectedRows = IndexSet(integer: row)
        }
        selectionAnchorRow = row
        window?.makeFirstResponder(self)
        refreshVisibleViews()
        return row
    }

    /// Extends a row-number selection from the stored Shift-click anchor.
    /// Command-Shift retains rows selected outside the resulting range.
    func extendRowSelection(to row: Int, preservesSelection: Bool) {
        let origin = selectionAnchorRow ?? row
        selectRowRange(from: origin, through: row, preservesSelection: preservesSelection)
    }

    /// Applies the continuous range represented by a row-number gutter drag.
    /// Command-drag keeps selections that existed before the drag began.
    func selectRowRange(from origin: Int, through row: Int, preservesSelection: Bool) {
        let rowCount = max(0, dataSource?.numberOfRows(in: self) ?? 0)
        guard origin >= 0, origin < rowCount, row >= 0, row < rowCount else { return }
        let lowerBound = min(origin, row)
        let upperBound = max(origin, row)
        let range = IndexSet(integersIn: lowerBound..<(upperBound + 1))
        if preservesSelection {
            selectedRows.formUnion(range)
        } else {
            selectedRows = range
        }
        selectionAnchorRow = origin
        window?.makeFirstResponder(self)
        refreshVisibleViews()
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
        let maximumRowNumber = max(1, dataSource?.maximumRowNumber(in: self) ?? rows)
        rowNumberWidth = Self.rowNumberColumnWidth(for: maximumRowNumber)
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
        dataSource?.grid(self, didResizeColumn: column, width: columnLayout.width(forColumn: column))
        updateDocumentMetrics()
    }

    private static let headerHeight: CGFloat = 30
    private static let headerFadeHeight: CGFloat = 1
    private static let minimumRowNumberWidth: CGFloat = 52

    private static func rowNumberColumnWidth(for maximumRowNumber: Int) -> CGFloat {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let numberWidth = ceil((String(maximumRowNumber) as NSString).size(withAttributes: [.font: font]).width)
        return max(minimumRowNumberWidth, numberWidth + 14)
    }
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
                y: CGFloat(row) * Self.rowHeight,
                width: bounds.width,
                height: Self.rowHeight
            )
            rowView.configure(
                row: row,
                columns: visibleColumns,
                columnLayout: columnLayout,
                isSelected: grid?.isRowSelected(row) ?? false,
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
    private static let rowHeight: CGFloat = 28

    private var rowCount = 0
    private var activeLabels: [Int: VirtualizedGridRowNumberView] = [:]
    private var recycledLabels: [VirtualizedGridRowNumberView] = []

    weak var grid: VirtualizedGridView? {
        didSet { refreshVisibleViews() }
    }
    /// Returns the selection origin, which lets a Shift-click drag continue
    /// to extend from the pre-existing selection anchor.
    var beginRowSelection: ((Int, Bool, Bool) -> Int?)?
    var extendRowSelection: ((Int, Int, Bool) -> Void)?

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
                y: CGFloat(row) * Self.rowHeight,
                width: bounds.width,
                height: Self.rowHeight
            )
            label.stringValue = String(grid?.rowNumber(forRow: row) ?? (row + 1))
            label.row = row
            label.isSelected = grid?.isRowSelected(row) ?? false
            label.beginRowSelection = beginRowSelection
            label.extendRowSelection = extendRowSelection
        }
    }

    private func visibleRowRange() -> Range<Int> {
        guard rowCount > 0, visibleRect.height > 0 else { return 0 ..< 0 }
        let lower = max(0, Int(floor(visibleRect.minY / Self.rowHeight)))
        let upper = min(rowCount, Int(ceil(visibleRect.maxY / Self.rowHeight)))
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

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
        needsDisplay = true
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
    var row = 0
    var isSelected = false {
        didSet { updateSelectionAppearance() }
    }
    var beginRowSelection: ((Int, Bool, Bool) -> Int?)?
    var extendRowSelection: ((Int, Int, Bool) -> Void)?
    private var dragOriginRow: Int?
    private var preservesSelectionWhileDragging = false

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
        updateSelectionAppearance()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = NSColor.separatorColor.cgColor
            updateSelectionAppearance()
        }
        needsDisplay = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) {
        let preservesSelection = event.modifierFlags.contains(.command)
        let extendsRange = event.modifierFlags.contains(.shift)
        dragOriginRow = beginRowSelection?(row, preservesSelection, extendsRange) ?? row
        preservesSelectionWhileDragging = preservesSelection
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = dragOriginRow,
              let target = row(at: convert(event.locationInWindow, from: nil))
        else { return }
        extendRowSelection?(origin, target, preservesSelectionWhileDragging)
    }

    override func mouseUp(with event: NSEvent) {
        dragOriginRow = nil
    }

    private func row(at location: NSPoint) -> Int? {
        guard let superview else { return nil }
        let position = superview.convert(location, from: self)
        var target = superview.hitTest(position)
        while let view = target {
            if let rowNumberView = view as? VirtualizedGridRowNumberView {
                return rowNumberView.row
            }
            target = view.superview
        }
        return nil
    }

    private func updateSelectionAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = (isSelected ? NSColor.selectedContentBackgroundColor : .clear).cgColor
        }
        label.textColor = isSelected ? .selectedTextColor : .secondaryLabelColor
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
    var requestSort: ((Int, Bool) -> Void)?
    var contextMenuForColumn: ((Int) -> NSMenu?)?

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
            cell.sortDirection = grid?.sortDirection(forColumn: column)
            cell.requestSort = requestSort
            cell.contextMenuForColumn = contextMenuForColumn
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
    var requestSort: ((Int, Bool) -> Void)?
    var contextMenuForColumn: ((Int) -> NSMenu?)?
    var sortDirection: GridSortDirection? {
        didSet { updateLabel() }
    }
    var stringValue: String {
        get { title }
        set {
            title = newValue
            updateLabel()
        }
    }
    private var title = ""

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

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
        needsDisplay = true
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
            requestSort?(column, event.modifierFlags.contains(.shift))
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

    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenuForColumn?(column)
    }

    private func updateLabel() {
        let indicator: String
        switch sortDirection {
        case .ascending: indicator = " ▲"
        case .descending: indicator = " ▼"
        case nil: indicator = ""
        }
        label.stringValue = title + indicator
    }
}

private final class VirtualizedGridRowView: NSView {
    private var activeCells: [Int: VirtualizedGridCellView] = [:]
    private var recycledCells: [VirtualizedGridCellView] = []

    override var isFlipped: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let row = rowIndex else { return }
        if isSelected {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 6, yRadius: 6).fill()
            return
        }
        guard row.isMultiple(of: 2) else { return }
        FinderGridPalette.alternateRow.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 6, yRadius: 6).fill()
    }

    var visibleCellViewCount: Int { activeCells.count }
    private var rowIndex: Int?
    private var isSelected = false

    func configure(
        row: Int,
        columns: Range<Int>,
        columnLayout: VirtualizedGridColumnLayout?,
        isSelected: Bool,
        value: (Int, Int) -> String
    ) {
        rowIndex = row
        self.isSelected = isSelected
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
            cell.isSelected = isSelected
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
    var isSelected = false {
        didSet { label.textColor = isSelected ? .selectedTextColor : .labelColor }
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

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

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
