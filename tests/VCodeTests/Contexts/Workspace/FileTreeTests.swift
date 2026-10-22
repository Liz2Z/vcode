import AppKit
import XCTest
@testable import VCode

final class FileTreeTests: XCTestCase {
    override func setUp() { _ = NSApplication.shared }

    func testIndexOnlyReturnsImmediateChildrenWithNaturalDirectoryOrder() {
        let index = FileTreeIndex(paths: ["src/module10/main.ts", "src/module2/你好.ts", "src/a.ts", "src-old/file.ts", "README.md"])
        XCTAssertEqual(index.children(in: "").map(\.path), ["src", "src-old", "README.md"])
        XCTAssertEqual(index.children(in: "src").map(\.path), ["src/module2", "src/module10", "src/a.ts"])
        XCTAssertEqual(index.children(in: "src/module2").map(\.name), ["你好.ts"])
        XCTAssertTrue(index.children(in: "missing").isEmpty)
    }

    func testFiftyThousandFilesStayCollapsedAndOnlyExpandedNodesMaterialize() throws {
        let tree = FileTree()
        let paths = (0..<100).flatMap { directory in (0..<500).map { "src/module\(directory)/file\($0).ts" } }
        let state = WorkspaceState(root: URL(fileURLWithPath: "/tmp/lazy-tree"), files: paths, git: GitStatus(root: URL(fileURLWithPath: "/tmp/lazy-tree"), branch: "main", files: paths, changes: [], hasHead: true))
        tree.show(state, changesOnly: false)
        XCTAssertEqual(tree.outline.numberOfRows, 1)
        XCTAssertEqual(tree.loadedNodeCount, 1)
        let src = try XCTUnwrap(tree.outline.item(atRow: 0) as? FileNode)
        XCTAssertFalse(tree.outline.isItemExpanded(src))
        tree.outline.expandItem(src)
        XCTAssertEqual(tree.outline.numberOfRows, 101)
        XCTAssertEqual(tree.loadedNodeCount, 101)
        let module = try XCTUnwrap(tree.outline.item(atRow: 1) as? FileNode)
        XCTAssertFalse(tree.outline.isItemExpanded(module))
        tree.outline.expandItem(module)
        XCTAssertEqual(tree.outline.numberOfRows, 601)
        XCTAssertEqual(tree.loadedNodeCount, 601)
        tree.show(state, changesOnly: false)
        XCTAssertTrue(tree.outline.item(atRow: 0) as? FileNode === src, "An unchanged refresh must keep the existing tree")
        tree.outline.collapseItem(src)
        let refreshed = WorkspaceState(root: state.root, files: paths + ["src/new/added.ts"], git: GitStatus(root: state.root, branch: state.branch, files: paths + ["src/new/added.ts"], changes: [], hasHead: true))
        tree.show(refreshed, changesOnly: false)
        XCTAssertEqual(tree.outline.numberOfRows, 1)
        XCTAssertEqual(tree.loadedNodeCount, 1, "A refresh must not materialize descendants of a collapsed parent")
        tree.select("src/module99/file499.ts")
        XCTAssertEqual((tree.outline.item(atRow: tree.outline.selectedRow) as? FileNode)?.path, "src/module99/file499.ts")
        XCTAssertLessThan(tree.loadedNodeCount, 1200)
    }

    func testChangesStartExpandedAndSearchOnlyMaterializesMatchingPaths() throws {
        let tree = FileTree()
        let state = WorkspaceState(root: URL(fileURLWithPath: "/tmp/changes-tree"), files: ["src/lib/target.ts", "src/other/ignored.ts"], git: GitStatus(root: URL(fileURLWithPath: "/tmp/changes-tree"), branch: "main", files: ["src/lib/target.ts", "src/other/ignored.ts"], changes: [GitChange(path: "src/lib/target.ts", kind: .modified), GitChange(path: "src/other/ignored.ts", kind: .added)], hasHead: true))
        tree.show(state, changesOnly: true)
        XCTAssertEqual(tree.outline.numberOfRows, 7)
        XCTAssertEqual(tree.loadedNodeCount, 7)
        tree.filter.stringValue = "target"
        tree.show(state, changesOnly: true)
        XCTAssertEqual(tree.outline.numberOfRows, 5)
        XCTAssertEqual(tree.loadedNodeCount, 5)
        tree.filter.stringValue = ""
        tree.show(state, changesOnly: true)
        XCTAssertEqual(tree.outline.numberOfRows, 7)
    }
    func testBothChangeSectionsShowSamePathAndPreserveExplicitCollapses() throws {
        let tree = FileTree()
        let root = URL(fileURLWithPath: "/tmp/scoped-changes")
        let path = "src/lib/shared.ts"
        let changes = [GitChange(path: path, kind: .modified, comparison: .staged), GitChange(path: path, kind: .modified, comparison: .unstaged)]
        let status = GitStatus(root: root, branch: "main", files: [path], changes: changes, hasHead: true)
        tree.show(WorkspaceState(root: root, files: [path], git: status), changesOnly: true)
        XCTAssertEqual(tree.outline.numberOfRows, 8)
        let nodes = (0..<8).compactMap { tree.outline.item(atRow: $0) as? FileNode }
        XCTAssertEqual(nodes.filter { $0.path == path }.count, 2)
        XCTAssertTrue(nodes.filter(\.directory).allSatisfy { tree.outline.isItemExpanded($0) })
        var selected: GitComparison?
        tree.onSelect = { _, scope in selected = scope }
        tree.select(path, comparison: .staged)
        _ = tree.outline.sendAction(tree.outline.action, to: tree.outline.target)
        XCTAssertEqual(selected, .staged)
        tree.select(path, comparison: .unstaged)
        _ = tree.outline.sendAction(tree.outline.action, to: tree.outline.target)
        XCTAssertEqual(selected, .unstaged)
        let staged = try XCTUnwrap(nodes.first { $0.isSection && $0.comparison == .staged })
        tree.outline.collapseItem(staged)
        let extra = GitChange(path: "other/file.ts", kind: .untracked, comparison: .unstaged)
        let next = GitStatus(root: root, branch: "main", files: [path, extra.path], changes: changes + [extra], hasHead: true)
        tree.show(WorkspaceState(root: root, files: next.files, git: next), changesOnly: true)
        let refreshedStaged = try XCTUnwrap(tree.outline.item(atRow: 0) as? FileNode)
        XCTAssertFalse(tree.outline.isItemExpanded(refreshedStaged))
        XCTAssertTrue((0..<tree.outline.numberOfRows).compactMap { tree.outline.item(atRow: $0) as? FileNode }.contains { $0.path == extra.path })
    }

