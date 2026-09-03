import AppKit

/// A compact, multi-line SQL editor. AppKit's attributed text storage gives us
/// syntax colours without bringing a web editor or a third-party dependency
/// into the native application.
final class SQLQueryBar: NSView, NSTextViewDelegate {
    let textView = SQLQueryTextView()
    private let formatButton = NSButton(title: "Format", target: nil, action: nil)
    private let validationLabel = NSTextField(labelWithString: "")

    /// Invoked with the complete multi-line query when the user presses
    /// Command-Return. The owner can execute it asynchronously without making
    /// the editor responsible for data access.
    var onExecute: ((String) -> Void)?
    /// Called after every user edit so validation can remain outside this view
    /// and run against the active SQLite cache without blocking typing.
    var onSQLChanged: ((String) -> Void)?

    private(set) var validationMessage: String?

    var sql: String {
        get { textView.string }
        set {
            textView.string = newValue
            highlightSyntax()
            setValidationMessage(nil)
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
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.55).cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
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

        formatButton.bezelStyle = .inline
        formatButton.font = .systemFont(ofSize: 11, weight: .medium)
        formatButton.toolTip = "Pretty print SQL (Command-Shift-F)"
        formatButton.target = self
        formatButton.action = #selector(prettyPrint(_:))

        validationLabel.font = .systemFont(ofSize: 11)
        validationLabel.textColor = .systemRed
        validationLabel.lineBreakMode = .byTruncatingTail
        validationLabel.isHidden = true

        addSubview(scrollView)
        addSubview(formatButton)
        addSubview(validationLabel)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: formatButton.leadingAnchor, constant: -4),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: validationLabel.topAnchor, constant: -2),
            formatButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            formatButton.bottomAnchor.constraint(equalTo: validationLabel.topAnchor, constant: -2),
            validationLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            validationLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            validationLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
        ])
        highlightSyntax()
    }

    func textDidChange(_ notification: Notification) {
        highlightSyntax()
        setValidationMessage(nil)
        onSQLChanged?(sql)
    }

    /// Runs the editor action. Kept separate from key handling so callers and
    /// tests can invoke the same Command-Return behavior directly.
    func executeQuery() {
        onExecute?(sql)
    }

    /// Shows the latest asynchronous validation result below the editor. A
    /// nil value represents a syntactically valid query.
    func setValidationMessage(_ message: String?) {
        validationMessage = message
        validationLabel.stringValue = message ?? ""
        validationLabel.isHidden = message == nil
        layer?.borderColor = (message == nil
            ? NSColor.separatorColor.withAlphaComponent(0.55)
            : NSColor.systemRed.withAlphaComponent(0.8)
        ).cgColor
        setAccessibilityValue(message)
    }

    /// Rewrites only SQL whitespace and keyword casing. String literals,
    /// quoted identifiers, and comments are deliberately retained verbatim.
    @objc func prettyPrint(_ sender: Any? = nil) {
        sql = Self.prettyPrintedSQL(for: sql)
    }

    private func highlightSyntax() {
        let selectedRange = textView.selectedRange()
        let attributed = Self.highlightedText(for: textView.string)
        textView.textStorage?.setAttributedString(attributed)
        textView.setSelectedRange(selectedRange)
    }

    static func highlightedText(for sql: String) -> NSAttributedString {
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
        // The muted colour separates the engine's ordering key from source
        // columns, which retain the normal identifier/string appearance.
        apply("\\\"__virgule_row_id\\\"", .tertiaryLabelColor)
        return result
    }

    static func prettyPrintedSQL(for sql: String) -> String {
        SQLPrettyPrinter.format(sql)
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
        super.keyDown(with: event)
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
