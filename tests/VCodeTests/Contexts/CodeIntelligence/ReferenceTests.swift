import AppKit
import XCTest
@testable import VCode

final class ReferenceTests: XCTestCase {
    override func setUp() { _ = NSApplication.shared }

    func testGroupedResultsDeduplicateAndUseCurrentDocumentPreview() throws {
        let root = URL(fileURLWithPath: "/tmp/reference-tests")
        let a = root.appendingPathComponent("a.ts"), b = root.appendingPathComponent("nested/b.ts")
        let first = CodeLocation(url: a, line: 0, character: 13)
        let second = CodeLocation(url: a, line: 2, character: 3)
        let third = CodeLocation(url: b, line: 7, character: 9)
        var chosen: CodeLocation?
        let controller = LocationsController(locations: [third, first, second, first], root: root, references: true, currentDocument: (a, ["const value: Payload = updated;", "", "let other: Payload;"])) { chosen = $0 }
        let window = NSWindow(contentViewController: controller)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.setContentSize(NSSize(width: 720, height: 400))
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(controller.summary.stringValue, "3 references · 2 files")
        XCTAssertEqual(controller.rows.count, 5)
        guard case .file(let url, let count) = controller.rows[0] else { return XCTFail("Expected file header") }
        XCTAssertEqual(url, a)
        XCTAssertEqual(count, 2)
        let table = try XCTUnwrap(find(NSTableView.self, in: controller.view).first)
        XCTAssertFalse(controller.tableView(table, shouldSelectRow: 0))
        let cell = try XCTUnwrap(controller.tableView(table, viewFor: table.tableColumns.first, row: 1))
        let labels = find(NSTextField.self, in: cell)
        XCTAssertTrue(labels.contains { $0.stringValue.contains("updated") })
        XCTAssertTrue(labels.contains { $0.stringValue == "1:14" })
        let visible = try XCTUnwrap(table.view(atColumn: 0, row: 1, makeIfNecessary: true))
        visible.layoutSubtreeIfNeeded()
        let excerpt = try XCTUnwrap(find(NSTextField.self, in: visible).first { $0.stringValue.contains("updated") })
        XCTAssertGreaterThanOrEqual(excerpt.bounds.width, min(excerpt.intrinsicContentSize.width, 250), "The code excerpt must have room to render, not only exist in the accessibility tree")
        XCTAssertGreaterThanOrEqual(excerpt.bounds.height, 16)
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        XCTAssertNil(chosen)
        _ = NSApp.sendAction(try XCTUnwrap(table.action), to: table.target, from: table)
        XCTAssertEqual(chosen, first)
    }

    func testNoReferencesShowsAnExplicitEmptyResultsWindow() throws {
        let pane = CodePane()
        let parent = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        parent.contentView = pane
        pane.show(lines: [CodeLine(number: 1, text: "interface Unused {}", kind: .unchanged)], path: "main.ts", title: "", detail: "", showsHeader: false)
        let presenter = InspectionPresenter()
        defer { presenter.dismiss(); parent.close() }
        presenter.show(.locations([]), kind: .references, index: 12, textView: pane.text, root: URL(fileURLWithPath: "/tmp"))
        let window = try XCTUnwrap(presenter.locationsWindow)
        XCTAssertEqual(window.title, "References · Unused")
        let labels = find(NSTextField.self, in: try XCTUnwrap(window.contentView))
        XCTAssertTrue(labels.contains { $0.stringValue == "No references found" && !$0.isHidden })
    }

