import AppKit
import XCTest
@testable import VCode

final class EditingPermissionTests: XCTestCase {
    override func setUp() { _ = NSApplication.shared }

    private func fixture() throws -> (URL, SourceEditStore) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("vcode-edit-permission-" + UUID().uuidString)
        let root = base.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "const value = 1;\nconsole.log(value);\n".write(to: root.appendingPathComponent("main.ts"), atomically: true, encoding: .utf8)
        try "second file\n".write(to: root.appendingPathComponent("other.txt"), atomically: true, encoding: .utf8)
        let store = SourceEditStore(directory: base.appendingPathComponent("recovery"))
        try store.activate(root)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        return (root, store)
    }

    private func show(_ editor: EditorView, root: URL, path: String = "main.ts") throws {
        let source = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        editor.prepare(path: path, diff: false, isGit: true)
        editor.show(FileSnapshot(path: path, before: "", after: source, rows: [], message: nil, isBinary: false, editable: true), diff: false, preserveScroll: false)
    }

    private func host(_ editor: EditorView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 580), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = editor
        editor.layoutSubtreeIfNeeded()
        return window
    }

    private func waitUntil(_ condition: @escaping () -> Bool) {
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)], timeout: 12), .completed)
    }

    func testDefaultReadOnlyAndTogglePreserveFindSelectionDirtyTextAndUndo() throws {
        let (root, store) = try fixture()
        let editor = EditorView(); editor.sourceEdits = store
        let window = host(editor)
        defer { editor.find.close(); window.close() }
        try show(editor, root: root)
        XCTAssertFalse(editor.sourceEditingAllowed)
        XCTAssertFalse(editor.right.text.isEditable)
        XCTAssertFalse(editor.canSaveDocument)
        XCTAssertTrue(editor.right.text.supportsCodeIntelligence)
        editor.sourceEditingAllowed = true
        XCTAssertTrue(editor.isEditableDocument)
        window.makeFirstResponder(editor.right.text)
        editor.right.text.setSelectedRange(NSRange(location: 6, length: 5))
        editor.performFind(.showFindInterface)
        waitUntil { editor.find.matches.count == 2 }
        editor.right.text.insertText("// edited\n", replacementRange: NSRange(location: 0, length: 0))
        editor.right.text.breakUndoCoalescing()
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        waitUntil { editor.find.matches.count == 2 }
        let text = editor.right.text.string
        let position = editor.right.readingPosition()
        let undo = try XCTUnwrap(editor.right.text.undoManager)
        XCTAssertTrue(undo.canUndo)
        editor.sourceEditingAllowed = false
        XCTAssertFalse(editor.isEditableDocument)
        XCTAssertTrue(editor.canSaveDocument, "Previously made edits remain explicitly savable")
        XCTAssertEqual(editor.right.text.string, text)
        XCTAssertEqual(editor.right.readingPosition(), position)
        XCTAssertTrue(editor.findBar.isFindBarVisible)
        XCTAssertTrue(editor.right.text.undoManager === undo)
        let undoItem = NSMenuItem(title: "Undo", action: NSSelectorFromString("undo:"), keyEquivalent: "z")
        XCTAssertFalse(editor.right.text.validateMenuItem(undoItem))
        editor.saveTextAs()
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("main.ts")), text)
        XCTAssertTrue(store.dirtyPaths.isEmpty)
        XCTAssertFalse(editor.canSaveDocument)
        editor.sourceEditingAllowed = true
        editor.right.text.undo(nil)
        XCTAssertTrue(store.buffer("main.ts")?.needsSave == true)
        editor.right.text.redo(nil)
        XCTAssertEqual(editor.right.text.string, text)
        XCTAssertTrue(store.dirtyPaths.isEmpty)
    }

    func testControllerSwitchAppliesToBothGroupsNewFilesAndFreshControllerStartsOff() throws {
        let (root, store) = try fixture()
        let controller = WorkspaceController(history: isolatedHistoryStore(), sourceEdits: store)
        let view = try XCTUnwrap(controller.view as? WorkspaceView)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentViewController = controller
        defer { controller.shutdown(); window.close() }
        let permission = NSMenuItem(title: "Allow File Editing", action: #selector(WorkspaceController.toggleFileEditing), keyEquivalent: "")
        permission.target = controller
        let menu = NSMenu(); menu.addItem(permission)
        XCTAssertTrue(controller.validateUserInterfaceItem(permission))
        XCTAssertEqual(permission.state, .off)
        controller.open(root)
        waitUntil { view.header.worktreeButton.title == "project" }
        controller.openFile("main.ts", diff: false)
        waitUntil { view.editor.currentSource != nil }
        XCTAssertFalse(view.editor.isEditableDocument)
        XCTAssertEqual(view.status.modeButton.title, "Read Only")
        XCTAssertTrue(view.status.modeButton.isEnabled)
        view.status.modeButton.performClick(nil)
        XCTAssertTrue(controller.validateUserInterfaceItem(permission))
        XCTAssertEqual(permission.state, .on)
        XCTAssertTrue(controller.allowsFileEditing)
        XCTAssertTrue(view.editor.isEditableDocument)
        controller.splitEditorRight()
        controller.openFile("other.txt", diff: false)
        waitUntil { view.editor.currentSource == "second file\n" }
        XCTAssertTrue(view.editorGroups.editors.allSatisfy(\.isEditableDocument))
        XCTAssertTrue(view.status.modeButton.isEnabled)
        view.status.modeButton.performClick(nil)
        XCTAssertTrue(controller.validateUserInterfaceItem(permission))
        XCTAssertEqual(permission.state, .off)
        XCTAssertFalse(controller.allowsFileEditing)
        XCTAssertTrue(view.editorGroups.editors.allSatisfy { !$0.right.text.isEditable })
        controller.openFile("main.ts", diff: false)
        waitUntil { view.editor.currentSource?.contains("const value") == true }
        XCTAssertFalse(view.editor.right.text.isEditable)
        controller.setFileEditingAllowed(true)
        let other = root.deletingLastPathComponent().appendingPathComponent("other-project")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try "new project\n".write(to: other.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        controller.open(other)
        waitUntil { view.header.worktreeButton.title == "other-project" }
        controller.openFile("file.txt", diff: false)
        waitUntil { view.editor.currentSource == "new project\n" }
        XCTAssertTrue(view.editor.isEditableDocument, "The global session switch also applies after changing projects")
        let fresh = WorkspaceController(history: isolatedHistoryStore(), sourceEdits: SourceEditStore(directory: root.deletingLastPathComponent().appendingPathComponent("fresh-recovery")))
        _ = fresh.view
        defer { fresh.shutdown() }
        XCTAssertFalse(fresh.allowsFileEditing)
        XCTAssertTrue(fresh.validateUserInterfaceItem(permission))
        XCTAssertEqual(permission.state, .off)
    }

    func testDraftAndDiffModesRemainIndependentOfTheGlobalPermission() throws {
        let (root, store) = try fixture()
        let editor = EditorView(); editor.sourceEdits = store
        editor.draftStore = TextDraftStore(directory: root.deletingLastPathComponent().appendingPathComponent("drafts"))
        editor.setWorkspaceOpen(true)
        let window = host(editor)
        defer { window.close() }
        editor.newTextTab()
        let draft = try XCTUnwrap(editor.activeDocument)
        XCTAssertTrue(editor.right.text.isEditable)
        editor.sourceEditingAllowed = true
        editor.sourceEditingAllowed = false
        XCTAssertTrue(editor.right.text.isEditable)
        XCTAssertTrue(editor.canSaveDocument)
        XCTAssertFalse(editor.canChangeSourceEditing)
        editor.sourceEditingAllowed = true
        editor.prepare(path: "main.ts", diff: true, isGit: true, comparison: .unstaged)
        let line = CodeLine(number: 1, text: "const value = 1;", kind: .unchanged)
        editor.show(FileSnapshot(path: "main.ts", before: line.text, after: line.text, rows: [DiffRow(left: line, right: line)], message: nil, isBinary: false, comparison: .unstaged), diff: true, preserveScroll: false)
        editor.editingSuspended = true; editor.editingSuspended = false
        XCTAssertFalse(editor.right.text.isEditable)
        XCTAssertFalse(editor.left.text.isEditable)
        XCTAssertFalse(editor.canSaveDocument)
        XCTAssertFalse(editor.canChangeSourceEditing)
        editor.sourceEditingAllowed = false
        editor.openDraft(draft)
        XCTAssertTrue(editor.isEditableDocument)
    }

    func testDirtyRecoveryAndRefreshDoNotBypassReadOnly() throws {
        let (root, store) = try fixture()
        try store.open("main.ts")
        store.update("main.ts", text: "recovered\ntext", sender: UUID())
        try store.flush()
        let recovered = SourceEditStore(directory: store.directory); try recovered.activate(root)
        let editor = EditorView(); editor.sourceEdits = recovered
        try show(editor, root: root)
        XCTAssertEqual(editor.right.text.string, "recovered\ntext")
        XCTAssertFalse(editor.right.text.isEditable)
        XCTAssertTrue(editor.canSaveDocument)
        editor.editingSuspended = true; editor.editingSuspended = false
        XCTAssertFalse(editor.right.text.isEditable)
        try show(editor, root: root)
        XCTAssertFalse(editor.right.text.isEditable)
        XCTAssertEqual(editor.right.text.string, "recovered\ntext")
        editor.showError(NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError))
        editor.sourceEditingAllowed = true
        XCTAssertFalse(editor.right.text.isEditable)
        XCTAssertFalse(editor.canSaveDocument)
    }

    func testMenuCannotTogglePermissionWhileAConfirmationSheetIsAttached() throws {
        let (root, store) = try fixture()
        let controller = WorkspaceController(history: isolatedHistoryStore(), sourceEdits: store)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 580), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentViewController = controller
        defer { controller.shutdown(); window.close() }
        let permission = NSMenuItem(title: "Allow File Editing", action: #selector(WorkspaceController.toggleFileEditing), keyEquivalent: "")
        permission.target = controller
        let menu = NSMenu(); menu.addItem(permission)
        controller.open(root)
        waitUntil { (controller.view as? WorkspaceView)?.header.worktreeButton.title == "project" }
        controller.setFileEditingAllowed(true)
        XCTAssertTrue(controller.validateUserInterfaceItem(permission))
        XCTAssertEqual(permission.state, .on)
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        window.beginSheet(sheet)
        XCTAssertFalse(controller.validateUserInterfaceItem(permission))
        menu.performActionForItem(at: 0)
        XCTAssertTrue(controller.allowsFileEditing, "An already dispatched action must respect the sheet lock too")
        window.endSheet(sheet); sheet.close()
        XCTAssertTrue(controller.validateUserInterfaceItem(permission))
        menu.performActionForItem(at: 0)
        XCTAssertFalse(controller.allowsFileEditing)
        XCTAssertTrue(controller.validateUserInterfaceItem(permission))
        XCTAssertEqual(permission.state, .off)
    }

    func testClickableModeKeepsTheStatusAppearanceAndFitsLongMessages() {
        let status = WorkspaceStatus()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 32), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = status
        defer { window.close() }
        XCTAssertFalse(status.modeButton.isBordered)
        XCTAssertFalse(status.modeButton.isEnabled)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            for editable in [false, true] {
                status.setEditable(editable)
                status.message.stringValue = String(repeating: "Long status ", count: 30)
                status.language.stringValue = "TypeScript · Ready"
                status.layoutSubtreeIfNeeded()
                XCTAssertEqual(status.modeButton.title, editable ? "Editable" : "Read Only")
                XCTAssertTrue(status.bounds.contains(status.modeButton.frame))
                XCTAssertLessThan(status.modeButton.frame.maxX, status.message.frame.minX)
                XCTAssertGreaterThan(status.modeButton.frame.width, 40)
            }
        }
    }


    func testStatusModeUsesHandBeforeClickAcrossTitleChangesAndStopsAtItsBounds() throws {
        let original = NSCursor.current
        defer { original.set() }
        let status = WorkspaceStatus()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 32), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = status
        defer { window.close() }
        func move(_ point: NSPoint, expected: NSCursor) throws {
            let location = status.convert(point, to: nil)
            for type in [NSEvent.EventType.mouseEntered, .cursorUpdate, .mouseMoved] {
                let event: NSEvent
                if type == .mouseMoved {
                    event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 0, pressure: 0))
                } else {
                    event = try XCTUnwrap(NSEvent.enterExitEvent(with: type, location: location, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, trackingNumber: 0, userData: nil))
                }
                NSCursor.crosshair.set()
                switch type {
                case .mouseEntered: status.mouseEntered(with: event)
                case .cursorUpdate: status.cursorUpdate(with: event)
                default: status.mouseMoved(with: event)
                }
                XCTAssertEqual(NSCursor.current, expected, "The first event must update the cursor without clicking: \(type), \(point)")
                XCTAssertEqual(status.modeBackground.isHidden, expected != .pointingHand, "Hover feedback must match the actual interactive region")
            }
        }
        for width: CGFloat in [920, 1200, 920] {
            window.setContentSize(NSSize(width: width, height: 32))
            for editable in [false, true, false] {
                status.setEditable(editable)
                status.modeButton.isEnabled = true
                status.message.stringValue = "Ln 12, Col 4"
                status.language.stringValue = "TypeScript · Ready"
                status.layoutSubtreeIfNeeded(); status.updateTrackingAreas()
                let areas = status.trackingAreas.filter { ($0.owner as? WorkspaceStatus) === status }
                XCTAssertTrue(areas.contains { $0.options.contains([.mouseMoved, .mouseEnteredAndExited, .activeAlways]) })
                XCTAssertTrue(areas.contains { $0.options.contains([.cursorUpdate, .activeInKeyWindow]) })
                let rect = status.convert(status.modeButton.bounds, from: status.modeButton)
                for x in [rect.minX + 2, rect.midX, rect.maxX - 2] {
                    try move(NSPoint(x: x, y: rect.midY), expected: .pointingHand)
                }
                let staticPoint = NSPoint(x: status.message.frame.midX, y: status.message.frame.midY)
                try move(staticPoint, expected: .arrow)
                status.modeButton.isEnabled = false
                try move(NSPoint(x: rect.midX, y: rect.midY), expected: .arrow)
                status.modeButton.isHidden = true
                try move(NSPoint(x: rect.midX, y: rect.midY), expected: .arrow)
                status.modeButton.isHidden = false
                try move(NSPoint(x: rect.midX, y: status.bounds.maxY + 10), expected: .crosshair)
            }
        }
    }


    func testStationaryModePointerUpdatesOnEnableAndLayoutWithoutChangingBackgroundCursor() {
        let original = NSCursor.current
        defer { original.set() }
        let status = WorkspaceStatus()
        let window = ModeCursorWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 32), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = status
        defer { window.close() }
        status.layoutSubtreeIfNeeded()
        let rect = status.convert(status.modeButton.bounds, from: status.modeButton)
        window.pointer = status.convert(NSPoint(x: rect.maxX - 1, y: rect.midY), to: nil)
        NSCursor.crosshair.set()
        status.setModeEnabled(true)
        XCTAssertEqual(NSCursor.current, .pointingHand)
        status.setModeEnabled(false)
        XCTAssertEqual(NSCursor.current, .arrow)
        status.setModeEnabled(true)
        XCTAssertEqual(NSCursor.current, .pointingHand)
        status.setEditable(true); status.layoutSubtreeIfNeeded()
        XCTAssertLessThan(status.modeButton.frame.maxX, rect.maxX - 1)
        XCTAssertEqual(NSCursor.current, .arrow, "The shorter title must retire the old hand region without moving the mouse")
        XCTAssertTrue(status.modeBackground.isHidden)
        status.setEditable(false); status.layoutSubtreeIfNeeded()
        XCTAssertEqual(NSCursor.current, .pointingHand)
        window.active = false
        NSCursor.crosshair.set()
        status.setModeEnabled(false); status.layoutSubtreeIfNeeded()
        XCTAssertEqual(NSCursor.current, .crosshair, "Background layout must not steal the foreground cursor")
        window.active = true
        window.pointer = status.convert(NSPoint(x: rect.midX, y: status.bounds.maxY + 10), to: nil)
        status.setModeEnabled(true); status.layoutSubtreeIfNeeded()
        XCTAssertEqual(NSCursor.current, .crosshair, "The editor or adjoining view owns the cursor outside the status bar")
    }


    func testHoverBackgroundKeepsTheNativeButtonHitTargetAndLeavesNoPermanentFill() {
        let status = WorkspaceStatus()
        let window = ModeCursorWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 32), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = status
        defer { window.close() }
        status.setModeEnabled(true); status.layoutSubtreeIfNeeded()
        XCTAssertTrue(status.modeBackground.isHidden)
        let frame = status.modeButton.frame
        window.pointer = status.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil)
        status.modeBackground.isHidden = false
        status.layoutSubtreeIfNeeded()
        XCTAssertEqual(status.modeButton.frame, frame)
        XCTAssertEqual(status.modeBackground.frame, frame)
        XCTAssertFalse(status.modeBackground.isHidden)
        XCTAssertTrue(status.hitTest(NSPoint(x: frame.midX, y: frame.midY)) === status.modeButton)
        status.modeBackground.isHidden = true
        XCTAssertTrue(status.modeBackground.isHidden)
        XCTAssertEqual(status.modeButton.frame, frame)
    }

}


private final class ModeCursorWindow: NSWindow {
    var pointer = NSPoint.zero
    var active = true
    override var mouseLocationOutsideOfEventStream: NSPoint { pointer }
    override var isKeyWindow: Bool { active }
}
