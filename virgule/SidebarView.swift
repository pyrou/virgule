import AppKit

struct SidebarBookmark: Equatable {
    let name: String
    let sql: String
}

final class SidebarView: NSView {
    var onOpenFile: (() -> Void)?
    var onSelectBookmark: ((SidebarBookmark) -> Void)?
    var onAddBookmark: (() -> Void)?

    private let fileValue = NSTextField(labelWithString: "No CSV open")
    private let schemaStack = NSStackView()
    private let bookmarkStack = NSStackView()
    private var bookmarks: [SidebarBookmark] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        buildView()
    }

    func update(sourceURL: URL?, columns: [String]) {
        fileValue.stringValue = sourceURL?.lastPathComponent ?? "No CSV open"
        fileValue.toolTip = sourceURL?.path
        schemaStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        if columns.isEmpty {
            let empty = NSTextField(labelWithString: sourceURL == nil ? "Open a CSV to inspect its columns" : "Reading schema…")
            empty.textColor = .secondaryLabelColor
            empty.font = .systemFont(ofSize: 12)
            schemaStack.addArrangedSubview(empty)
        } else {
            for (index, column) in columns.enumerated() {
                let label = NSTextField(labelWithString: column)
                label.font = .systemFont(ofSize: 12)
                label.lineBreakMode = .byTruncatingTail
                label.toolTip = column
                schemaStack.addArrangedSubview(label)
                if index == 0 { label.textColor = .labelColor }
            }
        }

    }

    func clearBookmarks() {
        bookmarks.removeAll()
        bookmarkStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
    }

    func addBookmark(_ bookmark: SidebarBookmark) {
        guard !bookmarks.contains(bookmark) else { return }
        bookmarks.append(bookmark)
        let button = NSButton(title: bookmark.name, target: self, action: #selector(bookmarkClicked(_:)))
        button.tag = bookmarks.count - 1
        button.bezelStyle = .recessed
        button.alignment = .left
        button.image = NSImage(systemSymbolName: "bookmark", accessibilityDescription: "Bookmark")
        button.imagePosition = .imageLeading
        button.toolTip = bookmark.sql
        bookmarkStack.addArrangedSubview(button)
    }

    private func buildView() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.55).cgColor

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 18
        content.edgeInsets = NSEdgeInsets(top: 18, left: 14, bottom: 18, right: 14)

        let fileSection = section(title: "FILES", symbol: "doc")
        let fileButton = NSButton(title: "Open CSV…", target: self, action: #selector(openFileClicked(_:)))
        fileButton.bezelStyle = .recessed
        fileButton.alignment = .left
        fileButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Open")
        fileButton.imagePosition = .imageLeading
        let fileGroup = NSStackView(views: [fileValue, fileButton])
        fileGroup.orientation = .vertical
        fileGroup.alignment = .leading
        fileGroup.spacing = 6
        fileSection.addArrangedSubview(fileGroup)

        let bookmarkSection = section(title: "BOOKMARKS", symbol: "bookmark")
        let addButton = NSButton(title: "Add current view", target: self, action: #selector(addBookmarkClicked(_:)))
        addButton.bezelStyle = .recessed
        addButton.alignment = .left
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add bookmark")
        addButton.imagePosition = .imageLeading
        bookmarkStack.orientation = .vertical
        bookmarkStack.alignment = .leading
        bookmarkStack.spacing = 4
        bookmarkSection.addArrangedSubview(bookmarkStack)
        bookmarkSection.addArrangedSubview(addButton)

        let schemaSection = section(title: "SCHEMA", symbol: "list.bullet")
        schemaStack.orientation = .vertical
        schemaStack.alignment = .leading
        schemaStack.spacing = 5
        schemaSection.addArrangedSubview(schemaStack)
        content.addArrangedSubview(fileSection)
        content.addArrangedSubview(bookmarkSection)
        content.addArrangedSubview(schemaSection)
        scrollView.documentView = content
        addSubview(scrollView)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
        ])
    }

    private func section(title: String, symbol: String) -> NSStackView {
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 11, weight: .semibold)
        heading.textColor = .secondaryLabelColor
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: title) ?? NSImage())
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        let headingRow = NSStackView(views: [icon, heading])
        headingRow.orientation = .horizontal
        headingRow.spacing = 5
        let section = NSStackView(views: [headingRow])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 7
        return section
    }

    @objc private func openFileClicked(_ sender: Any?) { onOpenFile?() }

    @objc private func addBookmarkClicked(_ sender: Any?) { onAddBookmark?() }

    @objc private func bookmarkClicked(_ sender: NSButton) {
        guard bookmarks.indices.contains(sender.tag) else { return }
        onSelectBookmark?(bookmarks[sender.tag])
    }
}
