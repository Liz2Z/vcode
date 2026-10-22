import AppKit
import XCTest
@testable import VCode

final class EditorGroupsTests: XCTestCase {
    override func setUp() { _ = NSApplication.shared }

    private func waitUntil(_ condition: @escaping () -> Bool, timeout: TimeInterval = 10) {
        wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)], timeout: timeout)
    }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vcode-editor-groups-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "export interface Alpha { value: number }\nexport const alpha: Alpha = { value: 1 };\nalpha.value;\n".write(to: root.appendingPathComponent("alpha.ts"), atomically: true, encoding: .utf8)
        try "export interface Beta { value: string }\nexport const beta: Beta = { value: 'two' };\nbeta.value;\n".write(to: root.appendingPathComponent("beta.ts"), atomically: true, encoding: .utf8)
        try "# Notes\n\nTwo independent editors.\n".write(to: root.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        return root
    }

    func testBothPaneLimitsResizeFocusAndRemovingGroupPreserveOtherReader() throws {
        let workspace = WorkspaceView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1360, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = workspace
        defer { withExtendedLifetime(window) {} }
        let groups = workspace.editorGroups
        XCTAssertFalse(workspace.editor.splitEditorButton.isEnabled)
        groups.splitActiveEditor()
        XCTAssertEqual(groups.editors.count, 1)
        workspace.show(WorkspaceState(root: URL(fileURLWithPath: "/tmp/group-layout"), files: ["alpha.ts"], git: nil), changesOnly: false)
        workspace.layoutSubtreeIfNeeded()
        let first = workspace.editor
        let source = (1...200).map { "// Reading line \($0)" }.joined(separator: "\n")
        first.prepare(path: "alpha.ts", diff: false, isGit: false)
        first.show(FileSnapshot(path: "alpha.ts", before: "", after: source, rows: [], message: nil, isBinary: false), diff: false, preserveScroll: false)
        first.layoutSubtreeIfNeeded()
        first.right.sync(to: NSPoint(x: 0, y: 300))
        let position = first.right.scroll.contentView.bounds.origin
        let outer = try XCTUnwrap(workspace.subviews.compactMap { $0 as? WorkspaceSplitView }.first)
        outer.setPosition(10_000, ofDividerAt: 0)
        first.splitEditorButton.performClick(nil)
        XCTAssertEqual(groups.editors.count, 2)
        XCTAssertTrue(first.splitEditorButton.isHidden)
        XCTAssertFalse(first.closeGroupButton.isHidden)
        XCTAssertTrue(groups.activeEditor === groups.editors[1])
        XCTAssertEqual(first.right.scroll.contentView.bounds.origin, position)
        for width: CGFloat in [1360, 920, 1700, 920] {
            window.setContentSize(NSSize(width: width, height: 700))
            workspace.layoutSubtreeIfNeeded()
            for editor in groups.editors { XCTAssertGreaterThanOrEqual(editor.frame.width, 219.5) }
            XCTAssertGreaterThanOrEqual(groups.frame.width, 451.5)
        }
        groups.activate(first)
        XCTAssertTrue(workspace.editor === first)
        let second = groups.editors[1]
        groups.splitActiveEditor()
        XCTAssertEqual(groups.editors.count, 2, "The requested layout has exactly two groups")
        second.closeGroupButton.performClick(nil)
        workspace.layoutSubtreeIfNeeded()
        XCTAssertEqual(groups.editors.count, 1)
        XCTAssertTrue(workspace.editor === first)
        XCTAssertEqual(first.right.text.string.trimmingCharacters(in: .newlines), source)
        let split = try XCTUnwrap(groups.subviews.first as? ResizableSplitView)
        XCTAssertEqual(split.arrangedSubviews.count, 1)
        XCTAssertEqual(first.frame.width, split.bounds.width, accuracy: 0.5)
        XCTAssertTrue(groups.splitView(split, shouldHideDividerAt: 0))
    }

    func testIndependentReadScopesRejectOnlyTheirOwnObsoleteOrClosedRequests() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = WorkspaceSession()
        defer { session.close() }
        let opened = expectation(description: "workspace open")
        session.onOpen = { _ in opened.fulfill() }
        session.open(root)
        wait(for: [opened], timeout: 10)
        let left = UUID(), right = UUID()
        let alpha = expectation(description: "left read"), beta = expectation(description: "right read")
        session.read("alpha.ts", diff: false, scope: left) { result in
            XCTAssertTrue((try? result.get().after.contains("interface Alpha")) == true)
            alpha.fulfill()
        }
        session.read("beta.ts", diff: false, scope: right) { result in
            XCTAssertTrue((try? result.get().after.contains("interface Beta")) == true)
            beta.fulfill()
        }
        wait(for: [alpha, beta], timeout: 10)
        var stale = false, closed = false
        let latest = expectation(description: "latest left read"), drained = expectation(description: "queue drained")
        session.read("alpha.ts", diff: false, scope: left) { _ in stale = true }
        session.read("notes.md", diff: false, scope: left) { _ in latest.fulfill() }
        session.read("beta.ts", diff: false, scope: right) { _ in closed = true }
        session.invalidateDocument(scope: right)
        session.read("alpha.ts", diff: false, scope: UUID()) { _ in drained.fulfill() }
        wait(for: [latest, drained], timeout: 10)
        XCTAssertFalse(stale)
        XCTAssertFalse(closed)
    }

    func testControllerLoadsRefreshesAndRoutesDefinitionsToEachGroup() throws {
        let root = try fixture()
        let nextRoot = try fixture()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: nextRoot) }
        let controller = WorkspaceController(history: isolatedHistoryStore())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1360, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentViewController = controller
        defer { controller.shutdown(); withExtendedLifetime(window) {} }
        let workspace = try XCTUnwrap(controller.view as? WorkspaceView)
        let groups = workspace.editorGroups
        controller.open(root)
        waitUntil { workspace.header.project.stringValue == root.lastPathComponent }
        let left = groups.activeEditor
        controller.openFile("alpha.ts", diff: false)
        controller.splitEditorRight()
        let right = groups.activeEditor
        XCTAssertFalse(left === right)
        controller.openFile("beta.ts", diff: false)
        waitUntil { left.right.text.string.contains("interface Alpha") && right.right.text.string.contains("interface Beta") }
        for (editor, name) in [(left, "alpha.ts"), (right, "beta.ts")] {
            let offset = (editor.right.text.string as NSString).range(of: "value", options: .backwards).location
            XCTAssertNotEqual(offset, NSNotFound)
            editor.right.text.onInspect?(offset, "definition")
            waitUntil({ editor.right.text.navigationFlashRange != nil }, timeout: 25)
            XCTAssertTrue(groups.activeEditor === editor)
            XCTAssertEqual(editor.activePath, name)
        }
        XCTAssertEqual(left.activePath, "alpha.ts")
        XCTAssertEqual(right.activePath, "beta.ts")
        let alphaPath = root.appendingPathComponent("alpha.ts"), betaPath = root.appendingPathComponent("beta.ts")
        try String(contentsOf: alphaPath, encoding: .utf8).replacingOccurrences(of: "value: 1", with: "value: 99").write(to: alphaPath, atomically: true, encoding: .utf8)
        try String(contentsOf: betaPath, encoding: .utf8).replacingOccurrences(of: "'two'", with: "'updated'").write(to: betaPath, atomically: true, encoding: .utf8)
        controller.refresh()
        waitUntil { left.right.text.string.contains("value: 99") && right.right.text.string.contains("'updated'") }
        groups.activate(left)
        controller.openFile("notes.md", diff: false)
        waitUntil { left.showingMarkdownPreview && !left.markdown.isRendering }
        XCTAssertEqual(right.activePath, "beta.ts")
        XCTAssertTrue(right.right.text.string.contains("'updated'"))
        right.closeGroupButton.performClick(nil)
        XCTAssertEqual(groups.editors.count, 1)
        XCTAssertTrue(groups.activeEditor === left)
        XCTAssertTrue(left.showingMarkdownPreview)
        controller.splitEditorRight()
        controller.openFile("beta.ts", diff: false)
        controller.open(nextRoot)
        waitUntil { workspace.header.project.stringValue == nextRoot.lastPathComponent }
        XCTAssertEqual(groups.editors.count, 1)
        XCTAssertNil(workspace.editor.activePath)
        XCTAssertTrue(workspace.editor.right.text.string.isEmpty)
        XCTAssertFalse(workspace.editor.welcome.isHidden)
    }

    func testComparisonGroupsKeepTheirVersionsDuringRefreshAndClosing() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("shared.ts")
        func write(_ value: Int) throws { try "export const version = \(value);\n".write(to: file, atomically: true, encoding: .utf8) }
        func git(_ args: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", root.path, "-c", "core.hooksPath=/dev/null"] + args
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
        }
        try write(1)
        try git(["init", "-q", "-b", "main"])
        try git(["add", "."])
        try git(["-c", "user.name=VCode", "-c", "user.email=test@localhost", "-c", "commit.gpgsign=false", "commit", "-qm", "Fixture"])
        try write(2); try git(["add", "shared.ts"]); try write(3)
        let controller = WorkspaceController(history: isolatedHistoryStore())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1360, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentViewController = controller
        defer { controller.shutdown(); withExtendedLifetime(window) {} }
        let workspace = try XCTUnwrap(controller.view as? WorkspaceView)
        let groups = workspace.editorGroups
        controller.open(root)
        waitUntil { workspace.header.branchButton.title == "Branch · main" }
        let left = groups.activeEditor
        controller.openFile("shared.ts", diff: true, comparison: .staged)
        controller.splitEditorRight()
        let right = groups.activeEditor
        controller.openFile("shared.ts", diff: true, comparison: .unstaged)
        waitUntil {
            left.left.text.string.contains("version = 1") && left.right.text.string.contains("version = 2")
                && right.left.text.string.contains("version = 2") && right.right.text.string.contains("version = 3")
        }
        XCTAssertEqual(left.activeComparison, .staged)
        XCTAssertEqual(right.activeComparison, .unstaged)
        try write(4)
        controller.refresh()
        waitUntil { right.right.text.string.contains("version = 4") && left.right.text.string.contains("version = 2") }
        controller.closeTab()
        waitUntil { right.activeComparison == .staged && right.right.text.string.contains("version = 2") }
        controller.closeTab()
        XCTAssertEqual(groups.editors.count, 1)
        XCTAssertTrue(groups.activeEditor === left)
        XCTAssertEqual(left.activeComparison, .staged)
        XCTAssertTrue(left.right.text.string.contains("version = 2"))
        controller.closeTab()
        XCTAssertEqual(groups.editors.count, 1)
        XCTAssertNil(left.activePath)
        XCTAssertFalse(left.welcome.isHidden)
    }
}
