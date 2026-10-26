import AppKit
import XCTest
@testable import VCode

final class IndexActionTests: XCTestCase {
    override func setUp() { _ = NSApplication.shared }

    private func row(_ path: String, _ comparison: GitComparison, in tree: FileTree) throws -> Int {
        try XCTUnwrap((0..<tree.outline.numberOfRows).first {
            guard let node = tree.outline.item(atRow: $0) as? FileNode else { return false }
            return node.path == path && node.comparison == comparison
        })
    }
    private func cell(_ path: String, _ comparison: GitComparison, in tree: FileTree) throws -> FileCell {
        try XCTUnwrap(tree.outline.view(atColumn: 0, row: row(path, comparison, in: tree), makeIfNecessary: true) as? FileCell)
    }
    private func state() -> WorkspaceState {
        let root = URL(fileURLWithPath: "/tmp/index-actions-layout")
        let paths = ["src/a.ts", "src/deep/b.ts", "other.ts"]
        let changes = paths.flatMap { path in [GitComparison.staged, .unstaged].map { GitChange(path: path, kind: .modified, comparison: $0) } }
        return WorkspaceState(root: root, files: paths, git: GitStatus(root: root, branch: "main", changes: changes, hasHead: true))
    }

    func testFileAndFolderButtonsHaveIndependentHitTargetsAndDoNotActivateOrCollapseRows() throws {
        let tree = FileTree()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = tree
        tree.show(state(), changesOnly: true)
        tree.layoutSubtreeIfNeeded()
        var calls: [(GitIndexAction, String)] = [], opened = 0
        tree.onSelect = { _, _ in opened += 1 }
        tree.onIndexAction = { calls.append(($0, $1.path)) }
        for comparison in [GitComparison.staged, .unstaged] {
            for path in ["src", "src/a.ts"] {
                let cell = try cell(path, comparison, in: tree)
                cell.layoutSubtreeIfNeeded()
                XCTAssertTrue(cell.indexButton.isHidden)
                cell.setRowHovered(true)
                XCTAssertFalse(cell.indexButton.isHidden)
                XCTAssertEqual(cell.indexButton.toolTip, (comparison == .staged ? "Unstage Changes" : "Stage Changes") + " · " + path)
                let point = cell.indexButton.convert(NSPoint(x: 11, y: 11), to: tree.outline.superview)
                XCTAssertTrue(tree.outline.hitTest(point) === cell.indexButton, "The outline must not consume the action click")
                let selection = tree.outline.selectedRow
                cell.indexButton.performClick(nil)
                XCTAssertEqual(tree.outline.selectedRow, selection)
                XCTAssertEqual(calls.last?.0, comparison == .staged ? .unstage : .stage)
                XCTAssertEqual(calls.last?.1, path)
            }
            let folder = tree.outline.item(atRow: try row("src", comparison, in: tree))!
            XCTAssertTrue(tree.outline.isItemExpanded(folder))
        }
        XCTAssertEqual(calls.count, 4)
        XCTAssertEqual(opened, 0)
        tree.setIndexBusy(true)
        let busy = try cell("src/a.ts", .unstaged, in: tree)
        XCTAssertFalse(busy.indexButton.isEnabled)
        busy.setRowHovered(true)
        busy.indexButton.performClick(nil)
        XCTAssertEqual(calls.count, 4)
        tree.setIndexBusy(false)
        tree.outline.isEnabled = false
        XCTAssertFalse(busy.indexButton.isEnabled)
        tree.outline.isEnabled = true
        XCTAssertTrue(busy.indexButton.isEnabled)
        withExtendedLifetime(window) {}
    }

