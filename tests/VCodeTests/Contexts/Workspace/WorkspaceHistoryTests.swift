import AppKit
import XCTest
@testable import VCode

final class WorkspaceHistoryTests: XCTestCase {
    private func directory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vcode-history-store-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func state(_ path: String, branch: String = "main", project: GitProject? = nil) -> WorkspaceState {
        let root = URL(fileURLWithPath: path, isDirectory: true)
        return WorkspaceState(root: root, files: [], git: project.map { _ in GitStatus(root: root, branch: branch, files: [], changes: [], hasHead: true) }, project: project)
    }

    func testPersistenceDeduplicationRefreshAndLimit() {
        let directory = directory()
        let store = WorkspaceHistoryStore(directory: directory, legacyDefaults: nil)
        let project = GitProject(commonDirectory: URL(fileURLWithPath: "/tmp/project/.git"), primaryRoot: URL(fileURLWithPath: "/tmp/project"))
        store.record(state("/tmp/project", project: project), at: Date(timeIntervalSince1970: 1))
        store.record(state("/tmp/linked", project: project), at: Date(timeIntervalSince1970: 2))
        store.update(state("/tmp/project", branch: "updated", project: project))
        XCTAssertEqual(store.entries.map(\.root.lastPathComponent), ["linked", "project"])
        XCTAssertEqual(store.entries.last?.branch, "updated")
        store.record(state("/tmp/project", branch: "updated", project: project), at: Date(timeIntervalSince1970: 3))
        let restored = WorkspaceHistoryStore(directory: directory, legacyDefaults: nil)
        XCTAssertEqual(restored.entries, store.entries)
        XCTAssertEqual(restored.entries.count, 2)
        XCTAssertEqual(restored.entries.first?.root.lastPathComponent, "project")
        for index in 0..<50 { store.record(state("/tmp/folder-\(index)")) }
        XCTAssertEqual(store.entries.count, WorkspaceHistoryStore.limit)
        XCTAssertEqual(WorkspaceHistoryStore(directory: directory, legacyDefaults: nil).entries.first?.root.lastPathComponent, "folder-49")
    }

    func testProjectGroupingKeepsSameNameRepositoriesSeparateAndFiltersWorktrees() {
        let first = GitProject(commonDirectory: URL(fileURLWithPath: "/tmp/a/project/.git"), primaryRoot: URL(fileURLWithPath: "/tmp/a/project"))
        let second = GitProject(commonDirectory: URL(fileURLWithPath: "/tmp/b/project/.git"), primaryRoot: URL(fileURLWithPath: "/tmp/b/project"))
        let entries = [
            RecentWorkspace(state: state("/tmp/a/project", project: first), openedAt: Date(timeIntervalSince1970: 1)),
            RecentWorkspace(state: state("/tmp/linked", branch: "feature", project: first), openedAt: Date(timeIntervalSince1970: 3)),
            RecentWorkspace(state: state("/tmp/b/project", project: second), openedAt: Date(timeIntervalSince1970: 2))
        ]
        let grouped = RecentProject.group(entries)
        XCTAssertEqual(grouped.count, 2)
        XCTAssertEqual(grouped.first?.workspaces.map(\.root.lastPathComponent), ["linked", "project"])
        XCTAssertEqual(RecentProject.group(entries, matching: "feature").first?.workspaces.count, 1)
        XCTAssertTrue(RecentProject.group(entries, matching: "nothing matches").isEmpty)
        let directory = directory()
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try! Data("bad history".utf8).write(to: directory.appendingPathComponent("workspace.json"))
        XCTAssertTrue(WorkspaceHistoryStore(directory: directory, legacyDefaults: nil).entries.isEmpty)
    }

