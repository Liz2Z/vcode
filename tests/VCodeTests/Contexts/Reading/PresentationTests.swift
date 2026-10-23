import AppKit
import XCTest
@testable import VCode

final class PresentationTests: XCTestCase {
    override func setUp() { _ = NSApplication.shared; NSApp.appearance = NSAppearance(named: .darkAqua) }

    func testSourceHasNoRetainedDividerAfterDiffAndWindowResize() throws {
        let editor = EditorView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = editor
        defer { withExtendedLifetime(window) {} }
        let before = "export const value = 1;\n"
        let after = "export const value = 2;\n"
        let snapshot = FileSnapshot(path: "main.ts", before: before, after: after, rows: [DiffRow(left: CodeLine(number: 1, text: before, kind: .removed), right: CodeLine(number: 1, text: after, kind: .added))], message: nil, isBinary: false)
        for diff in [false, true, false, true, false] {
            editor.prepare(path: snapshot.path, diff: diff, isGit: true)
            editor.show(snapshot, diff: diff, preserveScroll: false)
            for width: CGFloat in [1400, 700, 1800] {
                window.setContentSize(NSSize(width: width, height: 600))
                editor.layoutSubtreeIfNeeded()
                let split = try XCTUnwrap(editor.right.superview as? NSSplitView)
                split.adjustSubviews()
                XCTAssertEqual(split.arrangedSubviews.count, diff ? 2 : 1)
                XCTAssertTrue(split.arrangedSubviews.last === editor.right)
                XCTAssertEqual(editor.splitView(split, shouldHideDividerAt: 0), !diff)
                if diff {
                    XCTAssertTrue(split.arrangedSubviews.first === editor.left)
                    XCTAssertEqual(editor.right.frame.minX - editor.left.frame.maxX, 8, accuracy: 0.5)
                } else {
                    XCTAssertNil(editor.left.superview, "A merely hidden pane can leave a divider overlay over the source")
                    XCTAssertEqual(editor.right.frame.minX, 0, accuracy: 0.5)
                    XCTAssertEqual(editor.right.frame.width, split.bounds.width, accuracy: 0.5)
                }
            }
        }
    }

