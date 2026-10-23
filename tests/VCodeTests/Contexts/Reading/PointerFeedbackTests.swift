import AppKit
import XCTest
@testable import VCode

final class PointerFeedbackTests: XCTestCase {
    override func setUp() { _ = NSApplication.shared }

    func testButtonRegistersOnlyVisibleEnabledAreaAndInvalidatesWhenDisabled() {
        let window = CursorWindow(contentRect: NSRect(x: 0, y: 0, width: 120, height: 80), styleMask: [.borderless], backing: .buffered, defer: false)
        let scroll = NSScrollView()
        window.contentView = scroll
        let button = CursorButton(frame: NSRect(x: 0, y: 0, width: 300, height: 160))
        scroll.documentView = button
        scroll.layoutSubtreeIfNeeded()
        defer { withExtendedLifetime(window) {} }
        button.recorded.removeAll(); button.resetCursorRects()
        XCTAssertEqual(button.recorded, [button.visibleRect])
        XCTAssertLessThan(button.visibleRect.width, button.bounds.width)
        let invalidations = window.invalidations
        button.isEnabled = false
        XCTAssertGreaterThan(window.invalidations, invalidations)
        button.recorded.removeAll(); button.resetCursorRects()
        XCTAssertTrue(button.recorded.isEmpty)
        button.isEnabled = true
        button.isHidden = true
        button.recorded.removeAll(); button.resetCursorRects()
        XCTAssertTrue(button.recorded.isEmpty)
        button.isHidden = false
        scroll.contentView.scroll(to: NSPoint(x: 150, y: 30))
        button.recorded.removeAll(); button.resetCursorRects()
        XCTAssertEqual(button.recorded, [button.visibleRect])
    }

