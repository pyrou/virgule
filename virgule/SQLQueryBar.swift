import AppKit

/// Translates the friendly names shown in the editor to the names understood
/// by the local SQLite cache. The projection also retains enough position
/// information to report SQLite errors against the text the person sees.
struct SQLQueryPresentation {
    let sourcePath: String

    static let portableSource = "$file"
    static let internalRowID = "$virgule_row_id"
    private static let engineSource = "csv"
    private static let engineRowID = "\"__virgule_row_id\""

    func engineSQL(for displayedSQL: String) -> String {
        project(displayedSQL).engineSQL
    }

    func displayedError(_ message: String, for displayedSQL: String) -> String {
        let projection = project(displayedSQL)
        var displayedMessage = message
            .replacingOccurrences(of: "__virgule_row_id", with: Self.internalRowID)
        if !sourcePath.isEmpty {
            displayedMessage = displayedMessage.replacingOccurrences(of: "csv", with: sourcePath)
        }
        guard let range = displayedMessage.range(of: #"at line ([0-9]+), column ([0-9]+)"#, options: .regularExpression) else { return displayedMessage }
        let coordinates = String(displayedMessage[range])
            .components(separatedBy: CharacterSet.decimalDigits.inverted)
            .compactMap(Int.init)
        guard coordinates.count == 2,
              let displayed = projection.displayedLocation(line: coordinates[0], column: coordinates[1]) else {
            return displayedMessage
        }
        return displayedMessage.replacingCharacters(in: range, with: "at line \(displayed.line), column \(displayed.column)")
    }

    private func project(_ displayedSQL: String) -> Projection {
        let replacements = [(sourcePath, Self.engineSource), (Self.portableSource, Self.engineSource), (Self.internalRowID, Self.engineRowID)]
        var engine = ""
        var displayedOffsets = [0]
        var displayedOffset = 0
        let scalars = Array(displayedSQL.unicodeScalars)
        var index = 0
        var state = LexerState.code

        func append(_ engineText: String, displayedLength: Int) {
            let engineLength = engineText.unicodeScalars.count
            engine += engineText
            if engineLength == 0 { return }
            for offset in 1...engineLength {
                // SQLite only reports token boundaries. Mapping intermediate
                // characters to the token start still produces a useful,
                // visible location for an error within a substituted token.
                displayedOffsets.append(offset == engineLength ? displayedOffset + displayedLength : displayedOffset)
            }
            displayedOffset += displayedLength
        }

        while index < scalars.count {
            let scalar = scalars[index]
            switch state {
            case .code:
                if scalar == "'" { state = .singleQuote }
                else if scalar == "\"" { state = .doubleQuote }
                else if scalar == "-", index + 1 < scalars.count, scalars[index + 1] == "-" { state = .lineComment }
                else if scalar == "/", index + 1 < scalars.count, scalars[index + 1] == "*" { state = .blockComment }

                if let replacement = replacements.first(where: { candidate in
                    let token = Array(candidate.0.unicodeScalars)
                    guard !token.isEmpty, index + token.count <= scalars.count else { return false }
                    if candidate.0 == Self.portableSource {
                        let identifierCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_.$/"))
                        if index > 0, identifierCharacters.contains(scalars[index - 1]) { return false }
                        let end = index + token.count
                        if end < scalars.count, identifierCharacters.contains(scalars[end]) { return false }
                    }
                    return Array(scalars[index..<(index + token.count)]) == token
                }) {
                    append(replacement.1, displayedLength: replacement.0.unicodeScalars.count)
                    index += replacement.0.unicodeScalars.count
                    continue
                }
            case .singleQuote:
                if scalar == "'" {
                    if index + 1 < scalars.count, scalars[index + 1] == "'" {
                        append("''", displayedLength: 2)
                        index += 2
                        continue
                    }
                    state = .code
                }
            case .doubleQuote:
                if scalar == "\"" {
                    if index + 1 < scalars.count, scalars[index + 1] == "\"" {
                        append("\"\"", displayedLength: 2)
                        index += 2
                        continue
                    }
                    state = .code
                }
            case .lineComment:
                if scalar == "\n" { state = .code }
            case .blockComment:
                if scalar == "*", index + 1 < scalars.count, scalars[index + 1] == "/" {
                    append("*/", displayedLength: 2)
                    index += 2
                    state = .code
                    continue
                }
            }
            append(String(scalar), displayedLength: 1)
            index += 1
        }
        return Projection(engineSQL: engine, displayedSQL: displayedSQL, displayedOffsets: displayedOffsets)
    }

    private enum LexerState { case code, singleQuote, doubleQuote, lineComment, blockComment }

    private struct Projection {
        let engineSQL: String
        let displayedSQL: String
        let displayedOffsets: [Int]

        func displayedLocation(line: Int, column: Int) -> (line: Int, column: Int)? {
            guard line > 0, column > 0 else { return nil }
            let engineLines = engineSQL.split(separator: "\n", omittingEmptySubsequences: false)
            guard line <= engineLines.count else { return nil }
            let prefixLength = engineLines.prefix(line - 1).reduce(0) { $0 + $1.unicodeScalars.count + 1 }
            let engineOffset = prefixLength + min(column - 1, engineLines[line - 1].unicodeScalars.count)
            guard displayedOffsets.indices.contains(engineOffset) else { return nil }
            let displayedScalars = Array(displayedSQL.unicodeScalars)
            let displayedOffset = displayedOffsets[engineOffset]
            let before = displayedScalars.prefix(displayedOffset)
            let displayedLine = before.filter { $0 == "\n" }.count + 1
            let displayedColumn = before.reversed().prefix(while: { $0 != "\n" }).count + 1
            return (displayedLine, displayedColumn)
        }
    }
}

/// A compact, multi-line SQL editor. AppKit's attributed text storage gives us
/// syntax colours without bringing a web editor or a third-party dependency
/// into the native application.
final class SQLQueryBar: NSView, NSTextViewDelegate {
    let textView = SQLQueryTextView()
    private let formatButton = NSButton(title: "Format", target: nil, action: nil)
    private let undoButton = NSButton(title: "", target: nil, action: nil)
    private let redoButton = NSButton(title: "", target: nil, action: nil)
    private let copyButton = NSButton(title: "", target: nil, action: nil)
    private let historyButton = NSButton(title: "", target: nil, action: nil)
    private let helpButton = NSButton(title: "?", target: nil, action: nil)
    private let validationLabel = NSTextField(labelWithString: "")
    private var historyMenu = NSMenu()

