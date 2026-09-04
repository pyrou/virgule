import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var contentController: ContentViewController?

    func showInitialWindow() {
        guard window == nil else { return }

        let controller = ContentViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Virgule"
        window.isRestorable = false
        window.contentMinSize = NSSize(width: 640, height: 480)
        window.contentMaxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.contentViewController = controller
        let toolbar = NSToolbar(identifier: "com.fizzup.virgule.main-toolbar")
        toolbar.displayMode = .iconOnly
        toolbar.delegate = controller
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.makeKeyAndOrderFront(nil)
        window.setContentSize(NSSize(width: 960, height: 640))
        if let primaryScreen = NSScreen.screens.first {
            let visibleFrame = primaryScreen.visibleFrame
            let frame = window.frame
            window.setFrameOrigin(NSPoint(
                x: visibleFrame.midX - frame.width / 2,
                y: visibleFrame.midY - frame.height / 2
            ))
        }
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
        self.contentController = controller
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        showInitialWindow()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    @objc private func openDocument(_ sender: Any?) {
        contentController?.openCSV(sender)
    }

    @objc private func focusDatasetSearch(_ sender: Any?) {
        contentController?.focusDatasetSearch(sender)
    }

    /// Apps that construct `NSApplication` themselves do not receive a menu
    /// bar from a nib. Supplying the standard menus is what makes AppKit route
    /// Command key equivalents (including Copy, Paste and Select All) through
    /// the current responder.
    private func installMainMenu() {
        let mainMenu = NSMenu(title: "Main Menu")

        let appMenu = NSMenu(title: "Virgule")
        appMenu.addItem(withTitle: "About Virgule", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Virgule", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem(title: "Virgule", action: nil, keyEquivalent: "")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Open…", action: #selector(openDocument(_:)), keyEquivalent: "o")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let findMenu = NSMenu(title: "Find")
        findMenu.addItem(withTitle: "Find in Dataset", action: #selector(focusDatasetSearch(_:)), keyEquivalent: "f")
        let findItem = NSMenuItem(title: "Find", action: nil, keyEquivalent: "")
        findItem.submenu = findMenu
        mainMenu.addItem(findItem)

        NSApp.mainMenu = mainMenu
    }
}

@main
struct VirguleApplication {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()

        application.setActivationPolicy(.regular)
        application.delegate = delegate
        delegate.showInitialWindow()
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}