    func testFolderNameAndBlankSpaceToggleOnceAndExposePressedFeedback() throws {
        _ = NSApplication.shared
        let tree = FileTree()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = tree
        defer { withExtendedLifetime(window) {} }
        let root = URL(fileURLWithPath: "/tmp/row-click")
        tree.show(WorkspaceState(root: root, files: ["src/lib/file.ts"], git: nil), changesOnly: false)
        tree.layoutSubtreeIfNeeded()
        let folder = try XCTUnwrap(tree.outline.item(atRow: 0) as? FileNode)
        func click(x: CGFloat, expectedExpanded: Bool) throws {
            let point = tree.outline.convert(NSPoint(x: x, y: tree.outline.rect(ofRow: 0).midY), to: nil)
            let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: 0.1, windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
            tree.outline.mouseDown(with: down)
            let row = try XCTUnwrap(tree.outline.rowView(atRow: 0, makeIfNecessary: true) as? SelectionRowView)
            XCTAssertTrue(row.isPressed)
            tree.outline.mouseUp(with: up)
            XCTAssertFalse(row.isPressed)
            XCTAssertEqual(tree.outline.isItemExpanded(folder), expectedExpanded)
            row.mouseEntered(with: down)
            XCTAssertTrue(row.isHovered)
            row.mouseExited(with: down)
            XCTAssertFalse(row.isHovered)
        }
        try click(x: 75, expectedExpanded: true)
        try click(x: tree.outline.bounds.width - 8, expectedExpanded: false)
        try click(x: 8, expectedExpanded: true)
        XCTAssertEqual(tree.loadedNodeCount, 2, "Only one directory level should load")
    }

    func testDraggingOutCancelsFolderToggleAndMovesHoverToAnotherRow() throws {
        _ = NSApplication.shared
        let tree = FileTree()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = tree
        defer { withExtendedLifetime(window) {} }
        tree.show(WorkspaceState(root: URL(fileURLWithPath: "/tmp/pointer-tracking"), files: ["docs/note.md", "src/code.ts"], git: nil), changesOnly: false)
        tree.layoutSubtreeIfNeeded()
        func event(_ type: NSEvent.EventType, row: Int) throws -> NSEvent {
            let point = tree.outline.convert(NSPoint(x: 120, y: tree.outline.rect(ofRow: row).midY), to: nil)
            return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        }
        let src = try XCTUnwrap(tree.outline.item(atRow: 1) as? FileNode)
        tree.outline.mouseDown(with: try event(.leftMouseDown, row: 1))
        let selected = try XCTUnwrap(tree.outline.rowView(atRow: 1, makeIfNecessary: true) as? SelectionRowView)
        XCTAssertTrue(selected.isPressed)
        tree.outline.mouseDragged(with: try event(.leftMouseDragged, row: 0))
        let hovered = try XCTUnwrap(tree.outline.rowView(atRow: 0, makeIfNecessary: true) as? SelectionRowView)
        XCTAssertFalse(selected.isPressed)
        XCTAssertTrue(hovered.isHovered)
        tree.outline.mouseUp(with: try event(.leftMouseUp, row: 0))
        XCTAssertFalse(tree.outline.isItemExpanded(src), "Releasing outside the original row cancels the folder action")
        tree.outline.mouseExited(with: try event(.mouseMoved, row: 0))
        XCTAssertFalse(hovered.isHovered)
    }

}
