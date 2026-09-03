import AppKit
import UniformTypeIdentifiers

final class ContentViewController: NSViewController, NSToolbarDelegate, VirtualizedGridDataSource {
    private let engine = virgule_engine_create()
    private let titleLabel = NSTextField(labelWithString: "Open a CSV file to begin")
    private let detailLabel = NSTextField(wrappingLabelWithString: "Choose a CSV file or drag one into this window.")
    private let gridView = VirtualizedGridView()
    private let openButton = NSButton(title: "Open CSV…", target: nil, action: nil)
    private var currentImportID: UUID?
    private var previewRows: [[String]] = []

    deinit {
        virgule_engine_destroy(engine)
    }

    override func loadView() {
        let dropView = FileDropView()
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

        openButton.bezelStyle = .rounded
        openButton.target = self
        openButton.action = #selector(openCSV(_:))

        let readOnlyLabel = NSTextField(labelWithString: "Read-only — the source file is not modified.")
        readOnlyLabel.font = .systemFont(ofSize: 12, weight: .medium)
        readOnlyLabel.textColor = .secondaryLabelColor
        readOnlyLabel.alignment = .center

        let controls = NSStackView(views: [titleLabel, detailLabel, openButton, readOnlyLabel])
        controls.orientation = .vertical
        controls.alignment = .centerX
        controls.spacing = 12

        let stack = NSStackView(views: [controls, gridView])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12

        dropView.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: dropView.centerXAnchor),
            stack.topAnchor.constraint(equalTo: dropView.topAnchor, constant: 32),
            stack.leadingAnchor.constraint(equalTo: dropView.leadingAnchor, constant: 40),
            stack.trailingAnchor.constraint(equalTo: dropView.trailingAnchor, constant: -40),
            stack.bottomAnchor.constraint(equalTo: dropView.bottomAnchor, constant: -32),
            detailLabel.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
            gridView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            gridView.heightAnchor.constraint(greaterThanOrEqualToConstant: 220),
        ])
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
        gridView.isHidden = true
        gridView.reloadData()
        titleLabel.stringValue = "Importing \(url.lastPathComponent)…"
        detailLabel.stringValue = url.path
        openButton.isEnabled = false
        startImporting(url, importID: importID)
    }

    private func startImporting(_ url: URL, importID: UUID) {
        let context = Unmanaged.passRetained(ImportContext(controller: self, importID: importID))
        DispatchQueue.global(qos: .userInitiated).async {
            defer { context.release() }
            _ = url.path.withCString { sourcePath in
                virgule_engine_import_csv(
                    self.engine,
                    sourcePath,
                    virguleImportCallback,
                    context.toOpaque()
                )
            }
        }
    }

    fileprivate func receiveImportEvent(_ event: ImportEventSnapshot, importID: UUID) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.currentImportID == importID else { return }

            switch event.kind {
            case VIRGULE_IMPORT_STARTED.rawValue:
                self.detailLabel.stringValue = "Preparing import (\(event.totalBytes) bytes)…"
            case VIRGULE_IMPORT_PREVIEW.rawValue:
                self.detailLabel.stringValue = "Reading rows…"
                if self.previewRows.count < 5 {
                    self.previewRows.append(event.values)
                    self.gridView.isHidden = false
                    self.gridView.reloadData()
                }
            case VIRGULE_IMPORT_PROGRESS.rawValue:
                self.detailLabel.stringValue = "Imported \(event.importedRows) rows…"
            case VIRGULE_IMPORT_COMPLETED.rawValue:
                self.titleLabel.stringValue = "Imported \(event.importedRows) rows"
                self.detailLabel.stringValue = "Local read-only cache: \(event.message)"
                self.openButton.title = "Choose another CSV…"
                self.openButton.isEnabled = true
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
        previewRows.count
    }

    func numberOfColumns(in grid: VirtualizedGridView) -> Int {
        previewRows.map { $0.count }.max() ?? 0
    }

    func grid(_ grid: VirtualizedGridView, valueForRow row: Int, column: Int) -> String {
        previewRows[row].indices.contains(column) ? previewRows[row][column] : ""
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
}

private final class ImportContext {
    weak var controller: ContentViewController?
    let importID: UUID

    init(controller: ContentViewController, importID: UUID) {
        self.controller = controller
        self.importID = importID
    }
}

private struct ImportEventSnapshot {
    let kind: UInt32
    let importedRows: Int
    let totalBytes: UInt64
    let values: [String]
    let message: String
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