    func testResultHeadingsDisabledRowsAndReloadDoNotAdvertiseClicks() throws {
        let source = PointerRows()
        let table = NSTableView()
        table.addTableColumn(NSTableColumn(identifier: .init("result")))
        table.headerView = nil; table.rowHeight = 28
        table.dataSource = source; table.delegate = source
        table.target = source; table.action = #selector(PointerRows.choose(_:))
        let scroll = NSScrollView(); scroll.documentView = table
        let window = CursorWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 180), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = scroll
        defer { withExtendedLifetime(window) {}; withExtendedLifetime(source) {} }
        table.reloadData(); scroll.layoutSubtreeIfNeeded(); table.layoutSubtreeIfNeeded()
        let heading = try XCTUnwrap(table.rowView(atRow: 0, makeIfNecessary: true) as? SelectionRowView)
        let match = try XCTUnwrap(table.rowView(atRow: 1, makeIfNecessary: true) as? SelectionRowView)
        let unavailable = try XCTUnwrap(table.rowView(atRow: 2, makeIfNecessary: true) as? SelectionRowView)
        XCTAssertFalse(heading.hasClickAction)
        XCTAssertTrue(match.hasClickAction)
        XCTAssertFalse(unavailable.hasClickAction)
        table.isEnabled = false
        XCTAssertFalse(match.hasClickAction)
        table.isEnabled = true
        match.isActionEnabled = false
        XCTAssertFalse(match.hasClickAction)
        match.prepareForReuse()
        XCTAssertTrue(match.hasClickAction)
        source.count = 0; table.reloadData()
        XCTAssertFalse(match.hasClickAction)
    }

    func testTreeFoldersFilesAndExpandableSectionsUseHandExceptWhileDisabled() throws {
        let tree = FileTree()
        let window = CursorWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = tree
        defer { withExtendedLifetime(window) {} }
        let root = URL(fileURLWithPath: "/tmp/pointer-fixture")
        let state = WorkspaceState(root: root, files: ["src/a.ts"], git: GitStatus(root: root, branch: "main", changes: [GitChange(path: "src/a.ts", kind: .modified, comparison: .unstaged)], hasHead: true))
        tree.show(state, changesOnly: false)
        tree.outline.expandItem(tree.outline.item(atRow: 0))
        tree.layoutSubtreeIfNeeded()
        let folder = try XCTUnwrap(tree.outline.rowView(atRow: 0, makeIfNecessary: true) as? SelectionRowView)
        let file = try XCTUnwrap(tree.outline.rowView(atRow: 1, makeIfNecessary: true) as? SelectionRowView)
        XCTAssertTrue(folder.hasClickAction); XCTAssertTrue(file.hasClickAction)
        let invalidations = window.invalidations
        tree.outline.isEnabled = false
        XCTAssertFalse(folder.hasClickAction); XCTAssertFalse(file.hasClickAction)
        XCTAssertGreaterThan(window.invalidations, invalidations)
        tree.outline.isEnabled = true
        tree.show(state, changesOnly: true)
        tree.layoutSubtreeIfNeeded()
        let section = try XCTUnwrap(tree.outline.rowView(atRow: 0, makeIfNecessary: true) as? SelectionRowView)
        XCTAssertTrue(section.hasClickAction, "Changes sections can expand even when empty")
    }

    func testTabsAndFeedbackControlsShareNativeHandCursorRegistration() {
        let tabs = EditorTabs()
        var session = ReaderSession()
        session.open("one.ts"); session.open("two.ts")
        tabs.show(session)
        func buttons(_ view: NSView) -> [NSButton] {
            view.subviews.flatMap { ($0 as? NSButton).map { [$0] } ?? buttons($0) }
        }
        XCTAssertEqual(buttons(tabs).count, 4)
        XCTAssertTrue(buttons(tabs).allSatisfy { $0 is PointingHandButton })
        let button: NSButton = Theme.actionButton("Files")
        XCTAssertTrue(button is PointingHandButton)
    }

    func testGitRowsExcludeCurrentUnavailableAndBusyDestinations() throws {
        let root = URL(fileURLWithPath: "/tmp/pointer-main")
        let options = [
            GitWorktree(root: root, branch: "main", head: "123", isBare: false, isAvailable: true, note: nil),
            GitWorktree(root: URL(fileURLWithPath: "/tmp/pointer-other"), branch: "feature", head: "456", isBare: false, isAvailable: true, note: nil),
            GitWorktree(root: URL(fileURLWithPath: "/tmp/pointer-unavailable"), branch: "missing", head: "789", isBare: false, isAvailable: false, note: nil)
        ]
        let picker = GitDestinationPicker(kind: .worktrees)
        let window = CursorWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 440), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentViewController = picker
        defer { withExtendedLifetime(window) {} }
        picker.show(GitDestinations(root: root, currentBranch: "main", branches: [], worktrees: options))
        picker.view.layoutSubtreeIfNeeded()
        let rows = try (0..<3).map { try XCTUnwrap(picker.table.rowView(atRow: $0, makeIfNecessary: true) as? SelectionRowView) }
        XCTAssertFalse(rows[0].hasClickAction)
        XCTAssertTrue(rows[1].hasClickAction)
        XCTAssertFalse(rows[2].hasClickAction)
        let invalidations = window.invalidations
        picker.setBusy(true)
        XCTAssertFalse(rows[1].hasClickAction)
        XCTAssertGreaterThan(window.invalidations, invalidations)
        picker.setBusy(false)
        XCTAssertTrue(rows[1].hasClickAction)
    }

    func testTreeHoverShowsHandBeforeAnyClickIncludingChangesSections() throws {
        let originalCursor = NSCursor.current
        defer { originalCursor.set() }
        let tree = FileTree()
        let window = CursorWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = tree
        defer { withExtendedLifetime(window) {} }
        let root = URL(fileURLWithPath: "/tmp/pointer-before-click")
        let changes = [GitComparison.staged, .unstaged].map { GitChange(path: "src/a.ts", kind: .modified, comparison: $0) }
        let state = WorkspaceState(root: root, files: ["src/a.ts"], git: GitStatus(root: root, branch: "main", changes: changes, hasHead: true))
        var opened = 0
        tree.onSelect = { _, _ in opened += 1 }
        for changesOnly in [false, true] {
            tree.show(state, changesOnly: changesOnly)
            tree.outline.expandItem(nil, expandChildren: true)
            tree.layoutSubtreeIfNeeded(); tree.outline.updateTrackingAreas()
            let areas = tree.outline.trackingAreas.filter { ($0.owner as? FileOutlineView) === tree.outline }
            XCTAssertTrue(areas.contains { $0.options.contains([.cursorUpdate, .activeInKeyWindow]) })
            XCTAssertTrue(areas.contains { $0.options.contains([.mouseMoved, .mouseEnteredAndExited, .activeAlways]) }, "Hover must work before an activating click")
            for row in 0..<tree.outline.numberOfRows {
                let rect = tree.outline.rect(ofRow: row).intersection(tree.outline.visibleRect)
                for x in [rect.minX + 4, rect.midX, rect.maxX - 4] {
                    let point = tree.outline.convert(NSPoint(x: x, y: rect.midY), to: nil)
                    let entered = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseEntered, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, trackingNumber: 0, userData: nil))
                    let update = try XCTUnwrap(NSEvent.enterExitEvent(with: .cursorUpdate, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 2, trackingNumber: 0, userData: nil))
                    let moved = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 3, clickCount: 0, pressure: 0))
                    NSCursor.arrow.set(); tree.outline.mouseEntered(with: entered)
                    XCTAssertEqual(NSCursor.current, .pointingHand, "Entry must not require a click: row \(row)")
                    NSCursor.arrow.set(); tree.outline.cursorUpdate(with: update)
                    XCTAssertEqual(NSCursor.current, .pointingHand)
                    NSCursor.arrow.set(); tree.outline.mouseMoved(with: moved)
                    XCTAssertEqual(NSCursor.current, .pointingHand)
                }
            }
            let empty = NSPoint(x: tree.outline.visibleRect.midX, y: tree.outline.rect(ofRow: tree.outline.numberOfRows - 1).maxY + 12)
            XCTAssertTrue(tree.outline.visibleRect.contains(empty))
            let moved = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: tree.outline.convert(empty, to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 4, clickCount: 0, pressure: 0))
            NSCursor.pointingHand.set(); tree.outline.mouseMoved(with: moved)
            XCTAssertEqual(NSCursor.current, .arrow)
            let rowPoint = tree.outline.convert(NSPoint(x: tree.outline.visibleRect.midX, y: tree.outline.rect(ofRow: 0).midY), to: nil)
            let disabledMove = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: rowPoint, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 5, clickCount: 0, pressure: 0))
            tree.outline.isEnabled = false
            NSCursor.pointingHand.set(); tree.outline.mouseMoved(with: disabledMove)
            XCTAssertEqual(NSCursor.current, .arrow)
            tree.outline.isEnabled = true
            XCTAssertEqual(tree.outline.selectedRow, -1)
        }
        XCTAssertEqual(opened, 0, "Hover must not activate or select a row")
    }
}

private final class CursorButton: PointingHandButton {
    var recorded: [NSRect] = []
    override func addCursorRect(_ rect: NSRect, cursor: NSCursor) {
        if cursor == .pointingHand { recorded.append(rect) }
        super.addCursorRect(rect, cursor: cursor)
    }
}

private final class CursorWindow: NSWindow {
    var invalidations = 0
    override func invalidateCursorRects(for view: NSView) {
        invalidations += 1
        super.invalidateCursorRects(for: view)
    }
}

private final class PointerRows: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    var count = 3
    func numberOfRows(in tableView: NSTableView) -> Int { count }
    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { row == 0 }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { row == 1 }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { SelectionRowView() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? { Theme.label("row \(row)") }
    @objc func choose(_ sender: Any?) {}
}