    func testGlassUsesNativeMaterialAndKeepsItsContentInteractive() throws {
        let button = Theme.actionButton("Open")
        let surface = GlassSurface(content: button)
        if #available(macOS 26.0, *) {
            let glass = try XCTUnwrap(surface.material as? NSGlassEffectView)
            XCTAssertTrue(glass.contentView === button)
            XCTAssertFalse(button.isBordered)
        } else {
            XCTAssertTrue(surface.material is NSVisualEffectView)
        }
        XCTAssertTrue(button.isEnabled)
        let workspace = WorkspaceView(frame: NSRect(x: 0, y: 0, width: 1360, height: 860))
        func surfaces(_ view: NSView) -> [GlassSurface] {
            (view as? GlassSurface).map { [$0] } ?? view.subviews.flatMap(surfaces)
        }
        XCTAssertEqual(surfaces(workspace).count, 1, "Keep glass to one workspace surface")
    }

    func testRepositoryControlsAndBreadcrumbsFitNarrowAndWideWindows() throws {
        let workspace = WorkspaceView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 580), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = workspace
        defer { withExtendedLifetime(window) {} }
        workspace.header.show(WorkspaceState(root: URL(fileURLWithPath: "/tmp/a-very-long-project-name"), files: [], git: GitStatus(root: URL(fileURLWithPath: "/tmp/a-very-long-project-name"), branch: "feature/a-very-long-branch-name", changes: [], hasHead: true)))
        workspace.editor.prepare(path: "src/a-very-long-folder/a-very-long-file-name.ts", diff: true, isGit: true)
        for size in [NSSize(width: 920, height: 580), NSSize(width: 1360, height: 860)] {
            window.setContentSize(size)
            workspace.layoutSubtreeIfNeeded()
            workspace.editor.layoutSubtreeIfNeeded()
            for button in [workspace.header.branchButton, workspace.header.worktreeButton, workspace.header.historyButton, workspace.header.openButton] {
                let frame = button.convert(button.bounds, to: workspace.header)
                XCTAssertTrue(workspace.header.bounds.insetBy(dx: -1, dy: -1).contains(frame))
                XCTAssertGreaterThan(frame.width, 40)
            }
            XCTAssertTrue(workspace.header.subviews.compactMap { $0 as? NSTextField }.isEmpty, "The worktree selector is the only workspace title")
            XCTAssertLessThan(workspace.header.worktreeButton.frame.maxX, workspace.header.branchButton.frame.minX)
            XCTAssertGreaterThan(workspace.header.worktreeButton.font!.pointSize, workspace.header.branchButton.font!.pointSize)
            let breadcrumbs = workspace.editor.breadcrumbs
            XCTAssertEqual(breadcrumbs.bounds.height, 28)
            XCTAssertFalse(breadcrumbs.subviews.contains { $0 is NSButton }, "The reading action strip must not return")
            XCTAssertGreaterThanOrEqual(workspace.editor.bounds.width, 560)
            XCTAssertLessThanOrEqual(workspace.explorer.bounds.width, 360)
        }
        workspace.header.show(WorkspaceState(root: URL(fileURLWithPath: "/tmp/plain-folder"), files: [], git: nil))
        XCTAssertEqual(workspace.header.worktreeButton.title, "plain-folder")
        XCTAssertFalse(workspace.header.worktreeButton.isEnabled)
        XCTAssertEqual(workspace.header.worktreeButton.contentTintColor, Theme.text, "The workspace title remains readable when switching is unavailable")
    }

    func testSyntaxDoesNotTreatURLsInsideStringsAsComments() {
        let source = "const url = 'https://example.com'; // a comment\n"
        let storage = NSTextStorage(string: source)
        Syntax.apply(to: storage, path: "main.ts", font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        let stringRange = (source as NSString).range(of: "https://example.com")
        let commentRange = (source as NSString).range(of: "// a comment")
        let stringColor = storage.attribute(.foregroundColor, at: stringRange.location, effectiveRange: nil) as? NSColor
        let lastStringColor = storage.attribute(.foregroundColor, at: stringRange.location + stringRange.length - 1, effectiveRange: nil) as? NSColor
        let commentColor = storage.attribute(.foregroundColor, at: commentRange.location, effectiveRange: nil) as? NSColor
        XCTAssertEqual(stringColor, lastStringColor)
        XCTAssertNotEqual(stringColor, commentColor)
    }

    func testClosingLastTabClearsBothPanesAndRejectsLateContent() {
        let editor = EditorView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let snapshot = FileSnapshot(path: "main.ts", before: "const value = 1;", after: "const value = 2;", rows: [
            DiffRow(left: CodeLine(number: 1, text: "const value = 1;", kind: .removed), right: CodeLine(number: 1, text: "const value = 2;", kind: .added))
        ], message: nil, isBinary: false)
        for diff in [true, false] {
            editor.prepare(path: snapshot.path, diff: diff, isGit: true)
            editor.show(snapshot, diff: diff, preserveScroll: false)
            XCTAssertFalse(editor.right.text.string.isEmpty)
            XCTAssertTrue(editor.closeActiveTab())
            XCTAssertNil(editor.activePath)
            XCTAssertFalse(editor.welcome.isHidden)
            XCTAssertTrue(editor.breadcrumbs.isHidden)
            XCTAssertTrue(editor.left.isHiddenOrHasHiddenAncestor)
            XCTAssertTrue(editor.left.text.string.isEmpty)
            XCTAssertTrue(editor.right.text.string.isEmpty)
            editor.show(snapshot, diff: diff, preserveScroll: false)
            XCTAssertFalse(editor.welcome.isHidden, "A late read must not reopen a closed tab")
            XCTAssertTrue(editor.right.text.string.isEmpty)
        }
        editor.prepare(path: snapshot.path, diff: true, isGit: true)
        editor.show(snapshot, diff: true, preserveScroll: false)
        XCTAssertTrue(editor.welcome.isHidden)
        XCTAssertFalse(editor.breadcrumbs.isHidden)
        XCTAssertFalse(editor.right.text.string.isEmpty)
    }

    func testEmptyWorkspaceOffersFileSelectionAndKeepsThatStateAfterClosingLastTab() {
        let workspace = WorkspaceView()
        let editor = workspace.editor
        XCTAssertFalse(editor.welcome.openButton.isHidden)
        workspace.show(WorkspaceState(root: URL(fileURLWithPath: "/tmp/open-project"), files: ["main.ts"], git: nil), changesOnly: false)
        XCTAssertTrue(editor.welcome.openButton.isHidden)
        XCTAssertFalse(editor.welcome.openButton.isEnabled)
        let labels = editor.welcome.subviews.compactMap { $0 as? NSTextField }.map(\.stringValue)
        XCTAssertTrue(labels.contains("Select a file to begin."))
        XCTAssertFalse(labels.contains { $0.localizedCaseInsensitiveContains("Open folder") })
        editor.prepare(path: "main.ts", diff: false, isGit: false)
        editor.show(FileSnapshot(path: "main.ts", before: "", after: "export const value = 1;", rows: [], message: nil, isBinary: false), diff: false, preserveScroll: false)
        XCTAssertTrue(editor.closeActiveTab())
        XCTAssertFalse(editor.welcome.isHidden)
        XCTAssertTrue(editor.welcome.openButton.isHidden, "Closing the last file must not turn an open project into onboarding")
        workspace.show(WorkspaceState(root: URL(fileURLWithPath: "/tmp/another-worktree"), files: [], git: nil), changesOnly: false)
        editor.reset()
        XCTAssertTrue(editor.welcome.openButton.isHidden)
        editor.setWorkspaceOpen(false)
        XCTAssertFalse(editor.welcome.openButton.isHidden)
        XCTAssertTrue(editor.welcome.openButton.isEnabled)
    }

    func testPaddedDiffRowsMapToOriginalUTF16Positions() {
        let pane = CodePane(frame: NSRect(x: 0, y: 0, width: 600, height: 500))
        pane.show(lines: [
            CodeLine(number: 1, text: "const emoji = '🙂';", kind: .unchanged),
            CodeLine(number: nil, text: "", kind: .placeholder),
            CodeLine(number: 2, text: "export const result = emoji;", kind: .added)
        ], path: "main.ts", title: "Modified", detail: "WORKING TREE")
        XCTAssertNil(pane.position(at: pane.offsets[1]))
        XCTAssertEqual(pane.position(at: pane.offsets[2] + 13)?.line, 1)
        XCTAssertEqual(pane.position(at: pane.offsets[2] + 13)?.character, 13)
        XCTAssertEqual(pane.offsets[1], ("const emoji = '🙂';\n" as NSString).length)
        XCTAssertEqual(pane.characterRange(startLine: 1, startCharacter: 13, endLine: 1, endCharacter: 19), NSRange(location: pane.offsets[2] + 13, length: 6))
        XCTAssertNil(pane.characterRange(startLine: 1, startCharacter: 999, endLine: 1, endCharacter: 1000))
    }

    func testNativePaneLineGeometryAndRender() throws {
        let pane = CodePane(frame: NSRect(x: 0, y: 0, width: 630, height: 480))
        pane.show(lines: [
            CodeLine(number: 1, text: "export interface Project {", kind: .unchanged),
            CodeLine(number: 2, text: "  id: string;", kind: .unchanged),
            CodeLine(number: 3, text: "  name: string;", kind: .added),
            CodeLine(number: nil, text: "", kind: .placeholder),
            CodeLine(number: 4, text: "}", kind: .unchanged)
        ], path: "project.ts", title: "Modified", detail: "WORKING TREE")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 630, height: 480), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = pane
        pane.layoutSubtreeIfNeeded()
        guard let layout = pane.text.layoutManager, let container = pane.text.textContainer else { return XCTFail("Missing text layout") }
        layout.ensureLayout(for: container)
        let firstGlyph = layout.glyphIndexForCharacter(at: pane.offsets[0])
        let secondGlyph = layout.glyphIndexForCharacter(at: pane.offsets[1])
        let first = layout.lineFragmentRect(forGlyphAt: firstGlyph, effectiveRange: nil)
        let second = layout.lineFragmentRect(forGlyphAt: secondGlyph, effectiveRange: nil)
        XCTAssertEqual(second.minY - first.minY, 20, accuracy: 0.1)
        XCTAssertGreaterThan(pane.text.bounds.height, 0)
        if let output = ProcessInfo.processInfo.environment["VCODE_PANE_SNAPSHOT"], let bitmap = pane.bitmapImageRepForCachingDisplay(in: pane.bounds) {
            pane.cacheDisplay(in: pane.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output))
        }
        withExtendedLifetime(window) {}
    }

    func testWorkspaceFileTreeAndSplitDiffFlow() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vcode-window-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src/lib"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("src/workspace.ts")
        let context = (1...180).map { "// Additional context line \($0)\n" }.joined()
        let before = "export interface Workspace {\n  name: string;\n  files: string[];\n}\n\nexport function createWorkspace(name: string): Workspace {\n  return { name, files: [] };\n}\n" + context
        let after = "export interface Workspace {\n  name: string;\n  files: readonly string[];\n  version: number;\n}\n\nexport function createWorkspace(name: string): Workspace {\n  return { name, files: [], version: 1 };\n}\n" + context
        try before.write(to: source, atomically: true, encoding: .utf8)
        try "export const version = 1;\n".write(to: root.appendingPathComponent("src/lib/version.ts"), atomically: true, encoding: .utf8)
        for arguments in [["init", "-q", "-b", "main"], ["add", "."], ["-c", "user.name=VCode", "-c", "user.email=test@localhost", "-c", "commit.gpgsign=false", "commit", "-qm", "Initial workspace"]] {
            let git = Process()
            git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            git.arguments = ["-C", root.path] + arguments
            git.standardOutput = FileHandle.nullDevice
            git.standardError = FileHandle.nullDevice
            try git.run(); git.waitUntilExit()
            XCTAssertEqual(git.terminationStatus, 0)
        }
        try after.write(to: source, atomically: true, encoding: .utf8)
        let controller = WorkspaceController(history: isolatedHistoryStore())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1360, height: 860), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 1360, height: 860))
        defer { controller.shutdown() }
        func find<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
            (view as? T).map { [$0] } ?? [] + view.subviews.flatMap { find(type, in: $0) }
        }
        guard let tree = find(FileTree.self, in: controller.view).first else { return XCTFail("Missing file tree") }
        controller.open(root)
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in tree.outline.numberOfRows > 0 }, object: nil)
        wait(for: [loaded], timeout: 8)
        controller.showChanges()
        XCTAssertEqual(tree.heading.stringValue, "CHANGES")
        controller.openFile("src/workspace.ts", diff: true)
        var panes: [CodePane] = []
        let rendered = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            panes = find(CodePane.self, in: controller.view)
            return panes.count == 2 && panes[1].text.string.contains("readonly")
        }, object: nil)
        wait(for: [rendered], timeout: 8)
        guard panes.count == 2 else { return XCTFail("Diff must attach both panes after loading") }
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertFalse(panes[0].isHidden)
        XCTAssertEqual(panes[0].lines.count, panes[1].lines.count)
        XCTAssertTrue(panes[0].lines.contains { $0.kind == .placeholder })
        XCTAssertEqual(panes[1].position(at: panes[1].offsets[4])?.line, 4)
        for pane in panes {
            if let container = pane.text.textContainer { pane.text.layoutManager?.ensureLayout(for: container) }
        }
        let horizontalPositions = panes.map { $0.scroll.contentView.bounds.minX }
        panes[0].scroll.contentView.scroll(to: NSPoint(x: panes[0].scroll.contentView.bounds.minX, y: 340))
        panes[0].scroll.reflectScrolledClipView(panes[0].scroll.contentView)
        XCTAssertGreaterThan(panes[0].scroll.contentView.bounds.minY, 0)
        XCTAssertEqual(panes[0].scroll.contentView.bounds.minY, panes[1].scroll.contentView.bounds.minY, accuracy: 0.5)
        XCTAssertEqual(panes.map { $0.scroll.contentView.bounds.minX }, horizontalPositions)
        panes[1].scroll.contentView.scroll(to: NSPoint(x: panes[1].scroll.contentView.bounds.minX, y: 620))
        panes[1].scroll.reflectScrolledClipView(panes[1].scroll.contentView)
        XCTAssertEqual(panes[0].scroll.contentView.bounds.minY, panes[1].scroll.contentView.bounds.minY, accuracy: 0.5)
        panes[0].sync(to: .zero)
        panes[1].sync(to: .zero)
        if let output = ProcessInfo.processInfo.environment["VCODE_WINDOW_SNAPSHOT"], let bitmap = controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds) {
            controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output))
        }
        let serviceReady = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            find(NSTextField.self, in: controller.view).contains { $0.stringValue == "TypeScript · Ready" }
        }, object: nil)
        wait(for: [serviceReady], timeout: 25)
        let declarationReference = (panes[1].lines[6].text as NSString).range(of: "Workspace", options: .backwards)
        XCTAssertNotEqual(declarationReference.location, NSNotFound)
        panes[1].text.setSelectedRange(NSRange(location: panes[1].offsets[6] + declarationReference.location, length: 0))
        panes[1].text.onInspect?(panes[1].text.selectedRange().location, "definition")
        let definitionOpened = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            panes[0].isHidden && panes[1].position(at: panes[1].text.selectedRange().location)?.line == 0
        }, object: nil)
        wait(for: [definitionOpened], timeout: 25)
        XCTAssertEqual(panes[1].position(at: panes[1].text.selectedRange().location)?.character, 17)
        let destination = try XCTUnwrap(panes[1].text.navigationFlashRange)
        XCTAssertEqual((panes[1].text.string as NSString).substring(with: destination), "Workspace", "A real LSP definition jump must start the destination flash")
        controller.showFiles()
        controller.openFile("src/workspace.ts", diff: false, line: 6, character: 10)
        tree.select("src/workspace.ts")
        let sourceLoaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in panes[0].isHidden && panes[1].text.string == after }, object: nil)
        wait(for: [sourceLoaded], timeout: 8)
        let cursor = panes[1].position(at: panes[1].text.selectedRange().location)
        XCTAssertEqual(cursor?.line, 6)
        XCTAssertEqual(cursor?.character, 10)
        controller.closeTab()
        let restoredDiff = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !panes[0].isHidden }, object: nil)
        wait(for: [restoredDiff], timeout: 8)
        controller.closeTab()
        let editor = try XCTUnwrap(find(EditorView.self, in: controller.view).first)
        XCTAssertFalse(editor.welcome.isHidden)
        XCTAssertTrue(editor.breadcrumbs.isHidden)
        XCTAssertTrue(panes[0].isHiddenOrHasHiddenAncestor)
        XCTAssertNil(editor.activePath)
        withExtendedLifetime(window) {}
    }
}
