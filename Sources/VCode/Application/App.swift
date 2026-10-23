import AppKit

@main
struct VCodeApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private var workspace: WorkspaceController!
    private let history = WorkspaceHistoryStore()
    private var windowSave: DispatchWorkItem?
    private lazy var resourceUsage = ResourceUsageWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        workspace = WorkspaceController(history: history)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1360, height: 860), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "VCode"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = Theme.canvas
        window.isOpaque = false
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 920, height: 580)
        window.isReleasedWhenClosed = false
        window.contentViewController = workspace
        window.center()
        if let saved = history.windowPlacement, saved.width.isFinite, saved.height.isFinite, saved.x.isFinite, saved.y.isFinite {
            let frame = NSRect(x: saved.x, y: saved.y, width: max(920, saved.width), height: max(580, saved.height))
            if let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(frame) }) {
                let area = screen.visibleFrame
                let size = NSSize(width: min(frame.width, area.width), height: min(frame.height, area.height))
                window.setFrame(NSRect(x: min(max(frame.minX, area.minX), area.maxX - size.width), y: min(max(frame.minY, area.minY), area.maxY - size.height), width: size.width, height: size.height), display: false)
            }
        }
        window.delegate = self
        buildMenu()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let arguments = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        if let path = arguments.first {
            workspace.open(URL(fileURLWithPath: path, isDirectory: true))
        } else if let root = history.lastFolder, history.isAvailable(root) {
            workspace.open(root)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { windowSave?.cancel(); saveWindow(); workspace?.shutdown() }
    func windowDidMove(_ notification: Notification) { scheduleWindowSave() }
    func windowDidResize(_ notification: Notification) { scheduleWindowSave() }
    private func scheduleWindowSave() {
        windowSave?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.saveWindow() }
        windowSave = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }
    private func saveWindow() {
        guard let frame = window?.frame, window?.styleMask.contains(.fullScreen) != true else { return }
        history.saveWindow(WindowPlacement(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height))
    }
    func application(_ sender: NSApplication, openFile filename: String) -> Bool { workspace?.open(URL(fileURLWithPath: filename)); return true }

    @objc private func showResourceUsage() { resourceUsage.showWindow(nil) }

    private func buildMenu() {
        let main = NSMenu()
        func submenu(_ title: String) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            item.submenu = menu
            main.addItem(item)
            return menu
        }
        func item(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String, flags: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = flags
            item.target = target
            menu.addItem(item)
        }
        let app = submenu("VCode")
        item(app, "About VCode", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), "")
        item(app, "Resource Usage…", #selector(showResourceUsage), "", target: self)
        app.addItem(.separator())
        item(app, "Hide VCode", #selector(NSApplication.hide(_:)), "h")
        app.addItem(.separator())
        item(app, "Quit VCode", #selector(NSApplication.terminate(_:)), "q")
        let file = submenu("File")
        item(file, "Open Folder…", #selector(WorkspaceController.openFolder), "o", target: workspace)
        item(file, "Quick Open…", #selector(WorkspaceController.showQuickOpen), "p", target: workspace)
        item(file, "Refresh", #selector(WorkspaceController.refresh), "r", target: workspace)
        file.addItem(.separator())
        item(file, "Close Tab", #selector(WorkspaceController.closeTab), "w", target: workspace)
        let edit = submenu("Edit")
        item(edit, "Copy", #selector(NSText.copy(_:)), "c")
        item(edit, "Select All", #selector(NSText.selectAll(_:)), "a")
        edit.addItem(.separator())
        item(edit, "Find in Project…", #selector(WorkspaceController.showProjectSearch), "f", flags: [.command, .shift], target: workspace)
        let view = submenu("View")
        item(view, "Go Back", #selector(WorkspaceController.goBack), "-", flags: .control, target: workspace)
        item(view, "Go Forward", #selector(WorkspaceController.goForward), "-", flags: [.control, .shift], target: workspace)
        view.addItem(.separator())
        item(view, "Split Editor Right", #selector(WorkspaceController.splitEditorRight), "\\", target: workspace)
        view.addItem(.separator())
        item(view, "Files", #selector(WorkspaceController.showFiles), "1", target: workspace)
        item(view, "Changes", #selector(WorkspaceController.showChanges), "2", target: workspace)
        view.addItem(.separator())
        item(view, "Next Change", #selector(WorkspaceController.nextChange), String(UnicodeScalar(NSDownArrowFunctionKey)!), flags: .option, target: workspace)
        item(view, "Previous Change", #selector(WorkspaceController.previousChange), String(UnicodeScalar(NSUpArrowFunctionKey)!), flags: .option, target: workspace)
        let window = submenu("Window")
        item(window, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        item(window, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", flags: [.command, .control])
        NSApp.mainMenu = main
        NSApp.windowsMenu = window
    }
}