    /// Invoked with the complete multi-line query when the user presses
    /// Command-Return. The owner can execute it asynchronously without making
    /// the editor responsible for data access.
    var onExecute: ((String) -> Void)?
    /// Called after every user edit so validation can remain outside this view
    /// and run against the active SQLite cache without blocking typing.
    var onSQLChanged: ((String) -> Void)?

    /// The imported CSV schema. It is kept separate from query result headers
    /// so completion remains useful while a newly entered query is validated.
    var completionColumns: [String] = []
    /// Friendly table name shown in generated queries. It is display-only;
    /// `SQLQueryPresentation` converts it before SQLite sees the query.
    var sourcePath: String? {
        didSet { highlightSyntax() }
    }

    private(set) var validationMessage: String?
    /// Most-recent-first, de-duplicated queries executed from this editor.
    /// It is intentionally kept in memory: CSV views are local and transient.
    private(set) var queryHistory: [String] = []

    var sql: String {
        get { textView.string }
        set {
            textView.string = newValue
            highlightSyntax()
            setValidationMessage(nil)
            updateEditingControls()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 4, right: 0)
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.textContainerInset = NSSize(width: 10, height: 8)
        textView.minSize = NSSize(width: 0, height: 58)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = self
        textView.onCommandReturn = { [weak self] in
            self?.executeQuery()
        }
        textView.onFormat = { [weak self] in
            self?.prettyPrint()
        }
        scrollView.documentView = textView

        configureButton(formatButton, title: "Format", toolTip: "Pretty print SQL (Command-Shift-F)", action: #selector(prettyPrint(_:)))
        formatButton.font = .systemFont(ofSize: 11, weight: .medium)
        configureButton(undoButton, symbol: "arrow.uturn.backward", toolTip: "Undo (Command-Z)", action: #selector(undo(_:)))
        configureButton(redoButton, symbol: "arrow.uturn.forward", toolTip: "Redo (Command-Shift-Z)", action: #selector(redo(_:)))
        configureButton(copyButton, symbol: "doc.on.doc", toolTip: "Copy SQL", action: #selector(copyQuery(_:)))
        configureButton(historyButton, symbol: "clock.arrow.circlepath", toolTip: "Query history", action: #selector(showHistory(_:)))
        configureButton(helpButton, title: "?", toolTip: "Help for the function or operator at the cursor", action: #selector(showQuickHelp(_:)))

        validationLabel.font = .systemFont(ofSize: 11)
        validationLabel.textColor = .systemRed
        validationLabel.lineBreakMode = .byTruncatingTail
        validationLabel.isHidden = true

        let actions = NSStackView(views: [undoButton, redoButton, copyButton, historyButton, helpButton, formatButton])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 2
        actions.translatesAutoresizingMaskIntoConstraints = false

        let footer = NSStackView(views: [validationLabel, NSView(), actions])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 6
        footer.translatesAutoresizingMaskIntoConstraints = false

        let footerSeparator = NSBox()
        footerSeparator.boxType = .separator
        footerSeparator.translatesAutoresizingMaskIntoConstraints = false

        addSubview(scrollView)
        addSubview(footerSeparator)
        addSubview(footer)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -2),
            footer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            footer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            footer.heightAnchor.constraint(equalToConstant: 24),
            footerSeparator.leadingAnchor.constraint(equalTo: leadingAnchor),
            footerSeparator.trailingAnchor.constraint(equalTo: trailingAnchor),
            footerSeparator.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -1),
        ])
        highlightSyntax()
        updateEditingControls()
    }

    private func configureButton(_ button: NSButton, title: String? = nil, symbol: String? = nil, toolTip: String, action: Selector) {
        button.bezelStyle = .inline
        button.target = self
        button.action = action
        button.toolTip = toolTip
        button.setAccessibilityLabel(toolTip)
        if let title { button.title = title }
        if let symbol {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: toolTip)
            button.imagePosition = .imageOnly
        }
    }

    private func updateEditingControls() {
        undoButton.isEnabled = textView.undoManager?.canUndo ?? false
        redoButton.isEnabled = textView.undoManager?.canRedo ?? false
        copyButton.isEnabled = !sql.isEmpty
        historyButton.isEnabled = !queryHistory.isEmpty
    }

    func textDidChange(_ notification: Notification) {
        highlightSyntax()
        setValidationMessage(nil)
        updateEditingControls()
        onSQLChanged?(sql)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        updateEditingControls()
    }

    /// Supplies AppKit's native completion panel. NSTextView replaces exactly
    /// `partialWordRange`, so quoted source headers remain safe identifiers.
    func textView(
        _ textView: NSTextView,
        completions words: [String],
        forPartialWordRange charRange: NSRange,
        indexOfSelectedItem index: UnsafeMutablePointer<Int>?
    ) -> [String] {
        index?.pointee = -1
        return Self.completionCandidates(
            for: textView.string,
            cursor: NSMaxRange(charRange),
            columns: completionColumns
        )
    }

    /// Runs the editor action. Kept separate from key handling so callers and
    /// tests can invoke the same Command-Return behavior directly.
    func executeQuery() {
        let query = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        recordInHistory(query)
        onExecute?(sql)
    }

    private func recordInHistory(_ query: String) {
        queryHistory.removeAll { $0 == query }
        queryHistory.insert(query, at: 0)
        queryHistory = Array(queryHistory.prefix(20))
        updateEditingControls()
    }

    @objc private func undo(_ sender: Any?) {
        textView.undoManager?.undo()
        updateEditingControls()
    }

    @objc private func redo(_ sender: Any?) {
        textView.undoManager?.redo()
        updateEditingControls()
    }

    @objc private func copyQuery(_ sender: Any?) {
        _ = copyQuery(to: .general)
    }

    @discardableResult
    func copyQuery(to pasteboard: NSPasteboard) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(sql, forType: .string)
    }

