import AppKit
import XCTest
@testable import VCode

final class WorkspaceHistoryTests: XCTestCase {
    private func directory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vcode-history-store-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func state(_ path: String, branch: String = "main", project: GitProject? = nil) -> WorkspaceState {
        let root = URL(fileURLWithPath: path, isDirectory: true)
        return WorkspaceState(root: root, files: [], git: project.map { _ in GitStatus(root: root, branch: branch, changes: [], hasHead: true) }, project: project)
    }

    func testPersistenceDeduplicationRefreshAndLimit() {
        let directory = directory()
        let store = WorkspaceHistoryStore(directory: directory, legacyDefaults: nil)
        let project = GitProject(commonDirectory: URL(fileURLWithPath: "/tmp/project/.git"), primaryRoot: URL(fileURLWithPath: "/tmp/project"))
        store.record(state("/tmp/project", project: project), at: Date(timeIntervalSince1970: 1))
        store.record(state("/tmp/linked", project: project), at: Date(timeIntervalSince1970: 2))
        store.update(state("/tmp/project", branch: "updated", project: project))
        XCTAssertEqual(store.entries.map(\.root.lastPathComponent), ["linked", "project"])
        XCTAssertEqual(store.entries.last?.branch, "updated")
        store.record(state("/tmp/project", branch: "updated", project: project), at: Date(timeIntervalSince1970: 3))
        let restored = WorkspaceHistoryStore(directory: directory, legacyDefaults: nil)
        XCTAssertEqual(restored.entries, store.entries)
        XCTAssertEqual(restored.entries.count, 2)
        XCTAssertEqual(restored.entries.map(\.root.lastPathComponent), ["linked", "project"], "Switching must preserve order after restart")
        XCTAssertEqual(restored.lastFolder?.lastPathComponent, "project")
        XCTAssertEqual(RecentProject.group(restored.entries).first?.workspaces.map(\.root.lastPathComponent), ["linked", "project"])
        XCTAssertEqual(restored.entries.last?.branch, "updated")
        for index in 0..<50 { store.record(state("/tmp/folder-\(index)")) }
        XCTAssertEqual(store.entries.count, WorkspaceHistoryStore.limit)
        XCTAssertEqual(WorkspaceHistoryStore(directory: directory, legacyDefaults: nil).entries.first?.root.lastPathComponent, "folder-49")
    }

    func testProjectGroupingKeepsSameNameRepositoriesSeparateAndFiltersWorktrees() {
        let first = GitProject(commonDirectory: URL(fileURLWithPath: "/tmp/a/project/.git"), primaryRoot: URL(fileURLWithPath: "/tmp/a/project"))
        let second = GitProject(commonDirectory: URL(fileURLWithPath: "/tmp/b/project/.git"), primaryRoot: URL(fileURLWithPath: "/tmp/b/project"))
        let entries = [
            RecentWorkspace(state: state("/tmp/a/project", project: first), openedAt: Date(timeIntervalSince1970: 1)),
            RecentWorkspace(state: state("/tmp/linked", branch: "feature", project: first), openedAt: Date(timeIntervalSince1970: 3)),
            RecentWorkspace(state: state("/tmp/b/project", project: second), openedAt: Date(timeIntervalSince1970: 2))
        ]
        let grouped = RecentProject.group(entries)
        XCTAssertEqual(grouped.count, 2)
        XCTAssertEqual(grouped.first?.workspaces.map(\.root.lastPathComponent), ["linked", "project"])
        XCTAssertEqual(RecentProject.group(entries, matching: "feature").first?.workspaces.count, 1)
        XCTAssertTrue(RecentProject.group(entries, matching: "nothing matches").isEmpty)
        let directory = directory()
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try! Data("bad history".utf8).write(to: directory.appendingPathComponent("workspace.json"))
        XCTAssertTrue(WorkspaceHistoryStore(directory: directory, legacyDefaults: nil).entries.isEmpty)
    }

    func testSidebarWidthPersistsIndependentlyOfHistoryCleanupAndIgnoresInvalidValues() {
        let directory = directory(), store = WorkspaceHistoryStore(directory: directory, legacyDefaults: nil)
        XCTAssertEqual(store.recentSidebarWidth, 48)
        store.saveRecentSidebarWidth(240)
        store.record(state("/tmp/project")); store.clearRecents()
        XCTAssertEqual(WorkspaceHistoryStore(directory: directory, legacyDefaults: nil).recentSidebarWidth, 240)
        store.saveRecentSidebarWidth(.nan)
        XCTAssertEqual(store.recentSidebarWidth, 240)
        store.saveRecentSidebarWidth(-10)
        XCTAssertEqual(store.recentSidebarWidth, 48)
        store.saveRecentSidebarWidth(900)
        XCTAssertEqual(store.recentSidebarWidth, 360)
    }