    func testButtonsStaySquareBesideStatusAndDisappearWhenCellsReturnToFiles() throws {
        let tree = FileTree()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = tree
        for width: CGFloat in [360, 220, 300, 220] {
            window.setContentSize(NSSize(width: width, height: 600))
            tree.show(state(), changesOnly: true)
            tree.layoutSubtreeIfNeeded()
            for path in ["src", "src/deep", "src/a.ts", "src/deep/b.ts"] {
                let cell = try cell(path, .unstaged, in: tree)
                cell.setRowHovered(true)
                cell.layoutSubtreeIfNeeded()
                XCTAssertEqual(cell.indexButton.frame.width, 22, accuracy: 0.5)
                XCTAssertEqual(cell.indexButton.frame.height, 22, accuracy: 0.5)
                XCTAssertGreaterThanOrEqual(cell.indexButton.frame.minY, 3.5)
                XCTAssertLessThanOrEqual(cell.indexButton.frame.maxY, cell.bounds.height - 3.5)
                XCTAssertLessThanOrEqual(cell.label.alignmentRect(forFrame: cell.label.frame).maxX, cell.indexButton.frame.minX - 3.5)
                if cell.isDirectory {
                    XCTAssertTrue(cell.badge.isHidden)
                    XCTAssertEqual(cell.indexButton.alignmentRect(forFrame: cell.indexButton.frame).maxX, cell.bounds.width - 10, accuracy: 0.5,
                        "Folders must not reserve an empty Git status column")
                } else {
                    XCTAssertFalse(cell.badge.isHidden)
                    XCTAssertLessThan(cell.indexButton.frame.maxX, cell.badge.frame.minX)
                    XCTAssertLessThanOrEqual(cell.badge.alignmentRect(forFrame: cell.badge.frame).maxX, cell.bounds.width - 9.5)
                }
                let titleFrame = cell.label.frame
                let actionFrame = cell.indexButton.frame
                cell.setRowHovered(false)
                cell.layoutSubtreeIfNeeded()
                XCTAssertEqual(cell.label.frame, titleFrame)
                XCTAssertEqual(cell.indexButton.frame, actionFrame)
            }
            for i in 0..<tree.outline.numberOfRows where (tree.outline.item(atRow: i) as? FileNode)?.isSection == true {
                let section = try XCTUnwrap(tree.outline.view(atColumn: 0, row: i, makeIfNecessary: true) as? FileCell)
                XCTAssertTrue(section.indexButton.isHidden)
                section.setRowHovered(true)
                XCTAssertFalse(section.indexButton.isHidden)
                XCTAssertEqual(section.indexButton.toolTip, (tree.outline.item(atRow: i) as? FileNode)?.comparison == .staged ? "Unstage All Changes" : "Stage All Changes")
            }
            tree.show(state(), changesOnly: false)
            tree.outline.expandItem(nil, expandChildren: true)
            for i in 0..<tree.outline.numberOfRows {
                let cell = try XCTUnwrap(tree.outline.view(atColumn: 0, row: i, makeIfNecessary: true) as? FileCell)
                XCTAssertTrue(cell.indexButton.isHidden)
                XCTAssertNil(cell.onIndexAction)
            }
        }
        withExtendedLifetime(window) {}
    }

    func testMovingSelectedFileToOtherCategoryDoesNotSelectOrOpenItsOldRow() throws {
        let tree = FileTree()
        let root = URL(fileURLWithPath: "/tmp/index-selection")
        func state(_ comparison: GitComparison) -> WorkspaceState {
            WorkspaceState(root: root, files: ["a.ts", "b.ts"], git: GitStatus(root: root, branch: "main", changes: [
                GitChange(path: "a.ts", kind: .modified, comparison: comparison), GitChange(path: "b.ts", kind: .modified)
            ], hasHead: true))
        }
        tree.show(state(.unstaged), changesOnly: true)
        tree.select("a.ts", comparison: .unstaged)
        XCTAssertGreaterThanOrEqual(tree.outline.selectedRow, 0)
        var opened = 0
        tree.onSelect = { _, _ in opened += 1 }
        tree.show(state(.staged), changesOnly: true)
        XCTAssertEqual(tree.outline.selectedRow, -1)
        XCTAssertEqual(opened, 0)
    }

    func testOnlyHoveredRowShowsActionIncludingSectionsAndEmptySectionIsDisabled() throws {
        let tree = FileTree()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = tree
        tree.show(state(), changesOnly: true)
        tree.layoutSubtreeIfNeeded()
        let fileRow = try row("src/a.ts", .unstaged, in: tree)
        let file = try cell("src/a.ts", .unstaged, in: tree)
        let titleBefore = file.label.frame
        func hover(_ row: Int) throws {
            let point = tree.outline.convert(NSPoint(x: 50, y: tree.outline.rect(ofRow: row).midY), to: nil)
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
            tree.outline.mouseMoved(with: event)
        }
        try hover(fileRow)
        XCTAssertFalse(file.indexButton.isHidden)
        tree.outline.selectRowIndexes(IndexSet(integer: fileRow), byExtendingSelection: false)
        try hover(0)
        XCTAssertTrue(file.indexButton.isHidden, "A selected row must still hide its action when the pointer leaves")
        let section = try XCTUnwrap(tree.outline.view(atColumn: 0, row: 0, makeIfNecessary: true) as? FileCell)
        XCTAssertFalse(section.indexButton.isHidden)
        XCTAssertEqual(section.indexButton.toolTip, "Unstage All Changes")
        var called = false
        tree.onIndexAction = { action, target in
            XCTAssertEqual(action, .unstage)
            if case .all = target { called = true } else { XCTFail("Section action must target its whole category") }
        }
        let expanded = tree.outline.isItemExpanded(tree.outline.item(atRow: 0))
        section.indexButton.performClick(nil)
        XCTAssertTrue(called)
        XCTAssertEqual(tree.outline.isItemExpanded(tree.outline.item(atRow: 0)), expanded)
        file.layoutSubtreeIfNeeded()
        XCTAssertEqual(file.label.frame, titleBefore)
        tree.show(WorkspaceState(root: state().root, files: [], git: GitStatus(root: state().root, branch: "main", changes: [], hasHead: true)), changesOnly: true)
        let empty = try XCTUnwrap(tree.outline.view(atColumn: 0, row: 0, makeIfNecessary: true) as? FileCell)
        empty.setRowHovered(true)
        XCTAssertFalse(empty.indexButton.isEnabled)
        withExtendedLifetime(window) {}
    }