    @objc private func showHistory(_ sender: Any?) {
        historyMenu.removeAllItems()
        for query in queryHistory {
            let item = NSMenuItem(title: Self.historyTitle(for: query), action: #selector(selectHistoryItem(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = query
            item.toolTip = query
            historyMenu.addItem(item)
        }
        historyMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: historyButton.bounds.maxY), in: historyButton)
    }

    @objc private func selectHistoryItem(_ sender: NSMenuItem) {
        guard let query = sender.representedObject as? String else { return }
        sql = query
        textView.setSelectedRange(NSRange(location: (query as NSString).length, length: 0))
        onSQLChanged?(sql)
    }

    static func historyTitle(for query: String) -> String {
        let oneLine = query.components(separatedBy: .newlines).joined(separator: " ")
        return oneLine.count > 72 ? String(oneLine.prefix(69)) + "…" : oneLine
    }

    @objc private func showQuickHelp(_ sender: Any?) {
        guard let help = Self.quickHelp(for: sql, selectedRange: textView.selectedRange()) else {
            NSSound.beep()
            return
        }
        let menu = NSMenu()
        let title = NSMenuItem(title: help.title, action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        let detail = NSMenuItem(title: help.detail, action: nil, keyEquivalent: "")
        detail.isEnabled = false
        menu.addItem(detail)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: helpButton.bounds.maxY), in: helpButton)
    }

    /// Shows the latest asynchronous validation result below the editor. A
    /// nil value represents a syntactically valid query.
    func setValidationMessage(_ message: String?) {
        validationMessage = message
        validationLabel.stringValue = message ?? ""
        validationLabel.isHidden = message == nil
        setAccessibilityValue(message)
    }

    /// Rewrites only SQL whitespace and keyword casing. String literals,
    /// quoted identifiers, and comments are deliberately retained verbatim.
    @objc func prettyPrint(_ sender: Any? = nil) {
        sql = Self.prettyPrintedSQL(for: sql)
    }

    private func highlightSyntax() {
        let selectedRange = textView.selectedRange()
        let attributed = Self.highlightedText(for: textView.string, sourcePath: sourcePath)
        textView.textStorage?.setAttributedString(attributed)
        textView.setSelectedRange(selectedRange)
    }

    static func highlightedText(for sql: String, sourcePath: String? = nil) -> NSAttributedString {
        let range = NSRange(sql.startIndex..., in: sql)
        let result = NSMutableAttributedString(
            string: sql,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                .foregroundColor: NSColor.labelColor,
            ]
        )
        guard range.length > 0 else { return result }

        let apply = { (pattern: String, colour: NSColor) in
            guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                return
            }
            expression.enumerateMatches(in: sql, range: range) { match, _, _ in
                guard let match else { return }
                result.addAttribute(.foregroundColor, value: colour, range: match.range)
            }
        }

        apply("\\b(SELECT|FROM|WHERE|AS|AND|OR|NOT|NULL|IS|IN|LIKE|BETWEEN|CASE|WHEN|THEN|ELSE|END|JOIN|INNER|LEFT|RIGHT|OUTER|ON|GROUP|BY|HAVING|ORDER|ASC|DESC|LIMIT|OFFSET|DISTINCT|WITH|UNION|ALL|EXPLAIN|QUERY|PLAN)\\b", .systemPurple)
        apply("\\b(COUNT|SUM|AVG|MIN|MAX|COALESCE|LOWER|UPPER|LENGTH|ROUND|SUBSTR|CAST|DATE|DATETIME)\\s*(?=\\()", .systemBlue)
        apply("'(?:''|[^'])*'|\\\"(?:\\\"\\\"|[^\\\"])*\\\"", .systemRed)
        apply("\\b\\d+(?:\\.\\d+)?\\b", .systemOrange)
        apply("--[^\\n]*|/\\*[\\s\\S]*?\\*/", .secondaryLabelColor)
        if let sourcePath, !sourcePath.isEmpty {
            apply(NSRegularExpression.escapedPattern(for: sourcePath), .systemTeal)
        }
        apply(#"(?<![\w.$/])\$file(?![\w.$/])"#, .systemTeal)
        // The muted colour separates Virgule's stable ordering key from source
        // columns, which retain the normal identifier/string appearance.
        apply("\\$virgule_row_id\\b", .tertiaryLabelColor)
        return result
    }

    static func prettyPrintedSQL(for sql: String) -> String {
        SQLPrettyPrinter.format(sql)
    }

    /// Returns suggestions appropriate for the word that begins at `cursor`.
    /// This deliberately uses the SQL preceding the cursor: it is fast enough
    /// to run for every keypress and does not need to query SQLite on the main
    /// thread.
    static func completionCandidates(for sql: String, cursor: Int, columns: [String]) -> [String] {
        let length = (sql as NSString).length
        let safeCursor = min(max(0, cursor), length)
        let prefix = (sql as NSString).substring(to: safeCursor)
        let wordCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_$"))
        let partial = prefix.components(separatedBy: wordCharacters.inverted).last ?? ""
        let priorWords = prefix
            .dropLast(partial.count)
            .uppercased()
            .components(separatedBy: wordCharacters.inverted)
            .filter { !$0.isEmpty }
        let previous = priorWords.last ?? ""

        let candidates: [String]
        if ["FROM", "JOIN", "INTO", "UPDATE"].contains(previous) {
            candidates = ["csv", SQLQueryPresentation.portableSource]
        } else if partial.uppercased().hasPrefix("EXPL") {
            candidates = ["EXPLAIN", "EXPLAIN QUERY PLAN"]
        } else {
            candidates = SQLCompletion.keywords + SQLCompletion.functions + columns.map(SQLCompletion.identifier)
        }

        return Array(Set(candidates))
            .filter {
                let comparable = $0.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                return partial.isEmpty || comparable.range(of: partial, options: [.caseInsensitive, .anchored]) != nil
            }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Returns concise SQLite-oriented help for the token under the current
    /// selection or insertion point. Keeping this pure makes the help content
    /// available to tests without presenting an AppKit menu.
    static func quickHelp(for sql: String, selectedRange: NSRange) -> SQLQuickHelp? {
        let text = sql as NSString
        guard text.length > 0 else { return nil }
        let location = min(max(0, selectedRange.location), text.length)
        let range: NSRange
        if selectedRange.length > 0, NSMaxRange(selectedRange) <= text.length {
            range = selectedRange
        } else {
            let index = location == text.length ? location - 1 : location
            let character = text.character(at: index)
            let wordCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
            let operatorCharacters = CharacterSet(charactersIn: "=!<>|+-*/%")
            guard wordCharacters.contains(UnicodeScalar(character)!) || operatorCharacters.contains(UnicodeScalar(character)!) else {
                return nil
            }
            let accepted = wordCharacters.contains(UnicodeScalar(character)!) ? wordCharacters : operatorCharacters
            var start = index
            var end = index + 1
            while start > 0, accepted.contains(UnicodeScalar(text.character(at: start - 1))!) { start -= 1 }
            while end < text.length, accepted.contains(UnicodeScalar(text.character(at: end))!) { end += 1 }
            range = NSRange(location: start, length: end - start)
        }
        return SQLQuickHelp.lookup(text.substring(with: range))
    }
}

