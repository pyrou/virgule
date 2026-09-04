import AppKit

struct SidebarBookmark: Codable, Equatable {
    let name: String
    let sql: String
    let sourcePath: String
    let createdAt: Date

    init(name: String, sql: String, sourcePath: String = "", createdAt: Date = Date()) {
        self.name = name
        self.sql = sql
        self.sourcePath = sourcePath
        self.createdAt = createdAt
    }
}

final class SidebarView: NSView {
    var onOpenFile: (() -> Void)?
    var onSelectRecentFile: ((URL) -> Void)?
    var onSelectBookmark: ((SidebarBookmark) -> Void)?
    var onAddBookmark: (() -> Void)?

    private let fileValue = NSTextField(labelWithString: "No CSV open")
    private let fileStack = NSStackView()
    private let bookmarkStack = NSStackView()
    private var bookmarks: [SidebarBookmark] = []
    private var recentFiles: [URL] = []
    private var currentSourcePath = ""
    private let sidebarMaterial = NSVisualEffectView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        buildView()
    }

    func update(sourceURL: URL?) {
        fileValue.stringValue = sourceURL?.lastPathComponent ?? "No CSV open"
        fileValue.toolTip = sourceURL?.path
        currentSourcePath = sourceURL?.path ?? ""
        if !currentSourcePath.isEmpty {
            let stored = UserDefaults.standard.data(forKey: "virgule.sidebar.bookmarks")
                .flatMap { try? JSONDecoder().decode([SidebarBookmark].self, from: $0) } ?? []
            bookmarks = stored.filter { $0.sourcePath == currentSourcePath }
        } else {
            bookmarks = []
        }
        rebuildBookmarkButtons()
        if let sourceURL {
            recentFiles.removeAll { $0 == sourceURL }
            recentFiles.insert(sourceURL, at: 0)
            recentFiles = Array(recentFiles.prefix(8))
        }
        fileStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, url) in recentFiles.enumerated() {
            let button = NSButton(title: url.lastPathComponent, target: self, action: #selector(recentFileClicked(_:)))
            button.tag = index
            button.isBordered = false
            button.bezelStyle = .texturedRounded
            button.showsBorderOnlyWhileMouseInside = true
            button.alignment = .left
            button.image = NSImage(systemSymbolName: "doc", accessibilityDescription: "CSV file")
            button.imagePosition = .imageLeading
            button.toolTip = url.path
            fileStack.addArrangedSubview(button)
        }
    }

    func clearBookmarks() {
        bookmarks.removeAll()
        rebuildBookmarkButtons()
    }

    func addBookmark(_ bookmark: SidebarBookmark) {
        guard !bookmarks.contains(bookmark) else { return }
        let saved = SidebarBookmark(name: bookmark.name, sql: bookmark.sql, sourcePath: currentSourcePath)
        bookmarks.append(saved)
        var all = UserDefaults.standard.data(forKey: "virgule.sidebar.bookmarks")
            .flatMap { try? JSONDecoder().decode([SidebarBookmark].self, from: $0) } ?? []
        all.removeAll { $0.sourcePath == saved.sourcePath && $0.name == saved.name }
        all.append(saved)
        if let data = try? JSONEncoder().encode(all) {
            UserDefaults.standard.set(data, forKey: "virgule.sidebar.bookmarks")
        }
        rebuildBookmarkButtons()
    }

    private func rebuildBookmarkButtons() {
        bookmarkStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, bookmark) in bookmarks.enumerated() {
            let button = NSButton(title: bookmark.name, target: self, action: #selector(bookmarkClicked(_:)))
            button.tag = index
            button.isBordered = false
            button.bezelStyle = .texturedRounded
            button.showsBorderOnlyWhileMouseInside = true
            button.alignment = .left
            button.image = NSImage(systemSymbolName: "bookmark", accessibilityDescription: "Bookmark")
            button.imagePosition = .imageLeading
            button.toolTip = "Source: \(bookmark.sourcePath)\n\(bookmark.sql)\nBookmarked \(Self.dateFormatter.string(from: bookmark.createdAt))"
            bookmarkStack.addArrangedSubview(button)
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private func buildView() {
        sidebarMaterial.material = .sidebar
        sidebarMaterial.blendingMode = .withinWindow
        sidebarMaterial.state = .active
        addSubview(sidebarMaterial)

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 16
        content.edgeInsets = NSEdgeInsets(top: 14, left: 12, bottom: 18, right: 12)

        let fileSection = section(title: "FILES", symbol: "doc")
        let fileButton = NSButton(title: "Open CSV…", target: self, action: #selector(openFileClicked(_:)))
        fileButton.bezelStyle = .rounded
        fileButton.controlSize = .small
        fileButton.alignment = .left
        fileButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Open")
        fileButton.imagePosition = .imageLeading
        fileStack.orientation = .vertical
        fileStack.alignment = .leading
        fileStack.spacing = 4
        let fileGroup = NSStackView(views: [fileValue, fileStack, fileButton])
        fileGroup.orientation = .vertical
        fileGroup.alignment = .leading
        fileGroup.spacing = 6
        fileSection.addArrangedSubview(fileGroup)

        let bookmarkSection = section(title: "BOOKMARKS", symbol: "bookmark")
        let addButton = NSButton(title: "Add current view", target: self, action: #selector(addBookmarkClicked(_:)))
        addButton.isBordered = false
        addButton.bezelStyle = .texturedRounded
        addButton.showsBorderOnlyWhileMouseInside = true
        addButton.controlSize = .small
        addButton.alignment = .left
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add bookmark")
        addButton.imagePosition = .imageLeading
        bookmarkStack.orientation = .vertical
        bookmarkStack.alignment = .leading
        bookmarkStack.spacing = 4
        bookmarkSection.addArrangedSubview(bookmarkStack)
        bookmarkSection.addArrangedSubview(addButton)

        content.addArrangedSubview(fileSection)
        content.addArrangedSubview(bookmarkSection)
        scrollView.documentView = content
        addSubview(scrollView)
        sidebarMaterial.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            sidebarMaterial.leadingAnchor.constraint(equalTo: leadingAnchor),
            sidebarMaterial.trailingAnchor.constraint(equalTo: trailingAnchor),
            sidebarMaterial.topAnchor.constraint(equalTo: topAnchor),
            sidebarMaterial.bottomAnchor.constraint(equalTo: bottomAnchor),
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

    @objc private func recentFileClicked(_ sender: NSButton) {
        guard recentFiles.indices.contains(sender.tag) else { return }
        onSelectRecentFile?(recentFiles[sender.tag])
    }

    @objc private func addBookmarkClicked(_ sender: Any?) { onAddBookmark?() }

    @objc private func bookmarkClicked(_ sender: NSButton) {
        guard bookmarks.indices.contains(sender.tag) else { return }
        onSelectBookmark?(bookmarks[sender.tag])
    }
}