    func testCompactThresholdKeepsCurrentWorktreesTooltipsAndCleanupAccessible() throws {
        _ = NSApplication.shared
        let a = state("/tmp/one/project"), b = state("/tmp/two/project")
        let picker = WorkspaceHistorySidebar(entries: [a, b].enumerated().map { RecentWorkspace(state: $0.element, openedAt: Date(timeIntervalSince1970: Double($0.offset))) }, current: a.root, available: { $0 != b.root })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentViewController = picker
        defer { window.close() }
        for width: CGFloat in [240, 159, 48, 160, 360, 48] {
            window.setContentSize(NSSize(width: width, height: 600))
            window.contentView?.layoutSubtreeIfNeeded()
            let compact = width < 160
            XCTAssertEqual(picker.isCompact, compact)
            XCTAssertFalse(picker.table.floatsGroupRows, "Project headings scroll with rows instead of floating over transparent content")
            XCTAssertEqual(picker.filter.isHidden, compact)
            XCTAssertEqual(picker.clearButton.isHidden, compact)
            XCTAssertFalse(try XCTUnwrap(picker.table.enclosingScrollView).hasVerticalScroller)
            XCTAssertFalse(try XCTUnwrap(picker.table.enclosingScrollView).hasHorizontalScroller)
            XCTAssertEqual(picker.table.numberOfRows, compact ? 2 : 4)
            let row = compact ? 1 : 3
            let cell = try XCTUnwrap(picker.table.view(atColumn: 0, row: row, makeIfNecessary: true) as? HistoryCell)
            cell.layoutSubtreeIfNeeded()
            XCTAssertEqual(cell.frame.width, width - (compact ? 0 : 8), accuracy: 1, "Rows must fit the actual viewport, not retain an old column width")
            XCTAssertEqual(cell.path.isHidden, compact)
            XCTAssertTrue(cell.accessibilityLabel()?.contains(a.root.path) == true)
            XCTAssertTrue(cell.accessibilityLabel()?.contains("Current") == true)
            XCTAssertEqual(cell.removeButton.isHidden, compact)
            if compact {
                XCTAssertNil(cell.toolTip)
                XCTAssertEqual(cell.layer?.backgroundColor?.alpha, 0, "Cells must not paint a second background")
                let rowView = try XCTUnwrap(picker.table.rowView(atRow: row, makeIfNecessary: true) as? SelectionRowView)
                XCTAssertTrue(rowView.isCurrent)
                XCTAssertEqual(picker.view.layer?.backgroundColor?.alpha, 0)
            }
            XCTAssertTrue(cell.bounds.contains(cell.removeButton.frame))
            let titleRect = cell.title.convert(cell.title.bounds, to: cell)
            XCTAssertFalse(titleRect.intersects(cell.removeButton.frame))
            var removed: URL?
            picker.onRemove = { removed = $0 }
            if !compact {
                cell.removeButton.performClick(nil)
                XCTAssertEqual(removed, a.root, "Cleanup must target the full path even for identical abbreviations")
            }
            XCTAssertFalse(picker.tableView(picker.table, shouldSelectRow: compact ? 0 : 1), "Unavailable records cannot open")
        }
    }

    func testSwitchingCurrentWorkspaceMovesOnlyTheActiveBackground() throws {
        _ = NSApplication.shared
        let a = state("/tmp/first"), b = state("/tmp/second")
        let entries = [a, b].map { RecentWorkspace(state: $0, openedAt: Date()) }
        let sidebar = WorkspaceHistorySidebar(entries: entries, current: a.root, available: { _ in true })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 48, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentViewController = sidebar
        defer { window.close() }
        for current in [a.root, b.root, a.root] {
            sidebar.update(entries: entries, current: current)
            sidebar.view.layoutSubtreeIfNeeded()
            for index in sidebar.rows.indices {
                guard case .workspace(let entry) = sidebar.rows[index] else { continue }
                let row = try XCTUnwrap(sidebar.table.rowView(atRow: index, makeIfNecessary: true) as? SelectionRowView)
                XCTAssertEqual(row.isCurrent, entry.root == current, "Reloaded/reused rows must not retain an old active background")
            }
        }
    }

