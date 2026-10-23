import AppKit
import XCTest
@testable import VCode

final class ProjectSearchTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory.appendingPathComponent("vcode-search-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    @discardableResult private func write(_ path: String, _ content: String) throws -> String {
        let file = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: file, atomically: true, encoding: .utf8)
        return path
    }
    private func search(_ query: ProjectSearchQuery, paths: [String]? = nil, limit: Int = 2000) throws -> ProjectSearchResults {
        try RipgrepSearch().run(root: root, paths: paths ?? SourceFileStore(root: root).list(), query: query, limit: limit)
    }

    func testLiteralCaseWordAndRegexUseRealRipgrepAndUTF16Positions() throws {
        try write("src/main.ts", "🚀 const value = 'needle NEEDLE needled _needle';\r\nsecond needle\n")
        try write("src/other.ts", "Needle\n")
        let literal = try search(ProjectSearchQuery(text: "needle"))
        XCTAssertEqual(literal.matches.count, 3)
        XCTAssertEqual(literal.matches[0].ranges.count, 4)
        XCTAssertEqual(literal.matches[0].character, ("🚀 const value = '" as NSString).length)
        let sensitive = try search(ProjectSearchQuery(text: "needle", caseSensitive: true, wholeWord: true))
        XCTAssertEqual(sensitive.matches.count, 2)
        XCTAssertTrue(sensitive.matches.allSatisfy { $0.path == "src/main.ts" && $0.ranges.count == 1 })
        let regex = try search(ProjectSearchQuery(text: "n[e]+dle", wholeWord: true, regularExpression: true))
        XCTAssertEqual(regex.matches.reduce(0) { $0 + $1.ranges.count }, 4)
        try write("src/literal.ts", "a.b\naxb\n")
        XCTAssertEqual(try search(ProjectSearchQuery(text: "a.b"), paths: ["src/literal.ts"]).matches.count, 1)
        XCTAssertEqual(try search(ProjectSearchQuery(text: "a.b", regularExpression: true), paths: ["src/literal.ts"]).matches.count, 2)
        XCTAssertThrowsError(try search(ProjectSearchQuery(text: "[", regularExpression: true)))
        XCTAssertThrowsError(try search(ProjectSearchQuery(text: "[", regularExpression: true), paths: []))
    }

    func testExclusionsFileScopeUnusualNamesAndSymlinks() throws {
        let paths = try [write("src/main.ts", "needle\n"), write("tests/spec.ts", "needle\n"), write("src/generated/a.ts", "needle\n"), write("nested/tests/b.ts", "needle\n"), write("src/space and\nnewline.ts", "中文 🚀 needle\n"), write("-dash.ts", "needle\n")]
        try write("not-in-file-list.ts", "needle\n")
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link.ts").path, withDestinationPath: root.appendingPathComponent("src/main.ts").path)
        let output = try search(ProjectSearchQuery(text: "needle", excludedFolders: "tests, src/generated/"), paths: paths + ["link.ts", "../outside.ts", "/etc/hosts"])
        XCTAssertEqual(Set(output.matches.map(\.path)), ["src/main.ts", "src/space and\nnewline.ts", "-dash.ts"])
        XCTAssertEqual(output.skippedFiles, 3)
        let unicode = try XCTUnwrap(output.matches.first { $0.path.contains("newline") })
        XCTAssertEqual(unicode.character, ("中文 🚀 " as NSString).length)
        XCTAssertEqual(try search(ProjectSearchQuery(text: "needle", excludedFolders: "**/generated/**, tests"), paths: paths).matches.count, 3)
    }

    func testLimitsBinaryFilesLargeFilesBatchesAndCancelledRequests() throws {
        try write("many.ts", String(repeating: "needle\n", count: 20))
        let limited = try search(ProjectSearchQuery(text: "needle"), paths: ["many.ts"], limit: 3)
        XCTAssertEqual(limited.matches.count, 3); XCTAssertTrue(limited.limited)
        try Data("needle\n\0binary needle".utf8).write(to: root.appendingPathComponent("binary.dat"))
        try Data(repeating: 65, count: RipgrepSearch.maximumFileBytes + 1).write(to: root.appendingPathComponent("large.ts"))
        let skipped = try search(ProjectSearchQuery(text: "needle"), paths: ["binary.dat", "large.ts"])
        XCTAssertTrue(skipped.matches.isEmpty); XCTAssertEqual(skipped.skippedFiles, 1)
        var files: [String] = []
        for index in 0..<405 { files.append(try write("batch/\(index).ts", "needle\n")) }
        XCTAssertEqual(try search(ProjectSearchQuery(text: "needle"), paths: files).matches.count, 405)
        let cancelled = ProjectSearchTask(); cancelled.cancel()
        XCTAssertThrowsError(try RipgrepSearch().run(root: root, paths: files, query: ProjectSearchQuery(text: "needle"), task: cancelled))
        let late = expectation(description: "Cancelled request is never delivered"); late.isInverted = true
        let task = RipgrepSearch().search(root: root, paths: files, query: ProjectSearchQuery(text: "needle")) { _ in late.fulfill() }
        task.cancel(); wait(for: [late], timeout: 0.3)
        XCTAssertThrowsError(try RipgrepSearch(executable: nil).run(root: root, paths: files, query: ProjectSearchQuery(text: "needle")))
    }

    func testSearchUsesWorkspaceIgnoreRulesAndKeepsTrackedExceptions() throws {
        try write("generated/keep.ts", "needle\n")
        func git(_ arguments: [String]) throws {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", root.path] + arguments
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
        }
        try git(["init", "-q"]); try git(["add", "generated/keep.ts"])
        try write(".gitignore", "generated/\ncache/\n")
        try write("generated/untracked.ts", "needle\n"); try write("cache/data.ts", "needle\n")
        let state = try WorkspaceReader(folder: root).load()
        XCTAssertTrue(state.files.contains("generated/keep.ts"))
        XCTAssertFalse(state.files.contains("generated/untracked.ts")); XCTAssertFalse(state.files.contains("cache/data.ts"))
        XCTAssertEqual(try search(ProjectSearchQuery(text: "needle"), paths: state.files).matches.map(\.path), ["generated/keep.ts"])
    }

    func testQuickOpenFuzzyRankingRecentFilesAndPersistence() throws {
        let paths = ["src/config.ts", "tests/config.ts", "src/components/QuickOpen.swift", "README.md", "Café.ts"]
        let index = QuickOpenIndex(paths: paths)
        XCTAssertEqual(Array(index.matches("", recent: ["missing.ts", "README.md", "tests/config.ts"]).prefix(2)), ["README.md", "tests/config.ts"])
        XCTAssertEqual(index.matches("config", recent: ["tests/config.ts"]).first, "tests/config.ts")
        XCTAssertEqual(index.matches("sct", recent: []), ["src/config.ts", "src/components/QuickOpen.swift", "tests/config.ts"])
        XCTAssertEqual(index.matches("srccfg", recent: []), ["src/config.ts"])
        XCTAssertEqual(index.matches("src QuickOpen", recent: []), ["src/components/QuickOpen.swift"])
        XCTAssertEqual(index.matches("cafe", recent: []), ["Café.ts"])
        XCTAssertTrue(index.matches("zzzz", recent: []).isEmpty)
        XCTAssertEqual(index.matches("", recent: [], limit: 2).count, 2)
        let store = WorkspaceHistoryStore(directory: root.appendingPathComponent("state"), legacyDefaults: nil)
        let other = root.appendingPathComponent("other")
        store.record(WorkspaceState(root: root, files: paths, git: nil)); store.record(WorkspaceState(root: other, files: paths, git: nil))
        store.recordFile("README.md", in: root); store.recordFile("src/config.ts", in: root)
        store.recordFile("README.md", in: root); store.recordFile("tests/config.ts", in: other)
        XCTAssertEqual(store.recentFiles(in: root), ["README.md", "src/config.ts"])
        store.renameFiles(["src/config.ts": "src/settings.ts"], in: root)
        let restored = WorkspaceHistoryStore(directory: store.file.deletingLastPathComponent(), legacyDefaults: nil)
        XCTAssertEqual(restored.recentFiles(in: root), ["README.md", "src/settings.ts"])
        XCTAssertEqual(restored.recentFiles(in: other), ["tests/config.ts"])
        let old = root.appendingPathComponent("old-state")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("{\"version\":1,\"entries\":[]}".utf8).write(to: old.appendingPathComponent("workspace.json"))
        XCTAssertNil(WorkspaceHistoryStore(directory: old, legacyDefaults: nil).persistenceError)
    }

    func testSearchSidebarQuickOpenSplitSelectionMarkdownAndWorkspaceChanges() throws {
        try write("src/alpha.ts", "// first\n🚀 needle\n")
        try write("docs/readme.md", "# Heading\n\nneedle markdown\n")
        let controller = WorkspaceController(history: WorkspaceHistoryStore(directory: root.appendingPathComponent(".state"), legacyDefaults: nil))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentViewController = controller
        defer { controller.shutdown(); withExtendedLifetime(window) {} }
        let workspace = try XCTUnwrap(controller.view as? WorkspaceView)
        controller.open(root)
        waitUntil { workspace.header.worktreeButton.title == self.root.lastPathComponent }
        controller.openFile("src/alpha.ts", diff: false)
        waitUntil { workspace.editor.right.text.string.contains("needle") }
        let left = workspace.editor
        workspace.editorGroups.splitActiveEditor()
        let right = workspace.editor
        XCTAssertFalse(left === right)
        controller.showQuickOpen()
        let picker = try XCTUnwrap(controller.quickOpen)
        waitUntil { !picker.rows.isEmpty }
        XCTAssertEqual(picker.rows.first, "src/alpha.ts")
        picker.filter.stringValue = "readme"; picker.findFiles()
        waitUntil { picker.rows == ["docs/readme.md"] }
        picker.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        XCTAssertTrue(NSApp.sendAction(picker.table.action!, to: picker.table.target, from: picker.table))
        XCTAssertNil(controller.quickOpen)
        waitUntil { right.showingMarkdownPreview && !right.markdown.isRendering }
        XCTAssertEqual(left.activePath, "src/alpha.ts")
        workspace.navigation.search.performClick(nil)
        XCTAssertFalse(workspace.searchHost.isHidden); XCTAssertTrue(workspace.explorer.isHidden)
        XCTAssertTrue(workspace.navigation.search.isSelected)
        XCTAssertFalse(workspace.navigation.files.isSelected)
        XCTAssertFalse(workspace.navigation.changes.isSelected)
        let search = controller.projectSearch
        search.query.stringValue = "needle"
        search.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search.query))
        waitUntil { !search.isSearching && search.rows.count == 4 }
        XCTAssertTrue(search.status.stringValue.contains("2 files"))
        let row = try XCTUnwrap(search.rows.firstIndex { if case .match(let match) = $0 { return match.path == "docs/readme.md" }; return false })
        search.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        XCTAssertTrue(NSApp.sendAction(search.table.action!, to: search.table.target, from: search.table))
        waitUntil { !right.showingMarkdownPreview && right.right.text.selectedRange().location == ("# Heading\n\n" as NSString).length }
        XCTAssertEqual(left.activePath, "src/alpha.ts")
        controller.showFiles()
        XCTAssertTrue(workspace.searchHost.isHidden); XCTAssertFalse(workspace.explorer.isHidden)
        XCTAssertFalse(workspace.navigation.search.isSelected)
        workspace.navigation.changes.performClick(nil)
        XCTAssertTrue(workspace.navigation.changes.isSelected)
        workspace.navigation.search.performClick(nil)
        XCTAssertEqual(search.query.stringValue, "needle")
        XCTAssertTrue(workspace.navigation.search.isSelected)
        XCTAssertFalse(workspace.navigation.changes.isSelected)
        search.query.stringValue = "["; search.regexButton.isSelected = true
        search.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search.query))
        waitUntil { !search.isSearching && search.status.textColor == Theme.red }
        search.query.stringValue = "needle"; search.regexButton.isSelected = false
        search.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search.query))
        let another = root.appendingPathComponent("another")
        try FileManager.default.createDirectory(at: another, withIntermediateDirectories: true)
        controller.open(another)
        waitUntil { workspace.header.worktreeButton.title == "another" }
        // Leaving search for a new workspace restores the last tree mode.
        XCTAssertTrue(workspace.navigation.changes.isSelected)
        XCTAssertFalse(workspace.navigation.search.isSelected)
        XCTAssertTrue(search.rows.isEmpty); XCTAssertEqual(search.query.stringValue, "")
        controller.showQuickOpen(); controller.showHistory(); XCTAssertNil(controller.quickOpen)
    }

    private func waitUntil(_ condition: @escaping () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        let item = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [item], timeout: 10), .completed, file: file, line: line)
    }

    func testLargeQuickOpenIndexAndRapidQueriesKeepOnlyLatestRows() throws {
        let paths = (0..<20_000).map { "packages/module-\($0)/src/unique-file-\($0).ts" }
        let started = Date()
        let index = QuickOpenIndex(paths: paths)
        XCTAssertEqual(index.matches("unique-file-19876", recent: []).first, paths[19876])
        XCTAssertEqual(index.matches("", recent: [paths[19876]]).first, paths[19876])
        XCTAssertEqual(index.matches("file", recent: []).count, 100)
        print("Quick Open 20,000 paths: index and three queries \(Date().timeIntervalSince(started)) seconds")
        let picker = QuickOpenPicker(paths: paths, recent: [])
        _ = picker.view
        picker.filter.stringValue = "19876"; picker.findFiles()
        picker.filter.stringValue = "19877"; picker.findFiles()
        waitUntil { picker.rows.first == paths[19877] }
        XCTAssertEqual(picker.rows, index.matches("19877", recent: []))
    }

    func testSearchControlsFitMinimumSidebarAndExposeOptionState() throws {
        let search = ProjectSearchController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 220, height: 580), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentViewController = search
        window.setContentSize(NSSize(width: 220, height: 580))
        defer { withExtendedLifetime(window) {} }
        search.view.layoutSubtreeIfNeeded()
        let buttons = [search.caseButton, search.wordButton, search.regexButton]
        for button in buttons {
            let rect = button.convert(button.bounds, to: search.view)
            XCTAssertTrue(search.view.bounds.contains(rect))
            XCTAssertGreaterThanOrEqual(rect.height, 28)
            XCTAssertFalse(button.isSelected)
            button.performClick(nil)
            XCTAssertTrue(button.isSelected)
        }
        XCTAssertGreaterThan(search.query.frame.width, 180)
        XCTAssertGreaterThan(search.exclusions.frame.width, 180)
    }

    func testThreeSidebarDestinationsKeepFullTitlesAcrossMinimumWidthResize() {
        let navigation = WorkspaceNavigation()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 220, height: 40), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = navigation
        defer { withExtendedLifetime(window) {} }
        for width: CGFloat in [220, 500, 220] {
            window.setContentSize(NSSize(width: width, height: 40))
            navigation.layoutSubtreeIfNeeded()
            let buttons = [navigation.files, navigation.changes, navigation.search]
            for button in buttons {
                XCTAssertTrue(navigation.bounds.contains(button.frame))
                let textWidth = (button.title as NSString).size(withAttributes: [.font: button.font!]).width
                XCTAssertGreaterThanOrEqual(button.frame.width, ceil(textWidth) + 2 * button.horizontalPadding)
            }
            XCTAssertLessThan(navigation.files.frame.maxX, navigation.changes.frame.minX)
            XCTAssertLessThan(navigation.changes.frame.maxX, navigation.search.frame.minX)
        }
    }
}
