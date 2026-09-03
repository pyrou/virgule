import AppKit

final class ContentViewController: NSViewController {
    private let engine = virgule_engine_create()

    deinit {
        virgule_engine_destroy(engine)
    }

    override func loadView() {
        let label = NSTextField(labelWithString: "Open a CSV file to begin")
        label.font = .systemFont(ofSize: 20, weight: .medium)
        label.alignment = .center

        let stack = NSStackView(views: [label])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.distribution = .gravityAreas
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)

        let view = NSView()
        view.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        self.view = view
    }
}