    func testRecentActiveAndHoverPaintOneBackgroundWithTheSameGeometry() throws {
        _ = NSApplication.shared
        let row = SelectionRowView(frame: NSRect(x: 0, y: 0, width: 40, height: 44))
        func render(current: Bool, hovered: Bool, selected: Bool = false) throws -> NSBitmapImageRep {
            row.isCurrent = current; row.isHovered = hovered; row.isSelected = selected
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 44, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            row.drawBackground(in: row.bounds)
            if selected { row.drawSelection(in: row.bounds) }
            NSGraphicsContext.restoreGraphicsState()
            return bitmap
        }
        let active = try render(current: true, hovered: false)
        let activeHovered = try render(current: true, hovered: true, selected: true)
        let hover = try render(current: false, hovered: true)
        var painted = 0
        for y in 0..<44 { for x in 0..<40 {
            let a = try XCTUnwrap(active.colorAt(x: x, y: y))
            let b = try XCTUnwrap(activeHovered.colorAt(x: x, y: y))
            let h = try XCTUnwrap(hover.colorAt(x: x, y: y))
            XCTAssertEqual(a, b, "Hover/selection must not add another fill to the current row")
            XCTAssertEqual(a.alphaComponent > 0, h.alphaComponent > 0, "Active and hover must share the same inset and corner geometry")
            if a.alphaComponent > 0 { painted += 1 }
        } }
        XCTAssertGreaterThan(painted, 0)
        XCTAssertEqual(active.colorAt(x: 0, y: 0)?.alphaComponent, 0)
    }

    func testLeftSidebarRestoresWidthWithoutSavingTemporaryWindowClamp() throws {
        _ = NSApplication.shared
        let store = WorkspaceHistoryStore(directory: directory(), legacyDefaults: nil)
        store.saveRecentSidebarWidth(360)
        let controller = WorkspaceController(history: store)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1360, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentViewController = controller
        defer { controller.shutdown(); window.close() }
        window.setContentSize(NSSize(width: 1360, height: 700))
        let workspace = try XCTUnwrap(controller.view as? WorkspaceView)
        workspace.layoutSubtreeIfNeeded()
        XCTAssertEqual(workspace.recentSidebarWidth, 360, accuracy: 0.5)
        workspace.editorGroups.setWorkspaceOpen(true)
        workspace.editorGroups.splitActiveEditor(copyDocument: false)
        window.setContentSize(NSSize(width: 920, height: 700))
        workspace.layoutSubtreeIfNeeded()
        XCTAssertLessThan(workspace.recentSidebarWidth, 360)
        controller.saveReadingSession()
        XCTAssertEqual(store.recentSidebarWidth, 360, "Window clamping must not overwrite the chosen width")
        window.setContentSize(NSSize(width: 1360, height: 700))
        workspace.layoutSubtreeIfNeeded()
        XCTAssertEqual(workspace.recentSidebarWidth, 360, accuracy: 0.5)
    }

