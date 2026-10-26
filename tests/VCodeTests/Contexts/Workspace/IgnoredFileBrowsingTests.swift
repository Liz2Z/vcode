import AppKit
import XCTest
@testable import VCode

final class IgnoredFileBrowsingTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory.appendingPathComponent("vcode-ignored-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let git = Process(); git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["-C", root.path, "init", "-q"]
        try git.run(); git.waitUntilExit(); XCTAssertEqual(git.terminationStatus, 0)
        try write(".gitignore", "ignored/\nsecret.env\n")
        try write("main.ts", "searchableNeedle\n")
        try write("secret.env", "excludedNeedle\n")
        try write("ignored/deep/secret.ts", "excludedNeedle\n")
        try write("node_modules/pkg/index.ts", "excludedNeedle\n")
        try write("dist/output.ts", "excludedNeedle\n")
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func write(_ path: String, _ text: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    private func node(_ tree: FileTree, _ path: String) throws -> FileNode {
        try XCTUnwrap((0..<tree.outline.numberOfRows).compactMap { tree.outline.item(atRow: $0) as? FileNode }.first { $0.path == path }, "Missing row: " + path)
    }

    func testGitIgnoredNamesAreMutedIncludingLazyDescendantsButNotTrackedExceptions() throws {
        try write("tracked.ts", "tracked exception\n")
        let git = Process(); git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["-C", root.path, "add", "tracked.ts"]
        try git.run(); git.waitUntilExit(); XCTAssertEqual(git.terminationStatus, 0)
        try write(".gitignore", "ignored/\nsecret.env\ntracked.ts\n*.tmp\n!keep.tmp\n")
        try write("drop.tmp", "ignored\n"); try write("keep.tmp", "exception\n")
        try write("ignored-neighbor.ts", "normal\n")
        let reader = try WorkspaceReader(folder: root), state = try reader.load()
        XCTAssertTrue(state.isGitIgnored("ignored"))
        XCTAssertTrue(state.isGitIgnored("ignored/deep/secret.ts"))
        XCTAssertTrue(state.isGitIgnored("secret.env"))
        XCTAssertFalse(state.isGitIgnored("tracked.ts"))
        XCTAssertFalse(state.isGitIgnored("keep.tmp"))
        XCTAssertFalse(state.isGitIgnored("ignored-neighbor.ts"))
        let tree = FileTree()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = tree
        defer { withExtendedLifetime(window) {} }
        var loaded: [String] = []
        tree.loadDirectory = { loaded.append($0); return try reader.files.children(in: $0) }
        tree.show(state, changesOnly: false)
        XCTAssertTrue(loaded.isEmpty)
        tree.outline.expandItem(try node(tree, "ignored"))
        tree.outline.expandItem(try node(tree, "ignored/deep"))
        XCTAssertEqual(loaded, ["ignored", "ignored/deep"])
        var selected: String?
        tree.onSelect = { path, _ in selected = path }
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearanceName)
            for path in ["ignored", "ignored/deep", "ignored/deep/secret.ts", "secret.env", "drop.tmp", "main.ts", "tracked.ts", "keep.tmp", "ignored-neighbor.ts", "node_modules"] {
                let item = try node(tree, path)
                let row = tree.outline.row(forItem: item)
                let cell = try XCTUnwrap(tree.outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? FileCell)
                let expected = state.isGitIgnored(path) ? Theme.GitStatus.ignored : Theme.text
                XCTAssertEqual(cell.label.attributedStringValue.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, expected, path)
                cell.setRowHovered(true)
                tree.outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                XCTAssertEqual(cell.label.textColor, expected, "Selection must not remove the ignore decoration")
                XCTAssertEqual(cell.label.attributedStringValue.attribute(.strikethroughStyle, at: 0, effectiveRange: nil) as? Int, 0)
            }
        }
        tree.outline.selectRowIndexes(IndexSet(integer: tree.outline.row(forItem: try node(tree, "ignored/deep/secret.ts"))), byExtendingSelection: false)
        XCTAssertEqual(selected, "ignored/deep/secret.ts")
        XCTAssertEqual(try reader.snapshot(path: "ignored/deep/secret.ts", state: state, compare: false).after, "excludedNeedle\n")
    }

    func testChangingOnlyIgnoredDecorationRefreshesRowsWithoutLeavingOldMutedColor() throws {
        let tree = FileTree()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = tree
        defer { withExtendedLifetime(window) {} }
        for ignored: Set<String> in [["secret.env"], [], ["secret.env"]] {
            tree.show(WorkspaceState(root: root, files: ["secret.env", "main.ts"], git: nil, ignoredPaths: ignored), changesOnly: false)
            for path in ["secret.env", "main.ts"] {
                let row = tree.outline.row(forItem: try node(tree, path))
                let cell = try XCTUnwrap(tree.outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? FileCell)
                XCTAssertEqual(cell.label.textColor, ignored.contains(path) ? Theme.GitStatus.ignored : Theme.text)
            }
        }
        tree.show(WorkspaceState(root: root, files: ["secret.env"], git: GitStatus(root: root, branch: "main", changes: [GitChange(path: "secret.env", kind: .modified, comparison: .unstaged)], hasHead: true), ignoredPaths: ["secret.env"]), changesOnly: true)
        let row = tree.outline.row(forItem: try node(tree, "secret.env"))
        let cell = try XCTUnwrap(tree.outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? FileCell)
        XCTAssertEqual(cell.label.textColor, Theme.text, "Changes keeps its existing Git change presentation")
        XCTAssertEqual(cell.badge.stringValue, "M")
    }

    func testDirectoryMarkersNeverBecomeBlankRowsInsideTheirOwnFolder() throws {
        let index = FileTreeIndex(paths: ["src/", "src/empty/", "src/code.ts", "empty/"])
        XCTAssertEqual(index.children(in: "").map(\.path), ["empty", "src"])
        XCTAssertEqual(index.children(in: "src").map(\.path), ["src/empty", "src/code.ts"])
        XCTAssertTrue(index.children(in: "empty").isEmpty)
        XCTAssertTrue(index.children(in: "src/empty").isEmpty)

        try write("src/code.ts", "code\n")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src/empty"), withIntermediateDirectories: true)
        let tree = FileTree(), reader = try WorkspaceReader(folder: root)
        tree.show(try reader.load(), changesOnly: false)
        tree.outline.expandItem(try node(tree, "src"))
        tree.outline.expandItem(try node(tree, "src/empty"))
        let visible = (0..<tree.outline.numberOfRows).compactMap { tree.outline.item(atRow: $0) as? FileNode }
        XCTAssertTrue(visible.allSatisfy { !$0.name.isEmpty }, "Directory markers must not appear as empty file rows")
        XCTAssertEqual(try node(tree, "src").children?.map(\.path), ["src/empty", "src/code.ts"])
    }

    func testBrowseIgnoredFoldersOneLevelAtATimeWithoutAddingThemToSearchOrRecentMatches() throws {
        let reader = try WorkspaceReader(folder: root), state = try reader.load()
        XCTAssertTrue(state.files.contains("secret.env"))
        XCTAssertFalse(state.files.contains("ignored/deep/secret.ts"), "Closed ignored trees must not be scanned recursively")
        XCTAssertTrue(state.deferredDirectories.isSuperset(of: ["ignored", "node_modules", "dist"]))
        XCTAssertEqual(Set(state.searchableFiles), [".gitignore", "main.ts"])
        let tree = FileTree(); var loads: [String] = []
        tree.loadDirectory = { loads.append($0); return try reader.files.children(in: $0) }
        tree.show(state, changesOnly: false)
        XCTAssertTrue(loads.isEmpty)
        XCTAssertNotNil(try node(tree, "secret.env"))
        XCTAssertFalse(tree.outline.isItemExpanded(try node(tree, "ignored")))
        tree.outline.expandItem(try node(tree, "ignored"))
        XCTAssertEqual(loads, ["ignored"])
        XCTAssertFalse((0..<tree.outline.numberOfRows).contains { (tree.outline.item(atRow: $0) as? FileNode)?.path == "ignored/deep/secret.ts" })
        tree.outline.expandItem(try node(tree, "ignored/deep"))
        XCTAssertEqual(loads, ["ignored", "ignored/deep"])
        XCTAssertNotNil(try node(tree, "ignored/deep/secret.ts"))
        XCTAssertEqual(try reader.snapshot(path: "ignored/deep/secret.ts", state: state, compare: false).after, "excludedNeedle\n")
        XCTAssertTrue(QuickOpenIndex(paths: state.searchableFiles).matches("secret", recent: ["secret.env", "ignored/deep/secret.ts"]).isEmpty)
        XCTAssertTrue(try RipgrepSearch().run(root: root, paths: state.searchableFiles, query: ProjectSearchQuery(text: "excludedNeedle")).matches.isEmpty)
        XCTAssertEqual(try RipgrepSearch().run(root: root, paths: state.searchableFiles, query: ProjectSearchQuery(text: "searchableNeedle")).matches.map(\.path), ["main.ts"])
        let saved = tree.captureSession()
        tree.restoreSession(FileTreeReadingState(expanded: [], collapsed: [], selection: nil, query: "secret", scrollOffset: 0))
        XCTAssertEqual(tree.outline.numberOfRows, 0, "Sidebar matching must also exclude ignored files")
        tree.restoreSession(saved)
        XCTAssertNotNil(try node(tree, "ignored/deep/secret.ts"))
    }

    func testRefreshReopenAndRestoreSeeCurrentIgnoredContentsWithoutTraversingDirectoryLinks() throws {
        let reader = try WorkspaceReader(folder: root)
        let tree = FileTree()
        tree.loadDirectory = { try reader.files.children(in: $0) }
        tree.show(try reader.load(), changesOnly: false)
        tree.select("ignored/deep/secret.ts")
        let saved = tree.captureSession()
        try write("ignored/deep/new.ts", "new\n")
        try FileManager.default.removeItem(at: root.appendingPathComponent("ignored/deep/secret.ts"))
        tree.show(try reader.load(), changesOnly: false)
        XCTAssertNotNil(try node(tree, "ignored/deep/new.ts"))
        XCTAssertFalse((0..<tree.outline.numberOfRows).contains { (tree.outline.item(atRow: $0) as? FileNode)?.path == "ignored/deep/secret.ts" })
        let ignored = try node(tree, "ignored")
        tree.outline.collapseItem(ignored)
        try write("ignored/fresh.ts", "fresh\n")
        tree.outline.expandItem(ignored)
        XCTAssertNotNil(try node(tree, "ignored/fresh.ts"))
        let restored = FileTree(); restored.loadDirectory = { try reader.files.children(in: $0) }
        restored.show(try reader.load(), changesOnly: false); restored.restoreSession(saved)
        XCTAssertNotNil(try node(restored, "ignored/deep/new.ts"))
        let outside = root.deletingLastPathComponent()
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("ignored/link"), withDestinationURL: outside)
        XCTAssertFalse(try XCTUnwrap(reader.files.children(in: "ignored").first { $0.name == "link" }).directory)
        XCTAssertThrowsError(try reader.files.children(in: "ignored/link"))
        XCTAssertThrowsError(try reader.files.children(in: "../"))
    }

    func testVisibleIgnoredFoldersAndOpenedFilesReceiveExternalChanges() throws {
        let session = WorkspaceSession()
        defer { session.close() }
        let opened = expectation(description: "Workspace opened")
        session.open(root) { result in
            if case .failure(let error) = result { XCTFail(error.localizedDescription) }
            opened.fulfill()
        }
        wait(for: [opened], timeout: 5)
        session.inspectedDirectories = ["node_modules", "node_modules/pkg"]
        let changed = expectation(description: "Visible dependency folder receives changes")
        session.onRefresh = { _ in session.onRefresh = nil; changed.fulfill() }
        try write("node_modules/pkg/new.ts", "new\n")
        wait(for: [changed], timeout: 5)
        let read = expectation(description: "Open ignored source")
        session.read("node_modules/pkg/index.ts", diff: false) { _ in read.fulfill() }
        wait(for: [read], timeout: 5)
        session.inspectedDirectories = []
        let updated = expectation(description: "Opened ignored source stays watched after collapsing its folder")
        session.onRefresh = { _ in
            session.onRefresh = nil
            session.read("node_modules/pkg/index.ts", diff: false) { result in
                if case .success(let snapshot) = result { XCTAssertEqual(snapshot.after, "updated\n") }
                else { XCTFail("Could not reread ignored source") }
                updated.fulfill()
            }
        }
        try write("node_modules/pkg/index.ts", "updated\n")
        wait(for: [updated], timeout: 5)
    }

    func testLazyDirectoriesKeepEmptyFoldersAndDoNotScanLargeUnopenedSubtrees() throws {
        for i in 0..<300 { try write("ignored/pkg\(i)/nested/file.ts", "excluded\n") }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("empty"), withIntermediateDirectories: true)
        let reader = try WorkspaceReader(folder: root), state = try reader.load()
        XCTAssertEqual(state.files.count, 3)
        XCTAssertTrue(state.directories.contains("empty"))
        let tree = FileTree(); var loads: [String] = []
        tree.loadDirectory = { loads.append($0); return try reader.files.children(in: $0) }
        tree.show(state, changesOnly: false)
        XCTAssertTrue(loads.isEmpty)
        tree.outline.expandItem(try node(tree, "ignored"))
        XCTAssertEqual(loads, ["ignored"])
        XCTAssertEqual((try node(tree, "ignored")).children?.count, 301)
        XCTAssertFalse(loads.contains { $0.contains("nested") })
    }
}
