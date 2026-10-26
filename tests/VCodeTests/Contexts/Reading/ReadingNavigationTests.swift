import AppKit
import XCTest
@testable import VCode

final class ReadingNavigationTests: XCTestCase {
    override func setUp() { _ = NSApplication.shared }

    private func waitUntil(_ condition: @escaping () -> Bool, timeout: TimeInterval = 12, file: StaticString = #filePath, line: UInt = #line) {
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)], timeout: timeout)
        XCTAssertEqual(result, .completed, file: file, line: line)
    }

    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vcode-navigation-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["a.ts", "b.ts", "c.ts"] {
            let source = (0..<180).map { "// \(name) line \($0) " + String(repeating: "long ", count: 50) }.joined(separator: "\n")
            try source.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        return root
    }

    func testHistoryRestoresSelectionAndViewportPerGroupAndBranchesAfterBack() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = WorkspaceController(history: isolatedHistoryStore())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1360, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 1360, height: 700))
        defer { controller.shutdown(); withExtendedLifetime(window) {} }
        let workspace = try XCTUnwrap(controller.view as? WorkspaceView)
        controller.open(root)
        waitUntil { workspace.header.worktreeButton.title == root.lastPathComponent }
        let left = workspace.editor
        controller.openFile("a.ts", diff: false)
        waitUntil { left.currentSource?.contains("a.ts line 0") == true }
        workspace.layoutSubtreeIfNeeded()
        left.right.text.setSelectedRange(NSRange(location: left.right.offsets[70] + 12, length: 6))
        left.right.sync(to: NSPoint(x: 0, y: 1000))
        left.right.scroll.contentView.scroll(to: NSPoint(x: 120, y: 1000))
        left.right.scroll.reflectScrolledClipView(left.right.scroll.contentView)
        let originalY = left.right.scroll.contentView.bounds.minY
        let originalX = left.right.scroll.contentView.bounds.minX
        XCTAssertGreaterThan(originalX, 0)
        controller.openFile("b.ts", diff: false)
        waitUntil { left.currentSource?.contains("b.ts line 0") == true }
        XCTAssertTrue(left.canGoBack)
        left.allowsNavigation = false
        left.goBack()
        XCTAssertEqual(left.activePath, "b.ts")
        XCTAssertFalse(left.backButton.isEnabled)
        left.allowsNavigation = true
        controller.splitEditorRight()
        let right = workspace.editor
        waitUntil { right.currentSource?.contains("b.ts line 0") == true }
        controller.openFile("c.ts", diff: false)
        waitUntil { right.currentSource?.contains("c.ts line 0") == true }
        right.goBack()
        waitUntil { right.activePath == "b.ts" && right.currentSource?.contains("b.ts line 0") == true }
        XCTAssertEqual(left.activePath, "b.ts")
        workspace.editorGroups.activate(left)
        controller.goBack()
        waitUntil { left.activePath == "a.ts" && left.currentSource?.contains("a.ts line 0") == true }
        XCTAssertEqual(left.right.text.selectedRange(), NSRange(location: left.right.offsets[70] + 12, length: 6))
        XCTAssertEqual(left.right.scroll.contentView.bounds.minY, originalY, accuracy: 1)
        XCTAssertEqual(left.right.scroll.contentView.bounds.minX, originalX, accuracy: 1)
        XCTAssertEqual(right.activePath, "b.ts")
        controller.goForward()
        waitUntil { left.activePath == "b.ts" && left.currentSource?.contains("b.ts line 0") == true }
        controller.goBack()
        waitUntil { left.activePath == "a.ts" && left.currentSource?.contains("a.ts line 0") == true }
        controller.openFile("c.ts", diff: false)
        waitUntil { left.currentSource?.contains("c.ts line 0") == true }
        XCTAssertFalse(left.canGoForward)
        // Same-file definition jumps are separate stops, even with an existing tab.
        controller.openFile("c.ts", diff: false, line: 130, character: 7, highlightDestination: true)
        waitUntil { left.right.position(at: left.right.text.selectedRange().location)?.line == 130 }
        controller.goBack()
        waitUntil { left.right.position(at: left.right.text.selectedRange().location)?.line == 0 }
        XCTAssertEqual(left.activePath, "c.ts")
    }

    func testCloseReturnsToPreviousActiveEditorWithItsPositionAndKeepsOtherGroup() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = WorkspaceController(history: isolatedHistoryStore())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1360, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 1360, height: 700))
        defer { controller.shutdown(); withExtendedLifetime(window) {} }
        let workspace = try XCTUnwrap(controller.view as? WorkspaceView)
        controller.open(root)
        waitUntil { workspace.header.worktreeButton.title == root.lastPathComponent }
        let left = workspace.editor
        for path in ["a.ts", "b.ts", "c.ts", "a.ts"] {
            controller.openFile(path, diff: false)
            waitUntil { left.activePath == path && left.currentSource?.contains(path + " line 0") == true }
        }
        controller.splitEditorRight()
        let right = workspace.editor
        waitUntil { right.currentSource?.contains("a.ts line 0") == true }
        controller.openFile("c.ts", diff: false)
        waitUntil { right.currentSource?.contains("c.ts line 0") == true }
        workspace.editorGroups.activate(left)
        workspace.layoutSubtreeIfNeeded()
        let selection = NSRange(location: left.right.offsets[70] + 12, length: 6)
        left.right.text.setSelectedRange(selection)
        left.right.scroll.contentView.scroll(to: NSPoint(x: 120, y: 1000))
        left.right.scroll.reflectScrolledClipView(left.right.scroll.contentView)
        let viewport = left.right.scroll.contentView.bounds.origin
        XCTAssertGreaterThan(viewport.x, 0)
        XCTAssertGreaterThan(viewport.y, 0)
        // b.ts has c.ts to its right, but the previously active editor was a.ts.
        controller.openFile("b.ts", diff: false, line: 130, character: 7, highlightDestination: true)
        waitUntil { left.activePath == "b.ts" && left.right.position(at: left.right.text.selectedRange().location)?.line == 130 }
        controller.closeTab()
        waitUntil { left.activePath == "a.ts" && left.currentSource?.contains("a.ts line 0") == true }
        XCTAssertEqual(left.right.text.selectedRange(), selection)
        XCTAssertEqual(left.right.scroll.contentView.bounds.minX, viewport.x, accuracy: 1)
        XCTAssertEqual(left.right.scroll.contentView.bounds.minY, viewport.y, accuracy: 1)
        XCTAssertEqual(right.activePath, "c.ts")
        controller.closeTab()
        waitUntil { left.activePath == "c.ts" && left.currentSource?.contains("c.ts line 0") == true }
        controller.closeTab()
        XCTAssertEqual(workspace.editorGroups.editors.count, 1)
        XCTAssertTrue(workspace.editor === right)
        XCTAssertEqual(right.activePath, "c.ts")
    }

    func testExternalWritesRenameDeleteAndRecreateAutomaticallyPreserveAnchors() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = WorkspaceController(history: isolatedHistoryStore())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1360, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 1360, height: 700))
        defer { controller.shutdown(); withExtendedLifetime(window) {} }
        let workspace = try XCTUnwrap(controller.view as? WorkspaceView)
        controller.open(root)
        waitUntil { workspace.header.worktreeButton.title == root.lastPathComponent }
        let left = workspace.editor
        controller.openFile("a.ts", diff: false)
        waitUntil { left.currentSource?.contains("a.ts line 0") == true }
        controller.splitEditorRight()
        let right = workspace.editor
        controller.openFile("b.ts", diff: false)
        waitUntil { right.currentSource?.contains("b.ts line 0") == true }
        workspace.layoutSubtreeIfNeeded()
        left.right.text.setSelectedRange(NSRange(location: left.right.offsets[70] + 12, length: 6))
        left.right.sync(to: NSPoint(x: 0, y: 1000))
        let file = root.appendingPathComponent("a.ts")
        let oldSource = try String(contentsOf: file, encoding: .utf8)
        try ("// inserted one\n// inserted two\n" + oldSource).write(to: file, atomically: true, encoding: .utf8)
        waitUntil { left.currentSource?.hasPrefix("// inserted one") == true }
        XCTAssertEqual(left.right.position(at: left.right.text.selectedRange().location)?.line, 72)
        XCTAssertEqual(left.right.text.selectedRange().length, 6)
        XCTAssertEqual(left.right.scroll.contentView.bounds.minY, 1040, accuracy: 1)
        XCTAssertEqual(right.activePath, "b.ts")
        let renamed = root.appendingPathComponent("renamed.ts")
        try FileManager.default.moveItem(at: file, to: renamed)
        waitUntil { left.activePath == "renamed.ts" && left.currentSource?.contains("a.ts line 70") == true }
        XCTAssertEqual(left.right.position(at: left.right.text.selectedRange().location)?.line, 72)
        XCTAssertEqual(left.right.scroll.contentView.bounds.minY, 1040, accuracy: 1)
        try FileManager.default.removeItem(at: renamed)
        waitUntil { !left.subviews.compactMap { $0 as? NSTextField }.filter { $0.stringValue.contains("File deleted") && !$0.isHidden }.isEmpty }
        XCTAssertEqual(left.activePath, "renamed.ts")
        try ("// inserted one\n// inserted two\n" + oldSource).write(to: renamed, atomically: true, encoding: .utf8)
        waitUntil { !left.right.text.isHiddenOrHasHiddenAncestor && left.currentSource?.contains("a.ts line 70") == true }
        XCTAssertEqual(left.right.position(at: left.right.text.selectedRange().location)?.line, 72)
        XCTAssertEqual(left.right.scroll.contentView.bounds.minY, 1040, accuracy: 1)
        workspace.editorGroups.activate(left)
        controller.openFile("c.ts", diff: false)
        waitUntil { left.currentSource?.contains("c.ts line 0") == true }
        controller.goBack()
        waitUntil { left.activePath == "renamed.ts" && left.currentSource?.contains("a.ts line 70") == true }
        XCTAssertEqual(right.activePath, "b.ts")
    }

    func testAnchorUsesContextAndClampsRemovedOrEditedLines() {
        let lines = ["start", "{", "target", "}", "end"]
        let anchor = ReadingTextAnchor(line: 2, character: 6, lines: lines)
        XCTAssertEqual(anchor.resolvedLine(in: ["new", "new"] + lines), 4)
        XCTAssertEqual(anchor.resolvedLine(in: ["start", "{", "edited", "}", "end"]), 2)
        XCTAssertEqual(anchor.resolvedLine(in: []), 0)
        XCTAssertEqual(ReadingTextAnchor(line: 3, lines: lines).resolvedLine(in: ["end"]), 0)
    }

    func testMarkdownModeViewportAndExternalRefreshSurviveHistory() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("notes.md")
        let content = (0..<100).map { "## Heading \($0)\n\nParagraph \($0).\n" }.joined(separator: "\n")
        try content.write(to: file, atomically: true, encoding: .utf8)
        let controller = WorkspaceController(history: isolatedHistoryStore())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1360, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 1360, height: 700))
        defer { controller.shutdown(); withExtendedLifetime(window) {} }
        let workspace = try XCTUnwrap(controller.view as? WorkspaceView)
        controller.open(root)
        waitUntil { workspace.header.worktreeButton.title == root.lastPathComponent }
        let editor = workspace.editor
        controller.openFile("notes.md", diff: false)
        waitUntil { editor.showingMarkdownPreview && !editor.markdown.isRendering }
        workspace.layoutSubtreeIfNeeded()
        editor.markdown.scroll.contentView.scroll(to: NSPoint(x: 0, y: 600))
        editor.markdown.text.setSelectedRange(NSRange(location: 120, length: 4))
        controller.openFile("a.ts", diff: false)
        waitUntil { editor.currentSource?.contains("a.ts line 0") == true }
        controller.goBack()
        waitUntil { editor.activePath == "notes.md" && editor.showingMarkdownPreview && !editor.markdown.isRendering }
        XCTAssertEqual(editor.markdown.scroll.contentView.bounds.minY, 600, accuracy: 1)
        XCTAssertEqual(editor.markdown.text.selectedRange(), NSRange(location: 120, length: 4))
        try (content + "\nExternal addition\n").write(to: file, atomically: true, encoding: .utf8)
        waitUntil { editor.markdown.text.string.contains("External addition") && !editor.markdown.isRendering }
        XCTAssertEqual(editor.markdown.scroll.contentView.bounds.minY, 600, accuracy: 1)
        editor.showMarkdownSource()
        editor.right.text.setSelectedRange(NSRange(location: editor.right.offsets[30] + 3, length: 2))
        editor.right.sync(to: NSPoint(x: 0, y: 400))
        controller.openFile("b.ts", diff: false)
        waitUntil { editor.currentSource?.contains("b.ts line 0") == true }
        controller.goBack()
        waitUntil { editor.activePath == "notes.md" && editor.currentSource?.contains("External addition") == true }
        XCTAssertFalse(editor.showingMarkdownPreview)
        XCTAssertEqual(editor.right.position(at: editor.right.text.selectedRange().location)?.line, 30)
        XCTAssertEqual(editor.right.scroll.contentView.bounds.minY, 400, accuracy: 1)
    }

    func testTimelineBoundAndRenameApplyToBothDirections() {
        let anchor = ReadingTextAnchor(line: 0, lines: ["value"])
        let pane = PaneReadingPosition(start: anchor, end: anchor, top: anchor, verticalOffset: 0, horizontalOffset: 0)
        var history = ReadingHistory()
        for index in 0..<250 {
            history.visit(ReadingLocation(document: ReadingDocument(path: "\(index).ts", comparison: nil), right: pane, left: pane, markdown: nil, preview: false))
        }
        XCTAssertEqual(history.locations.count, 200)
        XCTAssertEqual(history.locations.first?.document.path, "50.ts")
        XCTAssertEqual(history.move(forward: false, current: nil)?.document.path, "248.ts")
        history.renamePaths(["248.ts": "renamed.ts", "249.ts": "next.ts"])
        XCTAssertEqual(history.move(forward: true, current: nil)?.document.path, "next.ts")
        XCTAssertEqual(history.move(forward: false, current: nil)?.document.path, "renamed.ts")
    }

    func testFocusedSplitMarkdownHistoryKeepsViewportWhenCaretIsOutsideIt() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = (0..<80).map { "## Section \($0)\n\nReading context \($0)." }.joined(separator: "\n\n")
        try source.write(to: root.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        let controller = WorkspaceController(history: isolatedHistoryStore())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 920, height: 580)
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 1100, height: 700))
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); controller.shutdown(); withExtendedLifetime(window) {} }
        let workspace = try XCTUnwrap(controller.view as? WorkspaceView)
        controller.open(root)
        waitUntil { workspace.header.worktreeButton.title == root.lastPathComponent }
        controller.openFile("a.ts", diff: false)
        waitUntil { workspace.editor.currentSource?.contains("a.ts line 0") == true }
        let left = workspace.editor
        controller.splitEditorRight()
        let editor = workspace.editor
        controller.openFile("notes.md", diff: false)
        waitUntil { editor.showingMarkdownPreview && !editor.markdown.isRendering }
        workspace.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(editor.markdown.scroll.frame.width, 250)
        XCTAssertGreaterThan(editor.markdown.scroll.frame.height, 300)
        window.makeFirstResponder(editor.markdown.text)
        editor.markdown.text.setSelectedRange(NSRange(location: 0, length: 0))
        editor.markdown.scroll.contentView.scroll(to: NSPoint(x: 0, y: 800))
        editor.markdown.scroll.reflectScrolledClipView(editor.markdown.scroll.contentView)
        let originalY = editor.markdown.scroll.contentView.bounds.minY
        XCTAssertGreaterThan(originalY, 700)
        controller.openFile("b.ts", diff: false)
        waitUntil { editor.currentSource?.contains("b.ts line 0") == true }
        // A cleared, hidden text view can retain a finite container height from
        // its preceding layout. History must lay out the entire new document.
        let container = try XCTUnwrap(editor.markdown.text.textContainer)
        container.containerSize.height = editor.markdown.scroll.contentSize.height + 38
        editor.backButton.performClick(nil)
        waitUntil { editor.activePath == "notes.md" && editor.showingMarkdownPreview && !editor.markdown.isRendering }
        window.displayIfNeeded()
        let settled = expectation(description: "layout and first responder settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { settled.fulfill() }
        wait(for: [settled], timeout: 2)
        XCTAssertEqual(editor.markdown.scroll.contentView.bounds.minY, originalY, accuracy: 1)
        XCTAssertEqual(editor.markdown.text.selectedRange(), NSRange(location: 0, length: 0))
        XCTAssertEqual(left.activePath, "a.ts")
    }

    func testMarkdownBackAndForwardAfterAsyncRefreshRetainVisibleContent() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let content = (0..<80).map { "## Section \($0)\n\nReading context \($0)." }.joined(separator: "\n\n")
        try content.write(to: root.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        let controller = WorkspaceController(history: isolatedHistoryStore())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 580), styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 920, height: 580)
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 920, height: 580))
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); controller.shutdown(); withExtendedLifetime(window) {} }
        let workspace = try XCTUnwrap(controller.view as? WorkspaceView)
        controller.open(root)
        waitUntil { workspace.header.worktreeButton.title == root.lastPathComponent }
        controller.openFile("a.ts", diff: false)
        waitUntil { workspace.editor.currentSource?.contains("a.ts line 0") == true }
        let left = workspace.editor
        controller.splitEditorRight()
        let editor = workspace.editor
        waitUntil { editor.currentSource?.contains("a.ts line 0") == true }
        controller.openFile("notes.md", diff: false)
        waitUntil { editor.showingMarkdownPreview && !editor.markdown.isRendering }
        workspace.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(editor.markdown.scroll.frame.width, 250)
        XCTAssertGreaterThan(editor.markdown.scroll.frame.height, 300)
        editor.markdown.scroll.contentView.scroll(to: NSPoint(x: 0, y: 832))
        editor.markdown.scroll.reflectScrolledClipView(editor.markdown.scroll.contentView)
        let y = editor.markdown.scroll.contentView.bounds.minY
        controller.openFile("c.ts", diff: false)
        waitUntil { editor.currentSource?.contains("c.ts line 0") == true }
        for _ in 0..<2 {
            editor.goBack()
            waitUntil { editor.activePath == "notes.md" && !editor.markdown.isRendering }
            // A refresh can arrive between starting and finishing preview rendering.
            controller.refresh()
            waitUntil { !editor.markdown.isRendering }
            window.displayIfNeeded()
            let settled = expectation(description: "native display settles")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { settled.fulfill() }
            wait(for: [settled], timeout: 2)
            XCTAssertEqual(editor.markdown.scroll.contentView.bounds.minY, y, accuracy: 1)
            editor.goForward()
            waitUntil { editor.activePath == "c.ts" && editor.currentSource?.contains("c.ts line 0") == true }
        }
        XCTAssertEqual(left.activePath, "a.ts")
    }

    func testRefreshDuringMarkdownHistoryArrivalKeepsThePendingAnchor() throws {
        let editor = EditorView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 450), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = editor
        window.setContentSize(NSSize(width: 600, height: 450))
        defer { window.orderOut(nil); withExtendedLifetime(window) {} }
        let source = (0..<60).map { "## Section \($0)\n\nReading context \($0)." }.joined(separator: "\n\n")
        func snapshot(_ text: String, path: String = "notes.md") -> FileSnapshot {
            FileSnapshot(path: path, before: "", after: text, rows: [], message: nil, isBinary: false)
        }
        editor.prepare(path: "notes.md", diff: false, isGit: false)
        editor.show(snapshot(source), diff: false, preserveScroll: false)
        waitUntil { !editor.markdown.isRendering }
        editor.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(editor.markdown.scroll.frame.height, 300)
        editor.markdown.scroll.contentView.scroll(to: NSPoint(x: 0, y: 832))
        let original = try XCTUnwrap(editor.markdown.readingPosition())
        editor.prepare(path: "other.ts", diff: false, isGit: false)
        editor.show(snapshot("const other = 1;", path: "other.ts"), diff: false, preserveScroll: false)
        editor.onRestoreLocation = { location in
            editor.prepare(path: location.document.path, diff: false, isGit: false, restoring: location, recordNavigation: false)
            editor.show(snapshot(source), diff: false, preserveScroll: false)
        }
        defer { editor.onRestoreLocation = nil }
        editor.goBack()
        XCTAssertTrue(editor.markdown.isRendering)
        XCTAssertEqual(editor.readingLocation()?.markdown?.top, original.top)
        // A changed snapshot arrives before the render completion is delivered.
        editor.show(snapshot(source + "\n\nExternal footer."), diff: false, preserveScroll: true)
        waitUntil { !editor.markdown.isRendering }
        XCTAssertEqual(editor.markdown.scroll.contentView.bounds.minY, original.y, accuracy: 1)
        XCTAssertEqual(editor.readingLocation()?.markdown?.top, original.top)
        XCTAssertTrue(editor.canGoForward)
    }

    func testLinkedWorktreeWatchesExternalGitMetadataAndBranchWithoutClearingGroups() throws {
        let primary = try root()
        let linked = primary.deletingLastPathComponent().appendingPathComponent("vcode-linked-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: linked); try? FileManager.default.removeItem(at: primary) }
        func git(_ args: [String], at root: URL) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", root.path, "-c", "core.hooksPath=/dev/null", "-c", "user.name=Test", "-c", "user.email=test@localhost", "-c", "commit.gpgsign=false"] + args
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, "\(args)")
        }
        try git(["init", "-qb", "main"], at: primary)
        let shared = primary.appendingPathComponent("shared.ts")
        try "export const version = 1;\n".write(to: shared, atomically: true, encoding: .utf8)
        try git(["add", "."], at: primary); try git(["commit", "-qm", "initial"], at: primary)
        try git(["branch", "same-content"], at: primary)
        try git(["worktree", "add", "-qb", "linked", linked.path], at: primary)
        let controller = WorkspaceController(history: isolatedHistoryStore())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1360, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 1360, height: 700))
        defer { controller.shutdown(); withExtendedLifetime(window) {} }
        let workspace = try XCTUnwrap(controller.view as? WorkspaceView)
        controller.open(linked)
        waitUntil { workspace.header.branchButton.title == "linked" }
        let left = workspace.editor
        controller.openFile("a.ts", diff: false)
        waitUntil { left.currentSource?.contains("a.ts line 0") == true }
        workspace.layoutSubtreeIfNeeded()
        left.right.text.setSelectedRange(NSRange(location: left.right.offsets[40] + 9, length: 0))
        left.right.sync(to: NSPoint(x: 0, y: 600))
        controller.splitEditorRight()
        let right = workspace.editor
        controller.openFile("shared.ts", diff: true, comparison: .unstaged)
        waitUntil { right.currentSource?.contains("version = 1") == true }
        let file = linked.appendingPathComponent("shared.ts")
        try "export const version = 2;\n".write(to: file, atomically: true, encoding: .utf8)
        waitUntil { right.right.text.string.contains("version = 2") && right.left.text.string.contains("version = 1") }
        // Only the index changes here, outside the linked worktree directory.
        try git(["add", "shared.ts"], at: linked)
        waitUntil { right.left.text.string.contains("version = 2") }
        try git(["reset", "--hard", "HEAD"], at: linked)
        waitUntil { right.right.text.string.contains("version = 1") }
        try git(["switch", "same-content"], at: linked)
        waitUntil { workspace.header.branchButton.title == "same-content" }
        XCTAssertEqual(workspace.editorGroups.editors.count, 2)
        XCTAssertEqual(left.activePath, "a.ts")
        XCTAssertEqual(left.right.position(at: left.right.text.selectedRange().location)?.line, 40)
        XCTAssertEqual(left.right.scroll.contentView.bounds.minY, 600, accuracy: 1)
        XCTAssertEqual(right.activePath, "shared.ts")
        let switched = expectation(description: "internal branch switch preserves reader")
        controller.activate(.branch("linked")) { result in
            XCTAssertEqual(try? result.get().branch, "linked")
            switched.fulfill()
        }
        wait(for: [switched], timeout: 10)
        XCTAssertEqual(workspace.editorGroups.editors.count, 2)
        XCTAssertEqual(left.activePath, "a.ts")
        waitUntil { right.currentSource?.contains("version = 1") == true }
        XCTAssertEqual(left.right.scroll.contentView.bounds.minY, 600, accuracy: 1)
    }
}