    func testCompactDetailCardFormatsContentFitsWindowAndKeepsReadingFocus() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 920, height: 580), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 920, height: 580))
        window.contentView = host
        let anchor = NSView(frame: NSRect(x: 8, y: 500, width: 40, height: 44))
        let reader = NSTextView(frame: NSRect(x: 100, y: 0, width: 500, height: 400))
        host.addSubview(anchor); host.addSubview(reader)
        let hover = RecentWorkspaceHover()
        defer { hover.dismiss(); window.close() }
        window.makeFirstResponder(reader)
        let entry = RecentWorkspace(state: state("/tmp/project-with-a-long-name/worktrees/feature-worktree"), openedAt: Date())
        for y: CGFloat in [500, 0] {
            anchor.frame.origin.y = y
            hover.show(entry, current: true, available: true, beside: anchor)
            let panel = try XCTUnwrap(hover.panel)
            XCTAssertTrue(window.convertToScreen(window.contentLayoutRect).contains(panel.frame))
            XCTAssertTrue(window.firstResponder === reader)
            func labels(_ view: NSView) -> [NSTextField] { (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(labels) }
            let fields = labels(try XCTUnwrap(panel.contentView))
            XCTAssertTrue(fields.contains { $0.stringValue == "feature-worktree" })
            XCTAssertTrue(fields.contains { $0.stringValue == entry.root.path })
            XCTAssertTrue(fields.contains { $0.stringValue == "Current workspace" })
            XCTAssertTrue(fields.allSatisfy { panel.contentView!.bounds.contains($0.convert($0.bounds, to: panel.contentView)) })
        }
        NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: window)
        XCTAssertNil(hover.panel)
    }

    func testManualCleanupPersistsWithoutDeletingWorkspacesOrCurrentSession() throws {
        let base = directory(), root = base.appendingPathComponent("current", isDirectory: true), other = base.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let store = WorkspaceHistoryStore(directory: base.appendingPathComponent("state"), legacyDefaults: nil)
        let current = state(root.path)
        store.record(state(other.path)); store.record(current)
        store.recordFile("source.ts", in: root)
        store.saveWindow(WindowPlacement(x: 10, y: 20, width: 920, height: 580))
        let session = WorkspaceReadingSession(groups: [], activeGroup: 0, splitRatio: 0.5, sidebarWidth: 240, changesOnly: false, trees: [:])
        store.saveReadingSession(session, in: root)
        store.removeRecent(other)
        XCTAssertEqual(store.entries.map(\.root), [root])
        XCTAssertEqual(WorkspaceHistoryStore(directory: store.file.deletingLastPathComponent(), legacyDefaults: nil).entries.map(\.root), [root])
        store.clearRecents()
        store.update(current)
        store.saveReadingSession(session, in: root)
        store.recordFile("next.ts", in: root)
        let restored = WorkspaceHistoryStore(directory: store.file.deletingLastPathComponent(), legacyDefaults: nil)
        XCTAssertTrue(restored.entries.isEmpty, "Background refresh and saving must not undo manual cleanup")
        XCTAssertEqual(restored.lastFolder, root)
        XCTAssertEqual(restored.readingSession(in: root), session)
        XCTAssertEqual(restored.recentFiles(in: root), ["next.ts", "source.ts"])
        XCTAssertEqual(restored.windowPlacement, store.windowPlacement)
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
        restored.record(current)
        XCTAssertEqual(restored.entries.map(\.root), [root], "An explicit visit records the workspace again")
    }

    func testPickerGuardsCurrentMissingRowsAndKeepsTextVisible() throws {
        _ = NSApplication.shared
        let available = state("/tmp/available")
        let current = state("/tmp/current")
        let missing = state("/tmp/missing")
        let entries = [available, current, missing].enumerated().map { RecentWorkspace(state: $0.element, openedAt: Date(timeIntervalSince1970: Double($0.offset))) }
        let picker = WorkspaceHistorySidebar(entries: entries, current: current.root, available: { $0 != missing.root })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 440), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = picker
        window.setContentSize(NSSize(width: 560, height: 440))
        window.contentView?.layoutSubtreeIfNeeded()
        defer { window.close() }
        XCTAssertEqual(picker.table.numberOfRows, 6)
        XCTAssertFalse(picker.tableView(picker.table, shouldSelectRow: 1))
        XCTAssertFalse(picker.tableView(picker.table, shouldSelectRow: 3))
        XCTAssertTrue(picker.tableView(picker.table, shouldSelectRow: 5))
        let cell = try XCTUnwrap(picker.table.view(atColumn: 0, row: 5, makeIfNecessary: true))
        cell.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(cell.frame.width, 400)
        var chosen: URL?
        picker.onChoose = { chosen = $0 }
        picker.table.selectRowIndexes(IndexSet(integer: 5), byExtendingSelection: false)
        XCTAssertTrue(picker.table.sendAction(picker.table.action, to: picker.table.target))
        XCTAssertEqual(chosen, available.root)
        picker.filter.stringValue = "missing"
        _ = picker.filter.sendAction(picker.filter.action, to: picker.filter.target)
        XCTAssertEqual(picker.table.numberOfRows, 2)
        picker.filter.stringValue = "absent"
        _ = picker.filter.sendAction(picker.filter.action, to: picker.filter.target)
        XCTAssertEqual(picker.table.numberOfRows, 0)
    }

    func testActualGitWorktreesShareIdentityAndControllerRecordsSuccessfulVisits() throws {
        _ = NSApplication.shared
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("vcode-history-" + UUID().uuidString)
        let primary = base.appendingPathComponent("project")
        let linked = base.appendingPathComponent("feature-worktree")
        try FileManager.default.createDirectory(at: primary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        func git(_ args: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", primary.path, "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"] + args
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, "\(args)")
        }
        try git(["init", "-q", "-b", "main"])
        try git(["-c", "user.name=Test", "-c", "user.email=test@localhost", "commit", "--allow-empty", "-qm", "initial"])
        try git(["worktree", "add", "-qb", "feature", linked.path])
        let a = try WorkspaceReader(folder: primary).load()
        let b = try WorkspaceReader(folder: linked).load()
        XCTAssertEqual(a.project?.commonDirectory, b.project?.commonDirectory)
        XCTAssertEqual(b.project?.primaryRoot, primary.resolvingSymlinksInPath())
        let history = WorkspaceHistoryStore(directory: directory(), legacyDefaults: nil)
        let controller = WorkspaceController(history: history)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 580), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 920, height: 580))
        defer { controller.shutdown(); window.close() }
        controller.open(primary)
        wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in history.entries.count == 1 }, object: nil)], timeout: 10)
        let switched = expectation(description: "Worktree visits use the same history")
        controller.activate(.worktree(linked.resolvingSymlinksInPath())) { result in
            XCTAssertEqual(try? result.get().branch, "feature")
            switched.fulfill()
        }
        wait(for: [switched], timeout: 10)
        XCTAssertEqual(history.entries.count, 2)
        XCTAssertEqual(RecentProject.group(history.entries).count, 1)
        XCTAssertEqual(history.entries.first?.branch, "feature")
        controller.showHistory()
        let picker = try XCTUnwrap(controller.children.compactMap { $0 as? WorkspaceHistorySidebar }.first)
        XCTAssertFalse(picker.isCompact, "History expanded: rail=\((controller.view as! WorkspaceView).recentSidebarWidth), view=\(picker.view.frame)")
        XCTAssertTrue(window.firstResponder === picker.filter.currentEditor())
        XCTAssertTrue(picker.control(picker.filter, textView: NSTextView(), doCommandBy: #selector(NSResponder.moveDown(_:))))
        XCTAssertEqual(picker.table.selectedRow, 2)
        XCTAssertTrue(controller.children.contains { $0 === picker }, "Selecting with Down must not close the panel")
        controller.showHistory()
        XCTAssertTrue(controller.children.contains { $0 === picker }, "Recent is a persistent sidebar")
        controller.open(base.appendingPathComponent("missing"))
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(history.entries.count, 2)

        controller.showHistory()
        let cleanup = try XCTUnwrap(controller.children.compactMap { $0 as? WorkspaceHistorySidebar }.first)
        window.contentView?.layoutSubtreeIfNeeded()
        let currentCell = try XCTUnwrap(cleanup.table.view(atColumn: 0, row: 1, makeIfNecessary: true) as? HistoryCell)
        currentCell.layoutSubtreeIfNeeded()
        let buttonPoint = try XCTUnwrap(cleanup.table.superview).convert(NSPoint(x: currentCell.removeButton.bounds.midX, y: currentCell.removeButton.bounds.midY), from: currentCell.removeButton)
        XCTAssertTrue(cleanup.table.hitTest(buttonPoint) === currentCell.removeButton, "Current rows must still allow cleanup")
        currentCell.removeButton.performClick(nil)
        XCTAssertEqual(history.entries.map(\.root), [a.root])
        XCTAssertEqual(cleanup.table.numberOfRows, 2)
        XCTAssertTrue(controller.children.contains { $0 === cleanup }, "Removing a record does not close the picker")
        XCTAssertEqual(window.title, "\(b.root.lastPathComponent) — VCode", "Removing the current entry does not switch worktrees")
        cleanup.filter.stringValue = "no visible results"
        _ = cleanup.filter.sendAction(cleanup.filter.action, to: cleanup.filter.target)
        XCTAssertEqual(cleanup.table.numberOfRows, 0)
        XCTAssertTrue(cleanup.clearButton.isEnabled, "Clear All also covers entries hidden by the filter")
        cleanup.clearButton.performClick(nil)
        XCTAssertTrue(history.entries.isEmpty)
        XCTAssertFalse(cleanup.clearButton.isEnabled)
        XCTAssertEqual(cleanup.filter.stringValue, "")
        XCTAssertEqual(history.lastFolder, b.root)
        controller.showHistory(); controller.showHistory()
        let empty = try XCTUnwrap(controller.children.compactMap { $0 as? WorkspaceHistorySidebar }.first)
        XCTAssertEqual(empty.table.numberOfRows, 0)
        XCTAssertFalse(empty.clearButton.isEnabled)
    }
}
