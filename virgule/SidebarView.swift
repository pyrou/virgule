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

private final class SidebarItem {
    enum Kind { case section, file, bookmark }
    let title: String
    let kind: Kind
    let url: URL?
    let bookmark: SidebarBookmark?
    var children: [SidebarItem] = []

    init(title: String, kind: Kind, url: URL? = nil, bookmark: SidebarBookmark? = nil) {
        self.title = title
        self.kind = kind
        self.url = url
        self.bookmark = bookmark
    }
}

final class SidebarView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    var onOpenFile: (() -> Void)?
    var onSelectRecentFile: ((URL) -> Void)?
    var onSelectBookmark: ((SidebarBookmark) -> Void)?
    var onAddBookmark: (() -> Void)?

    private let outlineView = NSOutlineView()
    private let openButton = NSButton(title: "Open CSV…", target: nil, action: nil)
    private var roots: [SidebarItem] = []
    private var recentFiles: [URL] = []
    private var bookmarks: [SidebarBookmark] = []
    private var currentSourcePath = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        buildView()
    }

    func update(sourceURL: URL?) {
        currentSourcePath = sourceURL?.path ?? ""
        if let sourceURL {
            recentFiles.removeAll { $0 == sourceURL }
            recentFiles.insert(sourceURL, at: 0)
            recentFiles = Array(recentFiles.prefix(8))
            let stored = UserDefaults.standard.data(forKey: "virgule.sidebar.bookmarks")
                .flatMap { try? JSONDecoder().decode([SidebarBookmark].self, from: $0) } ?? []
            bookmarks = stored.filter { $0.sourcePath == sourceURL.path }
        } else {
            bookmarks = []
        }
        rebuildItems()
    }

    func clearBookmarks() {
        bookmarks.removeAll()
        rebuildItems()
    }

    func addBookmark(_ bookmark: SidebarBookmark) {
        let saved = SidebarBookmark(name: bookmark.name, sql: bookmark.sql, sourcePath: currentSourcePath)
        guard !bookmarks.contains(saved) else { return }
        bookmarks.append(saved)
        var all = UserDefaults.standard.data(forKey: "virgule.sidebar.bookmarks")
            .flatMap { try? JSONDecoder().decode([SidebarBookmark].self, from: $0) } ?? []
        all.removeAll { $0.sourcePath == saved.sourcePath && $0.name == saved.name }
        all.append(saved)
        if let data = try? JSONEncoder().encode(all) {
            UserDefaults.standard.set(data, forKey: "virgule.sidebar.bookmarks")
        }
        rebuildItems()
    }

    private func rebuildItems() {
        let files = SidebarItem(title: "FILES", kind: .section)
        files.children = recentFiles.map { SidebarItem(title: $0.lastPathComponent, kind: .file, url: $0) }
        let saved = SidebarItem(title: "BOOKMARKS", kind: .section)
        saved.children = bookmarks.map { SidebarItem(title: $0.name, kind: .bookmark, bookmark: $0) }
        roots = [files, saved]
        outlineView.reloadData()
        roots.forEach { outlineView.expandItem($0) }
    }

    private func buildView() {
        let material = NSVisualEffectView()
        material.material = .sidebar
        material.blendingMode = .withinWindow
        material.state = .active
        addSubview(material)

        outlineView.headerView = nil
        outlineView.delegate = self
        outlineView.dataSource = self
        outlineView.style = .sourceList
        outlineView.rowSizeStyle = .default
        outlineView.selectionHighlightStyle = .regular
        outlineView.floatsGroupRows = false
        outlineView.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Sidebar")))
        outlineView.outlineTableColumn = outlineView.tableColumns[0]
        outlineView.indentationPerLevel = 16
        outlineView.backgroundColor = .clear

        let scrollView = NSScrollView()
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true

        openButton.target = self
        openButton.action = #selector(openFileClicked(_:))
        openButton.bezelStyle = .rounded
        openButton.controlSize = .small
        openButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Open")
        openButton.imagePosition = .imageLeading

        addSubview(scrollView)
        addSubview(openButton)
        material.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        openButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            material.leadingAnchor.constraint(equalTo: leadingAnchor), material.trailingAnchor.constraint(equalTo: trailingAnchor),
            material.topAnchor.constraint(equalTo: topAnchor), material.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor), scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor), scrollView.bottomAnchor.constraint(equalTo: openButton.topAnchor, constant: -8),
            openButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            openButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12), openButton.heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? SidebarItem)?.children.count ?? roots.count
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? SidebarItem)?.kind == .section
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let item = item as? SidebarItem { return item.children[index] }
        return roots[index]
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? SidebarItem else { return nil }
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: item.title)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        if item.kind == .section {
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .secondaryLabelColor
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor), label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        } else {
            let icon = NSImageView(image: NSImage(systemSymbolName: item.kind == .file ? "doc" : "bookmark", accessibilityDescription: nil) ?? NSImage())
            icon.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(icon)
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8), icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor), icon.widthAnchor.constraint(equalToConstant: 16),
                label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7), label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8), label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            if let url = item.url { label.toolTip = url.path }
            if let bookmark = item.bookmark {
                cell.toolTip = "Source: \(bookmark.sourcePath)\nBookmarked \(Self.dateFormatter.string(from: bookmark.createdAt))\n\(bookmark.sql)"
            }
        }
        cell.addSubview(label)
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let item = item as? SidebarItem else { return false }
        if let url = item.url { onSelectRecentFile?(url) }
        if let bookmark = item.bookmark { onSelectBookmark?(bookmark) }
        return item.kind != .section
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter(); formatter.dateStyle = .medium; formatter.timeStyle = .short; return formatter
    }()

    @objc private func openFileClicked(_ sender: Any?) { onOpenFile?() }
}
