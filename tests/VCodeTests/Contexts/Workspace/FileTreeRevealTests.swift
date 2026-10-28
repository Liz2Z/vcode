import AppKit
import XCTest
@testable import VCode

final class FileTreeRevealTests: XCTestCase {
    func testChangesMenuRevealsLazyFileAndFolderWithoutOpeningOrDiscardingEditors() throws {
        _ = NSApplication.shared
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("vcode-tree-reveal-" + UUID().uuidString)
        let root = base.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("node_modules/pkg"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let target = "node_modules/pkg/中文 tracked.ts"
        try "const value = 1;\n".write(to: root.appendingPathComponent(target), atomically: true, encoding: .utf8)
        try "keep editor\n".write(to: root.appendingPathComponent("other.ts"), atomically: true, encoding: .utf8)
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["-C", root.path, "init", "-q", "-b", "main"]
        git.standardOutput = FileHandle.nullDevice; git.standardError = FileHandle.nullDevice
        try git.run(); git.waitUntilExit(); XCTAssertEqual(git.terminationStatus, 0)
        for args in [["add", "."], ["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false", "commit", "-qm", "Initial"]] {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", root.path] + args
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
        }
        try "const value = 2;\n".write(to: root.appendingPathComponent(target), atomically: true, encoding: .utf8)
        let store = SourceEditStore(directory: base.appendingPathComponent("source-recovery"))
        let controller = WorkspaceController(history: isolatedHistoryStore(), sourceEdits: store)
        let view = try XCTUnwrap(controller.view as? WorkspaceView)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentViewController = controller
        defer { controller.shutdown(); window.close() }
        func waitUntil(_ condition: @escaping () -> Bool) {
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)], timeout: 12), .completed)
        }
        func reveal(_ path: String) throws {
            let node = try XCTUnwrap((0..<view.explorer.outline.numberOfRows).compactMap { view.explorer.outline.item(atRow: $0) as? FileNode }.first { $0.path == path })
            let menu = try XCTUnwrap(view.explorer.outline.onContextMenu?(node))
            let item = try XCTUnwrap(menu.items.first { $0.title == "Reveal in Files" })
            XCTAssertTrue(item.isEnabled)
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        }
        controller.setFileEditingAllowed(true)
        controller.open(root)
        waitUntil { view.header.worktreeButton.title == "project" }
        controller.openFile("other.ts", diff: false)
        waitUntil { view.editor.isEditableDocument }
        view.editor.right.text.insertText("unsaved ", replacementRange: NSRange(location: 0, length: 0))
        let document = view.editor.activeDocument
        let text = view.editor.right.text.string
        view.explorer.restoreSession(FileTreeReadingState(expanded: [], collapsed: [], selection: nil, query: "other", scrollOffset: 0))
        controller.showChanges()
        view.explorer.restoreSession(FileTreeReadingState(expanded: [], collapsed: [], selection: nil, query: "tracked", scrollOffset: 0))
        let changesState = view.explorer.captureSession()
        try reveal(target)
        XCTAssertTrue(view.navigation.files.isSelected)
        XCTAssertEqual(view.explorer.heading.stringValue, "FILES")
        XCTAssertEqual(view.explorer.filter.stringValue, "")
        XCTAssertEqual((view.explorer.outline.item(atRow: view.explorer.outline.selectedRow) as? FileNode)?.path, target)
        XCTAssertEqual(view.editor.activeDocument, document)
        XCTAssertEqual(view.editor.right.text.string, text)
        XCTAssertTrue(store.buffer("other.ts")?.needsSave == true)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("other.ts")), "keep editor\n")
        controller.showChanges()
        XCTAssertEqual(view.explorer.filter.stringValue, "tracked")
        XCTAssertEqual(view.explorer.captureSession().expanded, changesState.expanded)
        try reveal("node_modules/pkg")
        let selected = try XCTUnwrap(view.explorer.outline.item(atRow: view.explorer.outline.selectedRow) as? FileNode)
        XCTAssertEqual(selected.path, "node_modules/pkg")
        XCTAssertTrue(selected.directory)
        XCTAssertEqual(view.editor.activeDocument, document)

        controller.showChanges()
        controller.openFile(target, diff: true, comparison: .unstaged)
        waitUntil { view.editor.showingDiff && view.editor.right.text.string.contains("value = 2") }
        let diff = view.editor.activeDocument
        let documents = view.editor.captureSession().documents
        let diffText = view.editor.right.text.string
        try reveal(target)
        XCTAssertTrue(view.navigation.files.isSelected)
        XCTAssertEqual(view.editor.activeDocument, diff)
        XCTAssertTrue(view.editor.showingDiff)
        XCTAssertEqual(view.editor.right.text.string, diffText)
        XCTAssertEqual(view.editor.captureSession().documents, documents)
        XCTAssertTrue(store.buffer("other.ts")?.needsSave == true)
    }
}
