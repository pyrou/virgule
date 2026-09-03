import AppKit
import UniformTypeIdentifiers

final class ContentViewController: NSViewController, NSToolbarDelegate, VirtualizedGridDataSource {
    private let engine = virgule_engine_create()
    private let titleLabel = NSTextField(labelWithString: "Open a CSV file to begin")
    private let detailLabel = NSTextField(wrappingLabelWithString: "Choose a CSV file or drag one into this window.")
    private let gridView = VirtualizedGridView()
    private let queryBar = SQLQueryBar()
    private let openButton = NSButton(title: "Open CSV…", target: nil, action: nil)
    private let controls = NSStackView()
    private var emptyStateConstraints: [NSLayoutConstraint] = []
    private var previewStateConstraints: [NSLayoutConstraint] = []
    private var currentImportID: UUID?
    private var previewRows: [[String]] = []
    private var cachePath: String?
    private var importedRowCount = 0
    private var cachedRows: [Int: CachedRow] = [:]
    private var loadingPageOffsets = Set<Int>()
    private var columnCount = 0
    private var columnTitles: [String] = []
    private let pageSize = 256
    private let maximumCachedPages = 8

    deinit {
        virgule_engine_destroy(engine)
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
        gridView.isHidden = true
        queryBar.isHidden = true
        queryBar.toolTip = "The SQL for the current read-only CSV view."

        openButton.bezelStyle = .rounded
        openButton.target = self
        openButton.action = #selector(openCSV(_:))

        controls.addArrangedSubview(titleLabel)
        controls.addArrangedSubview(detailLabel)
        controls.addArrangedSubview(openButton)
        controls.orientation = .vertical
        controls.alignment = .centerX
        controls.spacing = 12

        dropView.addSubview(windowHeaderMaterial)
        dropView.addSubview(controls)
        dropView.addSubview(queryBar)
        dropView.addSubview(gridView)
        windowHeaderMaterial.translatesAutoresizingMaskIntoConstraints = false
        controls.translatesAutoresizingMaskIntoConstraints = false
        queryBar.translatesAutoresizingMaskIntoConstraints = false
        gridView.translatesAutoresizingMaskIntoConstraints = false

        emptyStateConstraints = [
            controls.centerXAnchor.constraint(equalTo: dropView.centerXAnchor),
            controls.centerYAnchor.constraint(equalTo: dropView.centerYAnchor),
        ]
        previewStateConstraints = [
            queryBar.topAnchor.constraint(equalTo: dropView.safeAreaLayoutGuide.topAnchor, constant: 12),
            queryBar.leadingAnchor.constraint(equalTo: dropView.leadingAnchor, constant: 16),
            queryBar.trailingAnchor.constraint(equalTo: dropView.trailingAnchor, constant: -16),
            queryBar.heightAnchor.constraint(equalToConstant: 78),
            gridView.topAnchor.constraint(equalTo: queryBar.bottomAnchor, constant: 12),
            gridView.leadingAnchor.constraint(equalTo: dropView.leadingAnchor),
            gridView.trailingAnchor.constraint(equalTo: dropView.trailingAnchor),
            gridView.bottomAnchor.constraint(equalTo: dropView.bottomAnchor),
        ]
        NSLayoutConstraint.activate([
            windowHeaderMaterial.leadingAnchor.constraint(equalTo: dropView.leadingAnchor),
            windowHeaderMaterial.trailingAnchor.constraint(equalTo: dropView.trailingAnchor),
            windowHeaderMaterial.topAnchor.constraint(equalTo: dropView.topAnchor),
            windowHeaderMaterial.bottomAnchor.constraint(equalTo: dropView.bottomAnchor),
            detailLabel.widthAnchor.constraint(lessThanOrEqualTo: dropView.widthAnchor, constant: -80),
            gridView.heightAnchor.constraint(greaterThanOrEqualToConstant: 220),
        ])
        NSLayoutConstraint.activate(emptyStateConstraints)
        view = dropView
    }

