import AppKit
import XCTest
@testable import VCode

final class SourceEditTests: XCTestCase {
    override func setUp() { _ = NSApplication.shared }

    private func fixture(_ contents: Data = Data("const target = 1;\n".utf8)) throws -> (URL, SourceEditStore) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("vcode-source-edit-" + UUID().uuidString)
        let root = base.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try contents.write(to: root.appendingPathComponent("main.ts"))
        let store = SourceEditStore(directory: base.appendingPathComponent("recovery"))
        try store.activate(root)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        return (root, store)
    }

    private func show(_ editor: EditorView, path: String = "main.ts", text: String = "const target = 1;\n", diff: Bool = false) {
        editor.sourceEditingAllowed = true
        editor.prepare(path: path, diff: diff, isGit: true)
        editor.show(FileSnapshot(path: path, before: text, after: text, rows: diff ? Diff.lines(text).enumerated().map {
            DiffRow(left: CodeLine(number: $0.offset + 1, text: $0.element, kind: .unchanged), right: CodeLine(number: $0.offset + 1, text: $0.element, kind: .unchanged))
        } : [], message: nil, isBinary: false, comparison: diff ? .workingTree : nil, editable: !diff), diff: diff, preserveScroll: false)
    }

    private func window(_ editor: EditorView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = editor
        editor.layoutSubtreeIfNeeded()
        return window
    }

    private func waitUntil(_ condition: @escaping () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 12), .completed, file: file, line: line)
    }

    private func editMenu(for responder: NSResponder) -> NSMenu {
        let menu = NSMenu(title: "Edit")
        StandardEditCommands.addUndoRedo(to: menu)
        for item in menu.items {
            XCTAssertNil(item.target, "The application menu starts with the native nil-target responder chain")
            // XCTest has no running NSApplication key-window loop. Resolve the
            // native action against the focused responder, then dispatch through
            // NSMenu rather than calling UndoManager directly.
            item.target = NSApp.target(forAction: item.action!, to: responder, from: item) as AnyObject?
            XCTAssertTrue(item.target === responder, "The focused text responder must own the standard action")
        }
        menu.update()
        return menu
    }

    private func keyEquivalent(_ menu: NSMenu, redo: Bool, window: NSWindow) throws {
        menu.update()
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: redo ? [.command, .shift] : .command, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: redo ? "Z" : "z",
            charactersIgnoringModifiers: redo ? "Z" : "z", isARepeat: false, keyCode: 6))
        XCTAssertTrue(menu.performKeyEquivalent(with: event))
    }

    func testStandardMenuAndCommandZUseFileHistoryAndUpdateSharedDirtyState() throws {
        let (_, store) = try fixture()
        let editor = EditorView(), other = EditorView()
        editor.sourceEdits = store; other.sourceEdits = store
        let host = window(editor)
        defer { host.close() }
        show(editor); show(other)
        host.makeFirstResponder(editor.right.text)
        let menu = editMenu(for: try XCTUnwrap(host.firstResponder))
        XCTAssertFalse(menu.items[0].isEnabled)
        XCTAssertFalse(menu.items[1].isEnabled)
        let baseline = editor.right.text.string
        editor.right.text.insertText("// 中文 🙂\n", replacementRange: NSRange(location: 0, length: 0))
        editor.right.text.breakUndoCoalescing()
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        XCTAssertTrue(editor.right.text.undoManager?.canUndo == true)
        XCTAssertFalse(host.undoManager?.canUndo == true, "Reproduce the independent window/file histories")
        menu.update()
        XCTAssertTrue(menu.items[0].isEnabled)
        menu.performActionForItem(at: 0)
        XCTAssertEqual(editor.right.text.string, baseline)
        XCTAssertEqual(other.right.text.string, baseline)
        XCTAssertTrue(store.dirtyPaths.isEmpty)
        XCTAssertFalse(editor.documentTitle(try XCTUnwrap(editor.activeDocument)).contains("•"))
        menu.update()
        XCTAssertTrue(menu.items[1].isEnabled)
        try keyEquivalent(menu, redo: true, window: host)
        XCTAssertTrue(editor.right.text.string.hasPrefix("// 中文 🙂\n"))
        XCTAssertEqual(other.right.text.string, editor.right.text.string)
        XCTAssertEqual(store.dirtyPaths, ["main.ts"])
        try keyEquivalent(menu, redo: false, window: host)
        XCTAssertEqual(editor.right.text.string, baseline)
        menu.update()
        menu.performActionForItem(at: 1)
        XCTAssertEqual(store.dirtyPaths, ["main.ts"])
        editor.right.text.isEditable = false
        menu.update()
        XCTAssertFalse(menu.items[0].isEnabled)
        XCTAssertFalse(menu.items[1].isEnabled)
        let readOnly = editor.right.text.string
        _ = NSApp.sendAction(NSSelectorFromString("undo:"), to: editor.right.text, from: menu.items[0])
        XCTAssertEqual(editor.right.text.string, readOnly)
    }

    func testDraftMenuUndoAndQueryInputKeepSeparateHistories() throws {
        let editor = EditorView()
        let (_, store) = try fixture()
        editor.draftStore = TextDraftStore(directory: store.directory.appendingPathComponent("drafts"))
        editor.setWorkspaceOpen(true)
        let host = window(editor)
        defer { editor.find.close(); host.close() }
        editor.newTextTab()
        host.makeFirstResponder(editor.right.text)
        editor.right.text.insertText("draft target", replacementRange: NSRange(location: 0, length: 0))
        editor.right.text.breakUndoCoalescing()
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        let menu = editMenu(for: try XCTUnwrap(host.firstResponder))
        try keyEquivalent(menu, redo: false, window: host)
        XCTAssertEqual(editor.right.text.string, "")
        try keyEquivalent(menu, redo: true, window: host)
        XCTAssertEqual(editor.right.text.string, "draft target")

        editor.performFind(.showFindInterface)
        let fieldEditor = try XCTUnwrap(editor.findBar.query.currentEditor() as? NSTextView)
        XCTAssertTrue(host.firstResponder === fieldEditor)
        XCTAssertFalse(fieldEditor === editor.right.text)
        XCTAssertFalse(editor.right.text === NSApp.target(forAction: NSSelectorFromString("undo:"), to: fieldEditor, from: nil) as AnyObject?)
        let queryBefore = fieldEditor.string
        fieldEditor.insertText(" query", replacementRange: NSRange(location: (queryBefore as NSString).length, length: 0))
        fieldEditor.breakUndoCoalescing()
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        let nativeTarget: NSResponder = fieldEditor.responds(to: NSSelectorFromString("undo:")) ? fieldEditor : host
        let queryMenu = editMenu(for: nativeTarget)
        try keyEquivalent(queryMenu, redo: false, window: host)
        XCTAssertEqual(fieldEditor.string, queryBefore)
        try keyEquivalent(queryMenu, redo: true, window: host)
        XCTAssertEqual(fieldEditor.string, queryBefore + " query")
        XCTAssertEqual(editor.right.text.string, "draft target")
    }

    func testFocusedGroupMenuOnlyChangesItsCurrentFile() throws {
        let (root, store) = try fixture()
        try Data("other".utf8).write(to: root.appendingPathComponent("other.ts"))
        let first = EditorView(), second = EditorView()
        first.sourceEdits = store; second.sourceEdits = store
        let a = window(first), b = window(second)
        defer { a.close(); b.close() }
        show(first); show(second, path: "other.ts", text: "other")
        first.right.text.insertText("first", replacementRange: NSRange(location: 0, length: 0))
        first.right.text.breakUndoCoalescing()
        second.right.text.insertText("second", replacementRange: NSRange(location: 0, length: 0))
        second.right.text.breakUndoCoalescing()
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        b.makeFirstResponder(second.right.text)
        let secondMenu = editMenu(for: try XCTUnwrap(b.firstResponder))
        try keyEquivalent(secondMenu, redo: false, window: b)
        XCTAssertEqual(second.right.text.string, "other")
        XCTAssertTrue(first.right.text.string.hasPrefix("first"))
        a.makeFirstResponder(first.right.text)
        let firstMenu = editMenu(for: try XCTUnwrap(a.firstResponder))
        try keyEquivalent(firstMenu, redo: false, window: a)
        XCTAssertEqual(first.right.text.string, "const target = 1;\n")
        XCTAssertTrue(store.dirtyPaths.isEmpty)
        try keyEquivalent(firstMenu, redo: true, window: a)
        XCTAssertTrue(first.right.text.string.hasPrefix("first"))
        XCTAssertEqual(second.right.text.string, "other")
    }

    func testSavePreservesBOMLineEndingsUnicodeAndPermissions() throws {
        let original = Data([0xef, 0xbb, 0xbf]) + Data("first\r\n中文🙂".utf8)
        let (root, store) = try fixture(original)
        let file = root.appendingPathComponent("main.ts")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        XCTAssertEqual(try store.open("main.ts").text, "first\r\n中文🙂")
        store.update("main.ts", text: "second\r\n中文🙂", sender: UUID())
        XCTAssertEqual(try Data(contentsOf: file), original, "Editing must not write into the repository")
        try store.save("main.ts")
        XCTAssertEqual(try Data(contentsOf: file), Data([0xef, 0xbb, 0xbf]) + Data("second\r\n中文🙂".utf8))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o755)
        XCTAssertFalse(try XCTUnwrap(store.buffer("main.ts")).needsSave)
    }

    func testExternalWriteDeletionAndSymlinkRefuseOverwriteAndAllowExportCopy() throws {
        let (root, store) = try fixture()
        let file = root.appendingPathComponent("main.ts")
        try store.open("main.ts")
        store.update("main.ts", text: "mine", sender: UUID())
        try Data("external".utf8).write(to: file)
        XCTAssertThrowsError(try store.save("main.ts"))
        XCTAssertEqual(try String(contentsOf: file), "external")
        XCTAssertEqual(try store.open("main.ts").text, "mine", "Refreshing dirty content must retain the working copy")
        let copy = root.appendingPathComponent("copy.ts")
        try store.export("main.ts", to: copy)
        XCTAssertEqual(try String(contentsOf: copy), "mine")
        XCTAssertEqual(store.dirtyPaths, ["main.ts"], "Exporting a copy does not save the original")
        try FileManager.default.removeItem(at: file)
        XCTAssertThrowsError(try store.save("main.ts"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: copy)
        XCTAssertThrowsError(try store.save("main.ts"))
        XCTAssertEqual(try String(contentsOf: copy), "mine")
    }

    func testRecoveryIsIsolatedByWorktreeAndLoadsEvenWhenOriginalIsDeleted() throws {
        let (root, store) = try fixture()
        try store.open("main.ts")
        store.update("main.ts", text: "unsaved 中文", sender: UUID())
        try store.flush()
        let second = root.deletingLastPathComponent().appendingPathComponent("worktree")
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try Data("other".utf8).write(to: second.appendingPathComponent("main.ts"))
        try store.activate(second)
        XCTAssertEqual(try store.open("main.ts").text, "other")
        let restored = SourceEditStore(directory: store.directory)
        try restored.activate(root)
        try FileManager.default.removeItem(at: root.appendingPathComponent("main.ts"))
        try restored.restoreRecovery("main.ts")
        XCTAssertEqual(restored.dirtyPaths, ["main.ts"])
        XCTAssertEqual(try restored.open("main.ts").text, "unsaved 中文")
        XCTAssertThrowsError(try restored.save("main.ts"))
        try restored.discard("main.ts")
        XCTAssertTrue(restored.dirtyPaths.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: store.directory.path).isEmpty)
    }

    func testCorruptRecoveryAndInvalidPathDoNotBecomeWritableBlankFiles() throws {
        let (_, store) = try fixture()
        try store.open("main.ts")
        store.update("main.ts", text: "unsaved", sender: UUID())
        try store.flush()
        let recovery = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: store.directory, includingPropertiesForKeys: nil).first)
        try Data("broken".utf8).write(to: recovery)
        let other = SourceEditStore(directory: store.directory)
        try other.activate(try XCTUnwrap(store.root))
        XCTAssertThrowsError(try other.open("main.ts"))
        XCTAssertThrowsError(try other.open("../escape"))
        XCTAssertThrowsError(try other.open("/absolute"))
        XCTAssertEqual(try String(contentsOf: recovery), "broken")
    }

    func testTwoGroupsShareEditsAndRefreshDoesNotReplaceDirtyTextOrLoseFind() throws {
        let (_, store) = try fixture()
        let first = EditorView(), second = EditorView()
        first.sourceEdits = store; second.sourceEdits = store
        let a = window(first), b = window(second)
        defer { a.close(); b.close() }
        show(first); show(second)
        XCTAssertTrue(first.isEditableDocument)
        XCTAssertTrue(first.right.text.supportsCodeIntelligence)
        second.right.text.setSelectedRange(NSRange(location: 6, length: 6))
        second.performFind(.showFindInterface)
        waitUntil { second.find.matches.count == 1 }
        first.right.text.insertText("target;\n", replacementRange: NSRange(location: first.right.text.string.utf16.count, length: 0))
        XCTAssertEqual(first.right.text.string, second.right.text.string)
        XCTAssertTrue(first.documentTitle(try XCTUnwrap(first.activeDocument)).contains("•"))
        waitUntil { second.find.matches.count == 2 }
        let source = first.right.text.string
        first.show(FileSnapshot(path: "main.ts", before: "", after: "const target = 1;\n", rows: [], message: nil, isBinary: false, editable: true), diff: false, preserveScroll: true)
        XCTAssertEqual(first.right.text.string, source)
        XCTAssertEqual(first.currentSource, source)
        XCTAssertEqual(first.right.diffOverview.frame.width, 45, accuracy: 1)
        first.saveTextAs()
        XCTAssertTrue(store.dirtyPaths.isEmpty)
        XCTAssertFalse(second.documentTitle(try XCTUnwrap(second.activeDocument)).contains("•"))
        XCTAssertTrue(second.findBar.isFindBarVisible)
    }

    func testFileSwitchUndoAndDiffReadOnlyRemainIndependent() throws {
        let (root, store) = try fixture()
        try Data("other".utf8).write(to: root.appendingPathComponent("other.ts"))
        let editor = EditorView()
        editor.sourceEdits = store
        let host = window(editor)
        defer { host.close() }
        show(editor)
        editor.right.text.insertText("typed", replacementRange: NSRange(location: 0, length: 0))
        editor.right.text.breakUndoCoalescing()
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        show(editor, path: "other.ts", text: "other")
        show(editor)
        XCTAssertTrue(editor.right.text.string.hasPrefix("typed"))
        host.makeFirstResponder(editor.right.text)
        let menu = editMenu(for: try XCTUnwrap(host.firstResponder))
        try keyEquivalent(menu, redo: false, window: host)
        XCTAssertEqual(editor.right.text.string, "const target = 1;\n")
        XCTAssertTrue(store.dirtyPaths.isEmpty)
        try keyEquivalent(menu, redo: true, window: host)
        XCTAssertTrue(store.dirtyPaths.contains("main.ts"))
        show(editor, diff: true)
        XCTAssertFalse(editor.right.text.isEditable)
        XCTAssertFalse(editor.left.text.isEditable)
        XCTAssertFalse(editor.isEditableDocument)
        host.makeFirstResponder(editor.right.text)
        menu.update()
        XCTAssertFalse(menu.items[0].isEnabled)
        XCTAssertFalse(menu.items[1].isEnabled)
        show(editor)
        XCTAssertTrue(editor.right.text.string.hasPrefix("typed"))
        XCTAssertTrue(editor.right.text.isEditable)
    }

    func testCloseCancelSaveAndDiscardAddressCorrectFile() throws {
        let (root, store) = try fixture()
        let editor = EditorView()
        editor.sourceEdits = store
        let host = window(editor)
        defer { host.close() }
        show(editor)
        editor.right.text.insertText("edited", replacementRange: NSRange(location: 0, length: 0))
        let document = try XCTUnwrap(editor.activeDocument)
        editor.closeActiveTab()
        clickSheet(host, title: "Cancel")
        XCTAssertEqual(editor.activeDocument, document)
        XCTAssertTrue(store.buffer("main.ts")?.needsSave == true)
        editor.closeActiveTab()
        clickSheet(host, title: "Save…")
        XCTAssertNil(editor.activeDocument)
        XCTAssertTrue(try String(contentsOf: root.appendingPathComponent("main.ts")).hasPrefix("edited"))
        show(editor)
        editor.right.text.insertText("discard", replacementRange: NSRange(location: 0, length: 0))
        editor.closeActiveTab()
        clickSheet(host, title: "Don’t Save")
        XCTAssertNil(editor.activeDocument)
        XCTAssertTrue(store.dirtyPaths.isEmpty)
        XCTAssertFalse(try String(contentsOf: root.appendingPathComponent("main.ts")).hasPrefix("discard"))
    }

    func testBatchCloseCancelDoesNotApplyEarlierDiscardAndExternalChangesResetStaleUndo() throws {
        let (root, store) = try fixture()
        try Data("other".utf8).write(to: root.appendingPathComponent("other.ts"))
        let editor = EditorView()
        editor.sourceEdits = store
        let host = window(editor)
        defer { host.close() }
        show(editor)
        editor.right.text.insertText("edited", replacementRange: NSRange(location: 0, length: 0))
        let first = try XCTUnwrap(editor.activeDocument)
        show(editor, path: "other.ts", text: "other")
        editor.right.text.insertText("edited", replacementRange: NSRange(location: 0, length: 0))
        let second = try XCTUnwrap(editor.activeDocument)
        var closed = false
        editor.requestClose([first, second]) { closed = true }
        clickSheet(host, title: "Don’t Save")
        clickSheet(host, title: "Cancel")
        XCTAssertFalse(closed)
        XCTAssertEqual(store.dirtyPaths, ["main.ts", "other.ts"])
        XCTAssertEqual(editor.captureSession().documents.count, 2)
        try store.save("main.ts")
        try Data("external main".utf8).write(to: root.appendingPathComponent("main.ts"))
        show(editor)
        XCTAssertEqual(editor.right.text.string, "external main")
        XCTAssertFalse(editor.right.text.undoManager?.canUndo == true, "Inactive files must not retain undo operations against old disk content")
    }

    func testInactiveRecoveryRestoresBeforeExitAndDeletedOriginalStaysEditableAfterCancel() throws {
        let (root, store) = try fixture()
        try Data("other".utf8).write(to: root.appendingPathComponent("other.ts"))
        let editor = EditorView()
        editor.sourceEdits = store
        let host = window(editor)
        defer { host.close() }
        show(editor)
        editor.right.text.insertText("recover", replacementRange: NSRange(location: 0, length: 0))
        show(editor, path: "other.ts", text: "other")
        let saved = editor.captureSession()
        let recoveredStore = SourceEditStore(directory: store.directory)
        try recoveredStore.activate(root)
        try FileManager.default.removeItem(at: root.appendingPathComponent("main.ts"))
        let restored = EditorView()
        restored.sourceEdits = recoveredStore
        restored.sourceEditingAllowed = true
        restored.restoreSession(saved)
        XCTAssertEqual(recoveredStore.dirtyPaths, ["main.ts"], "Inactive tabs must be known to exit confirmation")
        restored.prepare(path: "main.ts", diff: false, isGit: true)
        restored.show(FileSnapshot(path: "main.ts", before: "", after: "", rows: [], message: "File deleted", isBinary: false), diff: false, preserveScroll: false)
        XCTAssertEqual(restored.right.text.string, "recoverconst target = 1;\n")
        restored.editingSuspended = true
        restored.editingSuspended = false
        XCTAssertTrue(restored.isEditableDocument)
        XCTAssertNotNil(restored.readingLocation())
    }

    private func clickSheet(_ host: NSWindow, title: String, file: StaticString = #filePath, line: UInt = #line) {
        func buttons(_ view: NSView) -> [NSButton] { (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons) }
        guard let sheet = host.attachedSheet, let content = sheet.contentView,
              let button = buttons(content).first(where: { $0.title == title }) else { XCTFail("Missing sheet button: \(title)", file: file, line: line); return }
        button.performClick(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
    }

    func testControllerSaveRefreshesGitAndSwitchOrExitCanBeCancelled() throws {
        let (root, store) = try fixture()
        func git(_ args: [String]) throws {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", root.path] + args
            process.standardOutput = Pipe(); process.standardError = Pipe()
            try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
        }
        try git(["init", "-q"])
        try git(["add", "main.ts"])
        try git(["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "Initial"])
        let controller = WorkspaceController(history: isolatedHistoryStore(), sourceEdits: store)
        let view = try XCTUnwrap(controller.view as? WorkspaceView)
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1300, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false; host.contentViewController = controller
        defer { controller.shutdown(); host.close() }
        controller.setFileEditingAllowed(true)
        controller.open(root)
        waitUntil { view.header.worktreeButton.title == "project" }
        controller.openFile("main.ts", diff: false)
        waitUntil { view.editor.right.text.isEditable }
        XCTAssertTrue(view.status.modeButton.title == "Editable")
        view.editor.right.text.insertText("// saved\n", replacementRange: NSRange(location: 0, length: 0))
        controller.saveText()
        waitUntil { view.navigation.changes.toolTip?.contains("1 files") == true }
        XCTAssertTrue(try String(contentsOf: root.appendingPathComponent("main.ts")).hasPrefix("// saved"))
        view.editor.right.text.insertText("// unsaved\n", replacementRange: NSRange(location: 0, length: 0))
        var closeAllowed: Bool?
        controller.prepareToClose { closeAllowed = $0 }
        clickSheet(host, title: "Cancel")
        XCTAssertEqual(closeAllowed, false)
        XCTAssertTrue(view.editor.right.text.isEditable)
        let other = root.deletingLastPathComponent().appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        controller.open(other)
        clickSheet(host, title: "Cancel")
        XCTAssertEqual(view.header.worktreeButton.title, "project")
        XCTAssertTrue(view.editor.right.text.string.hasPrefix("// unsaved"))
        controller.open(other)
        clickSheet(host, title: "Don’t Save")
        waitUntil { view.header.worktreeButton.title == "other" }
        XCTAssertTrue(store.dirtyPaths.isEmpty)
    }
}
