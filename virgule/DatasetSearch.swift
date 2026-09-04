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
    var onOptionsChanged: ((String?, Bool) -> Void)?
    var onDismiss: (() -> Void)?

    private let columnPopup = NSPopUpButton()
    private let regexButton = NSButton(checkboxWithTitle: "Regex", target: nil, action: nil)
    private let closeButton = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close search")!, target: nil, action: nil)
    private let messageLabel = NSTextField(labelWithString: "")
    private var columns: [String] = []

    var selectedColumn: String? {
        columnPopup.selectedItem?.representedObject as? String
    }

    var usesRegularExpression: Bool {
        regexButton.state == .on
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        columnPopup.target = self
        columnPopup.action = #selector(optionsChanged(_:))
        regexButton.target = self
        regexButton.action = #selector(optionsChanged(_:))
        regexButton.setContentHuggingPriority(.required, for: .horizontal)
        regexButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        regexButton.toolTip = "Interpret the search text as a regular expression"

        closeButton.target = self
        closeButton.action = #selector(dismissSearch(_:))
        closeButton.bezelStyle = .inline
        closeButton.toolTip = "Close search"
        closeButton.setContentHuggingPriority(.required, for: .horizontal)
        closeButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        messageLabel.textColor = .systemRed
        messageLabel.font = .systemFont(ofSize: 11)
        messageLabel.lineBreakMode = .byTruncatingTail

        let stack = NSStackView(views: [columnPopup, regexButton, messageLabel, closeButton])
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
            columnPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 150),
        ])
        columnPopup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
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
        regexButton.state = .off
        columnPopup.selectItem(at: 0)
        messageLabel.stringValue = ""
    }

    func validateRegularExpression(_ text: String) -> Bool {
        if regexButton.state == .on {
            do {
                _ = try NSRegularExpression(pattern: text)
                messageLabel.stringValue = ""
            } catch {
                messageLabel.stringValue = "Invalid regular expression"
                return false
            }
        } else {
            messageLabel.stringValue = ""
        }
        return true
    }

    @objc private func optionsChanged(_ sender: Any?) {
        onOptionsChanged?(selectedColumn, usesRegularExpression)
    }

    @objc private func dismissSearch(_ sender: Any?) {
        onDismiss?()
    }
}