    private func repository() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vcode-index-session-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["init", "-q", "-b", "main", root.path]
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        try "new file\n".write(to: root.appendingPathComponent("file.ts"), atomically: true, encoding: .utf8)
        return root
    }

    func testControllerRoutesTreeActionsAndRefreshesWithoutOpeningAnotherDocument() throws {
        let root = try repository()
        let controller = WorkspaceController(history: isolatedHistoryStore())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = controller
        let view = try XCTUnwrap(controller.view as? WorkspaceView)
        defer { controller.shutdown(); withExtendedLifetime(window) {} }
        controller.open(root)
        func waitUntil(_ test: @escaping () -> Bool) {
            wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in test() }, object: nil)], timeout: 10)
        }
        waitUntil { view.header.worktreeButton.title == root.lastPathComponent }
        controller.showChanges()
        controller.openFile("file.ts", diff: true, comparison: .unstaged)
        waitUntil { view.editor.currentSource == "new file\n" }
        let documents = view.editor.captureSession().documents
        let stage = try cell("file.ts", .unstaged, in: view.explorer)
        stage.setRowHovered(true)
        stage.indexButton.performClick(nil)
        XCTAssertTrue(view.explorer.isIndexBusy)
        XCTAssertFalse(stage.indexButton.isEnabled)
        XCTAssertFalse(view.header.worktreeButton.isEnabled)
        waitUntil { !view.explorer.isIndexBusy && (0..<view.explorer.outline.numberOfRows).contains {
            let node = view.explorer.outline.item(atRow: $0) as? FileNode
            return node?.path == "file.ts" && node?.comparison == .staged
        } }
        XCTAssertEqual(view.editor.captureSession().documents, documents)
        XCTAssertEqual(view.editor.activeComparison, .unstaged)
        let unstage = try cell("file.ts", .staged, in: view.explorer)
        unstage.setRowHovered(true)
        unstage.indexButton.performClick(nil)
        waitUntil { !view.explorer.isIndexBusy && (0..<view.explorer.outline.numberOfRows).contains {
            let node = view.explorer.outline.item(atRow: $0) as? FileNode
            return node?.path == "file.ts" && node?.comparison == .unstaged
        } }
        XCTAssertEqual(view.editor.captureSession().documents, documents)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("file.ts")), "new file\n")
    }

    func testSessionSerializesIndexActionsRefreshesAndRecoversAfterLockedIndex() throws {
        let root = try repository()
        let session = WorkspaceSession()
        defer { session.close() }
        let opened = expectation(description: "opened")
        session.open(root) { _ in opened.fulfill() }
        wait(for: [opened], timeout: 10)
        var busy: [Bool] = [], refreshed: [WorkspaceState] = []
        session.onIndexBusyChange = { busy.append($0) }
        session.onRefresh = { refreshed.append($0) }
        let staged = expectation(description: "staged")
        session.updateIndex(.stage, target: .file("file.ts")) { result in
            XCTAssertEqual(try? result.get().changes.first?.comparison, .staged)
            staged.fulfill()
        }
        XCTAssertTrue(session.isUpdatingIndex)
        session.updateIndex(.stage, target: .file("file.ts")) { _ in XCTFail("Repeated click must be ignored while busy") }
        wait(for: [staged], timeout: 10)
        XCTAssertEqual(busy, [true, false])
        XCTAssertEqual(refreshed.last?.changes.first?.comparison, .staged)
        let lock = root.appendingPathComponent(".git/index.lock")
        try Data().write(to: lock)
        let failed = expectation(description: "locked index failed")
        session.updateIndex(.unstage, target: .file("file.ts")) { result in
            if case .success = result { XCTFail("Expected lock failure") }
            failed.fulfill()
        }
        wait(for: [failed], timeout: 10)
        XCTAssertFalse(session.isUpdatingIndex)
        XCTAssertEqual(busy, [true, false, true, false])
        try FileManager.default.removeItem(at: lock)
        let unstaged = expectation(description: "unstaged")
        session.updateIndex(.unstage, target: .file("file.ts")) { result in
            XCTAssertEqual(try? result.get().changes.first?.kind, .untracked)
            unstaged.fulfill()
        }
        wait(for: [unstaged], timeout: 10)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("file.ts")), "new file\n")
    }
}