    @objc private func openCSV(_ sender: Any?) {
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
        importedRowCount = 0
        cachedRows = [:]
        loadingPageOffsets = []
        columnCount = 0
        columnTitles = []
        queryBar.sql = ""
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
                self.queryBar.sql = Self.defaultSQL
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
                self.setGridVisible(true)
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

    func numberOfColumns(in grid: VirtualizedGridView) -> Int {
        max(columnTitles.count, columnCount, previewRows.map { $0.count }.max() ?? 0)
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
        loadingPageOffsets.insert(offset)
        let context = Unmanaged.passRetained(PageContext(controller: self, importID: importID, offset: offset))
        DispatchQueue.global(qos: .userInitiated).async {
            defer {
                context.release()
                DispatchQueue.main.async { [weak self] in
                    self?.finishLoadingPage(at: offset, importID: importID)
                }
            }
            _ = cachePath.withCString { path in
                virgule_engine_read_csv_page(
                    self.engine,
                    path,
                    offset,
                    self.pageSize,
                    virgulePageCallback,
                    context.toOpaque()
                )
            }
        }
    }

    fileprivate func receivePageRow(_ event: PageRowSnapshot, importID: UUID, offset: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.currentImportID == importID else { return }
            if let message = event.errorMessage {
                self.detailLabel.stringValue = "Could not load rows: \(message)"
                return
            }
            self.columnCount = max(self.columnCount, event.values.count)
            self.cachedRows[event.resultRow] = CachedRow(sourceRow: event.sourceRow, values: event.values)
        }
    }

    private func finishLoadingPage(at offset: Int, importID: UUID) {
        guard currentImportID == importID else { return }
        loadingPageOffsets.remove(offset)
        trimCachedPages(around: offset)
        gridView.reloadData()
    }

    private func trimCachedPages(around currentOffset: Int) {
        let minimumOffset = max(0, currentOffset - (maximumCachedPages / 2) * pageSize)
        let maximumOffset = currentOffset + (maximumCachedPages / 2) * pageSize
        cachedRows = cachedRows.filter { row, _ in row >= minimumOffset && row < maximumOffset }
    }

    private func setGridVisible(_ isVisible: Bool) {
        gridView.isHidden = !isVisible
        queryBar.isHidden = !isVisible
        controls.isHidden = isVisible
        NSLayoutConstraint.deactivate(isVisible ? emptyStateConstraints : previewStateConstraints)
        NSLayoutConstraint.activate(isVisible ? previewStateConstraints : emptyStateConstraints)
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.openCSV, .flexibleSpace, .space]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.openCSV, .flexibleSpace]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard itemIdentifier == .openCSV else { return nil }

        let item = NSToolbarItem(itemIdentifier: .openCSV)
        item.label = "Open CSV"
        item.paletteLabel = "Open CSV File"
        item.toolTip = "Open a CSV file"
        item.target = self
        item.action = #selector(openCSV(_:))
        item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Open CSV")
        return item
    }

    private static let csvContentTypes: [UTType] = [
        UTType(filenameExtension: "csv")!,
        UTType(filenameExtension: "tsv")!,
    ]

    private static func isCSV(_ url: URL) -> Bool {
        ["csv", "tsv"].contains(url.pathExtension.lowercased())
    }

    private static let defaultSQL = """
    SELECT *
    FROM csv
    ORDER BY "__virgule_row_id"
    """
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

private final class PageContext {
    weak var controller: ContentViewController?
    let importID: UUID
    let offset: Int

    init(controller: ContentViewController, importID: UUID, offset: Int) {
        self.controller = controller
        self.importID = importID
        self.offset = offset
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
    pageContext.controller?.receivePageRow(snapshot, importID: pageContext.importID, offset: pageContext.offset)
}

private extension NSToolbarItem.Identifier {
    static let openCSV = NSToolbarItem.Identifier("com.fizzup.virgule.open-csv")
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
