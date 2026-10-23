import AppKit
import XCTest
@testable import VCode

final class KeyboardShortcutsTests: XCTestCase {
    override func setUp() { _ = NSApplication.shared }

    private func menu() -> NSMenu {
        let menu = NSMenu()
        let view = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "View"); view.submenu = submenu; menu.addItem(view)
        let find = NSMenuItem(title: "Find in Project…", action: #selector(WorkspaceController.showProjectSearch), keyEquivalent: "f")
        find.keyEquivalentModifierMask = [.command, .shift]; submenu.addItem(find)
        KeyboardShortcutCatalog.register(find)
        let back = NSMenuItem(title: "Go Back", action: #selector(WorkspaceController.goBack), keyEquivalent: "-")
        back.keyEquivalentModifierMask = .control; back.isEnabled = false; submenu.addItem(back)
        KeyboardShortcutCatalog.register(back)
        let list = NSMenuItem(title: "Keyboard Shortcuts…", action: #selector(WorkspaceController.showKeyboardShortcuts), keyEquivalent: "")
        list.identifier = KeyboardShortcutCatalog.menuIdentifier; submenu.addItem(list)
        KeyboardShortcutCatalog.register(list)
        submenu.addItem(NSMenuItem(title: "Unbound", action: #selector(WorkspaceController.refresh), keyEquivalent: ""))
        return menu
    }

    private func key(_ character: String, flags: NSEvent.ModifierFlags = .command, code: UInt16 = 0, window: NSWindow? = nil, repeated: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window?.windowNumber ?? 0,
            context: nil, characters: character, charactersIgnoringModifiers: character, isARepeat: repeated, keyCode: code)!
    }

    func testCatalogFollowsMenusFormatsKeysAndIncludesContextActions() throws {
        let menu = menu()
        var entries = KeyboardShortcutCatalog.entries(in: menu)
        XCTAssertEqual(entries.filter { $0.group == "View" }.map(\.keys), ["⇧⌘F", "⌃-", "⌘K ⌘S"])
        XCTAssertFalse(entries.contains { $0.title == "Unbound" })
        XCTAssertTrue(entries.contains { $0.title == "Go Back" }, "Disabled commands still need documentation")
        XCTAssertTrue(entries.contains { $0.keys == "⌘Click" })
        XCTAssertTrue(entries.contains { $0.keys == "Escape" })
        XCTAssertEqual(KeyboardShortcutCatalog.displayKey(String(UnicodeScalar(NSDownArrowFunctionKey)!), modifiers: .option), "⌥↓")
        XCTAssertEqual(KeyboardShortcutCatalog.displayKey("f", modifiers: [.control, .command]), "⌃⌘F")
        let newCommand = NSMenuItem(title: "New Command", action: #selector(WorkspaceController.refresh), keyEquivalent: "r")
        menu.items[0].submenu?.addItem(newCommand)
        KeyboardShortcutCatalog.register(newCommand)
        entries = KeyboardShortcutCatalog.entries(in: menu)
        XCTAssertTrue(entries.contains { $0.title == "New Command" && $0.keys == "⌘R" })
    }

    func testChordRequiresCommandKThenCommandSAndDoesNotSwallowOtherShortcuts() {
        var chord = KeyboardShortcutChord()
        XCTAssertEqual(chord.handle(key("s"), now: 0), .passThrough)
        XCTAssertEqual(chord.handle(key("k", flags: [.command, .shift]), now: 0), .passThrough)
        XCTAssertEqual(chord.handle(key("k", flags: [.command, .capsLock]), now: 1), .waiting)
        XCTAssertEqual(chord.handle(key("k", repeated: true), now: 1.1), .waiting)
        XCTAssertEqual(chord.deadline, 3)
        XCTAssertEqual(chord.handle(key("s"), now: 1.2), .open)
        XCTAssertNil(chord.deadline)
        XCTAssertEqual(chord.handle(key("k"), now: 4), .waiting)
        XCTAssertEqual(chord.handle(key("p"), now: 4.1), .passThrough)
        XCTAssertEqual(chord.handle(key("s"), now: 4.2), .passThrough)
        XCTAssertEqual(chord.handle(key("k"), now: 6), .waiting)
        XCTAssertEqual(chord.handle(key("s", flags: []), now: 6.1), .passThrough)
        XCTAssertEqual(chord.handle(key("k"), now: 8), .waiting)
        XCTAssertEqual(chord.handle(key("\u{1b}", flags: [], code: 53), now: 8.1), .cancelled)
        XCTAssertEqual(chord.handle(key("k"), now: 10), .waiting)
        XCTAssertEqual(chord.handle(key("s"), now: 12.1), .passThrough)
    }

    func testSearchFiltersCommandsModifiersAndContextWithoutEmptyGroups() {
        let controller = KeyboardShortcutsController(entries: KeyboardShortcutCatalog.entries(in: menu()))
        _ = controller.view
        controller.filter.stringValue = "cmd shift f"; controller.filterChanged()
        XCTAssertEqual(controller.rows.count, 2)
        XCTAssertTrue(controller.summary.stringValue.hasPrefix("1 action ·"))
        if case .entry(let entry) = controller.rows.last { XCTAssertEqual(entry.title, "Find in Project") }
        else { XCTFail("Expected matching shortcut") }
        controller.filter.stringValue = "引用"; controller.filterChanged()
        XCTAssertEqual(controller.rows.count, 2)
        controller.filter.stringValue = "nothing-matches"; controller.filterChanged()
        XCTAssertTrue(controller.rows.isEmpty)
        XCTAssertEqual(controller.summary.stringValue, "No matching shortcuts")
        controller.filter.stringValue = ""; controller.filterChanged()
        XCTAssertEqual(controller.rows.count, 11)
    }

    func testSystemItemsAndAlternateCopiesCannotEnterTheCatalog() throws {
        let menu = menu()
        let submenu = try XCTUnwrap(menu.items.first?.submenu)
        let fullscreen = NSMenuItem(title: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullscreen.keyEquivalentModifierMask = []
        submenu.addItem(fullscreen)
        submenu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        submenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        let alternate = try XCTUnwrap(submenu.items.first?.copy() as? NSMenuItem)
        alternate.title = "System Alternate"
        alternate.keyEquivalentModifierMask = []
        submenu.addItem(alternate)
        let entries = KeyboardShortcutCatalog.entries(in: menu)
        XCTAssertEqual(entries.count, 8)
        XCTAssertFalse(entries.contains { ["Enter Full Screen", "Quit", "Copy", "System Alternate"].contains($0.title) })
        XCTAssertEqual(entries.filter { $0.title == "Find in Project" }.map(\.keys), ["⇧⌘F"])
    }

    func testSectionHeadersStayInClippedRowsAcrossNarrowWideLayoutsAndScrolling() throws {
        let entries = (0..<8).flatMap { group in (0..<5).map { KeyboardShortcutEntry(group: "Group \(group)", title: "Command \($0)", keys: "⇧⌘F") } }
        let controller = KeyboardShortcutsController(entries: entries)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 476), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentViewController = controller
        defer { withExtendedLifetime(window) {} }
        for width: CGFloat in [760, 920, 760] {
            window.setContentSize(NSSize(width: width, height: 476))
            controller.view.layoutSubtreeIfNeeded()
            let scroll = try XCTUnwrap(controller.table.enclosingScrollView)
            XCTAssertEqual(scroll.layer?.masksToBounds, true)
            XCTAssertFalse(controller.table.floatsGroupRows)
            for y: CGFloat in [0, 120, 400, 0] {
                scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                scroll.reflectScrolledClipView(scroll.contentView)
                controller.table.layoutSubtreeIfNeeded()
                let range = controller.table.rows(in: scroll.contentView.bounds)
                for row in range.location..<NSMaxRange(range) {
                    guard case .group = controller.rows[row] else { continue }
                    XCTAssertNotEqual(controller.table.delegate?.tableView?(controller.table, isGroupRow: row), true, "Static headings must not float out of the clip view")
                    let cell = try XCTUnwrap(controller.table.view(atColumn: 0, row: row, makeIfNecessary: true))
                    cell.layoutSubtreeIfNeeded()
                    let label = try XCTUnwrap(cell.subviews.compactMap { $0 as? NSTextField }.first)
                    XCTAssertTrue(cell.bounds.contains(label.frame))
                    XCTAssertLessThanOrEqual(cell.frame.maxX, controller.table.bounds.maxX)
                }
            }
        }
    }

    func testWorkspaceChordMenuRepeatedOpenCloseAndFocusWithoutProject() throws {
        let previousMenu = NSApp.mainMenu
        NSApp.mainMenu = menu()
        defer { NSApp.mainMenu = previousMenu }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let controller = WorkspaceController(history: WorkspaceHistoryStore(directory: root, legacyDefaults: nil))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 580), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentViewController = controller
        defer { controller.shutdown(); withExtendedLifetime(window) {}; try? FileManager.default.removeItem(at: root) }
        let workspace = try XCTUnwrap(controller.view as? WorkspaceView)
        window.makeFirstResponder(workspace.explorer.filter)
        XCTAssertTrue(controller.handleShortcutKey(key("k", window: window)))
        XCTAssertTrue(workspace.status.message.stringValue.contains("⌘K pressed"))
        XCTAssertTrue(controller.handleShortcutKey(key("s", window: window)))
        let picker = try XCTUnwrap(controller.shortcutsPicker)
        XCTAssertFalse(workspace.status.message.stringValue.contains("⌘K pressed"))
        workspace.layoutSubtreeIfNeeded()
        XCTAssertTrue(workspace.bounds.contains(picker.view.frame))
        XCTAssertLessThanOrEqual(picker.view.frame.height, workspace.bounds.height - 104)
        controller.showKeyboardShortcuts()
        XCTAssertTrue(controller.shortcutsPicker === picker)
        picker.onDismiss?()
        XCTAssertNil(controller.shortcutsPicker)
        XCTAssertTrue((window.firstResponder as? NSTextView)?.delegate as AnyObject? === workspace.explorer.filter)
        controller.showKeyboardShortcuts(); controller.closeTab()
        XCTAssertNil(controller.shortcutsPicker, "Command-W closes help instead of its underlying file")
        controller.showKeyboardShortcuts(); controller.showHistory()
        XCTAssertNil(controller.shortcutsPicker)
        controller.showKeyboardShortcuts()
        XCTAssertTrue(controller.children.contains { $0 === controller.shortcutsPicker })
        XCTAssertEqual(controller.children.count, 2, "Search controller and one help controller only")
    }

    func testPendingChordCancelsOnClickOtherWindowAndResigningKey() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let controller = WorkspaceController(history: WorkspaceHistoryStore(directory: root, legacyDefaults: nil))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 580), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentViewController = controller
        defer { controller.shutdown(); withExtendedLifetime(window) {}; try? FileManager.default.removeItem(at: root) }
        XCTAssertTrue(controller.handleShortcutKey(key("k", window: window)))
        let click = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
        XCTAssertFalse(controller.handleShortcutKey(click))
        XCTAssertFalse(controller.handleShortcutKey(key("s", window: window)))
        XCTAssertTrue(controller.handleShortcutKey(key("k", window: window)))
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        XCTAssertFalse(controller.handleShortcutKey(key("s", window: window)))
        XCTAssertTrue(controller.handleShortcutKey(key("k", window: window)))
        XCTAssertFalse(controller.handleShortcutKey(key("s")))
        XCTAssertFalse(controller.handleShortcutKey(key("s", window: window)))
        XCTAssertNil(controller.shortcutsPicker)
    }
}