struct SQLQuickHelp: Equatable {
    let title: String
    let detail: String

    static func lookup(_ rawToken: String) -> SQLQuickHelp? {
        let token = rawToken.uppercased()
        let entries: [String: String] = [
            "COUNT": "COUNT(expression) returns the number of non-NULL values; COUNT(*) counts rows.",
            "SUM": "SUM(expression) returns the total of numeric values.",
            "AVG": "AVG(expression) returns the average of numeric values.",
            "MIN": "MIN(expression) returns the smallest non-NULL value.",
            "MAX": "MAX(expression) returns the largest non-NULL value.",
            "COALESCE": "COALESCE(value, fallback, …) returns the first non-NULL argument.",
            "IFNULL": "IFNULL(value, fallback) returns fallback when value is NULL.",
            "NULLIF": "NULLIF(a, b) returns NULL when a equals b; otherwise it returns a.",
            "LOWER": "LOWER(text) converts ASCII letters in text to lower case.",
            "UPPER": "UPPER(text) converts ASCII letters in text to upper case.",
            "LENGTH": "LENGTH(value) returns the number of characters in text or bytes in a blob.",
            "ROUND": "ROUND(number, digits) rounds a number; digits is optional.",
            "SUBSTR": "SUBSTR(text, start, length) extracts part of text; length is optional.",
            "CAST": "CAST(value AS type) converts a value to a SQLite storage class.",
            "DATE": "DATE(value, modifiers…) returns an ISO-8601 date string.",
            "DATETIME": "DATETIME(value, modifiers…) returns an ISO-8601 date-time string.",
            "STRFTIME": "STRFTIME(format, value, modifiers…) formats a date or time.",
            "=": "Equal to.",
            "!=": "Not equal to.",
            "<>": "Not equal to.",
            "<": "Less than.",
            "<=": "Less than or equal to.",
            ">": "Greater than.",
            ">=": "Greater than or equal to.",
            "||": "Concatenates two text values.",
            "+": "Adds numeric values.",
            "-": "Subtracts numeric values.",
            "*": "Multiplies numeric values; in COUNT(*) it means every row.",
            "/": "Divides numeric values.",
            "%": "Returns the integer remainder.",
            "LIKE": "LIKE compares text against a pattern; % matches many characters and _ one character.",
            "IN": "IN matches a value against a list or subquery.",
            "IS": "IS compares values including NULL; use IS NULL or IS NOT NULL.",
            "BETWEEN": "BETWEEN tests whether a value is within an inclusive range.",
            "AND": "AND is true only when both conditions are true.",
            "OR": "OR is true when either condition is true.",
            "NOT": "NOT negates a condition."
        ]
        guard let detail = entries[token] else { return nil }
        return SQLQuickHelp(title: token, detail: detail)
    }
}

