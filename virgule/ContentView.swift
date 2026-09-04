import AppKit
import UniformTypeIdentifiers

final class ContentViewController: NSViewController, NSToolbarDelegate, NSSplitViewDelegate, VirtualizedGridDataSource, NSSearchFieldDelegate, NSMenuItemValidation, NSToolbarItemValidation {
    private let engine = virgule_engine_create()
    private let titleLabel = NSTextField(labelWithString: "Open a CSV file to begin")
    private let detailLabel = NSTextField(wrappingLabelWithString: "Choose a CSV file or drag one into this window.")
    private let gridView = VirtualizedGridView()
    private let queryBar = SQLQueryBar()
    private let searchBar = DatasetSearchBar()
    private let toolbarSearchField = NSSearchField()
    private let contentSplitView = NSSplitView()
    private let gridContainer = NSView()
    private let tableFooterContainer = NSView()
    private let tableFooter = NSTextField(labelWithString: "")
    private let openButton = NSButton(title: "Open CSV…", target: nil, action: nil)
    private let controls = NSStackView()
    private var emptyStateConstraints: [NSLayoutConstraint] = []
    private var previewStateConstraints: [NSLayoutConstraint] = []
    private var searchVisibleConstraints: [NSLayoutConstraint] = []
    private var searchHiddenConstraints: [NSLayoutConstraint] = []
    private var currentImportID: UUID?
    private var previewRows: [[String]] = []
    private var cachePath: String?
    private var sourceFileURL: URL?
    private var sourceRowCount = 0
    private var importedRowCount = 0
    private var queryPaneVisible = true
    private var cachedRows: [Int: CachedRow] = [:]
    private var loadingPageOffsets = Set<Int>()
    private var columnCount = 0
    private var columnTitles: [String] = []
    private var savedColumnWidths: [String: CGFloat] = [:]
    private var activeQuerySQL: String?
    private var pendingQuerySQL: String?
    private var baseQuerySQL = ""
    private var baseQueryReadsCSV = false
    private var sortDescriptors: [SortDescriptor] = []
    private var datasetSearch: DatasetSearch?
    private var currentViewID = UUID()
    private var currentValidationID = UUID()
    private var statisticsPopover: NSPopover?
    private var scheduledValidation: DispatchWorkItem?
    private let pageSize = 256
    private let maximumCachedPages = 8

    deinit {
        virgule_engine_destroy(engine)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        updateDatasetToolbarItemVisibility()
    }

    override func loadView() {
        let dropView = FileDropView()
        let windowHeaderMaterial = NSVisualEffectView()
        windowHeaderMaterial.material = .headerView
        windowHeaderMaterial.blendingMode = .withinWindow
        windowHeaderMaterial.state = .active
        dropView.onFileDropped = { [weak self] url in
            self?.selectSourceFile(url)
        }

        titleLabel.font = .systemFont(ofSize: 20, weight: .medium)
        titleLabel.alignment = .center

        detailLabel.font = .systemFont(ofSize: 13)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.alignment = .center
        detailLabel.maximumNumberOfLines = 2
        detailLabel.setContentCompressionResistancePriority(.required, for: .vertical)

        gridView.dataSource = self
        contentSplitView.isVertical = false
        contentSplitView.dividerStyle = .thin
        contentSplitView.delegate = self
        contentSplitView.addArrangedSubview(gridContainer)
        contentSplitView.addArrangedSubview(queryBar)
        contentSplitView.isHidden = true
        searchBar.isHidden = true
        queryBar.toolTip = "The SQL for the current read-only CSV view."
        queryBar.onExecute = { [weak self] sql in self?.executeQuery(sql) }
        queryBar.onSQLChanged = { [weak self] sql in self?.validateQueryWhileTyping(sql) }
        searchBar.onOptionsChanged = { [weak self] column, usesRegularExpression in
            self?.applyDatasetSearch(text: self?.toolbarSearchField.stringValue ?? "", column: column, usesRegularExpression: usesRegularExpression)
        }
        searchBar.onDismiss = { [weak self] in self?.hideDatasetSearch() }
        toolbarSearchField.placeholderString = "Search"
        toolbarSearchField.delegate = self
        toolbarSearchField.target = self
        toolbarSearchField.action = #selector(toolbarSearchChanged(_:))
        toolbarSearchField.sendsSearchStringImmediately = true
        toolbarSearchField.bezelStyle = .roundedBezel

        openButton.bezelStyle = .rounded
        openButton.target = self
        openButton.action = #selector(openCSV(_:))

        tableFooter.font = .systemFont(ofSize: 11)
        tableFooter.textColor = .secondaryLabelColor
        tableFooter.alignment = .right
        tableFooter.lineBreakMode = .byTruncatingMiddle
        tableFooter.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        gridContainer.addSubview(gridView)
        gridContainer.addSubview(searchBar)
        gridContainer.addSubview(tableFooterContainer)
        tableFooterContainer.addSubview(tableFooter)
        gridView.translatesAutoresizingMaskIntoConstraints = false
        searchBar.translatesAutoresizingMaskIntoConstraints = false
        tableFooterContainer.translatesAutoresizingMaskIntoConstraints = false
        tableFooter.translatesAutoresizingMaskIntoConstraints = false

        controls.addArrangedSubview(titleLabel)
        controls.addArrangedSubview(detailLabel)
        controls.addArrangedSubview(openButton)
        controls.orientation = .vertical
        controls.alignment = .centerX
        controls.spacing = 12

        dropView.addSubview(windowHeaderMaterial)
        dropView.addSubview(controls)
        dropView.addSubview(contentSplitView)
        windowHeaderMaterial.translatesAutoresizingMaskIntoConstraints = false
        controls.translatesAutoresizingMaskIntoConstraints = false
        contentSplitView.translatesAutoresizingMaskIntoConstraints = false

        emptyStateConstraints = [
            controls.centerXAnchor.constraint(equalTo: dropView.centerXAnchor),
            controls.centerYAnchor.constraint(equalTo: dropView.centerYAnchor),
        ]
        previewStateConstraints = [
            contentSplitView.leadingAnchor.constraint(equalTo: dropView.leadingAnchor),
            contentSplitView.trailingAnchor.constraint(equalTo: dropView.trailingAnchor),
            contentSplitView.topAnchor.constraint(equalTo: dropView.safeAreaLayoutGuide.topAnchor),
            contentSplitView.bottomAnchor.constraint(equalTo: dropView.bottomAnchor),
        ]
        searchVisibleConstraints = [
            gridView.topAnchor.constraint(equalTo: searchBar.bottomAnchor, constant: 8),
        ]
        searchHiddenConstraints = [
            gridView.topAnchor.constraint(equalTo: gridContainer.topAnchor),
        ]
        NSLayoutConstraint.activate([
            windowHeaderMaterial.leadingAnchor.constraint(equalTo: dropView.leadingAnchor),
            windowHeaderMaterial.trailingAnchor.constraint(equalTo: dropView.trailingAnchor),
            windowHeaderMaterial.topAnchor.constraint(equalTo: dropView.topAnchor),
            windowHeaderMaterial.bottomAnchor.constraint(equalTo: dropView.bottomAnchor),
            detailLabel.widthAnchor.constraint(lessThanOrEqualTo: dropView.widthAnchor, constant: -80),
            gridView.leadingAnchor.constraint(equalTo: gridContainer.leadingAnchor),
            gridView.trailingAnchor.constraint(equalTo: gridContainer.trailingAnchor),
            gridView.bottomAnchor.constraint(equalTo: tableFooterContainer.topAnchor),
            tableFooterContainer.leadingAnchor.constraint(equalTo: gridContainer.leadingAnchor),
            tableFooterContainer.trailingAnchor.constraint(equalTo: gridContainer.trailingAnchor),
            tableFooterContainer.bottomAnchor.constraint(equalTo: gridContainer.bottomAnchor),
            tableFooterContainer.heightAnchor.constraint(equalToConstant: 31),
            tableFooter.leadingAnchor.constraint(equalTo: tableFooterContainer.leadingAnchor, constant: 12),
            tableFooter.trailingAnchor.constraint(equalTo: tableFooterContainer.trailingAnchor, constant: -12),
            tableFooter.centerYAnchor.constraint(equalTo: tableFooterContainer.centerYAnchor),
            searchBar.topAnchor.constraint(equalTo: gridContainer.topAnchor, constant: 8),
            searchBar.leadingAnchor.constraint(equalTo: gridContainer.leadingAnchor, constant: 16),
            searchBar.trailingAnchor.constraint(equalTo: gridContainer.trailingAnchor, constant: -16),
            searchBar.heightAnchor.constraint(equalToConstant: 26),
        ])
        NSLayoutConstraint.activate(emptyStateConstraints)
        view = dropView
    }

