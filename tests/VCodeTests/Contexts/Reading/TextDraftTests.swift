import AppKit
import XCTest
@testable import VCode

final class TextDraftTests: XCTestCase {
    override func setUp() { _ = NSApplication.shared }

    private func store() throws -> TextDraftStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vcode-drafts-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return TextDraftStore(directory: root)
    }

    func testDraftAndRealFileHaveDifferentIdentityAndDoNotRenameTogether() {
        var session = ReaderSession()
        let draft = ReadingDocument(path: "Untitled-1", comparison: nil, draftID: UUID())
        session.open("Untitled-1")
        session.open(draft)
        XCTAssertEqual(session.documents.count, 2)
        XCTAssertNil(session.activePath, "Drafts must never be read from the repository or sent to LSP")
        session.renamePaths(["Untitled-1": "renamed.ts"])
        XCTAssertEqual(session.activeDocument, draft)
        XCTAssertEqual(session.documents.first?.path, "renamed.ts")
        let oldJSON = Data(#"{"path":"main.ts","comparison":null}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(ReadingDocument.self, from: oldJSON).draftID)
    }

    func testDraftStoresExactUnicodeAndTrailingNewlinesOutsideReadingSession() throws {
        let store = try store(), id = UUID()
        let draft = TextDraft(text: "中文 🙂\n  last line")
        try store.save(draft, id: id)
        XCTAssertEqual(try store.load(id), draft)
        let attrs = try FileManager.default.attributesOfItem(atPath: store.directory.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        let broken = store.directory.appendingPathComponent(id.uuidString + ".json")
        try Data("invalid".utf8).write(to: broken)
        XCTAssertThrowsError(try store.load(id))
        XCTAssertEqual(try String(contentsOf: broken), "invalid")
    }

    func testSaveDoesNotOverwriteAnExternallyChangedDestination() throws {
        let store = try store()
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        let destination = store.directory.appendingPathComponent("note.txt")
        var draft = try store.export(TextDraft(text: "first"), to: destination)
        XCTAssertFalse(draft.needsSave)
        draft.text = "second"
        XCTAssertTrue(draft.needsSave)
        try Data("external".utf8).write(to: destination)
        XCTAssertThrowsError(try store.export(draft, to: destination))
        XCTAssertEqual(try String(contentsOf: destination), "external")
        XCTAssertEqual(draft.text, "second")
    }

    func testEditableTextSwitchingAndSessionRestoreKeepExactContentsAndCursor() throws {
        let store = try store()
        let editor = EditorView()
        editor.draftStore = store
        editor.setWorkspaceOpen(true)
        editor.newTextTab()
        let document = try XCTUnwrap(editor.activeDocument)
        XCTAssertTrue(editor.right.text.isEditable)
        editor.right.text.insertText("中文 🙂\nsecond", replacementRange: NSRange(location: 0, length: 0))
        editor.right.text.setSelectedRange(NSRange(location: 3, length: 0))
        let saved = editor.captureSession()
        XCTAssertEqual(try store.load(document.draftID!).text, "中文 🙂\nsecond")
        let data = try JSONEncoder().encode(saved)
        let metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let documents = try XCTUnwrap(metadata["documents"] as? [[String: Any]])
        XCTAssertNil(documents.first?["text"], "Draft contents belong in DATA_HOME; STATE_HOME only keeps IDs and reading anchors")
        editor.prepare(path: "main.ts", diff: false, isGit: true)
        editor.show(FileSnapshot(path: "main.ts", before: "", after: "const a = 1;", rows: [], message: nil, isBinary: false), diff: false, preserveScroll: false)
        XCTAssertFalse(editor.right.text.isEditable)
        let source = editor.right.text.string
        editor.openDraft(document)
        XCTAssertTrue(editor.right.text.isEditable)
        XCTAssertEqual(editor.right.text.string, "中文 🙂\nsecond")
        XCTAssertEqual(editor.right.text.selectedRange().location, 3)
        XCTAssertEqual(source, "const a = 1;\n")
        let restored = EditorView()
        restored.draftStore = store
        restored.restoreSession(try JSONDecoder().decode(EditorReadingSession.self, from: data))
        XCTAssertEqual(restored.activeDocument, document)
        XCTAssertTrue(restored.right.text.isEditable)
        XCTAssertEqual(restored.right.text.string, "中文 🙂\nsecond")
        XCTAssertEqual(restored.right.text.selectedRange().location, 3)
    }

    func testOnlyDoubleClickOnTabStripWhitespaceCreatesADraft() throws {
        let editor = EditorView()
        editor.draftStore = try store()
        editor.setWorkspaceOpen(true)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = editor
        editor.newTextTab()
        editor.layoutSubtreeIfNeeded()
        let tabs = try XCTUnwrap(editor.subviews.compactMap { $0 as? EditorTabs }.first)
        let scroll = try XCTUnwrap(tabs.subviews.compactMap { $0 as? NSScrollView }.first)
        let stack = try XCTUnwrap(scroll.documentView as? NSStackView)
        let tab = try XCTUnwrap(stack.arrangedSubviews.first)
        let titlePoint = editor.convert(NSPoint(x: tab.frame.midX, y: tab.frame.midY), from: stack)
        XCTAssertFalse(tabs.hitTest(titlePoint) === tabs)
        let blankPoint = NSPoint(x: tabs.frame.maxX - 20, y: tabs.frame.midY)
        XCTAssertTrue(tabs.hitTest(blankPoint) === tabs)
        var count = 0
        tabs.onNewText = { count += 1 }
        for clicks in [1, 2] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: editor.convert(blankPoint, to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: clicks, pressure: 1))
            tabs.mouseDown(with: event)
            XCTAssertEqual(count, clicks == 1 ? 0 : 1)
        }
        withExtendedLifetime(window) {}
    }

    func testControllerUpdatesEditableStatusWhenSwitchingBackToSourceAndBetweenGroups() throws {
        let store = try store()
        let root = store.directory.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "read only".write(to: root.appendingPathComponent("source.txt"), atomically: true, encoding: .utf8)
        let controller = WorkspaceController(history: isolatedHistoryStore())
        let view = try XCTUnwrap(controller.view as? WorkspaceView)
        defer { controller.shutdown() }
        controller.setFileEditingAllowed(true)
        controller.open(root)
        wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in view.header.worktreeButton.title == "project" }, object: nil)], timeout: 10)
        view.editor.draftStore = store
        controller.newTextTab()
        XCTAssertTrue(view.status.modeButton.title == "Editable")
        controller.openFile("source.txt", diff: false)
        XCTAssertEqual(view.status.modeButton.title, "Read Only", "Mode must update before the asynchronous source load, without a code click")
        wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in view.editor.isEditableDocument }, object: nil)], timeout: 10)
        XCTAssertTrue(view.status.modeButton.title == "Editable")
        controller.newTextTab()
        let draftEditor = view.editor
        controller.splitEditorRight()
        controller.openFile("source.txt", diff: false)
        XCTAssertEqual(view.status.modeButton.title, "Read Only")
        wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in view.editor.isEditableDocument }, object: nil)], timeout: 10)
        view.editorGroups.activate(draftEditor)
        XCTAssertTrue(view.status.modeButton.title == "Editable")
        view.editorGroups.activate(view.editorGroups.editors[1])
        XCTAssertTrue(view.status.modeButton.title == "Editable")
    }

    func testMissingDraftShowsErrorAndDoesNotBecomeWritableEmptyText() throws {
        let editor = EditorView()
        editor.draftStore = try store()
        let document = ReadingDocument(path: "Untitled-1", comparison: nil, draftID: UUID())
        editor.openDraft(document)
        XCTAssertFalse(editor.right.text.isEditable)
        XCTAssertThrowsError(try editor.draftStore.load(document.draftID!))
    }

    func testEditingUpdatesLineMappingAndNativeUndoWithoutAddingTrailingNewline() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        let pane = CodePane()
        window.contentView = pane
        pane.showEditable("", path: "")
        pane.text.onTextChange = { pane.updateEditableLines(path: "") }
        pane.text.insertText("first\n🙂", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(pane.text.string, "first\n🙂")
        XCTAssertEqual(pane.position(at: 8)?.line, 1)
        XCTAssertEqual(pane.position(at: 8)?.character, 2)
        XCTAssertTrue(pane.text.undoManager?.canUndo == true)
        pane.text.undoManager?.undo()
        XCTAssertEqual(pane.text.string, "")
        pane.text.undoManager?.redo()
        XCTAssertEqual(pane.text.string, "first\n🙂")
        withExtendedLifetime(window) {}
    }
}
