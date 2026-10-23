import AppKit
import XCTest
@testable import VCode

final class ReadingSessionRestorationTests: XCTestCase {
    override func setUp() { _ = NSApplication.shared }

    private func waitUntil(_ condition: @escaping () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)], timeout: 12), .completed, file: file, line: line)
    }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vcode-restore-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src/deep"), withIntermediateDirectories: true)
        for name in ["a", "b", "deep/c"] {
            let text = (0..<180).map { "// \(name) line \($0) " + String(repeating: "long ", count: 40) }.joined(separator: "\n")
            try text.write(to: root.appendingPathComponent("src/\(name).ts"), atomically: true, encoding: .utf8)
        }
        try (0..<100).map { "## Section \($0)\n\nParagraph number \($0), with some **formatted content**.\n" }.joined(separator: "\n").write(to: root.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func window(_ history: WorkspaceHistoryStore) throws -> (WorkspaceController, WorkspaceView, NSWindow) {
        let controller = WorkspaceController(history: history)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1360, height: 800), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 1360, height: 800))
        let workspace = try XCTUnwrap(controller.view as? WorkspaceView)
        workspace.layoutSubtreeIfNeeded()
        return (controller, workspace, window)
    }

    private func open(_ root: URL, in controller: WorkspaceController, view: WorkspaceView) {
        controller.open(root)
        waitUntil { view.header.worktreeButton.title == root.lastPathComponent && view.navigation.search.isEnabled }
    }

    private func file(_ path: String, in controller: WorkspaceController, editor: EditorView, comparison: GitComparison? = nil) {
        controller.openFile(path, diff: comparison != nil, comparison: comparison ?? .workingTree, editor: editor)
        waitUntil { editor.activePath == path && editor.currentSource != nil && !editor.markdown.isRendering }
    }

    func testRelaunchRestoresGroupTabOrderInactivePositionsAndLazyTree() throws {
        let root = try fixture(), history = isolatedHistoryStore()
        let (controller, view, firstWindow) = try window(history)
        open(root, in: controller, view: view)
        let left = view.editor
        file("src/a.ts", in: controller, editor: left)
        view.layoutSubtreeIfNeeded()
        left.right.text.setSelectedRange(NSRange(location: left.right.offsets[65] + 10, length: 5))
        left.right.scroll.contentView.scroll(to: NSPoint(x: 90, y: 900))
        left.right.scroll.reflectScrolledClipView(left.right.scroll.contentView)
        let a = try XCTUnwrap(left.readingLocation())
        file("src/b.ts", in: controller, editor: left)
        file("src/deep/c.ts", in: controller, editor: left)
        let tabs = try XCTUnwrap(left.subviews.compactMap { $0 as? EditorTabs }.first)
        tabs.onMove?(ReadingDocument(path: "src/deep/c.ts", comparison: nil), 0)
        controller.splitEditorRight()
        let right = view.editor
        waitUntil { right.currentSource != nil }
        file("src/b.ts", in: controller, editor: right)
        right.right.text.setSelectedRange(NSRange(location: right.right.offsets[45] + 3, length: 0))
        right.right.sync(to: NSPoint(x: 0, y: 600))
        let b = try XCTUnwrap(right.readingLocation())
        view.explorer.select("src/a.ts")
        view.editorGroups.activate(left)
        view.restoreSidebarWidth(300)
        let split = try XCTUnwrap(view.editorGroups.subviews.first as? NSSplitView)
        split.setPosition((split.bounds.width - split.dividerThickness) * 0.4, ofDividerAt: 0)
        controller.saveReadingSession()
        controller.shutdown(); firstWindow.close()
        // Content changed while the application was closed: follow the anchor.
        let fileURL = root.appendingPathComponent("src/a.ts")
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        try (String(repeating: "// inserted\n", count: 4) + text).write(to: fileURL, atomically: true, encoding: .utf8)
        let restoredStore = WorkspaceHistoryStore(directory: history.file.deletingLastPathComponent(), legacyDefaults: nil)
        let (restored, restoredView, secondWindow) = try window(restoredStore)
        defer { restored.shutdown(); secondWindow.close() }
        open(try XCTUnwrap(restoredStore.lastFolder), in: restored, view: restoredView)
        waitUntil { restoredView.editorGroups.editors.count == 2 && restoredView.editorGroups.editors.allSatisfy { $0.currentSource != nil } }
        let groups = restoredView.editorGroups.editors
        XCTAssertTrue(restoredView.editor === groups[0])
        XCTAssertEqual(groups[0].captureSession().documents.map(\.path), ["src/deep/c.ts", "src/a.ts", "src/b.ts"])
        XCTAssertEqual(groups[0].activePath, "src/deep/c.ts")
        XCTAssertEqual(groups[1].activePath, "src/b.ts")
        XCTAssertEqual(groups[1].right.position(at: groups[1].right.text.selectedRange().location)?.line, b.right.start.line)
        XCTAssertEqual(groups[1].right.scroll.contentView.bounds.minY, 600, accuracy: 1)
        XCTAssertEqual(restoredView.sidebarWidth, 300, accuracy: 1)
        XCTAssertEqual(restoredView.editorGroups.splitRatio, 0.4, accuracy: 0.01)
        let tree = restoredView.explorer.captureSession()
        XCTAssertTrue(tree.expanded.contains("files\0src"))
        XCTAssertFalse(tree.expanded.contains("files\0src/deep"), "Restoring a tab must not eagerly expand its directory")
        XCTAssertEqual(tree.selection, "files\0src/a.ts")
        file("src/a.ts", in: restored, editor: groups[0])
        XCTAssertEqual(groups[0].right.position(at: groups[0].right.text.selectedRange().location)?.line, a.right.start.line + 4)
        XCTAssertEqual(groups[0].right.text.selectedRange().length, 5)
        XCTAssertEqual(groups[0].right.scroll.contentView.bounds.minX, a.right.horizontalOffset, accuracy: 1)
        XCTAssertEqual(groups[0].readingLocation()?.right.top.text, a.right.top.text)
    }

    func testMarkdownPreviewAndSourceModesSurvivePendingRestoreAndEmptySession() throws {
        let root = try fixture(), history = isolatedHistoryStore()
        let (controller, view, firstWindow) = try window(history)
        open(root, in: controller, view: view)
        file("notes.md", in: controller, editor: view.editor)
        view.editor.markdown.scroll.contentView.scroll(to: NSPoint(x: 0, y: 900))
        view.editor.markdown.scroll.reflectScrolledClipView(view.editor.markdown.scroll.contentView)
        let before = try XCTUnwrap(view.editor.readingLocation()?.markdown)
        controller.splitEditorRight()
        waitUntil { view.editor.currentSource != nil && !view.editor.markdown.isRendering }
        view.editor.showMarkdownSource()
        view.editor.right.sync(to: NSPoint(x: 0, y: 500))
        controller.shutdown(); firstWindow.close()
        let nextStore = WorkspaceHistoryStore(directory: history.file.deletingLastPathComponent(), legacyDefaults: nil)
        let (next, nextView, secondWindow) = try window(nextStore)
        defer { next.shutdown(); secondWindow.close() }
        open(root, in: next, view: nextView)
        // Save again before asynchronous Markdown rendering completes.
        next.saveReadingSession()
        let early = try XCTUnwrap(nextStore.readingSession(in: root)?.groups[0].positions.first?.markdown)
        XCTAssertEqual(early.top, before.top)
        waitUntil { nextView.editorGroups.editors.count == 2 && nextView.editorGroups.editors.allSatisfy { $0.currentSource != nil && !$0.markdown.isRendering } }
        let left = nextView.editorGroups.editors[0], right = nextView.editorGroups.editors[1]
        XCTAssertTrue(left.showingMarkdownPreview)
        XCTAssertFalse(right.showingMarkdownPreview)
        XCTAssertEqual(left.markdown.scroll.contentView.bounds.minY, before.y, accuracy: 1)
        XCTAssertEqual(right.right.scroll.contentView.bounds.minY, 500, accuracy: 1)
        nextView.editorGroups.close(right)
        XCTAssertTrue(left.closeActiveTab())
        next.saveReadingSession()
        let empty = try XCTUnwrap(nextStore.readingSession(in: root))
        XCTAssertEqual(empty.groups.count, 1)
        XCTAssertTrue(empty.groups[0].documents.isEmpty)
        XCTAssertNil(empty.groups[0].activeDocument)
    }

    func testWorktreesWithSameProjectKeepIndependentTabsTreesAndDiffScopes() throws {
        let primary = try fixture(), linked = primary.deletingLastPathComponent().appendingPathComponent("vcode-restore-linked-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: linked) }
        func git(_ args: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", primary.path, "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false", "-c", "user.name=Test", "-c", "user.email=test@example.invalid"] + args
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
        }
        try git(["init", "-qb", "main"]); try git(["add", "."]); try git(["commit", "-qm", "fixture"])
        try git(["worktree", "add", "-qb", "linked", linked.path])
        let destinations = try GitService(root: primary).destinations()
        let primaryRoot = destinations.root
        let linkedRoot = try XCTUnwrap(destinations.worktrees.first { $0.branch == "linked" }?.root)
        let history = isolatedHistoryStore()
        let (controller, view, window) = try window(history)
        defer { controller.shutdown(); window.close() }
        open(primary, in: controller, view: view)
        file("src/a.ts", in: controller, editor: view.editor)
        file("src/a.ts", in: controller, editor: view.editor, comparison: .staged)
        file("src/a.ts", in: controller, editor: view.editor, comparison: .unstaged)
        view.explorer.select("src/a.ts")
        controller.showChanges()
        if let node = view.explorer.outline.item(atRow: 0) { view.explorer.outline.collapseItem(node) }
        func activate(_ destination: GitDestination) {
            let done = expectation(description: "switch")
            controller.activate(destination) { result in
                if case .failure(let error) = result { XCTFail(error.localizedDescription) }
                done.fulfill()
            }
            wait(for: [done], timeout: 12)
        }
        activate(.worktree(linkedRoot))
        XCTAssertNil(view.editor.activePath)
        XCTAssertEqual(view.editorGroups.editors.count, 1)
        controller.showFiles()
        file("src/b.ts", in: controller, editor: view.editor)
        view.explorer.select("src/deep/c.ts")
        activate(.worktree(primaryRoot))
        waitUntil { view.editor.activeComparison == .unstaged && view.editor.currentSource != nil }
        XCTAssertEqual(view.editor.captureSession().documents.map(\.comparison), [nil, .staged, .unstaged])
        XCTAssertEqual(view.explorer.heading.stringValue, "CHANGES")
        XCTAssertFalse(view.explorer.outline.isItemExpanded(view.explorer.outline.item(atRow: 0)))
        activate(.worktree(linkedRoot))
        waitUntil { view.editor.activePath == "src/b.ts" && view.editor.currentSource != nil }
        XCTAssertEqual(view.explorer.heading.stringValue, "FILES")
        XCTAssertTrue(view.explorer.captureSession().expanded.contains("files\0src/deep"))
        XCTAssertEqual(history.entries.map(\.projectID).uniquedCount, 1)
        let rejected = expectation(description: "invalid branch")
        controller.activate(.branch("does-not-exist")) { result in
            if case .success = result { XCTFail("Expected switch failure") }
            rejected.fulfill()
        }
        wait(for: [rejected], timeout: 12)
        XCTAssertEqual(view.editor.activePath, "src/b.ts")
        controller.saveReadingSession()
        let restored = WorkspaceHistoryStore(directory: history.file.deletingLastPathComponent(), legacyDefaults: nil)
        XCTAssertEqual(restored.readingSession(in: primary)?.groups[0].documents.count, 3)
        XCTAssertEqual(restored.readingSession(in: linked)?.groups[0].activeDocument?.path, "src/b.ts")
    }

    func testImmediateQuitKeepsPendingTabsAndDeletedFilePositionWithoutReopeningClosedTabs() throws {
        let root = try fixture(), history = isolatedHistoryStore()
        let (controller, view, firstWindow) = try window(history)
        open(root, in: controller, view: view)
        file("src/a.ts", in: controller, editor: view.editor)
        view.editor.right.text.setSelectedRange(NSRange(location: view.editor.right.offsets[70] + 2, length: 4))
        controller.openFile("src/b.ts", diff: false)
        controller.shutdown(); firstWindow.close()
        try FileManager.default.removeItem(at: root.appendingPathComponent("src/a.ts"))
        let store = WorkspaceHistoryStore(directory: history.file.deletingLastPathComponent(), legacyDefaults: nil)
        let (next, nextView, secondWindow) = try window(store)
        defer { next.shutdown(); secondWindow.close() }
        open(root, in: next, view: nextView)
        waitUntil { nextView.editor.currentSource?.contains("b line 0") == true }
        XCTAssertEqual(nextView.editor.captureSession().documents.map(\.path), ["src/a.ts", "src/b.ts"])
        file("src/a.ts", in: next, editor: nextView.editor)
        XCTAssertEqual(nextView.editor.currentSource, "")
        XCTAssertEqual(nextView.editor.captureSession().positions.first { $0.document.path == "src/a.ts" }?.right.start.line, 70)
        XCTAssertTrue(nextView.editor.closeActiveTab())
        waitUntil { nextView.editor.currentSource?.contains("b line 0") == true }
        next.shutdown(); secondWindow.close()
        let lastStore = WorkspaceHistoryStore(directory: history.file.deletingLastPathComponent(), legacyDefaults: nil)
        let (last, lastView, thirdWindow) = try window(lastStore)
        defer { last.shutdown(); thirdWindow.close() }
        open(root, in: last, view: lastView)
        waitUntil { lastView.editor.currentSource?.contains("b line 0") == true }
        XCTAssertEqual(lastView.editor.captureSession().documents.map(\.path), ["src/b.ts"])
        XCTAssertEqual(lastView.editorGroups.editors.count, 1)
    }

    func testAutosaveCoalescesAndLegacyCorruptStatesRemainSafe() throws {
        let root = try fixture(), history = isolatedHistoryStore()
        let (controller, view, window) = try window(history)
        defer { controller.shutdown(); window.close() }
        open(root, in: controller, view: view)
        file("src/a.ts", in: controller, editor: view.editor)
        waitUntil { history.readingSession(in: root)?.groups.first?.activeDocument?.path == "src/a.ts" }
        view.editor.right.text.setSelectedRange(NSRange(location: view.editor.right.offsets[80] + 4, length: 3))
        waitUntil { history.readingSession(in: root)?.groups.first?.positions.first?.right.start.line == 80 }
        let directory = isolatedHistoryStore().file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("workspace.json")
        try Data("{\"version\":1,\"entries\":[]}".utf8).write(to: file)
        let legacy = WorkspaceHistoryStore(directory: directory, legacyDefaults: nil)
        XCTAssertNil(legacy.readingSession(in: root))
        legacy.saveReadingSession(try XCTUnwrap(history.readingSession(in: root)), in: root)
        XCTAssertNotNil(WorkspaceHistoryStore(directory: directory, legacyDefaults: nil).readingSession(in: root))
        let corrupt = Data("broken state".utf8); try corrupt.write(to: file)
        let blocked = WorkspaceHistoryStore(directory: directory, legacyDefaults: nil)
        blocked.saveReadingSession(try XCTUnwrap(history.readingSession(in: root)), in: root)
        XCTAssertNotNil(blocked.persistenceError)
        XCTAssertEqual(try Data(contentsOf: file), corrupt)
    }
}

private extension Array where Element: Hashable {
    var uniquedCount: Int { Set(self).count }
}
