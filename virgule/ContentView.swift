import AppKit
import UniformTypeIdentifiers

final class ContentViewController: NSViewController, NSToolbarDelegate {
    private let engine = virgule_engine_create()
    private let titleLabel = NSTextField(labelWithString: "Open a CSV file to begin")
    private let detailLabel = NSTextField(wrappingLabelWithString: "Choose a CSV file or drag one into this window.")
    private let openButton = NSButton(title: "Open CSV…", target: nil, action: nil)

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

        openButton.bezelStyle = .rounded
        openButton.target = self
        openButton.action = #selector(openCSV(_:))

        let readOnlyLabel = NSTextField(labelWithString: "Read-only — the source file is not modified.")
        readOnlyLabel.font = .systemFont(ofSize: 12, weight: .medium)
        readOnlyLabel.textColor = .secondaryLabelColor
        readOnlyLabel.alignment = .center

        let stack = NSStackView(views: [titleLabel, detailLabel, openButton, readOnlyLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12

        dropView.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: dropView.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: dropView.centerYAnchor),
            detailLabel.widthAnchor.constraint(lessThanOrEqualTo: dropView.widthAnchor, constant: -80),
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

        titleLabel.stringValue = url.lastPathComponent
        detailLabel.stringValue = url.path
        openButton.title = "Choose another CSV…"
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