    func testPickerGuardsCurrentMissingRowsAndKeepsTextVisible() throws {
        _ = NSApplication.shared
        let available = state("/tmp/available")
        let current = state("/tmp/current")
        let missing = state("/tmp/missing")
        let entries = [available, current, missing].enumerated().map { RecentWorkspace(state: $0.element, openedAt: Date(timeIntervalSince1970: Double($0.offset))) }
        let picker = WorkspaceHistoryPicker(entries: entries, current: current.root, available: { $0 != missing.root })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 440), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = picker
        window.contentView?.layoutSubtreeIfNeeded()
        defer { window.close() }
        XCTAssertEqual(picker.table.numberOfRows, 6)
        XCTAssertFalse(picker.tableView(picker.table, shouldSelectRow: 1))
        XCTAssertFalse(picker.tableView(picker.table, shouldSelectRow: 3))
        XCTAssertTrue(picker.tableView(picker.table, shouldSelectRow: 5))
        let cell = try XCTUnwrap(picker.table.view(atColumn: 0, row: 5, makeIfNecessary: true))
        cell.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(cell.frame.width, 400)
        var chosen: URL?
        picker.onChoose = { chosen = $0 }
        picker.table.selectRowIndexes(IndexSet(integer: 5), byExtendingSelection: false)
        XCTAssertTrue(picker.table.sendAction(picker.table.action, to: picker.table.target))
        XCTAssertEqual(chosen, available.root)
        picker.filter.stringValue = "missing"
        _ = picker.filter.sendAction(picker.filter.action, to: picker.filter.target)
        XCTAssertEqual(picker.table.numberOfRows, 2)
        picker.filter.stringValue = "absent"
        _ = picker.filter.sendAction(picker.filter.action, to: picker.filter.target)
        XCTAssertEqual(picker.table.numberOfRows, 0)
    }

    func testActualGitWorktreesShareIdentityAndControllerRecordsSuccessfulVisits() throws {
        _ = NSApplication.shared
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("vcode-history-" + UUID().uuidString)
        let primary = base.appendingPathComponent("project")
        let linked = base.appendingPathComponent("feature-worktree")
        try FileManager.default.createDirectory(at: primary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        func git(_ args: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", primary.path, "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"] + args
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, "\(args)")
        }
        try git(["init", "-q", "-b", "main"])
        try git(["-c", "user.name=Test", "-c", "user.email=test@localhost", "commit", "--allow-empty", "-qm", "initial"])
        try git(["worktree", "add", "-qb", "feature", linked.path])
        let a = try WorkspaceReader(folder: primary).load()
        let b = try WorkspaceReader(folder: linked).load()
        XCTAssertEqual(a.project?.commonDirectory, b.project?.commonDirectory)
        XCTAssertEqual(b.project?.primaryRoot, primary.resolvingSymlinksInPath())
        let history = WorkspaceHistoryStore(directory: directory(), legacyDefaults: nil)
        let controller = WorkspaceController(history: history)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 580), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        defer { controller.shutdown(); window.close() }
        controller.open(primary)
        wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in history.entries.count == 1 }, object: nil)], timeout: 10)
        let switched = expectation(description: "Worktree visits use the same history")
        controller.activate(.worktree(linked.resolvingSymlinksInPath())) { result in
            XCTAssertEqual(try? result.get().branch, "feature")
            switched.fulfill()
        }
        wait(for: [switched], timeout: 10)
        XCTAssertEqual(history.entries.count, 2)
        XCTAssertEqual(RecentProject.group(history.entries).count, 1)
        XCTAssertEqual(history.entries.first?.branch, "feature")
        controller.showHistory()
        let picker = try XCTUnwrap(controller.children.compactMap { $0 as? WorkspaceHistoryPicker }.first)
        XCTAssertTrue(window.firstResponder === picker.filter.currentEditor())
        XCTAssertTrue(picker.control(picker.filter, textView: NSTextView(), doCommandBy: #selector(NSResponder.moveDown(_:))))
        XCTAssertEqual(picker.table.selectedRow, 2)
        XCTAssertTrue(controller.children.contains { $0 === picker }, "Selecting with Down must not close the panel")
        controller.showHistory()
        XCTAssertFalse(controller.children.contains { $0 === picker })
        controller.open(base.appendingPathComponent("missing"))
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(history.entries.count, 2)
    }
}
