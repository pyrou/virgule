import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

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
        toolbar.displayMode = .iconAndLabel
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
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        showInitialWindow()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
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