    @objc func openCSV(_ sender: Any?) {
        if sourceFileURL != nil {
            (NSApp.delegate as? AppDelegate)?.showWindow()
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Open CSV file"
        panel.prompt = "Open"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = Self.csvContentTypes

        if panel.runModal() == .OK, let url = panel.url {
            selectSourceFile(url)
        }
    }

    func openSourceFile(_ url: URL) {
        selectSourceFile(url)
    }

    private func selectSourceFile(_ url: URL) {
        guard Self.isCSV(url) else {
            presentError(NSError(
                domain: "Virgule",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Virgule can only open CSV files."]
            ))
            return
        }

        let importID = UUID()
        currentImportID = importID
        previewRows = []
        cachePath = nil
        sourceFileURL = url
        // Associate the window with the source document so AppKit supplies the
        // native filename title, proxy icon, and file-location menu.
        view.window?.representedURL = url
        view.window?.title = url.lastPathComponent
        updateDatasetToolbarItemVisibility()
        sourceRowCount = 0
        importedRowCount = 0
        cachedRows = [:]
        loadingPageOffsets = []
        columnCount = 0
        columnTitles = []
        savedColumnWidths = [:]
        queryBar.completionColumns = []
        queryBar.sourcePath = url.path
        activeQuerySQL = nil
        pendingQuerySQL = nil
        baseQuerySQL = ""
        baseQueryReadsCSV = false
        sortDescriptors = []
        datasetSearch = nil
        searchBar.clear()
        toolbarSearchField.stringValue = ""
        currentViewID = UUID()
        currentValidationID = UUID()
        scheduledValidation?.cancel()
        queryBar.sql = ""
        updateTableFooter()
        setGridVisible(false)
        gridView.reloadData()
        titleLabel.stringValue = "Importing \(url.lastPathComponent)…"
        detailLabel.stringValue = url.path
        openButton.isEnabled = false
        startImporting(url, importID: importID)
    }

    private func startImporting(_ url: URL, importID: UUID) {
        let context = Unmanaged.passRetained(ImportContext(controller: self, importID: importID))
        let cacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.fizzup.virgule", isDirectory: true)
        DispatchQueue.global(qos: .userInitiated).async {
            defer { context.release() }
            _ = url.path.withCString { sourcePath in
                cacheDirectory.path.withCString { cachePath in
                    virgule_engine_import_csv(
                        self.engine,
                        sourcePath,
                        cachePath,
                        virguleImportCallback,
                        context.toOpaque()
                    )
                }
            }
        }
    }

    fileprivate func receiveImportEvent(_ event: ImportEventSnapshot, importID: UUID) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.currentImportID == importID else { return }

            switch event.kind {
            case VIRGULE_IMPORT_STARTED.rawValue:
                self.detailLabel.stringValue = "Preparing import (\(event.totalBytes) bytes)…"
            case VIRGULE_IMPORT_HEADERS.rawValue:
                self.columnTitles = event.values
                self.queryBar.completionColumns = event.values
                self.searchBar.setColumns(event.values)
                self.baseQuerySQL = self.sourceQuery()
                self.baseQueryReadsCSV = true
                self.queryBar.sql = self.renderedQuerySQL()
                self.gridView.reloadData()
            case VIRGULE_IMPORT_PREVIEW.rawValue:
                self.detailLabel.stringValue = "Reading rows…"
                if self.previewRows.count < 5 {
                    self.previewRows.append(event.values)
                    self.setGridVisible(true)
                    self.gridView.reloadData()
                }
            case VIRGULE_IMPORT_PROGRESS.rawValue:
                self.detailLabel.stringValue = "Imported \(event.importedRows) rows…"
            case VIRGULE_IMPORT_COMPLETED.rawValue:
                self.openButton.isEnabled = true
                self.cachePath = event.message
                self.importedRowCount = event.importedRows
                self.sourceRowCount = event.importedRows
                self.updateTableFooter()
                self.setGridVisible(true)
                self.restoreSavedColumnWidths()
                self.gridView.reloadData()
            case VIRGULE_IMPORT_ERROR.rawValue:
                self.titleLabel.stringValue = "Could not import the CSV"
                self.detailLabel.stringValue = event.message
                self.openButton.title = "Try another CSV…"
                self.openButton.isEnabled = true
            default:
                break
            }
        }
    }

    func numberOfRows(in grid: VirtualizedGridView) -> Int {
        cachePath == nil ? previewRows.count : importedRowCount
    }

    func maximumRowNumber(in grid: VirtualizedGridView) -> Int {
        max(sourceRowCount, importedRowCount, numberOfRows(in: grid))
    }

    func numberOfColumns(in grid: VirtualizedGridView) -> Int {
        Self.displayedColumnCount(
            cachePathIsAvailable: cachePath != nil,
            columnTitlesCount: columnTitles.count,
            columnCount: columnCount,
            previewRows: previewRows
        )
    }

    func grid(_ grid: VirtualizedGridView, titleForColumn column: Int) -> String {
        guard columnTitles.indices.contains(column) else { return "Column \(column + 1)" }
        return columnTitles[column]
    }

    func grid(_ grid: VirtualizedGridView, valueForRow row: Int, column: Int) -> String {
        if cachePath != nil {
            guard let values = cachedRows[row]?.values, values.indices.contains(column) else { return "" }
            return values[column]
        }
        return previewRows[row].indices.contains(column) ? previewRows[row][column] : ""
    }

    func grid(_ grid: VirtualizedGridView, rowNumberForRow row: Int) -> Int {
        cachedRows[row]?.sourceRow ?? row + 1
    }

    func grid(_ grid: VirtualizedGridView, didRequestSortColumn column: Int, appending: Bool) {
        guard cachePath != nil, columnTitles.indices.contains(column) else { return }

        if !appending, let existing = sortDescriptors.first(where: { $0.column == column }) {
            sortDescriptors = [SortDescriptor(
                column: column,
                direction: existing.direction == .ascending ? .descending : .ascending
            )]
        } else if !appending {
            sortDescriptors = [SortDescriptor(column: column, direction: .ascending)]
        } else if let index = sortDescriptors.firstIndex(where: { $0.column == column }) {
            sortDescriptors[index].direction = sortDescriptors[index].direction == .ascending ? .descending : .ascending
        } else {
            sortDescriptors.append(SortDescriptor(column: column, direction: .ascending))
        }

        let sql = renderedQuerySQL()
        queryBar.sql = sql
        executeQuery(sql, baseQuery: baseQuerySQL, sorting: sortDescriptors)
    }

    func grid(_ grid: VirtualizedGridView, sortDirectionForColumn column: Int) -> GridSortDirection? {
        sortDescriptors.first(where: { $0.column == column })?.direction
    }

    func grid(_ grid: VirtualizedGridView, contextMenuForColumn column: Int) -> NSMenu? {
        let menu = NSMenu()
        let ascending = NSMenuItem(title: "Sort ascending", action: #selector(sortColumnFromContext(_:)), keyEquivalent: "")
        ascending.target = self
        ascending.tag = column * 2
        let descending = NSMenuItem(title: "Sort descending", action: #selector(sortColumnFromContext(_:)), keyEquivalent: "")
        descending.target = self
        descending.tag = column * 2 + 1
        menu.addItem(ascending)
        menu.addItem(descending)
        menu.addItem(.separator())
        let copyName = NSMenuItem(title: "Copy column name", action: #selector(copyColumnName(_:)), keyEquivalent: "")
        copyName.target = self
        copyName.tag = column
        copyName.representedObject = grid.title(forColumn: column)
        menu.addItem(copyName)
        let stats = NSMenuItem(title: "Show statistics", action: #selector(showColumnStatistics(_:)), keyEquivalent: "")
        stats.target = self
        stats.tag = column
        stats.representedObject = grid.title(forColumn: column)
        menu.addItem(stats)
        return menu
    }

    @objc private func copyColumnName(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(name, forType: .string)
    }

    @objc private func sortColumnFromContext(_ sender: NSMenuItem) {
        let column = sender.tag / 2
        let direction: GridSortDirection = sender.tag.isMultiple(of: 2) ? .ascending : .descending
        sortDescriptors = [SortDescriptor(column: column, direction: direction)]
        let sql = renderedQuerySQL()
        queryBar.sql = sql
        executeQuery(sql, baseQuery: baseQuerySQL, sorting: sortDescriptors)
    }

    @objc private func showColumnStatistics(_ sender: NSMenuItem) {
        let column = sender.tag
        let title = sender.representedObject as? String ?? "Column"
        guard let cachePath, let importID = currentImportID, columnTitles.indices.contains(column) else { return }

        let popoverController = StatisticsPopoverViewController(columnTitle: title)
        _ = popoverController.view
        popoverController.showLoading()
        let popover = NSPopover()
        popover.contentViewController = popoverController
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 300, height: 236)
        statisticsPopover?.close()
        statisticsPopover = popover
        popover.show(relativeTo: gridView.bounds.insetBy(dx: 24, dy: 24), of: gridView, preferredEdge: .maxX)

        let viewID = currentViewID
        let sourceSQL = (activeQuerySQL ?? renderedQuerySQL()).trimmingCharacters(in: CharacterSet(charactersIn: "; \n\t"))
        let quotedColumn = Self.quoteIdentifier(columnTitles[column])
        let expression = "CAST(\(quotedColumn) AS TEXT)"
        let wrappedSQL = """
        SELECT COUNT(*),
               SUM(CASE WHEN TRIM(COALESCE(\(expression), '')) <> '' THEN 1 ELSE 0 END),
               COUNT(DISTINCT CASE WHEN TRIM(COALESCE(\(expression), '')) <> '' THEN \(expression) END),
               MIN(CASE WHEN TRIM(COALESCE(\(expression), '')) <> '' THEN \(expression) END),
               MAX(CASE WHEN TRIM(COALESCE(\(expression), '')) <> '' THEN \(expression) END),
               AVG(CASE WHEN TRIM(COALESCE(\(expression), '')) <> '' THEN CAST(\(quotedColumn) AS REAL) END)
        FROM (\n\(sourceSQL)\n) AS "__virgule_statistics_view"
        """
        let context = Unmanaged.passRetained(StatisticsContext(
            controller: self,
            importID: importID,
            viewID: viewID
        ))
        DispatchQueue.global(qos: .userInitiated).async {
            defer { context.release() }
            _ = cachePath.withCString { path in
                wrappedSQL.withCString { query in
                    virgule_engine_read_query_page(self.engine, path, query, 0, 1, virguleStatisticsCallback, context.toOpaque())
                }
            }
        }
    }

    fileprivate func receiveStatistics(_ event: StatisticsSnapshot, importID: UUID, viewID: UUID) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.currentImportID == importID, self.currentViewID == viewID else { return }
            if let error = event.error {
                self.statisticsPopover?.contentViewController.flatMap { $0 as? StatisticsPopoverViewController }?.showError(error)
            } else {
                self.statisticsPopover?.contentViewController.flatMap { $0 as? StatisticsPopoverViewController }?.show(event)
            }
        }
    }

    func grid(_ grid: VirtualizedGridView, didResizeColumn column: Int, width: CGFloat) {
        guard let cachePath, columnTitles.indices.contains(column) else { return }
        let columnName = columnTitles[column]
        savedColumnWidths[columnName] = width
        persistColumnWidth(width, named: columnName, in: cachePath)
    }

    func grid(_ grid: VirtualizedGridView, willDisplayRows rows: Range<Int>) {
        guard let cachePath, !rows.isEmpty else { return }
        let firstPage = (rows.lowerBound / pageSize) * pageSize
        let lastPage = ((rows.upperBound - 1) / pageSize) * pageSize
        for offset in stride(from: max(0, firstPage - pageSize), through: lastPage + pageSize, by: pageSize) {
            guard offset < importedRowCount, !loadingPageOffsets.contains(offset), !isPageCached(offset) else { continue }
            loadPage(at: offset, cachePath: cachePath)
        }
    }

    private func isPageCached(_ offset: Int) -> Bool {
        cachedRows[offset] != nil || (offset >= importedRowCount)
    }

    private func loadPage(at offset: Int, cachePath: String) {
        guard let importID = currentImportID else { return }
        let viewID = currentViewID
        let sql = activeQuerySQL
        loadingPageOffsets.insert(offset)
        let context = Unmanaged.passRetained(PageContext(controller: self, importID: importID, viewID: viewID, offset: offset))
        DispatchQueue.global(qos: .userInitiated).async {
            defer {
                context.release()
                DispatchQueue.main.async { [weak self] in
                    self?.finishLoadingPage(at: offset, importID: importID, viewID: viewID)
                }
            }
            _ = cachePath.withCString { path in
                if let sql {
                    sql.withCString { query in
                        virgule_engine_read_query_page(self.engine, path, query, offset, self.pageSize, virgulePageCallback, context.toOpaque())
                    }
                } else {
                    virgule_engine_read_csv_page(self.engine, path, offset, self.pageSize, virgulePageCallback, context.toOpaque())
                }
            }
        }
    }

    fileprivate func receivePageRow(_ event: PageRowSnapshot, importID: UUID, viewID: UUID, offset: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.currentImportID == importID, self.currentViewID == viewID else { return }
            if let message = event.errorMessage {
                self.detailLabel.stringValue = "Could not load rows: \(message)"
                return
            }
            self.columnCount = max(self.columnCount, event.values.count)
            self.cachedRows[event.resultRow] = CachedRow(sourceRow: event.sourceRow, values: event.values)
        }
    }

    private func finishLoadingPage(at offset: Int, importID: UUID, viewID: UUID) {
        guard currentImportID == importID, currentViewID == viewID else { return }
        loadingPageOffsets.remove(offset)
        if offset == 0 {
            establishInitialColumnWidths()
        }
        trimCachedPages(around: offset)
        gridView.reloadData()
    }

    private func trimCachedPages(around currentOffset: Int) {
        let minimumOffset = max(0, currentOffset - (maximumCachedPages / 2) * pageSize)
        let maximumOffset = currentOffset + (maximumCachedPages / 2) * pageSize
        cachedRows = cachedRows.filter { row, _ in row >= minimumOffset && row < maximumOffset }
    }

    private func setGridVisible(_ isVisible: Bool) {
        contentSplitView.isHidden = !isVisible
        searchBar.isHidden = true
        controls.isHidden = isVisible
        NSLayoutConstraint.deactivate(isVisible ? emptyStateConstraints : previewStateConstraints)
        NSLayoutConstraint.activate(isVisible ? previewStateConstraints : emptyStateConstraints)
        NSLayoutConstraint.deactivate(searchVisibleConstraints)
        NSLayoutConstraint.deactivate(searchHiddenConstraints)
        if isVisible {
            NSLayoutConstraint.activate(searchHiddenConstraints)
            setQueryPaneVisible(queryPaneVisible, animated: false)
        }
    }

    private func updateTableFooter() {
        guard let sourceFileURL else {
            tableFooter.stringValue = ""
            return
        }
        let displayedRowCount = cachePath == nil ? previewRows.count : importedRowCount
        tableFooter.stringValue = Self.tableFooterText(
            displayedRowCount: displayedRowCount,
            sourceRowCount: sourceRowCount,
            isSearching: datasetSearch != nil
        )
        tableFooter.toolTip = sourceFileURL.path
    }

    static func tableFooterText(
        displayedRowCount: Int,
        sourceRowCount: Int,
        isSearching: Bool
    ) -> String {
        let displayedLabel = displayedRowCount == 1 ? "1 row" : "\(displayedRowCount) rows"
        guard displayedRowCount != sourceRowCount else { return displayedLabel }

        let sourceLabel = sourceRowCount == 1 ? "1 row" : "\(sourceRowCount) rows"
        if isSearching {
            let matchingLabel = displayedRowCount == 1 ? "matching row" : "matching rows"
            return "\(displayedRowCount) \(matchingLabel) out of \(sourceLabel)"
        }
        return "\(displayedLabel) out of \(sourceLabel)"
    }

    @objc private func toggleQueryPane(_ sender: Any?) {
        guard !contentSplitView.isHidden else {
            NSSound.beep()
            return
        }
        setQueryPaneVisible(!queryPaneVisible, animated: true)
    }

    private func setQueryPaneVisible(_ isVisible: Bool, animated: Bool) {
        queryPaneVisible = isVisible
        let changes = {
            self.queryBar.isHidden = !isVisible
            self.contentSplitView.adjustSubviews()
            if isVisible {
                let preferredQueryHeight: CGFloat = 180
                let dividerPosition = max(220, self.contentSplitView.bounds.height - preferredQueryHeight)
                self.contentSplitView.setPosition(dividerPosition, ofDividerAt: 0)
            }
        }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.allowsImplicitAnimation = true
                changes()
            }
        } else {
            changes()
        }
        updateQueryPaneToolbarItem()
    }

    private func updateQueryPaneToolbarItem() {
        guard let item = view.window?.toolbar?.items.first(where: { $0.itemIdentifier == .queryPane }) else { return }
        item.label = queryPaneVisible ? "Hide SQL" : "Show SQL"
        item.paletteLabel = item.label
        item.toolTip = queryPaneVisible ? "Hide the SQL pane" : "Show the SQL pane"
    }

    private func updateDatasetToolbarItemVisibility() {
        let shouldHide = sourceFileURL == nil
        view.window?.toolbar?.items
            .filter { $0.itemIdentifier == .queryPane || $0.itemIdentifier == .search || $0.itemIdentifier == .exportView }
            .forEach { $0.isHidden = shouldHide }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(exportViewAsCSV(_:)) {
            return canExportCurrentView
        }
        return true
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        if item.itemIdentifier == .exportView {
            return canExportCurrentView
        }
        return true
    }

    private func executeQuery(_ sql: String, baseQuery: String? = nil, sorting: [SortDescriptor]? = nil) {
        guard let cachePath, let importID = currentImportID else { return }
        let presentation = SQLQueryPresentation(sourcePath: sourceFileURL?.path ?? "")
        let engineSQL = presentation.engineSQL(for: sql)
        let viewID = UUID()
        currentViewID = viewID
        pendingQuerySQL = engineSQL
        if let baseQuery {
            baseQuerySQL = baseQuery
        } else {
            datasetSearch = nil
            searchBar.clear()
            toolbarSearchField.stringValue = ""
            baseQuerySQL = sql.trimmingCharacters(in: .whitespacesAndNewlines)
            baseQueryReadsCSV = false
            sortDescriptors = []
        }
        if let sorting {
            sortDescriptors = sorting
        }
        // Keep the current result on screen while SQLite validates the next
        // query. Clearing the schema here briefly exposed fallback headers
        // ("Column 1", "Column 2", …) during sorts.
        detailLabel.stringValue = "Validating query…"
        gridView.reloadData()
        let context = Unmanaged.passRetained(QueryContext(
            controller: self,
            importID: importID,
            viewID: viewID,
            presentation: presentation,
            displayedSQL: sql
        ))
        DispatchQueue.global(qos: .userInitiated).async {
            defer { context.release() }
            _ = cachePath.withCString { path in
                engineSQL.withCString { query in
                    virgule_engine_describe_query(self.engine, path, query, virguleQueryCallback, context.toOpaque())
                }
            }
        }
    }

    fileprivate func receiveQueryDescription(_ event: ImportEventSnapshot, importID: UUID, viewID: UUID) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.currentImportID == importID, self.currentViewID == viewID else { return }
            guard event.kind == VIRGULE_IMPORT_HEADERS.rawValue else {
                self.pendingQuerySQL = nil
                self.detailLabel.stringValue = "Query error: \(event.message)"
                self.queryBar.setValidationMessage(event.message)
                return
            }
            self.queryBar.setValidationMessage(nil)
            self.activeQuerySQL = self.pendingQuerySQL
            self.pendingQuerySQL = nil
            self.cachedRows = [:]
            self.loadingPageOffsets = []
            self.columnTitles = event.values
            self.savedColumnWidths = [:]
            self.searchBar.setColumns(event.values)
            self.columnCount = event.values.count
            self.importedRowCount = event.importedRows
            self.detailLabel.stringValue = "\(event.importedRows) matching rows"
            self.updateTableFooter()
            self.restoreSavedColumnWidths()
            self.gridView.reloadData()
        }
    }

    /// Loads widths from the SQLite cache on a worker queue. This runs after a
    /// query schema is known, so saved names can be mapped to any new order.
    private func restoreSavedColumnWidths() {
        guard let cachePath, let importID = currentImportID else { return }
        let titles = columnTitles
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var widths: [String: CGFloat] = [:]
            for title in titles {
                let width = cachePath.withCString { path in
                    title.withCString { name in virgule_engine_column_width(path, name) }
                }
                if width.isFinite, width > 0 {
                    widths[title] = CGFloat(width)
                }
            }
            DispatchQueue.main.async {
                guard let self, self.currentImportID == importID else { return }
                self.savedColumnWidths.merge(widths) { _, savedWidth in savedWidth }
                self.gridView.restoreColumnWidths(widths)
            }
        }
    }

    /// Sizes only names that have no saved width, based on the first 15 rows
    /// already fetched for the current SQL result.
    private func establishInitialColumnWidths() {
        guard let cachePath, !columnTitles.isEmpty else { return }
        let sample = (0..<15).compactMap { cachedRows[$0]?.values }
        guard !sample.isEmpty else { return }
        var newWidths: [String: CGFloat] = [:]
        for (column, title) in columnTitles.enumerated() where savedColumnWidths[title] == nil {
            let values = sample.compactMap { $0.indices.contains(column) ? $0[column] : nil }
            let width = VirtualizedGridView.optimalColumnWidth(title: title, values: values)
            savedColumnWidths[title] = width
            newWidths[title] = width
            persistColumnWidth(width, named: title, in: cachePath)
        }
        guard !newWidths.isEmpty else { return }
        gridView.restoreColumnWidths(newWidths)
    }

    private func persistColumnWidth(_ width: CGFloat, named columnName: String, in cachePath: String) {
        DispatchQueue.global(qos: .utility).async {
            _ = cachePath.withCString { path in
                columnName.withCString { name in
                    virgule_engine_set_column_width(path, name, Double(width))
                }
            }
        }
    }

    private func validateQueryWhileTyping(_ sql: String) {
        scheduledValidation?.cancel()
        guard let cachePath, let importID = currentImportID else { return }
        let validationID = UUID()
        let presentation = SQLQueryPresentation(sourcePath: sourceFileURL?.path ?? "")
        let engineSQL = presentation.engineSQL(for: sql)
        currentValidationID = validationID
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let context = Unmanaged.passRetained(ValidationContext(
                controller: self,
                importID: importID,
                validationID: validationID,
                presentation: presentation,
                displayedSQL: sql
            ))
            DispatchQueue.global(qos: .userInitiated).async {
                defer { context.release() }
                _ = cachePath.withCString { path in
                    engineSQL.withCString { query in
                        virgule_engine_validate_query(
                            self.engine,
                            path,
                            query,
                            virguleValidationCallback,
                            context.toOpaque()
                        )
                    }
                }
            }
        }
        scheduledValidation = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(180), execute: workItem)
    }

    fileprivate func receiveValidation(_ event: ImportEventSnapshot, importID: UUID, validationID: UUID) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.currentImportID == importID, self.currentValidationID == validationID else { return }
            self.queryBar.setValidationMessage(event.kind == VIRGULE_IMPORT_HEADERS.rawValue ? nil : event.message)
        }
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.openCSV, .queryPane, .exportView, .search, .flexibleSpace, .space]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.openCSV, .queryPane, .exportView, .flexibleSpace, .search]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case .openCSV:
            let item = NSToolbarItem(itemIdentifier: .openCSV)
            item.label = "Open CSV"
            item.paletteLabel = "Open CSV File"
            item.toolTip = "Open a CSV file"
            item.target = self
            item.action = #selector(openCSV(_:))
            item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Open CSV")
            return item
        case .queryPane:
            let item = NSToolbarItem(itemIdentifier: .queryPane)
            item.target = self
            item.action = #selector(toggleQueryPane(_:))
            item.image = NSImage(systemSymbolName: "rectangle.bottomthird.inset.filled", accessibilityDescription: "SQL pane")
            item.label = "Hide SQL"
            item.paletteLabel = "Hide SQL"
            item.toolTip = "Hide the SQL pane"
            return item
        case .exportView:
            let item = NSToolbarItem(itemIdentifier: .exportView)
            item.target = self
            item.action = #selector(exportViewAsCSV(_:))
            item.image = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: "Save As")
            item.label = "Save As"
            item.paletteLabel = "Export view"
            item.toolTip = "Export the current view as CSV (Shift-Command-S)"
            return item
        case .search:
            let item = NSSearchToolbarItem(itemIdentifier: .search)
            item.label = "Search"
            item.paletteLabel = "Search dataset"
            item.toolTip = "Search dataset (⌘F)"
            item.searchField = toolbarSearchField
            item.preferredWidthForSearchField = 220
            return item
        default:
            return nil
        }
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainSplitPosition proposedPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        guard splitView == contentSplitView, dividerIndex == 0 else { return proposedPosition }
        let minimumGridHeight: CGFloat = 220
        let minimumQueryHeight: CGFloat = 100
        return min(
            max(proposedPosition, minimumGridHeight),
            max(minimumGridHeight, splitView.bounds.height - minimumQueryHeight)
        )
    }

    private static let csvContentTypes: [UTType] = [
        UTType(filenameExtension: "csv")!,
        UTType(filenameExtension: "tsv")!,
    ]

    private static func isCSV(_ url: URL) -> Bool {
        ["csv", "tsv"].contains(url.pathExtension.lowercased())
    }

    private func renderedQuerySQL() -> String {
        let unfilteredBase = baseQuerySQL.isEmpty ? sourceQuery() : baseQuerySQL
        let base = DatasetSearch.filteredSQL(baseSQL: unfilteredBase, columns: columnTitles, search: datasetSearch)
        let ordering = sortDescriptors.compactMap { descriptor -> String? in
            guard columnTitles.indices.contains(descriptor.column) else { return nil }
            let direction = descriptor.direction == .ascending ? "ASC" : "DESC"
            return "\(Self.quoteIdentifier(columnTitles[descriptor.column])) \(direction)"
        }
        guard !ordering.isEmpty else {
            return baseQueryReadsCSV ? base + "\nORDER BY \(SQLQueryPresentation.internalRowID)" : base
        }
        if baseQueryReadsCSV {
            return base + "\nORDER BY " + ordering.joined(separator: ", ") + ", \(SQLQueryPresentation.internalRowID)"
        }
        let queryWithoutTerminator = base.trimmingCharacters(in: CharacterSet(charactersIn: "; "))
        return "SELECT *\nFROM (\n\(queryWithoutTerminator)\n) AS \"__virgule_sorted_view\"\nORDER BY " + ordering.joined(separator: ", ")
    }

    private func sourceQuery() -> String {
        let path = sourceFileURL?.path ?? "csv"
        return "SELECT *\nFROM \(path)"
    }

    @objc func exportViewAsCSV(_ sender: Any?) {
        // AppKit panels must be created and presented on the main thread. Menu
        // and toolbar actions normally arrive here on main, but keeping this
        // boundary explicit also protects the export action if it is triggered
        // by another callback in the future.
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.exportViewAsCSV(nil)
            }
            return
        }
        guard canExportCurrentView else {
            NSSound.beep()
            return
        }
        guard let window = view.window else { return }

        let panel = NSSavePanel()
        panel.title = "Export View"
        panel.prompt = "Save"
        panel.nameFieldStringValue = suggestedExportFilename()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [UTType(filenameExtension: "csv")!]

        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, let destinationURL = panel.url else { return }
            self.exportCurrentView(to: destinationURL)
        }
    }

    private func exportCurrentView(to destinationURL: URL) {
        guard let cachePath, let rowCount = currentExportRowCount() else { return }
        let headers = (0..<Self.displayedColumnCount(
            cachePathIsAvailable: true,
            columnTitlesCount: columnTitles.count,
            columnCount: columnCount,
            previewRows: previewRows
        )).map { column in
            columnTitles.indices.contains(column) ? columnTitles[column] : "Column \(column + 1)"
        }
        let engineSQL = activeQuerySQL
        let importID = currentImportID
        let exportViewID = currentViewID

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                try self.writeCSVExport(
                    to: destinationURL,
                    cachePath: cachePath,
                    engineSQL: engineSQL,
                    rowCount: rowCount,
                    headers: headers,
                    importID: importID,
                    viewID: exportViewID
                )
            } catch {
                DispatchQueue.main.async {
                    self.presentError(error)
                }
            }
        }
    }

    private func writeCSVExport(
        to destinationURL: URL,
        cachePath: String,
        engineSQL: String?,
        rowCount: Int,
        headers: [String],
        importID: UUID?,
        viewID: UUID
    ) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        fileManager.createFile(atPath: destinationURL.path, contents: nil)
        let fileHandle = try FileHandle(forWritingTo: destinationURL)
        defer { fileHandle.closeFile() }

        let writer = CSVExportWriter(fileHandle: fileHandle)
        try writer.writeLine(headers)

        let pageSize = 512
        let exportContext = Unmanaged.passRetained(ExportContext(writer: writer))
        defer { exportContext.release() }

        for offset in stride(from: 0, to: rowCount, by: pageSize) {
            guard importID == currentImportID, viewID == currentViewID else { return }
            let limit = min(pageSize, rowCount - offset)
            let result = cachePath.withCString { path in
                if let engineSQL {
                    return engineSQL.withCString { query in
                        virgule_engine_read_query_page(self.engine, path, query, offset, limit, virguleExportPageCallback, exportContext.toOpaque())
                    }
                } else {
                    return virgule_engine_read_csv_page(self.engine, path, offset, limit, virguleExportPageCallback, exportContext.toOpaque())
                }
            }
            guard result == 0 else { throw CocoaError(.fileWriteUnknown) }
            if let error = exportContext.takeUnretainedValue().error {
                throw error
            }
        }

        if let error = exportContext.takeUnretainedValue().error {
            throw error
        }
    }

    private func currentExportRowCount() -> Int? {
        guard cachePath != nil else { return nil }
        return importedRowCount
    }

    private var canExportCurrentView: Bool {
        sourceFileURL != nil && cachePath != nil
    }

    private func suggestedExportFilename() -> String {
        let baseName = sourceFileURL?.deletingPathExtension().lastPathComponent ?? "export"
        return "\(baseName) export.csv"
    }

    static func displayedColumnCount(
        cachePathIsAvailable: Bool,
        columnTitlesCount: Int,
        columnCount: Int,
        previewRows: [[String]]
    ) -> Int {
        if cachePathIsAvailable {
            return max(columnTitlesCount, columnCount)
        }
        return max(columnTitlesCount, previewRows.map { $0.count }.max() ?? 0)
    }

    @objc private func toolbarSearchChanged(_ sender: Any?) {
        guard cachePath != nil else { return }
        applyDatasetSearch(
            text: toolbarSearchField.stringValue,
            column: searchBar.selectedColumn,
            usesRegularExpression: searchBar.usesRegularExpression
        )
    }

    private func applyDatasetSearch(text: String, column: String?, usesRegularExpression: Bool) {
        guard !text.isEmpty else {
            applyDatasetSearch(nil)
            hideSearchOptions()
            return
        }
        showSearchOptions()
        let search = DatasetSearch(text: text, column: column, usesRegularExpression: usesRegularExpression)
        guard searchBar.validateRegularExpression(text) else { return }
        applyDatasetSearch(search)
    }

    private func applyDatasetSearch(_ search: DatasetSearch?) {
        guard cachePath != nil, datasetSearch != search else { return }
        datasetSearch = search
        executeQuery(renderedQuerySQL(), baseQuery: baseQuerySQL, sorting: sortDescriptors)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "f",
            cachePath != nil {
            searchToolbarItem()?.beginSearchInteraction()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    @objc func focusDatasetSearch(_ sender: Any?) {
        guard cachePath != nil else { return }
        view.window?.makeFirstResponder(toolbarSearchField)
    }

    private func showSearchOptions() {
        guard searchBar.isHidden else { return }
        searchBar.isHidden = false
        NSLayoutConstraint.deactivate(searchHiddenConstraints)
        NSLayoutConstraint.activate(searchVisibleConstraints)
    }

    private func searchToolbarItem() -> NSSearchToolbarItem? {
        view.window?.toolbar?.items.first(where: { $0.itemIdentifier == .search }) as? NSSearchToolbarItem
    }

    private func hideDatasetSearch() {
        toolbarSearchField.stringValue = ""
        searchBar.clear()
        applyDatasetSearch(nil)
        hideSearchOptions()
        view.window?.makeFirstResponder(gridView)
    }

    private func hideSearchOptions() {
        guard !searchBar.isHidden else { return }
        searchBar.isHidden = true
        NSLayoutConstraint.deactivate(searchVisibleConstraints)
        NSLayoutConstraint.activate(searchHiddenConstraints)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === toolbarSearchField, commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        hideDatasetSearch()
        return true
    }

    nonisolated private static func quoteIdentifier(_ identifier: String) -> String {
        "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}

private final class ImportContext {
    weak var controller: ContentViewController?
    let importID: UUID

    init(controller: ContentViewController, importID: UUID) {
        self.controller = controller
        self.importID = importID
    }
}

private struct CachedRow {
    let sourceRow: Int
    let values: [String]
}

private struct SortDescriptor {
    let column: Int
    var direction: GridSortDirection
}

private final class ExportContext {
    let writer: CSVExportWriter
    var error: Error?

    init(writer: CSVExportWriter) {
        self.writer = writer
    }
}

private final class PageContext {
    weak var controller: ContentViewController?
    let importID: UUID
    let viewID: UUID
    let offset: Int

    init(controller: ContentViewController, importID: UUID, viewID: UUID, offset: Int) {
        self.controller = controller
        self.importID = importID
        self.viewID = viewID
        self.offset = offset
    }
}

private final class QueryContext {
    weak var controller: ContentViewController?
    let importID: UUID
    let viewID: UUID
    let presentation: SQLQueryPresentation
    let displayedSQL: String

    init(
        controller: ContentViewController,
        importID: UUID,
        viewID: UUID,
        presentation: SQLQueryPresentation,
        displayedSQL: String
    ) {
        self.controller = controller
        self.importID = importID
        self.viewID = viewID
        self.presentation = presentation
        self.displayedSQL = displayedSQL
    }
}

private struct StatisticsSnapshot {
    let values: [String]
    let error: String?
}

private final class StatisticsContext {
    weak var controller: ContentViewController?
    let importID: UUID
    let viewID: UUID

    init(controller: ContentViewController, importID: UUID, viewID: UUID) {
        self.controller = controller
        self.importID = importID
        self.viewID = viewID
    }
}

private final class StatisticsPopoverViewController: NSViewController {
    private let columnTitle: String
    private let stack = NSStackView()

    init(columnTitle: String) {
        self.columnTitle = columnTitle
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let view = NSView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
        ])
        self.view = view
    }

    func showLoading() {
        replace(with: [label("Statistics for \(columnTitle)", bold: true), label("Calculating…")])
    }

    func show(_ event: StatisticsSnapshot) {
        guard event.values.count >= 6 else { showError("No statistics available."); return }
        replace(with: [
            label("Statistics for \(columnTitle)", bold: true),
            label("Values: \(event.values[0])"),
            label("Non-empty: \(event.values[1])"),
            label("Unique: \(event.values[2])"),
            label("Minimum: \(display(event.values[3]))"),
            label("Maximum: \(display(event.values[4]))"),
            label("Average: \(display(event.values[5]))"),
        ])
    }

    func showError(_ message: String) {
        replace(with: [label("Statistics for \(columnTitle)", bold: true), label(message)])
    }

    private func display(_ value: String) -> String {
        guard !value.isEmpty else { return "—" }
        if let number = Double(value) {
            return number.rounded() == number ? String(Int(number)) : String(format: "%.2f", number)
        }
        return value
    }

    private func label(_ text: String, bold: Bool = false) -> NSTextField {
        let result = NSTextField(wrappingLabelWithString: text)
        if bold { result.font = .boldSystemFont(ofSize: NSFont.systemFontSize) }
        return result
    }

    private func replace(with views: [NSView]) {
        stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
        views.forEach { stack.addArrangedSubview($0) }
    }
}

private final class ValidationContext {
    weak var controller: ContentViewController?
    let importID: UUID
    let validationID: UUID
    let presentation: SQLQueryPresentation
    let displayedSQL: String

    init(
        controller: ContentViewController,
        importID: UUID,
        validationID: UUID,
        presentation: SQLQueryPresentation,
        displayedSQL: String
    ) {
        self.controller = controller
        self.importID = importID
        self.validationID = validationID
        self.presentation = presentation
        self.displayedSQL = displayedSQL
    }
}

private final class CSVExportWriter {
    private let fileHandle: FileHandle

    init(fileHandle: FileHandle) {
        self.fileHandle = fileHandle
    }

    func writeLine(_ values: [String]) throws {
        let line = values.map(Self.escapeField).joined(separator: ",") + "\n"
        try fileHandle.write(contentsOf: Data(line.utf8))
    }

    private static func escapeField(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}

private struct ImportEventSnapshot {
    let kind: UInt32
    let importedRows: Int
    let totalBytes: UInt64
    let values: [String]
    let message: String
}

private struct PageRowSnapshot {
    let resultRow: Int
    let sourceRow: Int
    let values: [String]
    let errorMessage: String?
}

private let virguleImportCallback: VirguleImportCallback = { event, context in
    guard let event, let context else { return }
    let importContext = Unmanaged<ImportContext>.fromOpaque(context).takeUnretainedValue()
    let importedEvent = event.pointee
    let values = importedEvent.values.map { values in
        (0 ..< Int(importedEvent.value_count)).compactMap { index in
            values[index].map { String(cString: $0) }
        }
    } ?? []
    let snapshot = ImportEventSnapshot(
        kind: importedEvent.kind,
        importedRows: importedEvent.imported_rows,
        totalBytes: importedEvent.total_bytes,
        values: values,
        message: importedEvent.message.map { String(cString: $0) } ?? ""
    )
    importContext.controller?.receiveImportEvent(snapshot, importID: importContext.importID)
}

private let virgulePageCallback: VirgulePageCallback = { row, context in
    guard let row, let context else { return }
    let pageContext = Unmanaged<PageContext>.fromOpaque(context).takeUnretainedValue()
    let pageRow = row.pointee
    let message = pageRow.message.map { String(cString: $0) } ?? ""
    let snapshot = PageRowSnapshot(
        resultRow: pageRow.result_row,
        sourceRow: Int(pageRow.source_row),
        values: pageRow.values.map { values in
            (0 ..< Int(pageRow.value_count)).compactMap { index in
                values[index].map { String(cString: $0) }
            }
        } ?? [],
        errorMessage: pageRow.result_row == Int.max ? message : nil
    )
    pageContext.controller?.receivePageRow(snapshot, importID: pageContext.importID, viewID: pageContext.viewID, offset: pageContext.offset)
}

private let virguleStatisticsCallback: VirgulePageCallback = { row, context in
    guard let row, let context else { return }
    let statisticsContext = Unmanaged<StatisticsContext>.fromOpaque(context).takeUnretainedValue()
    let pageRow = row.pointee
    let error = pageRow.result_row == Int.max ? (pageRow.message.map { String(cString: $0) } ?? "Could not calculate statistics.") : nil
    let values = pageRow.values.map { values in
        (0 ..< Int(pageRow.value_count)).compactMap { index in values[index].map { String(cString: $0) } }
    } ?? []
    statisticsContext.controller?.receiveStatistics(
        StatisticsSnapshot(values: values, error: error),
        importID: statisticsContext.importID,
        viewID: statisticsContext.viewID
    )
}

private let virguleExportPageCallback: VirgulePageCallback = { row, context in
    guard let row, let context else { return }
    let exportContext = Unmanaged<ExportContext>.fromOpaque(context).takeUnretainedValue()
    guard exportContext.error == nil else { return }
    let pageRow = row.pointee
    if pageRow.result_row == Int.max {
        exportContext.error = NSError(
            domain: "Virgule",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: pageRow.message.map { String(cString: $0) } ?? "Could not export the view."]
        )
        return
    }
    let values = pageRow.values.map { values in
        (0 ..< Int(pageRow.value_count)).compactMap { index in
            values[index].map { String(cString: $0) }
        }
    } ?? []
    do {
        try exportContext.writer.writeLine(values)
    } catch {
        exportContext.error = error
    }
}

private let virguleQueryCallback: VirguleImportCallback = { event, context in
    guard let event, let context else { return }
    let queryContext = Unmanaged<QueryContext>.fromOpaque(context).takeUnretainedValue()
    let queryEvent = event.pointee
    let values = queryEvent.values.map { values in
        (0 ..< Int(queryEvent.value_count)).compactMap { values[$0].map { String(cString: $0) } }
    } ?? []
    let message = queryEvent.message.map { String(cString: $0) } ?? ""
    let snapshot = ImportEventSnapshot(
        kind: queryEvent.kind,
        importedRows: queryEvent.imported_rows,
        totalBytes: queryEvent.total_bytes,
        values: values,
        message: queryContext.presentation.displayedError(message, for: queryContext.displayedSQL)
    )
    queryContext.controller?.receiveQueryDescription(snapshot, importID: queryContext.importID, viewID: queryContext.viewID)
}

private let virguleValidationCallback: VirguleImportCallback = { event, context in
    guard let event, let context else { return }
    let validationContext = Unmanaged<ValidationContext>.fromOpaque(context).takeUnretainedValue()
    let validationEvent = event.pointee
    let message = validationEvent.message.map { String(cString: $0) } ?? ""
    let snapshot = ImportEventSnapshot(
        kind: validationEvent.kind,
        importedRows: validationEvent.imported_rows,
        totalBytes: validationEvent.total_bytes,
        values: [],
        message: validationContext.presentation.displayedError(message, for: validationContext.displayedSQL)
    )
    validationContext.controller?.receiveValidation(
        snapshot,
        importID: validationContext.importID,
        validationID: validationContext.validationID
    )
}

private extension NSToolbarItem.Identifier {
    static let openCSV = NSToolbarItem.Identifier("com.fizzup.virgule.open-csv")
    static let queryPane = NSToolbarItem.Identifier("com.fizzup.virgule.query-pane")
    static let exportView = NSToolbarItem.Identifier("com.fizzup.virgule.export-view")
    static let search = NSToolbarItem.Identifier("com.fizzup.virgule.search")
}

private final class FileDropView: NSView {
    var onFileDropped: ((URL) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        firstCSVURL(in: sender) == nil ? [] : .copy
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        firstCSVURL(in: sender) != nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = firstCSVURL(in: sender) else { return false }
        onFileDropped?(url)
        return true
    }

    private func firstCSVURL(in draggingInfo: NSDraggingInfo) -> URL? {
        guard let urls = draggingInfo.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] else {
            return nil
        }
        return urls.first { ["csv", "tsv"].contains($0.pathExtension.lowercased()) }
    }
}