    func testHoverReferenceButtonRequestsExactSymbolAndClosesHover() throws {
        let pane = CodePane()
        let parent = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 700, height: 430), styleMask: [.borderless], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        parent.contentView = pane
        pane.show(lines: [CodeLine(number: 1, text: "interface Payload {}", kind: .unchanged)], path: "main.ts", title: "", detail: "", showsHeader: false)
        pane.layoutSubtreeIfNeeded()
        let presenter = InspectionPresenter()
        defer { presenter.dismiss(); parent.close() }
        var requested: Int?
        presenter.onFindReferences = { requested = $0 }
        presenter.show(.hover("```typescript\ninterface Payload\n```"), kind: .hover, index: 12, textView: pane.text, root: URL(fileURLWithPath: "/tmp"))
        let panel = try XCTUnwrap(presenter.hoverPanel)
        let button = try XCTUnwrap(find(NSButton.self, in: try XCTUnwrap(panel.contentView)).first { $0.title == "Find References" })
        XCTAssertTrue(parent.frame.contains(panel.frame))
        button.performClick(nil)
        XCTAssertEqual(requested, 12)
        XCTAssertNil(presenter.hoverPanel)
    }

    func testPreviewStoreReadsUTF16PositionedSourceAndReportsUnreadableFiles() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("vcode-reference-" + UUID().uuidString + ".ts")
        try "// 🙂\nconst result: Payload = value;\n".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let store = ReferencePreviewStore()
        let loaded = expectation(description: "Code excerpt loaded off main thread")
        store.line(at: CodeLocation(url: file, line: 1, character: 14)) { line in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(line, "const result: Payload = value;")
            loaded.fulfill()
        }
        let missing = expectation(description: "Missing preview remains a valid result")
        store.line(at: CodeLocation(url: file.appendingPathExtension("missing"), line: 0, character: 0)) { line in
            XCTAssertNil(line)
            missing.fulfill()
        }
        wait(for: [loaded, missing], timeout: 5)
    }

    func testCommandClickOnDeclarationShowsReferencesAndUsesStillJumpToDefinition() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vcode-definition-click-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = "/* 🙂 */ export interface Payload { value: string; }\nexport interface Unused { value: number; }\nexport interface Single { value: number; }\nexport const local: Payload = { value: 'hello' };\nexport const single: Single = { value: 1 };\n"
        let usage = "import type { Payload } from './model';\nexport function read(value: Payload): Payload { return value; }\n"
        try model.write(to: root.appendingPathComponent("model.ts"), atomically: true, encoding: .utf8)
        try usage.write(to: root.appendingPathComponent("usage.ts"), atomically: true, encoding: .utf8)
        try "interface Payload { other: boolean; }\nexport const unrelated: Payload = { other: true };\n".write(to: root.appendingPathComponent("unrelated.ts"), atomically: true, encoding: .utf8)
        try "{\"compilerOptions\":{\"strict\":true},\"include\":[\"*.ts\"]}".write(to: root.appendingPathComponent("tsconfig.json"), atomically: true, encoding: .utf8)
        let presenter = InspectionPresenter()
        let controller = WorkspaceController(history: isolatedHistoryStore(), inspection: presenter)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 650), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 1100, height: 650))
        defer { presenter.dismiss(); controller.shutdown(); withExtendedLifetime(window) {} }
        let workspace = try XCTUnwrap(controller.view as? WorkspaceView)
        func until(_ condition: @escaping () -> Bool, timeout: TimeInterval = 25) {
            let outcome = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)], timeout: timeout)
            XCTAssertEqual(outcome, .completed)
        }
        controller.open(root)
        until { workspace.header.worktreeButton.title == root.lastPathComponent }
        controller.openFile("model.ts", diff: false)
        let editor = workspace.editor
        until { editor.currentSource == model }
        workspace.layoutSubtreeIfNeeded()
        let declaration = (model as NSString).range(of: "Payload")
        // All parts of the identifier, including UTF-16 positions after an emoji,
        // must detect self-targeting; comparing only exact click/start positions fails.
        for index in [declaration.location, declaration.location + 3, NSMaxRange(declaration) - 1] {
            editor.right.text.onInspect?(index, "definition")
            until { presenter.locationsWindow != nil || editor.right.text.navigationFlashRange != nil }
            guard let resultWindow = presenter.locationsWindow else {
                XCTFail("Clicking a declaration must list its uses instead of flashing itself")
                return
            }
            XCTAssertEqual(resultWindow.title, "References · Payload")
            let results = try XCTUnwrap(resultWindow.contentViewController as? LocationsController)
            XCTAssertEqual(results.summary.stringValue, "4 references · 2 files")
            let locations = results.rows.compactMap { row -> CodeLocation? in
                if case .location(let location) = row { return location }; return nil
            }
            XCTAssertFalse(locations.contains { $0.url.lastPathComponent == "model.ts" && $0.line == 0 })
            XCTAssertFalse(locations.contains { $0.url.lastPathComponent == "unrelated.ts" })
            XCTAssertEqual(editor.activePath, "model.ts")
            XCTAssertNil(editor.right.text.navigationFlashRange)
            presenter.dismiss()
        }
        for (symbol, count) in [("Unused", 0), ("Single", 1)] {
            editor.right.text.onInspect?((model as NSString).range(of: symbol).location + 2, "definition")
            until { presenter.locationsWindow != nil }
            let resultWindow = try XCTUnwrap(presenter.locationsWindow)
            XCTAssertEqual(resultWindow.title, "References · " + symbol)
            let results = try XCTUnwrap(resultWindow.contentViewController as? LocationsController)
            XCTAssertEqual(results.summary.stringValue, "\(count) references · \(count) files")
            XCTAssertNil(editor.right.text.navigationFlashRange)
            presenter.dismiss()
        }
        // Same-file use and cross-file imported use retain ordinary definition jumps.
        let use = (model as NSString).range(of: "Payload", options: .backwards)
        editor.right.text.onInspect?(use.location + 2, "definition")
        until { editor.right.text.navigationFlashRange != nil }
        XCTAssertEqual(editor.right.text.navigationFlashRange, declaration)
        XCTAssertNil(presenter.locationsWindow)
        controller.openFile("usage.ts", diff: false)
        until { editor.currentSource == usage }
        editor.right.text.onInspect?((usage as NSString).range(of: "Payload", options: .backwards).location + 2, "definition")
        until { editor.activePath == "model.ts" && editor.right.text.navigationFlashRange != nil }
        XCTAssertEqual(editor.right.text.navigationFlashRange, declaration)
        XCTAssertNil(presenter.locationsWindow)
        // Clicking the target again should replace its existing arrival flash with a list.
        editor.right.text.onInspect?(declaration.location + 2, "definition")
        until { presenter.locationsWindow != nil }
        XCTAssertNil(editor.right.text.navigationFlashRange)
        presenter.dismiss()
        editor.right.text.onInspect?(declaration.location + 2, "definition")
        controller.openFile("usage.ts", diff: false)
        until { editor.currentSource == usage }
        let stale = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in presenter.locationsWindow != nil }, object: nil)
        stale.isInverted = true
        wait(for: [stale], timeout: 0.5)
        XCTAssertEqual(editor.activePath, "usage.ts")
    }

    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { find(type, in: $0) }
    }
}
