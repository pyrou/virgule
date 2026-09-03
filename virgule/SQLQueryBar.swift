import AppKit

/// A compact, multi-line SQL editor. AppKit's attributed text storage gives us
/// syntax colours without bringing a web editor or a third-party dependency
/// into the native application.
final class SQLQueryBar: NSView, NSTextViewDelegate {
    let textView = SQLQueryTextView()

    /// Invoked with the complete multi-line query when the user presses
    /// Command-Return. The owner can execute it asynchronously without making
    /// the editor responsible for data access.
    var onExecute: ((String) -> Void)?

    var sql: String {
        get { textView.string }
        set {
            textView.string = newValue
            highlightSyntax()
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
        scrollView.documentView = textView

        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        highlightSyntax()
    }

    func textDidChange(_ notification: Notification) {
        highlightSyntax()
    }

    /// Runs the editor action. Kept separate from key handling so callers and
    /// tests can invoke the same Command-Return behavior directly.
    func executeQuery() {
        onExecute?(sql)
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
        return result
    }
}

/// Preserves Return for multi-line editing while reserving Command-Return for
/// query execution, matching native macOS editor conventions.
final class SQLQueryTextView: NSTextView {
    var onCommandReturn: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isReturn = event.charactersIgnoringModifiers == "\r" || event.charactersIgnoringModifiers == "\n"
        if modifiers.contains(.command), isReturn {
            onCommandReturn?()
            return
        }
        super.keyDown(with: event)
    }
}