/// Preserves Return for multi-line editing while reserving Command-Return for
/// query execution, matching native macOS editor conventions.
final class SQLQueryTextView: NSTextView {
    var onCommandReturn: (() -> Void)?
    var onFormat: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isReturn = event.charactersIgnoringModifiers == "\r" || event.charactersIgnoringModifiers == "\n"
        if modifiers.contains(.command), isReturn {
            onCommandReturn?()
            return
        }
        if modifiers.contains([.command, .shift]), event.charactersIgnoringModifiers?.lowercased() == "f" {
            onFormat?()
            return
        }
        if modifiers == .control, event.charactersIgnoringModifiers == " " {
            complete(nil)
            return
        }
        super.keyDown(with: event)
    }

}

private enum SQLCompletion {
    static let keywords = [
        "SELECT", "FROM", "WHERE", "AS", "AND", "OR", "NOT", "NULL", "IS", "IN", "LIKE", "BETWEEN",
        "CASE", "WHEN", "THEN", "ELSE", "END", "JOIN", "INNER", "LEFT", "RIGHT", "OUTER", "ON",
        "GROUP", "BY", "HAVING", "ORDER", "ASC", "DESC", "LIMIT", "OFFSET", "DISTINCT", "WITH",
        "UNION", "ALL", "EXPLAIN", "EXPLAIN QUERY PLAN"
    ]
    static let functions = [
        "COUNT", "SUM", "AVG", "MIN", "MAX", "COALESCE", "LOWER", "UPPER", "LENGTH", "ROUND",
        "SUBSTR", "CAST", "DATE", "DATETIME", "STRFTIME", "IFNULL", "NULLIF"
    ]

