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
    private let appearance = AppearanceController()
    private let icons = AppIconController()
    private let updates = UpdateController()
    private var windowSave: DispatchWorkItem?
    private lazy var resourceUsage = ResourceUsageWindowController()
    private var pendingExternalURLs: [URL] = []
    private var readyForDocuments = false
    private var closingApproved = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        appearance.start()
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
        appearance.onError = { [weak self] message in
            (self?.workspace.view as? WorkspaceView)?.status.message.stringValue = message
        }
        if let error = appearance.settings.persistenceError { appearance.onError?(error) }
        icons.onError = { [weak self] message in
            (self?.workspace.view as? WorkspaceView)?.status.message.stringValue = message
        }
        icons.start()
        updates.onError = { [weak self] message in
            (self?.workspace.view as? WorkspaceView)?.status.message.stringValue = message
        }
        updates.beforeInstall = { [weak self] in
            self?.saveWindow()
            self?.workspace?.saveReadingSession()
        }
        buildMenu()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        readyForDocuments = true
        let arguments = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }.map { URL(fileURLWithPath: $0) }
        if !pendingExternalURLs.isEmpty {
            let urls = pendingExternalURLs; pendingExternalURLs = []
            workspace.openExternal(urls)
        } else if !arguments.isEmpty {
            workspace.openExternal(arguments)
        } else if let root = history.lastFolder, history.isAvailable(root) {
            workspace.open(root)
        }
        updates.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        workspace?.saveReadingSession()
        guard let workspace, !workspace.sourceEdits.dirtyPaths.isEmpty else { return .terminateNow }
        DispatchQueue.main.async {
            workspace.prepareToClose { allowed in sender.reply(toApplicationShouldTerminate: allowed) }
        }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) { windowSave?.cancel(); saveWindow(); workspace?.shutdown() }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        workspace?.saveReadingSession()
        if closingApproved { closingApproved = false; return true }
        guard let workspace, !workspace.sourceEdits.dirtyPaths.isEmpty else { return true }
        workspace.prepareToClose { [weak self, weak sender] allowed in
            guard let self, let sender, allowed else { return }
            self.closingApproved = true
            sender.performClose(nil)
        }
        return false
    }
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
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        receiveDocuments(filenames.map { URL(fileURLWithPath: $0) })
        sender.reply(toOpenOrPrint: .success)
    }
    func application(_ application: NSApplication, open urls: [URL]) { receiveDocuments(urls) }

    private func receiveDocuments(_ urls: [URL]) {
        guard readyForDocuments else { pendingExternalURLs.append(contentsOf: urls); return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        workspace.openExternal(urls)
    }

    @objc private func showResourceUsage() { resourceUsage.showWindow(nil) }

    @objc private func showAbout() {
        var options: [NSApplication.AboutPanelOptionKey: Any] = [:]
        if let image = icons.currentImage { options[.applicationIcon] = image }
        NSApp.orderFrontStandardAboutPanel(options: options)
    }

    private func buildMenu() {
        let main = NSMenu()
        func submenu(_ title: String) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            item.submenu = menu
            main.addItem(item)
            return menu
        }
        func item(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String, flags: NSEvent.ModifierFlags = .command, target: AnyObject? = nil, includeInShortcutList: Bool = true) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = flags
            item.target = target
            menu.addItem(item)
            if includeInShortcutList { KeyboardShortcutCatalog.register(item) }
        }
        let app = submenu("VCode")
        item(app, "About VCode", #selector(showAbout), "", target: self)
        updates.addMenuItems(to: app)
        app.addItem(.separator())
        item(app, "Resource Usage…", #selector(showResourceUsage), "", target: self)
        app.addItem(.separator())
        item(app, "Hide VCode", #selector(NSApplication.hide(_:)), "h", includeInShortcutList: false)
        app.addItem(.separator())
        item(app, "Quit VCode", #selector(NSApplication.terminate(_:)), "q", includeInShortcutList: false)
        let file = submenu("File")
        item(file, "New Text Tab", #selector(WorkspaceController.newTextTab), "n", target: workspace)
        item(file, "Save Text", #selector(WorkspaceController.saveText), "s", target: workspace)
        item(file, "Save Text As…", #selector(WorkspaceController.saveTextAs), "s", flags: [.command, .shift], target: workspace)
        file.addItem(.separator())
        item(file, "Open Folder…", #selector(WorkspaceController.openFolder), "o", target: workspace)
        item(file, "Quick Open…", #selector(WorkspaceController.showQuickOpen), "p", target: workspace)
        item(file, "Refresh", #selector(WorkspaceController.refresh), "r", target: workspace)
        file.addItem(.separator())
        item(file, "Close Tab", #selector(WorkspaceController.closeTab), "w", target: workspace)
        let edit = submenu("Edit")
        StandardEditCommands.addUndoRedo(to: edit)
        edit.addItem(.separator())
        item(edit, "Cut", #selector(NSText.cut(_:)), "x", includeInShortcutList: false)
        item(edit, "Paste", #selector(NSText.paste(_:)), "v", includeInShortcutList: false)
        item(edit, "Copy", #selector(NSText.copy(_:)), "c", includeInShortcutList: false)
        item(edit, "Select All", #selector(NSText.selectAll(_:)), "a", includeInShortcutList: false)
        edit.addItem(.separator())
        item(edit, "Allow File Editing", #selector(WorkspaceController.toggleFileEditing), "", target: workspace)
        edit.addItem(.separator())
        item(edit, "Find in Editor…", #selector(WorkspaceController.findInEditor), "f", target: workspace)
        item(edit, "Find Next", #selector(WorkspaceController.findNext), "g", target: workspace)
        item(edit, "Find Previous", #selector(WorkspaceController.findPrevious), "g", flags: [.command, .shift], target: workspace)
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
        view.addItem(.separator())
        let shortcuts = NSMenuItem(title: "Keyboard Shortcuts…", action: #selector(WorkspaceController.showKeyboardShortcuts), keyEquivalent: "")
        shortcuts.identifier = KeyboardShortcutCatalog.menuIdentifier
        shortcuts.toolTip = "Keyboard Shortcuts (\(KeyboardShortcutCatalog.chord))"
        shortcuts.target = workspace
        view.addItem(shortcuts)
        KeyboardShortcutCatalog.register(shortcuts)
        view.addItem(.separator())
        appearance.addMenuItems(to: view)
        view.addItem(.separator())
        icons.addMenu(to: view)
        let window = submenu("Window")
        item(window, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m", includeInShortcutList: false)
        item(window, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", flags: [.command, .control], includeInShortcutList: false)
        NSApp.mainMenu = main
        NSApp.windowsMenu = window
    }
}
