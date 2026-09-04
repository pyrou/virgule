import AppKit

/// A search constraint applied to the current read-only SQL view. It wraps
/// the view instead of altering its SQL, so clearing search always restores
/// the exact preceding result.
struct DatasetSearch: Equatable {
    var text: String
    /// `nil` searches every result column; otherwise this is the column name
    /// from the current grid result.
    var column: String?
    var usesRegularExpression: Bool

    var isActive: Bool { !text.isEmpty }

    static func filteredSQL(baseSQL: String, columns: [String], search: DatasetSearch?) -> String {
        guard let search, search.isActive else { return baseSQL }
        let searchableColumns = search.column.map { [$0] } ?? columns
        guard !searchableColumns.isEmpty else { return baseSQL }

        let literal = quoteLiteral(search.text)
        let clauses = searchableColumns.map { column in
            let value = "CAST(\(quoteIdentifier(column)) AS TEXT)"
            if search.usesRegularExpression {
                return "virgule_regexp(\(literal), \(value))"
            }
            return "instr(lower(\(value)), lower(\(literal))) > 0"
        }
        let query = baseSQL.trimmingCharacters(in: CharacterSet(charactersIn: "; \n\t"))
        return "SELECT *\nFROM (\n\(query)\n) AS \"__virgule_search_view\"\nWHERE " + clauses.joined(separator: " OR ")
    }

    private static func quoteIdentifier(_ identifier: String) -> String {
        "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func quoteLiteral(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }
}

final class DatasetSearchBar: NSView {
    var onSearchChanged: ((DatasetSearch?) -> Void)?

    private let searchField = NSSearchField()
    private let columnPopup = NSPopUpButton()
    private let regexButton = NSButton(checkboxWithTitle: "Regex", target: nil, action: nil)
    private let messageLabel = NSTextField(labelWithString: "")
    private var columns: [String] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        searchField.placeholderString = "Search dataset"
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.sendsSearchStringImmediately = true

        columnPopup.target = self
        columnPopup.action = #selector(searchChanged(_:))
        regexButton.target = self
        regexButton.action = #selector(searchChanged(_:))
        regexButton.toolTip = "Interpret the search text as a regular expression"

        messageLabel.textColor = .systemRed
        messageLabel.font = .systemFont(ofSize: 11)
        messageLabel.lineBreakMode = .byTruncatingTail

        let stack = NSStackView(views: [searchField, columnPopup, regexButton, messageLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            searchField.widthAnchor.constraint(equalToConstant: 230),
            columnPopup.widthAnchor.constraint(equalToConstant: 150),
        ])
        setColumns([])
    }

    required init?(coder: NSCoder) { nil }

    func setColumns(_ columns: [String]) {
        let selected = columnPopup.selectedItem?.representedObject as? String
        self.columns = columns
        columnPopup.removeAllItems()
        columnPopup.addItem(withTitle: "All columns")
        columnPopup.lastItem?.representedObject = nil
        for column in columns {
            columnPopup.addItem(withTitle: column)
            columnPopup.lastItem?.representedObject = column
        }
        if let selected, let item = columnPopup.itemArray.first(where: { ($0.representedObject as? String) == selected }) {
            columnPopup.select(item)
        }
    }

    func clear() {
        searchField.stringValue = ""
        regexButton.state = .off
        columnPopup.selectItem(at: 0)
        messageLabel.stringValue = ""
    }

    func focusSearchField() {
        window?.makeFirstResponder(searchField)
    }

    @objc private func searchChanged(_ sender: Any?) {
        let search = DatasetSearch(
            text: searchField.stringValue,
            column: columnPopup.selectedItem?.representedObject as? String,
            usesRegularExpression: regexButton.state == .on
        )
        guard search.isActive else {
            messageLabel.stringValue = ""
            onSearchChanged?(nil)
            return
        }
        if search.usesRegularExpression {
            do {
                _ = try NSRegularExpression(pattern: search.text)
                messageLabel.stringValue = ""
            } catch {
                messageLabel.stringValue = "Invalid regular expression"
                return
            }
        } else {
            messageLabel.stringValue = ""
        }
        onSearchChanged?(search)
    }
}