    nonisolated static func identifier(_ name: String) -> String {
        let simpleIdentifier = name.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil
        return simpleIdentifier ? name : "\"\(name.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}

private enum SQLPrettyPrinter {
    private enum Token: Equatable {
        case word(String)
        case quoted(String)
        case comment(String)
        case symbol(Character)
        case `operator`(String)
    }

    private static let keywords: Set<String> = [
        "SELECT", "FROM", "WHERE", "AS", "AND", "OR", "NOT", "NULL", "IS", "IN", "LIKE", "BETWEEN",
        "CASE", "WHEN", "THEN", "ELSE", "END", "JOIN", "INNER", "LEFT", "RIGHT", "OUTER", "ON",
        "GROUP", "BY", "HAVING", "ORDER", "ASC", "DESC", "LIMIT", "OFFSET", "DISTINCT", "WITH",
        "UNION", "ALL", "EXPLAIN", "QUERY", "PLAN", "INSERT", "UPDATE", "DELETE", "VALUES", "SET"
    ]
    private static let clauseStarters: Set<String> = [
        "SELECT", "FROM", "WHERE", "HAVING", "LIMIT", "OFFSET", "UNION", "EXPLAIN", "INSERT", "UPDATE", "DELETE"
    ]

    static func format(_ sql: String) -> String {
        let tokens = tokenize(sql)
        guard !tokens.isEmpty else { return sql }

        var lines: [String] = []
        var current = ""
        var indentation = 0
        var parenthesisBlocks: [Bool] = []
        var previousWord = ""

        func append(_ value: String, spaceBefore: Bool = true) {
            if spaceBefore, !current.isEmpty, !current.hasSuffix(" ") { current += " " }
            current += value
        }
        func finishLine() {
            let line = current.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return }
            lines.append(String(repeating: "    ", count: max(0, indentation)) + line)
            current = ""
        }
        func startsClause(_ word: String, next: Token?) -> Bool {
            if word == "GROUP" || word == "ORDER" {
                guard case let .word(nextWord) = next else { return false }
                return nextWord.uppercased() == "BY"
            }
            return clauseStarters.contains(word)
        }

        for (index, token) in tokens.enumerated() {
            let next = tokens.indices.contains(index + 1) ? tokens[index + 1] : nil
            switch token {
            case let .word(raw):
                let word = keywords.contains(raw.uppercased()) ? raw.uppercased() : raw
                if startsClause(word, next: next) {
                    finishLine()
                    append(word, spaceBefore: false)
                } else if word == "AND" || word == "OR" {
                    finishLine()
                    append(word, spaceBefore: false)
                } else {
                    append(word)
                }
                previousWord = word
            case let .quoted(value):
                append(value)
                previousWord = ""
            case let .comment(value):
                finishLine()
                append(value, spaceBefore: false)
                finishLine()
                previousWord = ""
            case .symbol("("):
                if previousWord == "IN" || previousWord == "EXISTS" || previousWord.isEmpty {
                    append("(")
                } else {
                    current += "("
                }
                let beginsSubquery: Bool
                if case let .word(nextWord) = next {
                    beginsSubquery = ["SELECT", "WITH"].contains(nextWord.uppercased())
                } else {
                    beginsSubquery = false
                }
                parenthesisBlocks.append(beginsSubquery)
                if beginsSubquery {
                    finishLine()
                    indentation += 1
                }
                previousWord = ""
            case .symbol(")"):
                let closesSubquery = parenthesisBlocks.popLast() ?? false
                if closesSubquery {
                    finishLine()
                    indentation = max(0, indentation - 1)
                }
                append(")", spaceBefore: false)
                previousWord = ""
            case .symbol(","):
                current = current.trimmingCharacters(in: .whitespaces) + ","
                current += " "
                previousWord = ""
            case .symbol(";"):
                current = current.trimmingCharacters(in: .whitespaces) + ";"
                finishLine()
                previousWord = ""
            case let .symbol(value):
                append(String(value))
                previousWord = ""
            case let .operator(value):
                append(value, spaceBefore: !(value == "*" && current.hasSuffix("(")))
                previousWord = ""
            }
        }
        finishLine()
        return lines.joined(separator: "\n")
    }

    private static func tokenize(_ sql: String) -> [Token] {
        var tokens: [Token] = []
        var index = sql.startIndex
        func advance(_ position: inout String.Index) { position = sql.index(after: position) }

        while index < sql.endIndex {
            let character = sql[index]
            if character.isWhitespace { advance(&index); continue }
            if character == "'" || character == "\"" {
                let quote = character
                let start = index
                advance(&index)
                while index < sql.endIndex {
                    if sql[index] == quote {
                        let afterQuote = sql.index(after: index)
                        if afterQuote < sql.endIndex, sql[afterQuote] == quote {
                            index = sql.index(after: afterQuote)
                            continue
                        }
                        advance(&index)
                        break
                    }
                    advance(&index)
                }
                tokens.append(.quoted(String(sql[start..<index])))
            } else if character == "-", sql.index(after: index) < sql.endIndex, sql[sql.index(after: index)] == "-" {
                let start = index
                while index < sql.endIndex, sql[index] != "\n" { advance(&index) }
                tokens.append(.comment(String(sql[start..<index])))
            } else if character == "/", sql.index(after: index) < sql.endIndex, sql[sql.index(after: index)] == "*" {
                let start = index
                index = sql.index(index, offsetBy: 2)
                while index < sql.endIndex {
                    if sql[index] == "*", sql.index(after: index) < sql.endIndex, sql[sql.index(after: index)] == "/" {
                        index = sql.index(index, offsetBy: 2)
                        break
                    }
                    advance(&index)
                }
                tokens.append(.comment(String(sql[start..<index])))
            } else if character.isLetter || character == "_" || character.isNumber {
                let start = index
                while index < sql.endIndex, sql[index].isLetter || sql[index].isNumber || sql[index] == "_" || sql[index] == "." {
                    advance(&index)
                }
                tokens.append(.word(String(sql[start..<index])))
            } else if "(),;".contains(character) {
                tokens.append(.symbol(character))
                advance(&index)
            } else {
                let start = index
                while index < sql.endIndex, !sql[index].isWhitespace, !"(),;'\"".contains(sql[index]) {
                    advance(&index)
                }
                tokens.append(.operator(String(sql[start..<index])))
            }
        }
        return tokens
    }
}
